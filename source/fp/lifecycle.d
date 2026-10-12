/// The lifetimes of the elements libfp containers hold: how an element is copied, moved, and ended.
///
/// A container keeps every slot it has allocated in one of two states: live, or empty, which is all zero bytes. Copying, moving and ending an element goes through a convention the element type declares, in this order of preference:
/// $(UL
///   $(LI `finalize()` ends the element's lifetime. It must be safe on an empty value and leave it empty.)
///   $(LI `moveTo(ref T dest)` moves into an empty `dest` and leaves the source empty. Without it, a move is a bit copy followed by zeroing the source.)
///   $(LI `copyTo(ref T dest)` deep-copies into an empty `dest`. Without it, a copy is assignment, which runs a postblit if the type has one.)
/// )
/// D's `~this` is honoured too, when the type has no `finalize`. A type whose lifetime is its bytes (`isBitMoveable!T`) declares none of these, and every operation on it stays a `memcpy`, so `fp.string` and arrays of numbers are unaffected.
///
/// A fat pointer element is one of those: a container of `char*` holds addresses, not owners, and freeing it does not free what they point at. To make a container own its elements, put them in `Owned`, which declares the hooks and frees what it points at.
///
/// A container function that takes an element by value takes over that copy's lifetime: it is moved into the container, or ended when the call does not keep it. Lookups do not take over the caller's element, but they do end the copy they make.
///
/// Plain assignment to a slot that already holds an element is a bit copy and does not end the previous one's lifetime; replace a live slot with `moveInto` or `copyInto`.
///
/// A type whose destructor releases resources must make its copies independent, with a postblit or `copyTo`: D runs `~this` on every copy it makes, and a copy with no copy constructor is a bit copy aliasing the original, so the same resources would be released more than once.
///
/// Every hook, and any `~this` or postblit, must be `@nogc nothrow`, because libfp calls them from `@nogc` code.
///
/// Examples:
/// ---
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// Owned* slot = fp.pointer.malloc!Owned(2);
/// scope(exit) fp.pointer.free(slot);
/// slot[0].data = cast(int*) 1;
/// fp.lifecycle.moveInto(slot[1], slot[0]);
/// assert(slot[0].data is null && slot[1].data == cast(int*) 1);
/// fp.lifecycle.endLifetime(slot[1]);
/// ---
module fp.lifecycle;

import core.stdc.string;

static import fp.pointer;
static import fp.dynarray;
static import fp.hashtable;


@nogc nothrow:


private template hasFinalize(T) { enum hasFinalize = __traits(hasMember, T, "finalize"); }
private template hasMoveTo(T) { enum hasMoveTo = __traits(hasMember, T, "moveTo"); }
private template hasCopyTo(T) { enum hasCopyTo = __traits(hasMember, T, "copyTo"); }
// `~this` and `this(this)` have no callable names; the compiler stores them under these. Both must be `@nogc nothrow`, as libfp calls them from `@nogc` code.
private template hasDestructor(T) { enum hasDestructor = __traits(hasMember, T, "__xdtor"); }
private template hasPostblit(T) { enum hasPostblit = __traits(hasMember, T, "__postblit"); }

// A member that is not an expression, like a type alias in an opaque C struct, is not a field and holds no lifetime.
private template memberBitMoveable(T, string name) {
	static if (!__traits(compiles, typeof(__traits(getMember, T, name))))
		enum memberBitMoveable = true;
	else
		enum memberBitMoveable = isBitMoveable!(typeof(__traits(getMember, T, name)));
}

private template membersBitMoveable(T, size_t i = 0) {
	static if (i >= __traits(allMembers, T).length)
		enum membersBitMoveable = true;
	else static if (memberBitMoveable!(T, __traits(allMembers, T)[i]))
		enum membersBitMoveable = membersBitMoveable!(T, i + 1);
	else
		enum membersBitMoveable = false;
}

/// Whether `T`'s lifetime is exactly its bytes, so every operation on it is a `memcpy`: no `finalize`, `moveTo`, `copyTo`, postblit or destructor, and no member that has one.
///
/// Examples:
/// ---
/// static assert(isBitMoveable!long && isBitMoveable!(char[8]));
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// static assert(!isBitMoveable!Owned);
/// ---
template isBitMoveable(T) {
	static if (is(T == struct)) {
		enum isBitMoveable = !hasFinalize!T && !hasMoveTo!T && !hasCopyTo!T && !hasDestructor!T && !hasPostblit!T && membersBitMoveable!(T);
	} else static if (is(T == U[N], U, size_t N)) {
		enum isBitMoveable = isBitMoveable!U;
	} else {
		enum isBitMoveable = true;
	}
}

/// Makes `count` slots at `p` fit to hold elements: does nothing when their lifetime is their bytes, zeroes them otherwise, so a spare slot is always empty.
///
/// Examples:
/// ---
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// Owned[2] slots;
/// initSlots(slots.ptr, 2);
/// endLifetime(slots[0]); // safe: the slot was made empty
/// assert(slots[0].data is null);
/// ---
void initSlots(T)(T* p, size_t count) @trusted {
	static if (!isBitMoveable!T) {
		if (p is null || count == 0) return;
		core.stdc.string.memset(p, 0, T.sizeof * count);
	}
}

/// Ends `e`'s lifetime, leaving it empty: `finalize()` if `T` has one, else its `~this`, else nothing. Safe on an already empty `e`.
///
/// Examples:
/// ---
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// Owned e;
/// e.data = cast(int*) 1;
/// endLifetime(e);
/// assert(e.data is null);
/// endLifetime(e); // empty: a no-op
/// ---
void endLifetime(T)(ref T e) {
	static if (hasFinalize!T) e.finalize();
	else static if (hasDestructor!T) __traits(getMember, e, "__xdtor")();
}

/// Moves `src` into `dest`, ending whatever `dest` held and leaving `src` empty.
///
/// Examples:
/// ---
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// Owned from, to;
/// from.data = cast(int*) 1;
/// moveInto(to, from);
/// assert(to.data == cast(int*) 1 && from.data is null);
/// ---
void moveInto(T)(ref T dest, ref T src) @trusted {
	static if (isBitMoveable!T) core.stdc.string.memcpy(&dest, &src, T.sizeof);
	else static if (hasMoveTo!T) { endLifetime(dest); src.moveTo(dest); }
	else {
		endLifetime(dest);
		core.stdc.string.memcpy(&dest, &src, T.sizeof);
		core.stdc.string.memset(&src, 0, T.sizeof);
	}
}

/// Copies `src` into `dest`, ending whatever `dest` held. Uses `copyTo` if `T` has one, otherwise assignment, which runs a postblit if `T` has one.
///
/// Examples:
/// ---
/// struct Owned { int* data; void copyTo(ref Owned dest) @nogc nothrow { dest.data = data; } }
/// Owned from, to;
/// from.data = cast(int*) 1;
/// copyInto(to, from);
/// assert(to.data == from.data);
/// ---
void copyInto(T)(ref T dest, ref T src) @trusted {
	static if (isBitMoveable!T) core.stdc.string.memcpy(&dest, &src, T.sizeof);
	else static if (hasCopyTo!T) {
		endLifetime(dest);
		src.copyTo(dest);
	} else {
		endLifetime(dest);
		dest = src; // assignment runs a postblit, which cannot see `dest`'s old bytes, so the lifetime ends first
	}
}

/// Ends the lifetime of `copy`, a bit copy of another element that the caller does not store. When `T` has a copy constructor, the value copied is itself a copy that owns its resources, so they are released here; otherwise the copy aliases the original, so it is only zeroed: the original keeps the resources, and a destructor now sees the empty state.
///
/// Examples:
/// ---
/// struct Handle { int* data; ~this() @nogc nothrow { data = null; } }
/// Handle original;
/// original.data = cast(int*) 1;
/// Handle copy = original;
/// endCopyLifetime(copy);
/// assert(copy.data is null && original.data == cast(int*) 1);
/// ---
void endCopyLifetime(T)(ref T copy) {
	static if (!isBitMoveable!T) {
		static if (hasPostblit!T) endLifetime(copy);
		else initSlots(&copy, 1); // the copy shares the original's resources, so it must be emptied rather than ended
	}
}

/// Ends the lifetime of `copy`, a value made by `copyInto` that the caller does not store. It owns what it holds when `T` deep-copies, with `copyTo` or a postblit; otherwise the copy is a bit copy aliasing the original, so it is only zeroed.
///
/// Examples:
/// ---
/// struct Handle { int* data; void copyTo(ref Handle dest) @nogc nothrow { dest.data = data; } void finalize() @nogc nothrow { data = null; } }
/// Handle original, copy;
/// original.data = cast(int*) 1;
/// copyInto(copy, original);
/// endCopiedLifetime(copy);
/// assert(copy.data is null && original.data == cast(int*) 1);
/// ---
void endCopiedLifetime(T)(ref T copy) {
	static if (!isBitMoveable!T) {
		static if (hasCopyTo!T || hasPostblit!T) endLifetime(copy);
		else initSlots(&copy, 1); // a bit copy, so the original still owns the resources
	}
}

/// Exchanges the two elements' lifetimes.
///
/// Examples:
/// ---
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// Owned a, b;
/// a.data = cast(int*) 1;
/// b.data = cast(int*) 2;
/// swapInto(a, b);
/// assert(a.data == cast(int*) 2 && b.data == cast(int*) 1);
/// ---
void swapInto(T)(ref T a, ref T b) @trusted {
	static if (hasMoveTo!T) {
		T scratch;
		moveInto(scratch, a);
		moveInto(a, b);
		moveInto(b, scratch);
	} else {
		ubyte[T.sizeof] scratch;
		core.stdc.string.memcpy(scratch.ptr, &a, T.sizeof);
		core.stdc.string.memcpy(&a, &b, T.sizeof);
		core.stdc.string.memcpy(&b, scratch.ptr, T.sizeof);
	}
}

/// Ends the lifetimes of the `count` elements at `p`, leaving them empty. Does nothing when their lifetime is their bytes.
///
/// Examples:
/// ---
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// Owned[2] slots;
/// slots[0].data = cast(int*) 1;
/// endLifetimes(slots.ptr, 2);
/// assert(slots[0].data is null);
/// ---
void endLifetimes(T)(T* p, size_t count) @trusted {
	static if (!isBitMoveable!T) {
		if (p is null || count == 0) return;
		foreach (i; 0 .. count) endLifetime(p[i]);
		core.stdc.string.memset(p, 0, T.sizeof * count);
	}
}

/// Moves `count` elements from `src` to `dest`, ending the lifetimes `dest` held and leaving the source slots empty. The ranges must not overlap.
///
/// Examples:
/// ---
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// Owned[2] src, dest;
/// src[0].data = cast(int*) 1;
/// moveRange(dest.ptr, src.ptr, 1);
/// assert(dest[0].data == cast(int*) 1 && src[0].data is null);
/// ---
void moveRange(T)(T* dest, T* src, size_t count) @trusted {
	static if (isBitMoveable!T) core.stdc.string.memcpy(dest, src, T.sizeof * count);
	else foreach (i; 0 .. count) moveInto(dest[i], src[i]);
}

/// Copies `count` elements from `src` into `dest`, ending the lifetimes `dest` held. The ranges must not overlap.
///
/// Examples:
/// ---
/// struct Owned { int* data; void copyTo(ref Owned dest) @nogc nothrow { dest.data = data; } }
/// Owned[2] src, dest;
/// src[0].data = cast(int*) 1;
/// copyRange(dest.ptr, src.ptr, 1);
/// assert(dest[0].data == cast(int*) 1);
/// ---
void copyRange(T)(T* dest, T* src, size_t count) @trusted {
	static if (isBitMoveable!T) core.stdc.string.memcpy(dest, src, T.sizeof * count);
	else foreach (i; 0 .. count) copyInto(dest[i], src[i]);
}

/// A hook that ends one element's lifetime from its bytes, for a container holding elements without knowing their type.
alias FinalizeFunction = void function(inout ubyte[]);

// Ends the lifetime of the `T` stored in `slot`.
private void finalizeSlot(T)(inout ubyte[] slot) @trusted { endLifetime(*cast(T*) slot.ptr); }

/// The `FinalizeFunction` for `T`: null when its lifetime is its bytes, otherwise one that ends it with its `finalize` or `~this`.
///
/// Examples:
/// ---
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// static assert(fp.lifecycle.finalizeFunction!int() is null);
/// Owned[2] slots;
/// slots[0].data = cast(int*) 1;
/// fp.lifecycle.finalizeFunction!Owned()(cast(inout(ubyte)[]) slots[0 .. 1]);
/// assert(slots[0].data is null);
/// ---
FinalizeFunction finalizeFunction(T)() {
	static if (isBitMoveable!T) return null;
	else return &finalizeSlot!T;
}


// Frees `p` whichever libfp container it is, doing nothing for stack memory and pointers libfp did not allocate.
private void freeOwned(T)(T* p) @trusted {
	if (p is null) return;
	switch (fp.pointer.pointerType(p)) {
		case fp.pointer.PointerType.heap: fp.pointer.free(p); break;
		case fp.pointer.PointerType.dynarray: fp.dynarray.free(p); break;
		case fp.pointer.PointerType.hashTable: fp.hashtable.free(p); break;
		default: break;
	}
}

// A copy of `p`'s elements as a container of the same kind, or null if the allocator refused or `p` is not a libfp container.
private T* cloneOwned(T)(T* p) @trusted {
	if (p is null) return null;
	switch (fp.pointer.pointerType(p)) {
		case fp.pointer.PointerType.heap: {
			immutable n = fp.pointer.length(p);
			T* copy = fp.pointer.malloc!T(n);
			if (copy !is null) copyRange(copy, p, n);
			return copy;
		}
		case fp.pointer.PointerType.dynarray: return fp.dynarray.clone(p);
		case fp.pointer.PointerType.hashTable: return fp.hashtable.clone(p);
		default: return null;
	}
}

/// An owning handle to a libfp container, for when a container should release its `fp.pointer`, `fp.dynarray` or `fp.hashtable` elements as it is itself freed or shrunk. It is a plain `T*` with the hooks above: `finalize` frees what it points at, `moveTo` transfers the pointer, and `copyTo` deep-copies it. `alias p this` keeps it usable wherever a `T*` is.
///
/// Only `copyTo` deep-copies: an implicit by-value copy of an `Owned!T` is a bit copy, so passing one to a container hands over the resource and leaves the caller's handle naming it too — do not end that handle's lifetime afterwards.
///
/// Examples:
/// ---
/// char* text = fp.string.makeDynamic("hi");
/// Owned!char* lines = null;
/// fp.dynarray.pushBack(lines, Owned!char(text));
/// fp.dynarray.free(lines); // frees the string with the array
/// ---
struct Owned(T) {
	T* p; /// The container this owns, or null.

	alias p this;

	void finalize() @nogc nothrow { freeOwned(p); p = null; }
	void moveTo(ref Owned!T dest) @nogc nothrow { dest.p = p; p = null; }
	void copyTo(ref Owned!T dest) @nogc nothrow { endLifetime(dest); dest.p = cloneOwned(p); }
}


version(unittest) {
	private __gshared int finalizeCount = 0;

	private struct Counted {
		int* data;
		void finalize() @nogc nothrow { if (data !is null) { ++finalizeCount; data = null; } }
		void copyTo(ref Counted dest) @nogc nothrow { dest.data = data; }
	}

	private struct Deep {
		int* data;
		this(this) @nogc nothrow { data = data is null ? null : cast(int*) 1; }
		void finalize() @nogc nothrow { if (data !is null) { ++finalizeCount; data = null; } }
	}

	private struct Movable {
		int* data;
		void moveTo(ref Movable to) @nogc nothrow { to.data = data; data = null; }
	}
}


unittest {
	static assert(isBitMoveable!int && isBitMoveable!long && isBitMoveable!(char[8]) && isBitMoveable!(const char*));
	static assert(isBitMoveable!(ubyte[3]));
	static assert(!isBitMoveable!Counted);
	static assert(!isBitMoveable!(Counted[2]));
	static assert(!isBitMoveable!(Counted[2][3]));
	struct Plain { int a; Counted b; }
	static assert(!isBitMoveable!Plain);
	struct OnlyMove { int* p; void moveTo(ref OnlyMove to) @nogc nothrow { to.p = p; p = null; } }
	static assert(!isBitMoveable!OnlyMove);
	struct OnlyCopy { int* p; void copyTo(ref OnlyCopy to) @nogc nothrow { to.p = p; } }
	static assert(!isBitMoveable!OnlyCopy);
	struct WithPostblit { int a; this(this) @nogc nothrow {} }
	static assert(!isBitMoveable!WithPostblit);
	struct WithDtor { int a; ~this() @nogc nothrow {} }
	static assert(!isBitMoveable!WithDtor);
	struct Nested { WithDtor inner; }
	static assert(!isBitMoveable!Nested);

	// The hooks these types declare are the ones `moveInto` and `copyInto` use.
	OnlyMove from;
	from.p = cast(int*) 1;
	OnlyMove to;
	moveInto(to, from);
	assert(to.p == cast(int*) 1 && from.p is null);
	OnlyCopy src;
	src.p = cast(int*) 2;
	OnlyCopy dst;
	dst.p = cast(int*) 3;
	copyInto(dst, src);
	assert(dst.p == src.p); // `copyTo` ran, replacing `dst`'s own value
}

unittest {
	// `finalize` is the convention; a D destructor is reached through the compiler's `__xdtor`.
	finalizeCount = 0;
	Counted c;
	c.data = cast(int*) 1;
	endLifetime(c);
	assert(c.data is null && finalizeCount == 1);
	endLifetime(c);
	assert(finalizeCount == 1);

	struct DtorCounted { int* data; ~this() @nogc nothrow { if (data !is null) { ++finalizeCount; data = null; } } }
	DtorCounted d;
	d.data = cast(int*) 2;
	endLifetime(d);
	assert(d.data is null && finalizeCount == 2);
	endLifetime(d);
	assert(finalizeCount == 2);
}

unittest {
	Counted from, to;
	from.data = cast(int*) 1;
	to.data = cast(int*) 2;
	finalizeCount = 0;
	moveInto(to, from);
	assert(to.data == cast(int*) 1 && from.data is null && finalizeCount == 1);

	// Moving into an empty slot ends nothing.
	Counted empty;
	moveInto(empty, to);
	assert(to.data is null && empty.data == cast(int*) 1 && finalizeCount == 1);

	// A bit-moveable move is a plain copy, and the source keeps its bytes.
	int x = 3, y = 5;
	moveInto(y, x);
	assert(x == 3 && y == 3);
}

unittest {
	Counted from, to;
	from.data = cast(int*) 1;
	to.data = cast(int*) 2;
	finalizeCount = 0;
	copyInto(to, from);
	assert(to.data == cast(int*) 1 && finalizeCount == 1);

	// A postblit runs on assignment, so a copy of `Deep` is deep.
	Deep a, b;
	a.data = cast(int*) 1;
	b.data = cast(int*) 2;
	finalizeCount = 0;
	copyInto(b, a);
	assert(b.data == cast(int*) 1 && finalizeCount == 1);

	// A type with both `finalize` and `~this` is ended by `finalize`, not by the destructor assignment would run.
	struct Both {
		int* data;
		void finalize() @nogc nothrow { if (data !is null) { ++finalizeCount; data = null; } }
		~this() @nogc nothrow {}
	}
	Both live, fresh;
	live.data = cast(int*) 3;
	fresh.data = cast(int*) 4;
	finalizeCount = 0;
	copyInto(live, fresh);
	assert(finalizeCount == 1 && live.data == cast(int*) 4);

	int x = 1, y = 2;
	copyInto(y, x);
	assert(y == 1);
}

unittest {
	Counted a, b;
	a.data = cast(int*) 1;
	b.data = cast(int*) 2;
	finalizeCount = 0;
	swapInto(a, b);
	assert(a.data == cast(int*) 2 && b.data == cast(int*) 1 && finalizeCount == 0);
	swapInto(a, a);
	assert(a.data == cast(int*) 2);

	int x = 1, y = 2;
	swapInto(x, y);
	assert(x == 2 && y == 1);

	Movable m, n;
	m.data = cast(int*) 1;
	n.data = cast(int*) 2;
	swapInto(m, n);
	assert(m.data == cast(int*) 2 && n.data == cast(int*) 1);
}

unittest {
	Counted[4] slots;
	for (size_t i; i < 4; ++i)
		slots[i].data = cast(int*) (i + 1);
	finalizeCount = 0;
	endLifetimes(slots.ptr, 2);
	assert(finalizeCount == 2 && slots[0].data is null && slots[1].data is null);
	assert(slots[2].data == cast(int*) 3);
	endLifetimes(slots.ptr, 0);
	assert(finalizeCount == 2);

	Counted spare;
	spare.data = cast(int*) 9;
	initSlots(&spare, 1);
	assert(spare.data is null);
	int raw = 7;
	initSlots(&raw, 1);
	assert(raw == 7); // bit-moveable slots need no preparation
}

unittest {
	Counted[4] src, dest;
	for (size_t i; i < 4; ++i)
		src[i].data = cast(int*) (i + 1);
	dest[0].data = cast(int*) 20;
	finalizeCount = 0;
	moveRange(dest.ptr, src.ptr, 4);
	assert(finalizeCount == 1);
	foreach (i; 0 .. 4)
		assert(dest[i].data == cast(int*) (i + 1) && src[i].data is null);

	Counted[2] copyDest;
	copyDest[0].data = cast(int*) 30;
	finalizeCount = 0;
	copyRange(copyDest.ptr, dest.ptr, 2);
	assert(finalizeCount == 1 && copyDest[0].data == cast(int*) 1 && copyDest[1].data == cast(int*) 2);

	int[3] ints = [1, 2, 3];
	int[3] out_;
	moveRange(out_.ptr, ints.ptr, 3);
	assert(out_ == [1, 2, 3]);
}

unittest {
	static assert(!isBitMoveable!(Owned!int));

	Owned!int o = Owned!int(fp.pointer.malloc!int(3));
	o[0] = 1;
	o[2] = 3;
	assert(fp.pointer.length(o) == 3 && o[2] == 3);

	Owned!int moved;
	moveInto(moved, o);
	assert(o.p is null && moved.p !is null && moved[2] == 3);

	Owned!int copied;
	copyInto(copied, moved);
	assert(copied.p !is moved.p && copied[0] == 1 && copied[2] == 3);
	endLifetime(copied);
	assert(copied.p is null);

	// A dynarray is owned and copied like the other containers.
	Owned!int dyn = Owned!int(fp.dynarray.create!int(2));
	assert(dyn.p !is null && fp.dynarray.length(dyn.p) == 2);
	Owned!int dynTwin;
	copyInto(dynTwin, dyn);
	assert(dynTwin.p !is dyn.p && fp.dynarray.length(dynTwin.p) == 2);
	endLifetime(dynTwin);
	endLifetime(dyn);
	assert(dyn.p is null);

	// A stack `Array` is not ours to free, and a null handle ends nothing.
	fp.pointer.Array!(int, 2) stackArr;
	stackArr[0] = 1;
	Owned!int borrowed = Owned!int(stackArr.ptr);
	Owned!int notCopied;
	copyInto(notCopied, borrowed); // memory libfp did not allocate is neither copied nor released
	assert(notCopied.p is null && stackArr[0] == 1);
	endLifetime(borrowed);
	assert(borrowed.p is null && stackArr[0] == 1);

	// A hash table is owned and copied like the other containers.
	int* table = fp.hashtable.create!int();
	assert(table !is null);
	assert(fp.hashtable.insert(table, 7) !is null);
	Owned!int owner = Owned!int(table);
	Owned!int twin;
	copyInto(twin, owner);
	assert(twin.p !is owner.p && fp.hashtable.contains(twin.p, 7));
	endLifetime(twin);
	endLifetime(owner);

	Owned!int none;
	endLifetime(none);
	fp.pointer.free(moved.p);
}

/// The lifetimes of the elements libfp containers hold: how an element is copied, moved, and ended.
///
/// A container keeps every slot it has allocated in one of two states: live, or empty, which is all zero bytes. Copying, moving and ending an element goes through a convention the element type declares, in this order of preference:
/// $(UL
///   $(LI `finalize()` ends the element's lifetime. It must be safe on an empty value and leave it empty.)
///   $(LI `moveTo(ref T destination)` moves into an empty `destination` and leaves the source empty. Without it, a move is a bit copy followed by zeroing the source.)
///   $(LI `copyTo(ref T destination)` deep-copies into an empty `destination`. It may return `bool`, returning false on refused allocation. Without it, a copy is assignment, which runs a postblit if the type has one.)
/// )
/// A struct or static array that declares none of these, but holds a field or element that does, takes its lifetime from its parts: ending, copying and discarding it does so field by field, so a component holding an `Owned` or a `fp.rope.Rope` needs no hook of its own.
///
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
/// Owned* slot = fp.pointer.allocate!Owned(2);
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
static import fp.algorithms;


@nogc nothrow:


// `__traits(hasMember)` looks through a pointer, whose pointee's hooks are not its own, so only an aggregate is asked.
private enum bool declares(T, string hook) = (is(T == struct) || is(T == union)) && __traits(hasMember, T, hook);
private template hasFinalize(T) { enum hasFinalize = declares!(T, "finalize"); }
private template hasMoveTo(T) { enum hasMoveTo = declares!(T, "moveTo"); }
private template hasCopyTo(T) { enum hasCopyTo = declares!(T, "copyTo"); }
// `~this` and `this(this)` have no callable names; the compiler stores them under these. Both must be `@nogc nothrow`, as libfp calls them from `@nogc` code.
private template hasDestructor(T) { enum hasDestructor = declares!(T, "__xdtor"); }
private template hasPostblit(T) { enum hasPostblit = declares!(T, "__postblit"); }
private template hasOwnDestructor(T) { enum hasOwnDestructor = declares!(T, "__dtor"); }

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

// A struct or static array with no hook of its own but a part that has one: its lifetime is its parts', one by one.
private template composed(T) {
	static if (is(T == struct))
		enum composed = !isBitMoveable!T && !hasFinalize!T && !hasOwnDestructor!T;
	else static if (is(T == U[N], U, size_t N))
		enum composed = !isBitMoveable!U;
	else
		enum composed = false;
}

// Like `composed`, for copying: such a struct copies through its parts unless it copies itself.
private template copiesByParts(T) {
	static if (is(T == struct))
		enum copiesByParts = composed!T && !hasCopyTo!T && !hasPostblit!T;
	else static if (is(T == U[N], U, size_t N))
		enum copiesByParts = !isBitMoveable!U;
	else
		enum copiesByParts = false;
}

/// Makes `count` slots at `p` fit to hold elements: does nothing when their lifetime is their bytes, zeroes them otherwise, so a spare slot is always empty.
///
/// Examples:
/// ---
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// Owned[2] slots;
/// emptySlots(slots.ptr, 2);
/// endLifetime(slots[0]); // safe: the slot was made empty
/// assert(slots[0].data is null);
/// ---
void emptySlots(T)(T* p, size_t count) @trusted {
	static if (!isBitMoveable!T) {
		if (p is null || count == 0) return;
		core.stdc.string.memset(p, 0, T.sizeof * count);
	}
}

/// Ends `e`'s lifetime, leaving it empty: `finalize()` if `T` has one, else its `~this`, else, for a struct or static array, each field's or element's lifetime in turn, so a struct holding an `Owned` or a `fp.rope.Rope` needs no hook of its own. Safe on an already empty `e`.
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
	else static if (composed!T) {
		static if (is(T == struct)) static foreach (i; 0 .. T.tupleof.length) endLifetime(e.tupleof[i]);
		else foreach (ref element; e) endLifetime(element);
	} else static if (hasDestructor!T) __traits(getMember, e, "__xdtor")();
}

/// Moves `source` into `destination`, ending whatever `destination` held and leaving `source` empty.
///
/// Examples:
/// ---
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// Owned from, to;
/// from.data = cast(int*) 1;
/// moveInto(to, from);
/// assert(to.data == cast(int*) 1 && from.data is null);
/// ---
void moveInto(T)(ref T destination, ref T source) @trusted {
	static if (isBitMoveable!T) core.stdc.string.memcpy(&destination, &source, T.sizeof);
	else static if (hasMoveTo!T) { endLifetime(destination); source.moveTo(destination); }
	else {
		endLifetime(destination);
		core.stdc.string.memcpy(&destination, &source, T.sizeof);
		core.stdc.string.memset(&source, 0, T.sizeof);
	}
}

/// Copies `source` into `destination`, ending whatever `destination` held. Uses `copyTo` if `T` has one, else a postblit through assignment, else, for a struct or static array with parts that copy themselves, each part in turn.
///
/// Returns false if an allocation was refused, leaving `destination` empty.
///
/// Examples:
/// ---
/// struct Owned { int* data; bool copyTo(ref Owned destination) @nogc nothrow { destination.data = data; return true; } }
/// Owned from, to;
/// from.data = cast(int*) 1;
/// assert(copyInto(to, from));
/// assert(to.data == from.data);
/// ---
bool copyInto(T)(ref T destination, ref T source) @trusted {
	static if (isBitMoveable!T) {
		core.stdc.string.memcpy(&destination, &source, T.sizeof);
		return true;
	} else static if (hasCopyTo!T) {
		endLifetime(destination);
		static if (is(typeof(source.copyTo(destination)) == bool))
			return source.copyTo(destination);
		else {
			source.copyTo(destination);
			return true;
		}
	} else static if (copiesByParts!T) {
		static if (is(T == struct)) {
			static foreach (i; 0 .. T.tupleof.length) {
				if (!copyInto(destination.tupleof[i], source.tupleof[i])) {
					static foreach (j; 0 .. i)
						endLifetime(destination.tupleof[j]);
					core.stdc.string.memset(&destination, 0, T.sizeof);
					return false;
				}
			}
			return true;
		} else {
			foreach (i; 0 .. T.length) {
				if (!copyInto(destination[i], source[i])) {
					foreach (j; 0 .. i)
						endLifetime(destination[j]);
					core.stdc.string.memset(&destination, 0, T.sizeof);
					return false;
				}
			}
			return true;
		}
	} else {
		endLifetime(destination);
		destination = source; // assignment runs a postblit, which cannot see `destination`'s old bytes, so the lifetime ends first
		return true;
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
/// discardBitCopy(copy);
/// assert(copy.data is null && original.data == cast(int*) 1);
/// ---
void discardBitCopy(T)(ref T copy) {
	static if (!isBitMoveable!T) {
		static if (hasPostblit!T) endLifetime(copy);
		else static if (copiesByParts!T) {
			static if (is(T == struct)) static foreach (i; 0 .. T.tupleof.length) discardBitCopy(copy.tupleof[i]);
			else foreach (ref element; copy) discardBitCopy(element);
		}
		else emptySlots(&copy, 1); // the copy shares the original's resources, so it must be emptied rather than ended
	}
}

/// Ends the lifetime of `copy`, a value made by `copyInto` that the caller does not store. It owns what it holds when `T` deep-copies, with `copyTo` or a postblit; otherwise the copy is a bit copy aliasing the original, so it is only zeroed. A struct or static array without either is handled part by part.
///
/// Examples:
/// ---
/// struct Handle { int* data; void copyTo(ref Handle destination) @nogc nothrow { destination.data = data; } void finalize() @nogc nothrow { data = null; } }
/// Handle original, copy;
/// original.data = cast(int*) 1;
/// copyInto(copy, original);
/// discardCopy(copy);
/// assert(copy.data is null && original.data == cast(int*) 1);
/// ---
void discardCopy(T)(ref T copy) {
	static if (!isBitMoveable!T) {
		static if (hasCopyTo!T || hasPostblit!T) endLifetime(copy);
		else static if (copiesByParts!T) {
			static if (is(T == struct)) static foreach (i; 0 .. T.tupleof.length) discardCopy(copy.tupleof[i]);
			else foreach (ref element; copy) discardCopy(element);
		}
		else emptySlots(&copy, 1); // a bit copy, so the original still owns the resources
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

/// Moves `count` elements from `source` to `destination`, ending the lifetimes `destination` held and leaving the source slots empty. The ranges must not overlap.
///
/// Examples:
/// ---
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// Owned[2] source, destination;
/// source[0].data = cast(int*) 1;
/// moveRange(destination.ptr, source.ptr, 1);
/// assert(destination[0].data == cast(int*) 1 && source[0].data is null);
/// ---
void moveRange(T)(T* destination, T* source, size_t count) @trusted {
	static if (isBitMoveable!T) core.stdc.string.memcpy(destination, source, T.sizeof * count);
	else foreach (i; 0 .. count) moveInto(destination[i], source[i]);
}

/// Copies `count` elements from `source` into `destination`, ending the lifetimes `destination` held. The ranges must not overlap.
///
/// Returns false at the first element whose copy was refused, leaving the ones copied so far copied and that element empty; the elements after it are untouched.
///
/// Examples:
/// ---
/// struct Owned { int* data; bool copyTo(ref Owned destination) @nogc nothrow { destination.data = data; return true; } }
/// Owned[2] source, destination;
/// source[0].data = cast(int*) 1;
/// assert(copyRange(destination.ptr, source.ptr, 1));
/// assert(destination[0].data == cast(int*) 1);
/// ---
bool copyRange(T)(T* destination, T* source, size_t count) @trusted {
	static if (isBitMoveable!T) {
		core.stdc.string.memcpy(destination, source, T.sizeof * count);
		return true;
	} else {
		foreach (i; 0 .. count) if (!copyInto(destination[i], source[i])) return false;
		return true;
	}
}

/// A hook that ends one element's lifetime from its bytes, for a container holding elements without knowing their type.
alias Finalizer = void function(inout ubyte[]);

// wrapper: adapts endLifetime to Finalizer, the hook a container needs to end an element whose type it does not know
private void finalizeSlot(T)(inout ubyte[] slot) @trusted { endLifetime(*cast(T*) slot.ptr); }

/// The `Finalizer` for `T`: null when its lifetime is its bytes, otherwise one that ends it with its `finalize` or `~this`.
///
/// Examples:
/// ---
/// struct Owned { int* data; void finalize() @nogc nothrow { data = null; } }
/// static assert(fp.lifecycle.finalizerOf!int() is null);
/// Owned[2] slots;
/// slots[0].data = cast(int*) 1;
/// fp.lifecycle.finalizerOf!Owned()(cast(inout(ubyte)[]) slots[0 .. 1]);
/// assert(slots[0].data is null);
/// ---
Finalizer finalizerOf(T)() {
	static if (isBitMoveable!T) return null;
	else return &finalizeSlot!T;
}



// --- equality and hashing ------------------------------------------------------

/// Zeroes the bytes of `value` that belong to no field, at any depth, so two values with the same fields have the same bytes however their padding was left. It cannot fail.
///
/// Examples:
/// ---
/// struct Padded { ubyte a; ulong b; }
/// Padded x;
/// (cast(ubyte*) &x)[1] = 7; // garbage between the fields
/// normalizePadding(x);
/// assert((cast(ubyte*) &x)[1] == 0);
/// ---
void normalizePadding(T)(ref T value) @trusted {
	static if (is(T == struct)) {
		ubyte* raw = cast(ubyte*) &value;
		ubyte[T.sizeof] field;
		static foreach (i; 0 .. T.tupleof.length)
			field[T.tupleof[i].offsetof .. T.tupleof[i].offsetof + typeof(T.tupleof[i]).sizeof] = 1;
		for (size_t i = 0; i < T.sizeof; ++i)
			if (!field[i]) raw[i] = 0;
		static foreach (i; 0 .. T.tupleof.length) {{
			alias Member = typeof(T.tupleof[i]);
			static if (is(Member == struct))
				normalizePadding(value.tupleof[i]);
			else static if (__traits(isStaticArray, Member))
				foreach (ref element; value.tupleof[i])
					normalizePadding(element);
		}}
	}
}

// The bytes of `value` with its padding zeroed, in a buffer aligned as `T` is.
private struct FieldBytes(T) {
	align(T.alignof) ubyte[T.sizeof] bytes;
}

private FieldBytes!T fieldBytes(T)(ref const T value) @trusted {
	FieldBytes!T out_;
	core.stdc.string.memcpy(out_.bytes.ptr, &value, T.sizeof);
	normalizePadding(*cast(T*) out_.bytes.ptr);
	return out_;
}

/// Whether `a` and `b` hold the same value: through `T.equal(a, b)` if `T` declares it (as `ecrs.relation.Relates` does); for a struct or static array that owns memory only through its parts, part by part; otherwise by the bytes of their fields, padding ignored. A type that owns memory itself must declare `equal`, since its bytes are addresses. It cannot fail.
///
/// Examples:
/// ---
/// struct Padded { ubyte a; ulong b; }
/// Padded x = Padded(1, 2), y = Padded(1, 2);
/// (cast(ubyte*) &x)[1] = 7;
/// assert(equal(x, y));
/// assert(!equal(x, Padded(1, 3)));
/// ---
bool equal(T)(auto ref const T a, auto ref const T b) @trusted {
	static if (declares!(T, "equal")) return T.equal(a, b);
	else static if (composed!T) {
		static if (is(T == struct)) {
			static foreach (i; 0 .. T.tupleof.length)
				if (!equal(a.tupleof[i], b.tupleof[i])) return false;
		} else foreach (i; 0 .. T.length)
			if (!equal(a[i], b[i])) return false;
		return true;
	} else {
		static assert(isBitMoveable!T, T.stringof ~ " owns memory, so compare it with an `equal` of its own");
		auto x = fieldBytes(a), y = fieldBytes(b);
		return x.bytes == y.bytes;
	}
}

/// The hash of `value`, consistent with `equal`: `T.contentHash(value)` if `T` declares it (as `ecrs.relation.Relates` does); for a struct or static array that owns memory only through its parts, its parts' hashes chained with `fp.algorithms.combine`; otherwise `fp.algorithms.hashBytes` of its fields' bytes, padding ignored. A type that owns memory itself must declare `contentHash`. It cannot fail.
///
/// Examples:
/// ---
/// struct Padded { ubyte a; ulong b; }
/// Padded x = Padded(1, 2), y = Padded(1, 2);
/// (cast(ubyte*) &x)[1] = 7;
/// assert(contentHash(x) == contentHash(y));
/// ---
size_t contentHash(T)(auto ref const T value) @trusted {
	static if (declares!(T, "contentHash")) return T.contentHash(value);
	else static if (composed!T) {
		ulong hash = fp.algorithms.chainStart;
		static if (is(T == struct)) {
			static foreach (i; 0 .. T.tupleof.length) hash = fp.algorithms.combine(hash, contentHash(value.tupleof[i]));
		} else foreach (ref element; value) hash = fp.algorithms.combine(hash, contentHash(element));
		return cast(size_t) hash;
	} else {
		static assert(isBitMoveable!T, T.stringof ~ " owns memory, so hash it with a `contentHash` of its own");
		auto x = fieldBytes(value);
		return cast(size_t) fp.algorithms.hashBytes(x.bytes[]);
	}
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
			T* copy = fp.pointer.allocate!T(n);
			if (copy is null) return null;
			if (!copyRange(copy, p, n)) { fp.pointer.free(copy); return null; }
			return copy;
		}
		case fp.pointer.PointerType.dynarray: return fp.dynarray.clone(p);
		case fp.pointer.PointerType.hashTable: return fp.hashtable.clone(p);
		default: return null;
	}
}

// How many elements the libfp container `p` holds, 0 for null or memory libfp did not allocate.
private size_t ownedCount(T)(const(T)* p) @trusted {
	// A pointer to a const struct does not convert to the `inout(void*)` the queries take, though one to a const scalar does.
	auto raw = cast(const(void)*) p;
	switch (fp.pointer.pointerType(raw)) {
		case fp.pointer.PointerType.hashTable: {
			size_t n = 0;
			foreach (x; fp.hashtable.occupied(p)) ++n;
			return n;
		}
		case fp.pointer.PointerType.heap: case fp.pointer.PointerType.stack: return fp.pointer.length(raw);
		case fp.pointer.PointerType.dynarray: return fp.dynarray.length(raw);
		default: return 0;
	}
}

// The elements of the libfp allocation or dynarray `p`, in order.
private const(T)[] ownedElements(T)(const(T)* p) @trusted {
	return p is null ? null : p[0 .. ownedCount(p)];
}

/// An owning handle to a libfp container, for when a container should release its `fp.pointer`, `fp.dynarray` or `fp.hashtable` elements as it is itself freed or shrunk. It is a plain `T*` with the hooks above: `finalize` frees what it points at, `moveTo` transfers the pointer, and `copyTo` deep-copies it. `alias p this` keeps it usable wherever a `T*` is.
///
/// Only `copyTo` deep-copies: an implicit by-value copy of an `Owned!T` is a bit copy, so passing one to a container hands over the resource and leaves the caller's handle naming it too — do not end that handle's lifetime afterwards.
///
/// Examples:
/// ---
/// char* text = fp.string.clone("hi");
/// Owned!char* lines = null;
/// fp.dynarray.pushBack(lines, Owned!char(text));
/// fp.dynarray.free(lines); // frees the string with the array
/// ---
struct Owned(T) {
	T* p; /// The container this owns, or null.

	alias p this;

	void finalize() @nogc nothrow { freeOwned(p); p = null; }
	void moveTo(ref Owned!T destination) @nogc nothrow { destination.p = p; p = null; }
	bool copyTo(ref Owned!T destination) @nogc nothrow {
		endLifetime(destination);
		if (p is null) return true;
		destination.p = cloneOwned(p);
		return destination.p !is null;
	}

	/// Whether `a` and `b` own the same elements, each compared through `fp.lifecycle.equal`: in order for an `fp.pointer` or `fp.dynarray` allocation, in any order for an `fp.hashtable`, which takes time quadratic in its size. A null handle owns nothing, so it equals an empty container. It cannot fail.
	///
	/// Examples:
	/// ---
	/// auto a = Owned!char(fp.string.clone("hi")), b = Owned!char(fp.string.clone("hi"));
	/// scope(exit) { a.finalize(); b.finalize(); }
	/// Owned!char none, empty = Owned!char(fp.dynarray.create!char(0));
	/// scope(exit) empty.finalize();
	/// assert(Owned!char.equal(a, b) && Owned!char.equal(none, empty));
	/// ---
	static bool equal(ref const Owned a, ref const Owned b) @nogc nothrow @trusted {
		if (a.p is b.p) return true;
		immutable hashed = fp.pointer.pointerType(cast(const(void)*) a.p) == fp.pointer.PointerType.hashTable;
		if (hashed != (fp.pointer.pointerType(cast(const(void)*) b.p) == fp.pointer.PointerType.hashTable)) return ownedCount(a.p) == 0 && ownedCount(b.p) == 0;
		if (ownedCount(a.p) != ownedCount(b.p)) return false;
		if (!hashed) {
			auto x = ownedElements(a.p), y = ownedElements(b.p);
			foreach (i; 0 .. x.length) if (!.equal(x[i], y[i])) return false;
			return true;
		}
		foreach (x; fp.hashtable.occupied(a.p)) {
			bool found = false;
			foreach (y; fp.hashtable.occupied(b.p)) if (.equal(*x, *y)) { found = true; break; }
			if (!found) return false;
		}
		return true;
	}

	/// The hash of the elements `a` owns, consistent with `equal`: chained in order, or for an `fp.hashtable` summed, since its order is not its value. It cannot fail.
	///
	/// Examples:
	/// ---
	/// auto a = Owned!char(fp.string.clone("hi")), b = Owned!char(fp.string.clone("hi"));
	/// scope(exit) { a.finalize(); b.finalize(); }
	/// assert(Owned!char.contentHash(a) == Owned!char.contentHash(b));
	/// ---
	static size_t contentHash(ref const Owned a) @nogc nothrow @trusted {
		if (fp.pointer.pointerType(cast(const(void)*) a.p) == fp.pointer.PointerType.hashTable) {
			size_t sum = 0;
			foreach (x; fp.hashtable.occupied(a.p)) sum += .contentHash(*x);
			return sum;
		}
		ulong hash = fp.algorithms.chainStart;
		foreach (ref x; ownedElements(a.p)) hash = fp.algorithms.combine(hash, .contentHash(x));
		return cast(size_t) hash;
	}
}


version(unittest) {
	static import fp.string;
	static import fp.testing;

	private __gshared int finalizeCount = 0;

	private struct Counted {
		int* data;
		void finalize() @nogc nothrow { if (data !is null) { ++finalizeCount; data = null; } }
		void copyTo(ref Counted destination) @nogc nothrow { destination.data = data; }
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
	// A pointer is an address, whatever its pointee declares: freeing a list of them must not finalize what they point at.
	static assert(isBitMoveable!(Counted*) && isBitMoveable!(Owned!int*));
	Counted pointee, twin;
	Counted* at = &pointee;
	assert(equal(at, &pointee) && !equal(at, &twin) && contentHash(at) == contentHash(&pointee));
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
	OnlyCopy source;
	source.p = cast(int*) 2;
	OnlyCopy destination;
	destination.p = cast(int*) 3;
	assert(copyInto(destination, source));
	assert(destination.p == source.p); // `copyTo` ran, replacing `destination`'s own value

	struct FailingCopy {
		int* p;
		bool copyTo(ref FailingCopy to) @nogc nothrow { return false; }
	}
	FailingCopy badSource, badDest;
	assert(!copyInto(badDest, badSource));

	auto ownedStr = Owned!char(fp.string.clone("hello"));
	scope(exit) ownedStr.finalize();
	auto previous = fp.testing.limitAllocations(0);
	Owned!char ownedCopy;
	assert(!copyInto(ownedCopy, ownedStr));
	fp.testing.restoreAllocator(previous);
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
	assert(copyInto(to, from));
	assert(to.data == cast(int*) 1 && finalizeCount == 1);

	// A postblit runs on assignment, so a copy of `Deep` is deep.
	Deep a, b;
	a.data = cast(int*) 1;
	b.data = cast(int*) 2;
	finalizeCount = 0;
	assert(copyInto(b, a));
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
	assert(copyInto(live, fresh));
	assert(finalizeCount == 1 && live.data == cast(int*) 4);

	int x = 1, y = 2;
	assert(copyInto(y, x));
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
	emptySlots(&spare, 1);
	assert(spare.data is null);
	int raw = 7;
	emptySlots(&raw, 1);
	assert(raw == 7); // bit-moveable slots need no preparation
}

unittest {
	Counted[4] source, destination;
	for (size_t i; i < 4; ++i)
		source[i].data = cast(int*) (i + 1);
	destination[0].data = cast(int*) 20;
	finalizeCount = 0;
	moveRange(destination.ptr, source.ptr, 4);
	assert(finalizeCount == 1);
	foreach (i; 0 .. 4)
		assert(destination[i].data == cast(int*) (i + 1) && source[i].data is null);

	Counted[2] copyDestination;
	copyDestination[0].data = cast(int*) 30;
	finalizeCount = 0;
	assert(copyRange(copyDestination.ptr, destination.ptr, 2));
	assert(finalizeCount == 1 && copyDestination[0].data == cast(int*) 1 && copyDestination[1].data == cast(int*) 2);

	struct PartlyFailing {
		int* p;
		bool copyTo(ref PartlyFailing to) @nogc nothrow { to.p = p; return p !is null; }
	}
	PartlyFailing[2] failing = [PartlyFailing(cast(int*) 40), PartlyFailing(null)];
	PartlyFailing[2] partial;
	assert(!copyRange(partial.ptr, failing.ptr, 2)); // stops at the refused copy
	assert(partial[0].p == cast(int*) 40 && partial[1].p is null);

	int[3] ints = [1, 2, 3];
	int[3] out_;
	moveRange(out_.ptr, ints.ptr, 3);
	assert(out_ == [1, 2, 3]);
}

unittest {
	static assert(!isBitMoveable!(Owned!int));

	Owned!int o = Owned!int(fp.pointer.allocate!int(3));
	o[0] = 1;
	o[2] = 3;
	assert(fp.pointer.length(o) == 3 && o[2] == 3);

	Owned!int moved;
	moveInto(moved, o);
	assert(o.p is null && moved.p !is null && moved[2] == 3);

	Owned!int copied;
	assert(copyInto(copied, moved));
	assert(copied.p !is moved.p && copied[0] == 1 && copied[2] == 3);
	endLifetime(copied);
	assert(copied.p is null);

	// A dynarray is owned and copied like the other containers.
	Owned!int dyn = Owned!int(fp.dynarray.create!int(2));
	assert(dyn.p !is null && fp.dynarray.length(dyn.p) == 2);
	Owned!int dynTwin;
	assert(copyInto(dynTwin, dyn));
	assert(dynTwin.p !is dyn.p && fp.dynarray.length(dynTwin.p) == 2);
	endLifetime(dynTwin);
	endLifetime(dyn);
	assert(dyn.p is null);

	// A stack `Array` is not ours to free, and a null handle ends nothing.
	fp.pointer.Array!(int, 2) stackArray;
	stackArray[0] = 1;
	Owned!int borrowed = Owned!int(stackArray.ptr);
	Owned!int notCopied;
	assert(!copyInto(notCopied, borrowed)); // memory libfp did not allocate is neither copied nor released
	assert(notCopied.p is null && stackArray[0] == 1);
	endLifetime(borrowed);
	assert(borrowed.p is null && stackArray[0] == 1);

	// A hash table is owned and copied like the other containers.
	int* table = fp.hashtable.create!int();
	assert(table !is null);
	assert(fp.hashtable.insert(table, 7) !is null);
	Owned!int owner = Owned!int(table);
	Owned!int twin;
	assert(copyInto(twin, owner));
	assert(twin.p !is owner.p && fp.hashtable.contains(twin.p, 7));
	assert(equal(twin, owner) && contentHash(twin) == contentHash(owner));
	endLifetime(twin);

	// Handles compare by what they own: a hash table in any order, a sequence in order, and nothing alike however it is held.
	int* reordered = fp.hashtable.create!int();
	foreach (key; [9, 7]) assert(fp.hashtable.insert(reordered, key) !is null);
	assert(fp.hashtable.insert(owner.p, 9) !is null);
	Owned!int other = Owned!int(reordered);
	assert(equal(owner, other) && contentHash(owner) == contentHash(other));
	assert(fp.hashtable.insert(reordered, 8) !is null);
	assert(!equal(owner, other));
	endLifetime(other);
	endLifetime(owner);
	Owned!int sequence = Owned!int(fp.dynarray.create!int(2)), heap = Owned!int(fp.pointer.allocate!int(2));
	sequence[0] = heap[0] = 1;
	sequence[1] = heap[1] = 2;
	assert(equal(sequence, heap) && contentHash(sequence) == contentHash(heap));
	heap[1] = 3;
	assert(!equal(sequence, heap));
	struct Id { uint value; }
	auto ids = Owned!Id(fp.dynarray.create!Id(1)), twinIds = Owned!Id(fp.dynarray.create!Id(1));
	ids[0] = twinIds[0] = Id(4);
	assert(equal(ids, twinIds) && contentHash(ids) == contentHash(twinIds));
	endLifetime(ids);
	endLifetime(twinIds);
	struct Holder { Owned!int items; int weight; }
	auto emptied = Holder(Owned!int(fp.dynarray.create!int(0)), 1);
	assert(equal(Holder(Owned!int.init, 1), emptied) && !equal(Holder(Owned!int.init, 2), emptied));
	endLifetime(emptied);
	endLifetime(sequence);
	endLifetime(heap);

	Owned!int none;
	endLifetime(none);
	fp.pointer.free(moved.p);
}

unittest { // equal and contentHash ignore padding at any depth, and defer to a type's own hooks
	static struct Inner { ubyte a; uint b; }
	static struct Outer { ubyte tag; Inner inner; Inner[2] pair; }
	Outer x, y;
	foreach (i; 0 .. Outer.sizeof) (cast(ubyte*) &x)[i] = 0xAA; // garbage everywhere, padding included
	x.tag = 1; x.inner = Inner(2, 3); x.pair = [Inner(4, 5), Inner(6, 7)];
	y.tag = 1; y.inner = Inner(2, 3); y.pair = [Inner(4, 5), Inner(6, 7)];
	assert(equal(x, y) && contentHash(x) == contentHash(y));
	y.pair[1].b = 8;
	assert(!equal(x, y));
	assert(equal(3, 3) && !equal(3, 4) && contentHash(3) == contentHash(3));

	static struct Hooked {
		int value;
		int ignored;
		static bool equal(ref const Hooked a, ref const Hooked b) @nogc nothrow { return a.value == b.value; }
		static size_t contentHash(ref const Hooked hash) @nogc nothrow { return hash.value; }
	}
	assert(equal(Hooked(1, 2), Hooked(1, 3)) && contentHash(Hooked(5, 9)) == 5);
}

unittest { // a struct without hooks of its own ends, copies and discards through its fields' hooks
	static int ended = 0, copied = 0;
	static struct Part {
		int* data;
		void finalize() @nogc nothrow { if (data !is null) ++ended; data = null; }
		void copyTo(ref Part destination) @nogc nothrow { ++copied; destination.data = data; }
	}
	static struct Aliasing { int* data; void finalize() @nogc nothrow { if (data !is null) ++ended; data = null; } }
	static struct Whole { int plain; Part part; Part[2] pair; Aliasing view; }
	static assert(!isBitMoveable!Whole);

	Whole a;
	a.plain = 1;
	a.part.data = cast(int*) 1;
	a.pair[1].data = cast(int*) 2;
	a.view.data = cast(int*) 3;

	Whole b;
	assert(copyInto(b, a));
	assert(copied == 3 && b.plain == 1 && b.part.data == cast(int*) 1 && b.view.data == cast(int*) 3);
	discardCopy(b); // the deep-copied parts are ended, the aliasing one only zeroed
	assert(ended == 2 && b.part.data is null && b.view.data is null);

	endLifetime(a);
	assert(ended == 5 && a.part.data is null && a.pair[1].data is null && a.view.data is null && a.plain == 1);
	endLifetime(a); // empty: a no-op
	assert(ended == 5);
}

unittest { // equal and contentHash compose through the parts of a struct that owns memory only through them
	static struct Text {
		char* data;
		void finalize() @nogc nothrow { data = null; }
		static bool equal(ref const Text a, ref const Text b) @nogc nothrow { return (a.data is null) == (b.data is null); }
		static size_t contentHash(ref const Text t) @nogc nothrow { return t.data is null ? 1 : 2; }
	}
	static struct Pair { Text name; int count; }
	static assert(!isBitMoveable!Pair);
	char[2] buffer;
	Pair x = Pair(Text(buffer.ptr), 3), y = Pair(Text(buffer.ptr + 1), 3);
	assert(equal(x, y) && contentHash(x) == contentHash(y)); // the parts' hooks, not their addresses, decide
	y.count = 4;
	assert(!equal(x, y));
	Pair[2] both = [x, x];
	assert(equal(both, both) && contentHash(both) == contentHash(both));
}

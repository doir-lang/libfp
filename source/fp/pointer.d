/// The fat pointer core. A fat pointer is a plain `T*` with a `Header` stored just before its first element, recording how the memory was allocated and how many elements it holds, and a zero byte just after its last element, so a `char*` is also a valid C string.
///
/// Examples:
/// ---
/// int* p = malloc!int(3);
/// p[0] = 1;
/// assert(length(p) == 3);
/// free(p);
/// assert(p is null);
/// ---
module fp.pointer;

import core.stdc.stdlib;
static import core.checkedint;

version(DigitalMars) {
	version(FpAllowDMD) {} else
		static assert(0,
			"libfp: DMD is not supported. The stack built on libfp (Mizu, and the "
			~ "DOIR compiler on top of it) builds only with LDC, and `alloca` needs "
			~ "a real alloca call, which DMD cannot emit under -betterC "
			~ "(dlang/dmd#18276). Build with LDC (--compiler=ldc2). To analyse "
			~ "these sources with DMD without running them, set -version=FpAllowDMD.");
}


/// Signature of the function that allocates, reallocates and frees the raw memory behind every libfp container. Its semantics mirror `realloc`:
/// $(UL
///   $(LI `p is null && size > 0`: allocate new memory.)
///   $(LI `p !is null && size > 0`: reallocate, preserving existing data.)
///   $(LI `size == 0`: free `p` (if non-null) and return `null`.)
/// )
alias AllocFunction = void* function(void* p, size_t size) @nogc nothrow;

/// The allocator every libfp container uses. Reassign it to plug in your own, and restore the previous one when done.
///
/// Examples:
/// ---
/// static size_t calls;
/// static AllocFunction underlying;
/// static void* counting(void* p, size_t size) @nogc nothrow {
/// 	++calls;
/// 	return underlying(p, size);
/// }
/// underlying = allocFunction;
/// allocFunction = &counting;
/// scope(exit) allocFunction = underlying;
///
/// int* p = malloc!int(1);
/// free(p);
/// assert(calls == 2);
/// ---
AllocFunction allocFunction = &defaultAllocFunction;

private void* defaultAllocFunction(void* p, size_t size) @nogc nothrow {
	if (size == 0) {
		if (p !is null) core.stdc.stdlib.free(p);
		return null;
	}
	return core.stdc.stdlib.realloc(p, size);
}


@nogc nothrow:


private enum ushort validityMask = 0xFF00;
private enum ushort validityTag = 0xFE00;

/// How a fat pointer's memory was allocated, as recorded in its `Header`. Every tag shares the high byte `validityTag`, so `valid` can reject memory that was never a fat pointer.
enum PointerType : ushort {
	none = 0, /// Not a fat pointer (or null).
	heap = validityTag | 0xFE, /// From `malloc` or `realloc`.
	stack = validityTag | 0xFF, /// From `Array` or `alloca`.
	dynarray = validityTag | 0xFD, /// An `fp.dynarray`.
	hashTable = validityTag | 0xFC, /// An `fp.hashtable`.
}

/// The bookkeeping stored immediately before a fat pointer's first element. The containers built on fat pointers extend it by nesting it at the end of a larger header of their own.
struct Header {
	PointerType type; /// How the memory was allocated.
	size_t size; /// The number of elements (not bytes).
}

/// Returned by every search in libfp when nothing matched.
enum size_t notFound = size_t.max;

/// Returned in place of an index by functions that return one, when an allocation they needed was refused. Like `notFound`, it is never a valid index.
enum size_t allocationRefused = notFound - 1;


// `headerOf`, `valid` and `length` force inlining: callers in other dub packages cannot inline them without LTO, and `length` is hot.

/// The `Header` in front of fat pointer `p`. `p` must not be null.
///
/// Examples:
/// ---
/// int* p = malloc!int(2);
/// scope(exit) free(p);
/// assert(headerOf(p).size == 2);
/// assert(headerOf(p).type == PointerType.heap);
/// ---
pragma(inline, true)
package inout(Header)* headerOf(inout(void)* p) @trusted {
	return cast(inout(Header)*)(cast(const(ubyte)*) p - Header.sizeof);
}

/// Allocates, reallocates (when `p` is non-null) or, when `size` is 0, frees a heap fat pointer of `size` bytes, recording `size` in its header. Returns null if the allocator refused or the total with the header would overflow, leaving `p` untouched.
///
/// Examples:
/// ---
/// void* p = rawAlloc(null, 8);
/// assert(headerOf(p).size == 8);
/// assert(rawAlloc(p, 0) is null);
/// ---
package void* rawAlloc(void* p, size_t size) @trusted {
	if (p is null && size == 0) return null;
	if (size == 0) {
		cast(void)allocFunction(headerOf(p), 0);
		return null;
	}

	void* base = p is null ? null : cast(void*) headerOf(p);
	bool overflow = false;
	immutable total = core.checkedint.addu(core.checkedint.addu(Header.sizeof, size, overflow), 1, overflow);
	if (overflow) return null;
	ubyte* raw = cast(ubyte*) allocFunction(base, total);
	if (raw is null) return null;

	ubyte* data = raw + Header.sizeof;
	Header* h = headerOf(data);
	h.type = PointerType.heap;
	h.size = size;
	data[size] = 0;
	return data;
}

/// `rawAlloc` for `count` elements of `elemSize` bytes each, recording the element count rather than the byte count. Returns null if the allocator refused or the byte count would overflow, leaving `p` untouched.
///
/// Examples:
/// ---
/// void* p = rawRealloc(null, int.sizeof, 4);
/// assert(headerOf(p).size == 4);
/// cast(void)rawAlloc(p, 0);
/// ---
package void* rawRealloc(void* p, size_t elemSize, size_t count) @trusted {
	bool overflow = false;
	immutable bytes = core.checkedint.mulu(elemSize, count, overflow);
	if (overflow) return null;
	void* data = rawAlloc(p, bytes);
	if (data is null) return null;
	headerOf(data).size = count;
	return data;
}


/// Allocates a heap fat pointer to `n` uninitialized `T`s, or returns null if the allocator refused or their byte count would overflow.
///
/// Examples:
/// ---
/// float* p = malloc!float(4);
/// scope(exit) free(p);
/// assert(length(p) == 4);
/// assert(heapAllocated(p));
/// ---
T* malloc(T)(size_t n) {
	return cast(T*) rawRealloc(null, T.sizeof, n);
}

/// Resizes heap fat pointer `p` (or allocates one, if `p` is null) to `n` elements, preserving the existing ones. Returns null if the allocator refused or their byte count would overflow, in which case `p` is still valid.
///
/// Examples:
/// ---
/// int* p = malloc!int(2);
/// p[1] = 7;
/// int* bigger = realloc(p, 10);
/// assert(bigger !is null);
/// p = bigger;
/// scope(exit) free(p);
/// assert(length(p) == 10);
/// assert(p[1] == 7);
/// ---
T* realloc(T)(T* p, size_t n) {
	return cast(T*) rawRealloc(cast(void*) p, T.sizeof, n);
}

/// Frees heap fat pointer `p`. The `ref` overload also sets `p` to null.
///
/// Examples:
/// ---
/// int* p = malloc!int(1);
/// free(p);
/// assert(p is null);
/// free(p); // freeing null is a no-op
/// ---
void free(T)(ref T* p) {
	cast(void)rawAlloc(cast(void*) p, 0);
	p = null;
}
/// Ditto
void free(T)(const T* p) {
	cast(void)rawAlloc(cast(void*) p, 0);
}


/// A fat pointer to `N` elements in automatic (stack) storage, with its header and terminator alongside. It converts to `T*` implicitly.
///
/// Examples:
/// ---
/// Array!(int, 4) arr;
/// arr[0] = 3;
/// assert(length(arr) == 4);
/// assert(stackAllocated(arr));
/// ---
struct Array(T, size_t N) {
	private Header header = Header(PointerType.stack, N);
	private T[N] storage;
	private ubyte terminator = 0;

	/// The fat pointer itself.
	///
	/// Examples:
	/// ---
	/// Array!(char, 2) text;
	/// char* p = text.ptr;
	/// assert(length(p) == 2);
	/// ---
	@property inout(T)* ptr() inout pure return {
		return storage.ptr;
	}

	alias ptr this;
}

/// Writes a stack header and terminator around `count` elements at `data`, returning `data`. `alloca` calls it as an initializer expression, since a mixin template's body cannot hold statements; it is public because that expression runs in the caller's scope.
///
/// Examples:
/// ---
/// ubyte[Header.sizeof + 3 * int.sizeof + 1] buffer;
/// int* p = initStackHeader(cast(int*)(buffer.ptr + Header.sizeof), 3);
/// assert(length(p) == 3 && stackAllocated(p));
/// ---
T* initStackHeader(T)(T* data, size_t count) @trusted {
	Header* h = headerOf(data);
	h.type = PointerType.stack;
	h.size = count;
	(cast(ubyte*) data)[T.sizeof * count] = 0;
	return data;
}

/// Declares `T* name`, a fat pointer to `countExpr` elements allocated on the stack with `alloca`, for when the size is only known at run time; prefer `Array` when it is known at compile time.
///
/// It is a mixin template because `alloca` must run in the stack frame that uses the memory. That memory lives until the enclosing function returns, not until the end of the block, so using it in a loop or a deeply recursive function grows the stack with every pass.
///
/// Params:
///   T         = element type
///   name      = identifier the resulting `T*` is bound to
///   countExpr = source text of a `size_t` expression for the element count
///
/// Examples:
/// ---
/// size_t n = 5;
/// mixin alloca!(float, "temp", "n");
/// foreach (ref v; slice(temp)) v = 1.5f;
/// assert(length(temp) == 5 && temp[4] == 1.5f);
/// ---
mixin template alloca(T, string name, string countExpr) {
	// The body resolves names where it is mixed in, which need not have `fp` in scope.
	static import core.stdc.stdlib;
	static import fp.pointer;
	mixin(
		"auto __" ~ name ~ "_count = cast(size_t)(" ~ countExpr ~ ");"
		~ "ubyte* __" ~ name ~ "_raw = cast(ubyte*) core.stdc.stdlib.alloca(" ~ "fp.pointer.Header.sizeof + " ~ T.stringof ~ ".sizeof * __" ~ name ~ "_count + 1);"
		~ T.stringof ~ "* " ~ name ~ " = fp.pointer.initStackHeader(cast(" ~ T.stringof ~ "*)(__" ~ name ~ "_raw + fp.pointer.Header.sizeof), __" ~ name ~ "_count);"
	);
}


/// Whether `p` is a live fat pointer of any kind. A dynarray or hash table that has capacity but no elements yet is valid; any other empty one is not.
///
/// Examples:
/// ---
/// int* p = malloc!int(1);
/// scope(exit) free(p);
/// assert(valid(p));
/// assert(!valid(cast(int*) null));
/// ---
pragma(inline, true)
bool valid(inout void* p) @trusted {
	if (p is null) return false;
	inout(Header)* h = headerOf(p);
	if ((cast(ushort) h.type & validityMask) != validityTag) return false;
	if (h.size > 0) return true;

	// Only dynarray and hash table headers have a `capacity` field in front of this one; reading it for any other kind overruns the allocation.
	if (h.type != PointerType.dynarray && h.type != PointerType.hashTable) return false;
	immutable capacity = *cast(const(size_t)*)(cast(const(ubyte)*) h - size_t.sizeof);
	return capacity > 0;
}

/// How `p` was allocated, or `PointerType.none` if it is null.
///
/// Examples:
/// ---
/// Array!(int, 1) arr;
/// assert(pointerType(arr) == PointerType.stack);
/// assert(pointerType(cast(int*) null) == PointerType.none);
/// ---
PointerType pointerType(inout void* p) {
	if (p is null) return PointerType.none;
	return headerOf(p).type;
}

/// Whether `p` lives on the stack (`Array` or `alloca`).
///
/// Examples:
/// ---
/// Array!(int, 1) arr;
/// assert(stackAllocated(arr));
/// ---
bool stackAllocated(inout void* p) {
	return pointerType(p) == PointerType.stack;
}

/// Whether `p` lives on the heap (`malloc`, `realloc`, or a dynarray).
///
/// Examples:
/// ---
/// int* p = malloc!int(1);
/// scope(exit) free(p);
/// assert(heapAllocated(p));
/// ---
bool heapAllocated(inout void* p) {
	immutable t = pointerType(p);
	return t == PointerType.heap || t == PointerType.dynarray;
}

/// The number of elements (not bytes) in fat pointer `p`, or 0 if it is not valid.
///
/// Examples:
/// ---
/// int* p = malloc!int(6);
/// scope(exit) free(p);
/// assert(length(p) == 6);
/// assert(length(cast(int*) null) == 0);
/// ---
pragma(inline, true)
size_t length(inout void* p) {
	if (!valid(p)) return 0;
	return headerOf(p).size;
}

/// Ditto
alias size = length;

/// Whether fat pointer `p` holds no elements.
///
/// Examples:
/// ---
/// assert(empty(cast(int*) null));
/// int* p = malloc!int(1);
/// scope(exit) free(p);
/// assert(!empty(p));
/// ---
bool empty(inout void* p) {
	return length(p) == 0;
}


/// A pointer to the first element of `p`.
///
/// Examples:
/// ---
/// Array!(int, 2) arr;
/// arr[0] = 4;
/// assert(*front(arr.ptr) == 4);
/// ---
inout(T)* front(T)(inout T* p) {
	return p;
}

/// A pointer to the last element of `p` (to the first, if `p` is empty).
///
/// Examples:
/// ---
/// Array!(int, 2) arr;
/// arr[1] = 9;
/// assert(*back(arr.ptr) == 9);
/// ---
inout(T)* back(T)(inout T* p) @trusted {
	immutable n = length(p);
	return p + (n > 0 ? n - 1 : 0);
}

/// A non-owning D slice over all of `p`'s elements.
///
/// Examples:
/// ---
/// Array!(int, 3) arr;
/// foreach (i, ref v; slice(arr.ptr)) v = cast(int) i;
/// assert(slice(arr.ptr) == [0, 1, 2]);
/// ---
inout(T)[] slice(T)(inout T* p) {
	return p[0 .. length(p)];
}


unittest {
	int* arr = malloc!int(20);
	assert(arr !is null);
	scope(exit) assert(arr is null); // Scope exits run in reverse order!
	scope(exit) free(arr);

	int* bigger = realloc!int(arr, 25);
	assert(bigger !is null);
	arr = bigger;
	arr[20] = 6;

	assert(valid(arr));
	assert(!stackAllocated(arr));
	assert(heapAllocated(arr));
	assert(length(arr) == 25);
	assert(arr[20] == 6);
	assert(!empty(arr));

	int[] view = slice(arr);
	assert(view.length == 25 && view[20] == 6);
	int[] sub = view[20 .. 23];
	assert(sub[0] == 6);
	sub[1] = 8;
	assert(arr[21] == 8);

	// A `const(int)*` lvalue would still bind to `ref T*`, with `T` deduced as `const(int)`, so only an rvalue reaches the by-value overload.
	int* other = malloc!int(4);
	assert(other !is null);
	free(cast(const int*) other);

	// Byte counts that wrap must be refused, not allocated small: `size_t.max / 4 + 2` ints are 4 bytes past the top.
	assert(malloc!int(size_t.max / 4 + 2) is null);
	assert(malloc!ubyte(size_t.max) is null);
	assert(realloc(arr, size_t.max / 4 + 2) is null);
	assert(length(arr) == 25 && arr[20] == 6);
}

unittest {
	Array!(int, 20) fixed;
	fixed[10] = 6;
	assert(valid(fixed) && stackAllocated(fixed) && !heapAllocated(fixed));
	assert(length(fixed) == 20 && fixed[10] == 6);

	// Where `fp` names something else, as after `import fp.pointer : alloca;`, the mixin must still reach its own module.
	int fp = 0;
	mixin alloca!(int, "dynamic", "20");
	dynamic[10] = 6;
	assert(valid(dynamic) && stackAllocated(dynamic) && !heapAllocated(dynamic));
	assert(length(dynamic) == 20 && dynamic[10] == 6 && fp == 0);
}

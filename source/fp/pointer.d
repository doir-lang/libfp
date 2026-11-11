/// The fat pointer core.
/// A fat pointer is a plain `T*` with a `Header` stored just before its first element, recording how the memory was allocated and how many elements it holds, and a zero byte just after its last element, so a `char*` is also a valid C string.
///
/// Examples:
/// ---
/// int* p = allocate!int(3);
/// p[0] = 1;
/// assert(length(p) == 3);
/// free(p);
/// assert(p is null);
/// ---
module fp.pointer;

static import core.stdc.stdlib;
static import core.checkedint;
static import fp.lifecycle;

version(DigitalMars) {
	version(FpAllowDMD) {} else
		static assert(0,
			"libfp: DMD is not supported. The stack built on libfp (Mizu, and the "
			~ "DOIR compiler on top of it) builds only with LDC, and `allocateOnStack` needs "
			~ "a real alloca call, which DMD cannot emit under -betterC "
			~ "(dlang/dmd#18276). Build with LDC (--compiler=ldc2). To analyse "
			~ "these sources with DMD without running them, set -version=FpAllowDMD.");
}


/// Signature of the function that allocates, reallocates and frees the raw memory behind every libfp container.
/// Its semantics mirror C's `realloc`:
/// $(UL
///   $(LI `p is null && size > 0`: allocate new memory.)
///   $(LI `p !is null && size > 0`: reallocate, preserving existing data.)
///   $(LI `size == 0`: free `p` (if non-null) and return `null`.)
/// )
///
/// The memory it returns must be aligned to `maxAlignment`, as C's `malloc`'s is.
alias Allocator = void* function(void* p, size_t size) @nogc nothrow;

/// The allocator every libfp container uses.
/// Reassign it to plug in your own, and restore the previous one when done.
///
/// Examples:
/// ---
/// static size_t calls;
/// static Allocator underlying;
/// static void* counting(void* p, size_t size) @nogc nothrow {
/// 	++calls;
/// 	return underlying(p, size);
/// }
/// underlying = allocator;
/// allocator = &counting;
/// scope(exit) allocator = underlying;
///
/// int* p = allocate!int(1);
/// free(p);
/// assert(calls == 2);
/// ---
Allocator allocator = &defaultAllocator;

private void* defaultAllocator(void* p, size_t size) @nogc nothrow {
	if (size == 0) {
		if (p !is null) core.stdc.stdlib.free(p);
		return null;
	}
	return core.stdc.stdlib.realloc(p, size);
}


@nogc nothrow:


private enum ushort validityMask = 0xFF00;
private enum ushort validityTag = 0xFE00;

/// How a fat pointer's memory was allocated, as recorded in its `Header`.
/// Every tag shares the high byte `validityTag`, so `valid` can reject memory that was never a fat pointer.
enum PointerType : ushort {
	none = 0, /// Not a fat pointer (or null).
	heap = validityTag | 0xFE, /// From `allocate` or `resize`.
	stack = validityTag | 0xFF, /// From `Array` or `allocateOnStack`.
	dynarray = validityTag | 0xFD, /// An `fp.dynarray`.
	hashTable = validityTag | 0xFC, /// An `fp.hashtable`.
}

/// The bookkeeping stored immediately before a fat pointer's first element.
/// The containers built on fat pointers extend it by nesting it at the end of a larger header of their own.
struct Header {
	PointerType type; /// How the memory was allocated.
	size_t size; /// The number of elements (not bytes).
}

/// The alignment of every heap fat pointer's first element, and so the largest `T.alignof` a libfp container accepts: `2 * size_t.sizeof`, which C's `malloc` guarantees.
///
/// Examples:
/// ---
/// int* p = allocate!int(1);
/// scope(exit) free(p);
/// assert(cast(size_t) p % maxAlignment == 0);
/// ---
enum size_t maxAlignment = 2 * size_t.sizeof;

/// The padding that, put in front of a header of `bytes` bytes, makes it a whole number of `maxAlignment`s, so the elements just after it are aligned.
/// Every header goes at the front, so the fields that end it stay adjacent to the elements.
///
/// Examples:
/// ---
/// static assert((headerPadding!12 + 12) % maxAlignment == 0);
/// static assert(headerPadding!(2 * maxAlignment) == 0);
/// ---
package enum size_t headerPadding(size_t bytes) = (maxAlignment - bytes % maxAlignment) % maxAlignment;

/// The bytes from the start of a heap or `allocateOnStack` fat pointer's memory to its first element: the `Header`, after the padding that aligns the elements.
///
/// Examples:
/// ---
/// static assert(prefixBytes >= Header.sizeof && prefixBytes % maxAlignment == 0);
/// ---
enum size_t prefixBytes = headerPadding!(Header.sizeof) + Header.sizeof;

/// Returned by every search in libfp when nothing matched.
enum size_t notFound = size_t.max;

/// Returned in place of an index by functions that return one, when an allocation they needed was refused.
/// Like `notFound`, it is never a valid index.
enum size_t allocationRefused = notFound - 1;


// `headerOf`, `valid` and `length` force inlining: callers in other dub packages cannot inline them without LTO, and `length` is hot.

/// The `Header` in front of fat pointer `p`.
/// `p` must not be null.
///
/// Examples:
/// ---
/// int* p = allocate!int(2);
/// scope(exit) free(p);
/// assert(headerOf(p).size == 2);
/// assert(headerOf(p).type == PointerType.heap);
/// ---
pragma(inline, true)
package inout(Header)* headerOf(inout void* p) @trusted {
	assert(p !is null, "fp.pointer: null has no header");
	assert(cast(size_t) p > Header.sizeof, "fp.pointer: a header before the start of memory");
	return cast(inout(Header)*)(cast(const(ubyte)*) p - Header.sizeof);
}

// Thread-local, since every thread querying a null container writes it.
version(WASI) {
	private template decimal(size_t n) {
		static if (n < 10) enum decimal = "0123456789"[n .. n + 1];
		else enum decimal = decimal!(n / 10) ~ decimal!(n % 10);
	}

	// LDC compiles D thread-locals as shared globals on wasm, so the dummy is declared as a real LLVM thread_local instead.
	private H* nullHeaderOf(H)() @trusted {
		static import ldc.llvmasm;
		enum name = `@"fp.pointer.nullHeader.` ~ H.mangleof ~ `"`;
		return ldc.llvmasm.__irEx!(
			name ~ " = linkonce_odr thread_local global [" ~ decimal!(H.sizeof) ~ " x i8] zeroinitializer, align " ~ decimal!(H.alignof),
			"ret ptr " ~ name, "", H*)();
	}
} else {
	private template nullHeader(H) {
		H nullHeader;
	}

	// wrapper: the portable twin of the wasm version above
	private H* nullHeaderOf(H)() @trusted {
		return &nullHeader!H;
	}
}

/// The container header of type `H` in front of fat pointer `p`, for the containers that extend `Header` with one of their own.
/// For null it returns a zeroed dummy of the calling thread's own, so every query on a null container reads as empty rather than faulting, on any number of threads at once; writes to the dummy are discarded by the next call.
///
/// Examples:
/// ---
/// static struct Extended { size_t capacity; Header base; }
/// assert(containerHeaderOf!Extended(null).capacity == 0);
/// ---
package H* containerHeaderOf(H)(inout void* p) @trusted {
	if (p is null) {
		H* dummy = nullHeaderOf!H();
		*dummy = H.init;
		return dummy;
	}
	assert((cast(ushort) headerOf(p).type & validityMask) == validityTag, "fp.pointer: a container header for something that is not a fat pointer");
	assert(H.sizeof >= Header.sizeof + size_t.sizeof, "fp.pointer: a container header holds a capacity in front of the fat pointer header");
	return cast(H*)(cast(const(ubyte)*) p - H.sizeof);
}

/// Whether `p` is a live fat pointer of any kind.
/// A dynarray or hash table that has capacity but no elements yet is valid; any other empty one is not.
///
/// Examples:
/// ---
/// int* p = allocate!int(1);
/// scope(exit) free(p);
/// assert(valid(p));
/// assert(!valid(cast(int*) null));
/// ---
pragma(inline, true)
bool valid(inout void* p) @trusted {
	if (p is null) return false;
	inout(Header)* header = headerOf(p);
	if ((cast(ushort) header.type & validityMask) != validityTag) return false;
	if (header.size > 0) return true;

	// Only dynarray and hash table headers have a `capacity` field in front of this one; reading it for any other kind overruns the allocation.
	if (header.type != PointerType.dynarray && header.type != PointerType.hashTable) return false;
	immutable capacity = *cast(const(size_t)*)(cast(const(ubyte)*) header - size_t.sizeof);
	return capacity > 0;
}

/// How `p` was allocated, or `PointerType.none` if it is null.
///
/// Examples:
/// ---
/// Array!(int, 1) array;
/// assert(pointerType(array) == PointerType.stack);
/// assert(pointerType(cast(int*) null) == PointerType.none);
/// ---
PointerType pointerType(inout void* p) {
	if (p is null) return PointerType.none;
	assert((cast(ushort) headerOf(p).type & validityMask) == validityTag, "fp.pointer: the type of something that is not a fat pointer");
	return headerOf(p).type;
}

/// Whether `p` lives on the stack (`Array` or `allocateOnStack`).
///
/// Examples:
/// ---
/// Array!(int, 1) array;
/// assert(onStack(array));
/// ---
bool onStack(inout void* p) {
	return pointerType(p) == PointerType.stack;
}

/// Whether `p` lives on the heap (`allocate`, `resize`, a dynarray or a hash table); false for null and for anything that is not a fat pointer.
///
/// Examples:
/// ---
/// int* p = allocate!int(1);
/// scope(exit) free(p);
/// assert(onHeap(p));
/// assert(!onHeap(cast(int*) null));
/// ---
bool onHeap(inout void* p) {
	immutable type = pointerType(p);
	return type == PointerType.heap || type == PointerType.dynarray || type == PointerType.hashTable;
}

/// The number of elements (not bytes) in fat pointer `p`, or 0 if it is not valid.
///
/// Examples:
/// ---
/// int* p = allocate!int(6);
/// scope(exit) free(p);
/// assert(length(p) == 6);
/// assert(length(cast(int*) null) == 0);
/// ---
pragma(inline, true)
size_t length(inout void* p) {
	if (!valid(p)) return 0;
	assert(headerOf(p).size != notFound && headerOf(p).size != allocationRefused, "fp.pointer: a length that is a sentinel");
	return headerOf(p).size;
}


/// Whether fat pointer `p` holds no elements.
///
/// Examples:
/// ---
/// assert(empty(cast(int*) null));
/// int* p = allocate!int(1);
/// scope(exit) free(p);
/// assert(!empty(p));
/// ---
bool empty(inout void* p) {
	return length(p) == 0;
}

/// Allocates `payloadBytes` bytes of elements behind a container header of type `H`, which ends in a `Header`.
/// The header is reset to `H.init` and tagged `type`, with no elements, and a terminator follows the payload.
/// Returns the first element, or null if the allocator refused or the total would overflow.
///
/// Examples:
/// ---
/// static struct Extended { ubyte[headerPadding!(size_t.sizeof + Header.sizeof)] padding; size_t capacity; Header base; }
/// int* p = cast(int*) allocateContainer!Extended(4 * int.sizeof, PointerType.dynarray);
/// assert(p !is null);
/// scope(exit) cast(void)allocator(containerHeaderOf!Extended(p), 0);
/// assert(pointerType(p) == PointerType.dynarray && containerHeaderOf!Extended(p).capacity == 0);
/// ---
package void* allocateContainer(H)(size_t payloadBytes, PointerType type) @trusted {
	static assert(H.sizeof % maxAlignment == 0, "fp.pointer: " ~ H.stringof ~ " must be padded to a multiple of maxAlignment");
	bool overflow = false;
	immutable total = core.checkedint.addu(core.checkedint.addu(H.sizeof, payloadBytes, overflow), 1, overflow);
	if (overflow) return null;
	assert(type == PointerType.dynarray || type == PointerType.hashTable, "fp.pointer: only dynarrays and hash tables have container headers");
	ubyte* raw = cast(ubyte*) allocator(null, total);
	if (raw is null) return null;
	assert(cast(size_t) raw % maxAlignment == 0, "fp.pointer: the allocator returned memory aligned below maxAlignment");

	*cast(H*) raw = H.init;
	ubyte* data = raw + H.sizeof;
	headerOf(data).type = type;
	data[payloadBytes] = 0;
	return data;
}

/// Rejects, at compile time, an element type `T` whose alignment exceeds `maxAlignment`, which only `Array` can hold.
///
/// Examples:
/// ---
/// mixin requireAlignable!long;
/// ---
mixin template requireAlignable(T) {
	// The mixin site need not have `fp` in scope.
	static import fp.pointer;
	static assert(T.alignof <= fp.pointer.maxAlignment, "fp.pointer: " ~ T.stringof ~ " needs more alignment than maxAlignment; only fp.pointer.Array accepts it");
}

/// Allocates, reallocates (when `p` is non-null) or, when `size` is 0, frees a heap fat pointer of `size` bytes, recording `size` in its header.
/// `p` must be null or a heap fat pointer.
/// Returns null if the allocator refused or the total with the header would overflow, leaving `p` untouched.
///
/// Examples:
/// ---
/// void* p = resizeHeap(null, 8);
/// assert(headerOf(p).size == 8);
/// assert(resizeHeap(p, 0) is null);
/// ---
package void* resizeHeap(void* p, size_t size) @trusted {
	if (p is null && size == 0) return null;
	assert(p is null || headerOf(p).type == PointerType.heap, "fp.pointer: not a heap fat pointer; free each kind through its own module");
	if (size == 0) {
		cast(void)allocator(cast(ubyte*) p - prefixBytes, 0);
		return null;
	}

	void* base = p is null ? null : cast(ubyte*) p - prefixBytes;
	bool overflow = false;
	immutable total = core.checkedint.addu(core.checkedint.addu(prefixBytes, size, overflow), 1, overflow);
	if (overflow) return null;
	ubyte* raw = cast(ubyte*) allocator(base, total);
	if (raw is null) return null;

	assert(cast(size_t) raw % maxAlignment == 0, "fp.pointer: the allocator returned memory aligned below maxAlignment");
	ubyte* data = raw + prefixBytes;
	Header* header = headerOf(data);
	header.type = PointerType.heap;
	header.size = size;
	data[size] = 0;
	assert(valid(data) && length(data) == size, "fp.pointer: a heap block of the wrong size");
	return data;
}

/// `resizeHeap` for `count` elements of `elementSize` bytes each, recording the element count rather than the byte count.
/// Returns null if the allocator refused or the byte count would overflow, leaving `p` untouched.
///
/// Examples:
/// ---
/// void* p = resizeHeapArray(null, int.sizeof, 4);
/// assert(headerOf(p).size == 4);
/// cast(void)resizeHeap(p, 0);
/// ---
package void* resizeHeapArray(void* p, size_t elementSize, size_t count) @trusted {
	bool overflow = false;
	immutable bytes = core.checkedint.mulu(elementSize, count, overflow);
	if (overflow) return null;
	assert(elementSize > 0, "fp.pointer: elements of no size");
	void* data = resizeHeap(p, bytes);
	if (data is null) return null;
	headerOf(data).size = count;
	assert(count == 0 || valid(data), "fp.pointer: a heap array that is not a fat pointer");
	return data;
}


/// Allocates a heap fat pointer to `n` uninitialized `T`s, or returns null if `n` is 0, the allocator refused, or their byte count would overflow.
/// Elements whose lifetime is not their bytes are left empty.
///
/// Examples:
/// ---
/// float* p = allocate!float(4);
/// scope(exit) free(p);
/// assert(length(p) == 4);
/// assert(onHeap(p));
/// ---
T* allocate(T)(size_t n) {
	mixin requireAlignable!T;
	T* p = cast(T*) resizeHeapArray(null, T.sizeof, n);
	assert(p is null || n == 0 || (onHeap(p) && length(p) == n), "fp.pointer: allocate made the wrong length");
	fp.lifecycle.emptySlots(p, n);
	return p;
}

/// Resizes heap fat pointer `p` (or allocates one, if `p` is null) to `n` elements, preserving the existing ones.
/// Returns null if the allocator refused or their byte count would overflow, in which case `p` is still valid.
/// An `n` of 0 instead frees `p`, also returning null, so `p` must not be used or freed again.
/// Elements whose lifetime is not their bytes are ended in the slots `p` loses and left empty in the ones it gains; shrinking such a type moves the kept elements into a new block.
///
/// Examples:
/// ---
/// int* p = allocate!int(2);
/// p[1] = 7;
/// int* bigger = resize(p, 10);
/// assert(bigger !is null);
/// p = bigger;
/// scope(exit) free(p);
/// assert(length(p) == 10);
/// assert(p[1] == 7);
/// ---
T* resize(T)(T* p, size_t n) {
	mixin requireAlignable!T;
	assert(p is null || pointerType(p) == PointerType.heap, "fp.pointer: resizing something not from allocate");
	immutable oldLength = length(p);
	static if (!fp.lifecycle.isBitMoveable!T) {
		// Truncating the block would drop the removed elements' bytes before their lifetimes could end, so a shrink moves the kept ones into a fresh block.
		if (n < oldLength) {
			if (n == 0) {
				fp.lifecycle.endLifetimes(p, oldLength);
				cast(void) resizeHeap(p, 0);
				return null;
			}
			T* data = cast(T*) resizeHeap(null, T.sizeof * n);
			if (data is null) return null;
			fp.lifecycle.emptySlots(data, n);
			fp.lifecycle.moveRange(data, p, n);
			fp.lifecycle.endLifetimes(p + n, oldLength - n);
			cast(void) resizeHeap(p, 0);
			headerOf(data).size = n;
			return data;
		}
	}
	T* data = cast(T*) resizeHeapArray(cast(void*) p, T.sizeof, n);
	if (data !is null && n > oldLength) fp.lifecycle.emptySlots(data + oldLength, n - oldLength);
	assert(data is null || n == 0 || length(data) == n, "fp.pointer: resize made the wrong length");
	return data;
}

/// Frees heap fat pointer `p`, which may be null but must not be another kind of fat pointer, ending the lifetimes of its elements first.
/// The `ref` overload also sets `p` to null.
///
/// Examples:
/// ---
/// int* p = allocate!int(1);
/// free(p);
/// assert(p is null);
/// free(p); // freeing null is a no-op
/// ---
void free(T)(ref T* p) {
	free(cast(const T*) p);
	p = null;
}
/// Ditto
void free(T)(const T* p) {
	assert(p is null || pointerType(p) == PointerType.heap, "fp.pointer: freeing something not from allocate; free each kind through its own module");
	fp.lifecycle.endLifetimes(cast(T*) p, length(p));
	cast(void)resizeHeap(cast(void*) p, 0);
}


/// A fat pointer to `N` elements in automatic (stack) storage, with its header and terminator alongside.
/// It converts to `T*` implicitly.
/// Unlike the heap containers, it accepts any `T.alignof`.
/// Elements whose type declares a lifetime have it ended when the declaration goes out of scope, and such an `Array` must not be copied: the copy shares the elements' bytes, so both would end the same lifetimes.
///
/// Examples:
/// ---
/// Array!(int, 4) array;
/// array[0] = 3;
/// assert(length(array) == 4);
/// assert(onStack(array));
/// ---
struct Array(T, size_t N) {
	private ubyte[(T.alignof - Header.sizeof % T.alignof) % T.alignof] padding;
	private Header header = Header(PointerType.stack, N);
	private T[N] storage;
	private ubyte terminator = 0;

	// Automatic storage cannot outlive the declaration, so elements with a lifetime declared must have it ended here.
	static if (!fp.lifecycle.isBitMoveable!T) {
		~this() @nogc nothrow { fp.lifecycle.endLifetimes(storage.ptr, N); }
	}

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

/// Writes a stack header and terminator around `count` elements at `data`, returning `data`.
/// `allocateOnStack` calls it as an initializer expression, since a mixin template's body cannot hold statements; it is public because that expression runs in the caller's scope.
///
/// Examples:
/// ---
/// align(maxAlignment) ubyte[prefixBytes + 3 * int.sizeof + 1] buffer;
/// int* p = initializeStackHeader(cast(int*)(buffer.ptr + prefixBytes), 3);
/// assert(length(p) == 3 && onStack(p));
/// ---
T* initializeStackHeader(T)(T* data, size_t count) @trusted {
	assert(data !is null, "fp.pointer: a stack array with no memory");
	assert(cast(size_t) data % T.alignof == 0, "fp.pointer: a stack array misaligned for its elements");
	Header* header = headerOf(data);
	header.type = PointerType.stack;
	header.size = count;
	(cast(ubyte*) data)[T.sizeof * count] = 0;
	fp.lifecycle.emptySlots(data, count);
	return data;
}

/// Declares `T* name`, a fat pointer to `countExpr` elements allocated on the stack with C's `alloca`, for when the size is only known at run time; prefer `Array` when it is known at compile time.
///
/// It is a mixin template because C's `alloca` must run in the stack frame that uses the memory.
/// That memory lives until the enclosing function returns, not until the end of the block, so using it in a loop or a deeply recursive function grows the stack with every pass.
/// Unlike `Array`, no destructor ends the elements' lifetimes, since the only thing in scope is a plain `T*`; call `fp.lifecycle.endLifetimes` before the frame goes away if `T` declares one.
///
/// Params:
///   T         = element type
///   name      = identifier the resulting `T*` is bound to
///   countExpr = source text of a `size_t` expression for the element count
///
/// Examples:
/// ---
/// size_t n = 5;
/// mixin allocateOnStack!(float, "scratch", "n");
/// foreach (ref v; slice(scratch)) v = 1.5f;
/// assert(length(scratch) == 5 && scratch[4] == 1.5f);
/// ---
mixin template allocateOnStack(T, string name, string countExpr) {
	// The body resolves names where it is mixed in, which need not have `fp` in scope.
	static import core.stdc.stdlib;
	static import fp.pointer;
	mixin fp.pointer.requireAlignable!T;
	mixin(
		"auto __" ~ name ~ "_count = cast(size_t)(" ~ countExpr ~ ");"
		~ "ubyte* __" ~ name ~ "_raw = cast(ubyte*) core.stdc.stdlib.alloca(fp.pointer.prefixBytes + T.sizeof * __" ~ name ~ "_count + 1);"
		~ "T* " ~ name ~ " = fp.pointer.initializeStackHeader(cast(T*)(__" ~ name ~ "_raw + fp.pointer.prefixBytes), __" ~ name ~ "_count);"
	);
}


/// A pointer to the last element of `p` (to the first, if `p` is empty).
///
/// Examples:
/// ---
/// Array!(int, 2) array;
/// array[1] = 9;
/// assert(*back(array.ptr) == 9);
/// ---
inout(T)* back(T)(inout T* p) @trusted {
	immutable n = length(p);
	assert(n == 0 || valid(p), "fp.pointer: back of something that is not a fat pointer");
	return p + (n > 0 ? n - 1 : 0);
}

/// A non-owning D slice over all of `p`'s elements.
///
/// Examples:
/// ---
/// Array!(int, 3) array;
/// foreach (i, ref v; slice(array.ptr)) v = cast(int) i;
/// assert(slice(array.ptr) == [0, 1, 2]);
/// ---
inout(T)[] slice(T)(inout T* p) {
	return p[0 .. length(p)];
}


/// Copies the elements of `source` over `destination`, which must be the same length; the two may overlap.
/// The copy is of bytes, so it suits elements whose lifetime is their bytes (`fp.lifecycle.isBitMoveable`); it stands in for slice assignment, which needs druntime under `-betterC`.
/// It cannot fail.
///
/// Examples:
/// ---
/// char[8] buffer;
/// copy(buffer[0 .. 3], "abc");
/// assert(buffer[0 .. 3] == "abc");
/// int[4] numbers = [1, 2, 3, 4];
/// copy(numbers[1 .. 4], numbers[0 .. 3]);
/// assert(numbers == [1, 1, 2, 3]);
/// ---
void copy(T)(T[] destination, const(T)[] source) @trusted {
	static assert(fp.lifecycle.isBitMoveable!T, "fp.pointer.copy copies bytes; move " ~ T.stringof ~ " with fp.lifecycle.moveRange or copyRange");
	assert(destination.length == source.length, "fp.pointer.copy: lengths differ");
	assert(source.length == 0 || (destination.ptr !is null && source.ptr !is null), "fp.pointer.copy: copying to or from nowhere");
	static import core.stdc.string;
	core.stdc.string.memmove(destination.ptr, source.ptr, T.sizeof * source.length);
}

/// Sets every element of `destination` to `value`, as C's `memset` does for bytes; like `copy`, it suits elements whose lifetime is their bytes and stands in for slice assignment under `-betterC`.
/// View raw memory as `(cast(ubyte*) p)[0 .. bytes]` to clear it.
/// It cannot fail.
///
/// Examples:
/// ---
/// ubyte[4] bytes = [1, 2, 3, 4];
/// fill(bytes[1 .. 3], 0);
/// assert(bytes == [1, 0, 0, 4]);
/// long[3] numbers;
/// fill(numbers[], -1);
/// assert(numbers == [-1, -1, -1]);
/// ---
void fill(T)(T[] destination, const T value) @trusted {
	static assert(fp.lifecycle.isBitMoveable!T, "fp.pointer.fill copies bytes; set " ~ T.stringof ~ " elements with fp.lifecycle.copyRange");
	assert(destination.ptr !is null || destination.length == 0, "fp.pointer.fill: filling nowhere");
	static if (T.sizeof == 1) {
		static import core.stdc.string;
		core.stdc.string.memset(destination.ptr, *cast(const(ubyte)*) &value, destination.length);
	} else foreach (ref element; destination) element = value;
}


version(unittest) {
	private __gshared int finalizeCount = 0;

	private struct Handle {
		int* data;
		void finalize() @nogc nothrow { if (data !is null) { ++finalizeCount; data = null; } }
	}
}


unittest {
	int* array = allocate!int(20);
	assert(array !is null);
	scope(exit) assert(array is null); // Scope exits run in reverse order!
	scope(exit) free(array);

	int* bigger = resize!int(array, 25);
	assert(bigger !is null);
	array = bigger;
	array[20] = 6;

	assert(valid(array));
	assert(!onStack(array));
	assert(onHeap(array));
	assert(!onHeap(cast(int*) null) && !onStack(cast(int*) null));
	assert(length(array) == 25);
	assert(array[20] == 6);
	assert(!empty(array));

	// Each thread queries null containers through a dummy header of its own, which no other thread writes.
	version(Posix) {
		static import core.sys.posix.pthread;
		static extern(C) void* dummyOf(void*) @nogc nothrow { return containerHeaderOf!Header(null); }
		core.sys.posix.pthread.pthread_t thread;
		void* theirs;
		assert(core.sys.posix.pthread.pthread_create(&thread, null, &dummyOf, null) == 0);
		assert(core.sys.posix.pthread.pthread_join(thread, &theirs) == 0);
		assert(theirs !is null && theirs !is containerHeaderOf!Header(null));
	}

	int[] view = slice(array);
	assert(view.length == 25 && view[20] == 6);
	int[] sub = view[20 .. 23];
	assert(sub[0] == 6);
	sub[1] = 8;
	assert(array[21] == 8);

	// A `const(int)*` lvalue would still bind to `ref T*`, with `T` deduced as `const(int)`, so only an rvalue reaches the by-value overload.
	int* other = allocate!int(4);
	assert(other !is null);
	free(cast(const int*) other);

	// Byte counts that wrap must be refused, not allocated small: `size_t.max / 4 + 2` ints are 4 bytes past the top.
	assert(allocate!int(size_t.max / 4 + 2) is null);
	assert(allocate!ubyte(size_t.max) is null);
	assert(resize(array, size_t.max / 4 + 2) is null);
	assert(length(array) == 25 && array[20] == 6);

	// Elements with a lifetime: `allocate` starts them empty, `resize` ends the slots it drops and empties the ones it adds, `free` ends the rest.
	static assert(!fp.lifecycle.isBitMoveable!Handle);
	Handle* owned = allocate!Handle(3);
	assert(owned !is null && owned[2].data is null);
	owned[0].data = cast(int*) 1;
	owned[1].data = cast(int*) 2;
	finalizeCount = 0;
	Handle* shrunk = resize!Handle(owned, 1);
	assert(shrunk !is null && length(shrunk) == 1 && finalizeCount == 1);
	Handle* grown = resize!Handle(shrunk, 3);
	assert(grown !is null && grown[2].data is null && finalizeCount == 1);
	free(grown);
	assert(grown is null && finalizeCount == 2);

	Handle* cleared = allocate!Handle(2);
	cleared[0].data = cast(int*) 7;
	finalizeCount = 0;
	assert(resize!Handle(cleared, 0) is null && finalizeCount == 1); // an `n` of 0 frees, ending every element's lifetime
}

unittest {
	Array!(int, 20) fixed;
	fixed[10] = 6;
	assert(valid(fixed) && onStack(fixed) && !onHeap(fixed));
	assert(length(fixed) == 20 && fixed[10] == 6);

	// A stack array ends the lifetimes of elements whose type declares one, at the end of the block they live in.
	finalizeCount = 0;
	{
		Array!(Handle, 3) handles;
		handles[0].data = cast(int*) 1;
		assert(handles[1].data is null);
	}
	assert(finalizeCount == 1);

	// Where `fp` names something else, as after `import fp.pointer : allocateOnStack;`, the mixin must still reach its own module.
	int fp = 0;
	mixin allocateOnStack!(int, "dynamic", "20");
	dynamic[10] = 6;
	assert(valid(dynamic) && onStack(dynamic) && !onHeap(dynamic));
	assert(length(dynamic) == 20 && dynamic[10] == 6 && fp == 0);

	// A struct, and a type the mixin site names only through a qualified import, which its `.stringof` would lose.
	static struct Pair { int a, b; }
	mixin allocateOnStack!(Pair, "pairs", "2");
	pairs[1] = Pair(3, 4);
	assert(length(pairs) == 2 && pairs[1].b == 4);
	static import core.stdc.stdio;
	mixin allocateOnStack!(core.stdc.stdio.fpos_t, "positions", "3");
	assert(length(positions) == 3 && onStack(positions));

	// Elements as aligned as `maxAlignment` allows, wherever they live; `Array` takes any alignment.
	static struct Wide { align(maxAlignment) ubyte b; }
	static struct Wider { align(4 * maxAlignment) ubyte b; }
	Wide* heap = allocate!Wide(3);
	assert(heap !is null);
	scope(exit) free(heap);
	Wide* moved = resize(heap, 300);
	assert(moved !is null);
	heap = moved;
	mixin allocateOnStack!(Wide, "wides", "3");
	Array!(Wide, 3) wideArray;
	Array!(Wider, 3) widerArray;
	assert(cast(size_t) heap % Wide.alignof == 0 && cast(size_t) wides % Wide.alignof == 0);
	assert(cast(size_t) wideArray.ptr % Wide.alignof == 0 && cast(size_t) widerArray.ptr % Wider.alignof == 0);
	assert(length(heap) == 300 && length(wides) == 3 && length(widerArray) == 3);
	static assert(!__traits(compiles, allocate!Wider(1)));

	// `fill` sets one-byte elements of any type, structs and empty slices, and refuses a type with a lifetime of its own.
	char[3] letters = "abc";
	fill(letters[0 .. 2], 'z');
	fill(letters[3 .. 3], 'q');
	assert(letters == "zzc");
	Pair[2] filled;
	fill(filled[], Pair(5, 6));
	assert(filled[0] == Pair(5, 6) && filled[1] == Pair(5, 6));
	Handle[1] owners;
	static assert(__traits(compiles, fill(filled[], Pair.init)) && !__traits(compiles, fill(owners[], Handle.init)));
}

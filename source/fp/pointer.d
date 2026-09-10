module fp.pointer;

import core.stdc.stdlib : cRealloc = realloc, cFree = free, cAlloca = alloca;

/**
 * Signature of the function used to allocate/reallocate/free the raw memory
 * backing a fat pointer. Semantics mirror `realloc`:
 *
 * $(UL
 *   $(LI `p is null && size > 0`: allocate new memory.)
 *   $(LI `p !is null && size > 0`: reallocate, preserving existing data.)
 *   $(LI `size == 0`: free `p` (if non-null) and return `null`.)
 * )
 *
 * Override `fpAllocFunction` to plug in a custom allocator.
 */
alias AllocFn = void* function(void* p, size_t size) @nogc nothrow;

private void* defaultAllocFunction(void* p, size_t size) @nogc nothrow {
	if (size == 0) {
		if (p !is null) cFree(p);
		return null;
	}
	return cRealloc(p, size);
}

/// The allocator currently used by the library. Reassign to customize.
AllocFn allocFunction = &defaultAllocFunction;


@nogc nothrow: // every declaration below is @nogc nothrow unless stated otherwise


package enum PointerType : ushort {
	none = 0,
	heap = 0xFEFE,
	stack = 0xFEFF,
	dynarray = 0xFEFD,
	hashTable = 0xFEFC,
}

private enum ushort validityMask = 0xFF00;
private enum ushort validityTag = 0xFE00;

package struct Header {
	PointerType type;
	size_t size;
}

enum size_t notFound = size_t.max;

package inout(Header)* headerOf(inout(void)* p) @trusted {
	return cast(inout(Header)*)(cast(const(ubyte)*) p - Header.sizeof);
}

package void* rawAlloc(void* p, size_t size) @trusted {
	if (p is null && size == 0) return null;
	if (size == 0) {
		allocFunction(headerOf(p), 0);
		return null;
	}

	void* base = p is null ? null : cast(void*) headerOf(p);
	immutable size_t total = Header.sizeof + size + 1;
	ubyte* raw = cast(ubyte*) allocFunction(base, total);
	if (raw is null) return null;

	ubyte* data = raw + Header.sizeof;
	Header* h = headerOf(data);
	h.type = PointerType.heap;
	h.size = size;
	data[size] = 0;
	return data;
}

package void* rawRealloc(void* p, size_t elemSize, size_t count) @trusted {
	void* data = rawAlloc(p, elemSize * count);
	if (data is null) return null;
	Header* h = headerOf(data);
	h.type = PointerType.heap;
	h.size = count;
	return data;
}

T* malloc(T)(size_t n) {
	return cast(T*) rawRealloc(null, T.sizeof, n);
}

T* realloc(T)(T* p, size_t n) {
	return cast(T*) rawRealloc(cast(void*) p, T.sizeof, n);
}

void free(T)(const T* p) {
	rawAlloc(cast(void*) p, 0);
}
void free(T)(ref T* p) {
	rawAlloc(cast(void*) p, 0);
	p = null;
}

bool valid(inout void* p) @trusted {
	if (p is null) return false;
	inout(Header)* h = headerOf(p);
	size_t capacity = *cast(const(size_t)*)(cast(const(ubyte)*) h - size_t.sizeof);
	return (cast(ushort) h.type & validityMask) == validityTag && (h.size > 0 || capacity > 0);
}

PointerType pointerType(inout void* p) {
	if (p is null) return PointerType.none;
	return headerOf(p).type;
}

bool stackAllocated(inout void* p) {
	return pointerType(p) == PointerType.stack;
}

bool heapAllocated(inout void* p) {
	immutable t = pointerType(p);
	return t == PointerType.heap || t == PointerType.dynarray;
}

/// Number of elements in the fat pointer `p` (not bytes).
size_t length(inout void* p) {
	if (!valid(p)) return 0;
	return headerOf(p).size;
}

alias size = length;

bool empty(inout void* p) {
	return length(p) == 0;
}

inout(T)* front(T)(inout(T)* p) {
	return p;
}

inout(T)* back(T)(inout(T)* p) @trusted {
	immutable n = length(p);
	return p + (n > 0 ? n - 1 : 0);
}

inout(T)[] slice(T)(inout(T)* p) {
	return p[0 .. length(p)];
}

struct Array(T, size_t N) {
	private Header header = Header(PointerType.stack, N);
	private T[N] storage;
	private ubyte terminator = 0;

	/// The fat pointer itself.
	@property inout(T)* ptr() inout @nogc nothrow pure return {
		return storage.ptr;
	}

	alias ptr this;
}



version(DigitalMars) {
	// alloca is a DMD bug under -betterC on Linux (dlang/dmd#18276), so don't even try to use it there.
} else {
	/**
	* Allocate a fat pointer on the stack with a size known only at run time.
	*
	* D has no native runtime-sized automatic (stack) arrays, so — just like the
	* C macro this replaces — this is a `mixin template`: it must be instantiated
	* directly in the scope that needs the buffer, because the `alloca` call has
	* to execute in *that* stack frame to remain valid after the mixin "returns".
	* Prefer `Array` whenever the size is known at compile time.
	*
	* $(B Requires LDC.) DMD fails to inline `alloca` under `-betterC` on Linux
	* (a real `alloca()` call is emitted, which fails to link — a known DMD bug,
	* dlang/dmd#18276) — this reproduces even for a bare, non-templated call, so
	* it isn't specific to this mixin. Build/test with `--compiler=ldc2` when
	* using this mixin; `Array!(T, N)` above has no such restriction.
	*
	* Params:
	*   T         = element type
	*   name      = identifier the resulting `T*` is bound to
	*   countExpr = source text of a `size_t` expression for the element count
	*
	* ---
	* void process(size_t n) {
	*     mixin alloca!(float, "temp", "n");
	*     foreach (ref v; Slice(temp)) v = 1.5f;
	* } // `temp`'s storage is gone once process() returns — never return it!
	* ---
	*/
	mixin template alloca(T, string name, string countExpr) {
		mixin(
			"auto __" ~ name ~ "_count = cast(size_t)(" ~ countExpr ~ ");" 
			~ "ubyte* __" ~ name ~ "_raw = cast(ubyte*) fp.pointer.cAlloca(" ~ "fp.pointer.Header.sizeof + " ~ T.stringof ~ ".sizeof * __" ~ name ~ "_count + 1);" 
			~ T.stringof ~ "* " ~ name ~ " = fp.pointer.initStackHeader(cast(" ~ T.stringof ~ "*)(__" ~ name ~ "_raw + fp.pointer.Header.sizeof), __" ~ name ~ "_count);"
		);
	}

	/**
	* Write a stack-allocation header for `data`/`count` and return `data`
	* back unchanged. Used by `alloca` — the mixin template's body is a
	* declaration scope, so this has to be callable as an initializer
	* expression (`T* name = initStackHeader(...);`) rather than invoked as
	* its own statement. Not normally called directly.
	*/
	package T* initStackHeader(T)(T* data, size_t count) @trusted {
		Header* h = headerOf(data);
		h.type = PointerType.stack;
		h.size = count;
		(cast(ubyte*) data)[T.sizeof * count] = 0;
		return data;
	}

	unittest {
		mixin alloca!(int, "arr", "20");
		arr[10] = 6;

		assert(valid(arr));
		assert(stackAllocated(arr));
		assert(!heapAllocated(arr));
		assert(length(arr) == 20);
		assert(arr[10] == 6);
	}
}


unittest {
	Array!(int, 20) arr;
	arr[10] = 6;

	assert(valid(arr));
	assert(stackAllocated(arr));
	assert(!heapAllocated(arr));
	assert(length(arr) == 20);
	assert(arr[10] == 6);
}

unittest {
	int* arr = malloc!int(20);
	scope(exit) assert(arr is null); // Scope exits run in reverse order!
	scope(exit) free(arr);

	arr = realloc!int(arr, 25);
	arr[20] = 6;

	assert(valid(arr));
	assert(!stackAllocated(arr));
	assert(heapAllocated(arr));
	assert(length(arr) == 25);
	assert(arr[20] == 6);	
}

unittest {
	int* arr = malloc!int(20);
	scope(exit) free(arr);

	arr[10] = 6;

	int[] view = slice(arr);
	assert(view.length == 20);
	assert(view[10] == 6);

	int[] sub = view[10 .. 13];
	assert(sub[0] == 6);
	sub[1] = 8;
	sub[2] = 6;
	assert(view[11] == 8);

	foreach (v; sub)
		assert(v == 6 || v == 8);
}

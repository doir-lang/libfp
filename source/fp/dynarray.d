module fp.dynarray;

import core.stdc.string;

import fp.pointer;
public import fp.pointer : length, size, empty, front, back, slice;

package struct Header {
	size_t capacity;
	fp.pointer.Header base;
}

private enum size_t defaultSizeBytes = 16;

private __gshared Header nullHeaderRef;


@nogc nothrow: // every declaration below is @nogc nothrow unless stated otherwise


package Header* headerOf(inout void* p) @trusted {
	if (p is null) {
		nullHeaderRef = Header.init;
		return &nullHeaderRef;
	}
	return cast(Header*)(cast(const(ubyte)*) p - Header.sizeof);
}

bool valid_dynarray(inout void* p) {
	return headerOf(p).base.type == PointerType.dynarray;
}

alias valid = valid_dynarray;

/// Number of elements that can be stored without reallocating.
size_t capacity(inout void* p) {
	if (!valid(p)) return 0;
	return headerOf(p).capacity;
}

private void* rawAlloc(size_t payloadBytes) @trusted {
	immutable total = Header.sizeof + payloadBytes + 1;
	ubyte* raw = cast(ubyte*) allocFunction(null, total);
	if (raw is null) return null;

	ubyte* data = raw + Header.sizeof;
	Header* h = headerOf(data);
	h.capacity = 0;
	h.base.type = PointerType.dynarray;
	h.base.size = 0;
	data[payloadBytes] = 0;
	return data;
}

/// Grows/shrinks-in-place-if-possible so `da` has room for `newSize` elements, returning a pointer to element `newSize - 1`.
///
/// Returns null if the allocator refused, in which case `da` is left exactly
/// as it was found — still valid, still the old size. `headerOf(null)` hands
/// back a shared dummy header rather than faulting, so an unchecked failure
/// here would not surface until something dereferenced it much later.
package T* maybeGrow(T)(ref T* da, size_t newSize, bool updateUtilized, bool exactSizing) @trusted {
	size_t upperPowerOfTwo(size_t v) pure {
		--v;
		v |= v >> 1;
		v |= v >> 2;
		v |= v >> 4;
		v |= v >> 8;
		v |= v >> 16;
		v |= v >> 32;
		++v;
		return v;
	}

	if (da is null) {
		size_t initialCapacity = exactSizing ? newSize : (defaultSizeBytes / T.sizeof);
		if (initialCapacity == 0) initialCapacity++;
		da = cast(T*) rawAlloc(initialCapacity * T.sizeof);
		if (da is null) return null;
		headerOf(da).capacity = initialCapacity;
	}

	assert(valid(da));
	Header* h = headerOf(da);
	if (h.capacity >= newSize) {
		if (updateUtilized)
			h.base.size = h.base.size > newSize ? h.base.size : newSize;
		return da + (newSize - 1);
	}

	immutable newCapacity = exactSizing ? newSize : upperPowerOfTwo(newSize);
	T* oldData = da;
	T* newData = cast(T*) rawAlloc(newCapacity * T.sizeof);
	// Bail before freeing `oldData`: a caller that cannot grow can still use
	// what it already had.
	if (newData is null) return null;
	Header* newH = headerOf(newData);
	newH.capacity = newCapacity;
	newH.base.size = updateUtilized ? (h.base.size > newSize ? h.base.size : newSize) : h.base.size;
	core.stdc.string.memcpy(newData, oldData, T.sizeof * h.base.size);

	allocFunction(headerOf(oldData), 0);
	da = newData;
	return da + (newSize - 1);
}

/// Grows array to exactly `size` elements (capacity matches size exactly).
T* growToSize(T)(ref T* da, size_t size) {
	return maybeGrow(da, size, true, true);
}

T* create(T)(size_t size) {
	T* da = null;
	if (growToSize(da, size) is null) return null;
	return da;
}

/// Grows array by `toAdd` elements; new elements are uninitialized.
T* grow(T)(ref T* da, size_t toAdd) {
	return maybeGrow(da, length(da) + toAdd, true, false);
}

/// Reserves capacity for at least `size` elements without changing length.
T* reserve(T)(ref T* da, size_t size) {
	return maybeGrow(da, size, false, true);
}

/// Returns false if the array could not grow, leaving it unchanged.
bool pushBack(T)(ref T* da, T value) {
	T* slot = maybeGrow(da, length(da) + 1, true, false);
	if (slot is null) return false;
	*slot = value;
	return true;
}

/// Inserts `count` uninitialized elements at `pos`, returning a pointer to the
/// first of them, or null if the array could not grow.
T* insertUninitialized(T)(ref T* da, size_t pos, size_t count) @trusted {
	assert(count > 0);
	assert(pos <= length(da));

	immutable oldSize = length(da);
	if (maybeGrow(da, oldSize + count, true, false) is null) return null;

	ubyte* raw = cast(ubyte*) da;
	ubyte* oldStart = raw + pos * T.sizeof;
	ubyte* newStart = oldStart + count * T.sizeof;
	immutable bytesToMove = (raw + length(da) * T.sizeof) - newStart;
	core.stdc.string.memmove(newStart, oldStart, bytesToMove);
	return cast(T*) oldStart;
}

/// Ditto
bool insert(T)(ref T* da, size_t pos, T value) {
	T* slot = insertUninitialized(da, pos, 1);
	if (slot is null) return false;
	*slot = value;
	return true;
}

/// Ditto
bool pushFront(T)(ref T* da, T value) {
	return insert(da, 0, value);
}

/// Deletes `count` elements starting at `start`; if `matchCapacity`, also reallocates so capacity matches the new (smaller) size exactly.
T* deleteRange(T)(ref T* da, size_t start, size_t count, bool matchCapacity = false) @trusted {
	immutable oldSize = length(da);
	assert(start + count <= oldSize);

	ubyte* raw = cast(ubyte*) da;
	ubyte* newStart = raw + start * T.sizeof;
	ubyte* oldStart = newStart + count * T.sizeof;
	immutable bytesToMove = (raw + oldSize * T.sizeof) - oldStart;

	if (matchCapacity) {
		immutable newLength = oldSize - count;
		T* newData = null;
		// Shrinking is a convenience, not a requirement: if the smaller
		// allocation is refused, keep the array as it is.
		if (growToSize(newData, newLength) is null) return null;
		Header* newH = headerOf(newData);
		newH.capacity = newLength;

		ubyte* newRaw = cast(ubyte*) newData;
		ubyte* insertedStart = newRaw + start * T.sizeof;
		if (oldStart != raw)
			core.stdc.string.memcpy(newRaw, raw, insertedStart - newRaw);
		core.stdc.string.memcpy(insertedStart, oldStart, bytesToMove);

		allocFunction(headerOf(da), 0);
		da = newData;
		newStart = insertedStart;
	} else if (count > 0) {
		headerOf(da).base.size -= count;
		core.stdc.string.memmove(newStart, oldStart, bytesToMove);
	}

	return cast(T*) newStart;
}

T* removeAt(T)(ref T* da, size_t pos) {
	return deleteRange(da, pos, 1, false);
}

T* shrinkToFit(T)(ref T* da) {
	return deleteRange(da, 0, 0, true);
}

/// Removes the last `count` elements; returns a pointer to the first removed one.
T* popBackCount(T)(T* da, size_t count) @trusted {
	assert(count <= length(da));
	Header* h = headerOf(da);
	h.base.size = h.base.size <= count ? 0 : h.base.size - count;
	return da + h.base.size;
}

T* popBack(T)(T* da) {
	return popBackCount(da, 1);
}

/// Sets size to 0 without freeing the underlying capacity.
void clear(T)(T* da) @trusted {
	headerOf(da).base.size = 0;
}

/// Returns false if the scratch buffer the swap needs could not be allocated.
bool swapRange(T)(T* da, size_t start1, size_t start2, size_t count) @trusted {
	assert(start1 + count <= length(da));
	assert(start2 + count <= length(da));
	if (start1 == start2 || count == 0) return true;

	immutable bytes = count * T.sizeof;
	ubyte* scratch = cast(ubyte*) allocFunction(null, bytes);
	if (scratch is null) return false;

	ubyte* a = cast(ubyte*)(da + start1);
	ubyte* b = cast(ubyte*)(da + start2);
	core.stdc.string.memcpy(scratch, a, bytes);
	core.stdc.string.memcpy(a, b, bytes);
	core.stdc.string.memcpy(b, scratch, bytes);

	allocFunction(scratch, 0);
	return true;
}

/// Ditto
bool swap(T)(T* da, size_t pos1, size_t pos2) {
	return swapRange(da, pos1, pos2, 1);
}

/// Copies `src`'s elements (and, unless `shrink`, its spare capacity) into
/// `dest`. Returns false if `dest` could not be sized to hold them.
bool cloneTo(T)(ref T* dest, inout T* src, bool shrink = false) @trusted {
	immutable newCapacity = shrink ? length(src) : capacity(src);
	if (growToSize(dest, newCapacity) is null) return false;
	core.stdc.string.memcpy(dest, src, length(dest) * T.sizeof);
	Header* h = headerOf(dest);
	h.capacity = newCapacity;
	h.base.size = length(src);
	return true;
}

T* clone(T)(inout T* src) {
	if (src is null) return null;
	T* result = null;
	if (!cloneTo(result, src, true)) return null;
	return result;
}

/// Ditto
bool concatenate(T)(ref T* dest, inout(T)[] src) @trusted {
	immutable preSize = length(dest);
	if (maybeGrow(dest, preSize + src.length, true, false) is null) return false;
	core.stdc.string.memcpy(dest + preSize, src.ptr, src.length * T.sizeof);
	return true;
}

void concatenate(T)(ref T* dest, inout T* src) {
	concatenate(dest, slice(src));
}

void free(T)(const T* da) @trusted {
	if (da !is null) allocFunction(headerOf(da), 0);
}
void free(T)(ref T* da) @trusted {
	free(cast(const T*) da);
	da = null;
}

unittest {
	// headerOf(null) / valid / capacity / length on a never-allocated pointer.
	int* neverAllocated = null;
	assert(!valid_dynarray(neverAllocated));
	assert(capacity(neverAllocated) == 0);
	assert(length(neverAllocated) == 0);
}

unittest {
	int* arr = null;
	scope(exit) assert(arr is null); // Scope exits run in reverse order!
	scope(exit) free(arr);

	reserve(arr, 20);
	assert(capacity(arr) == 20); // NOTE: dynarrays aren't "valid" until they have had at least one element added!
	assert(length(arr) == 0);

	pushBack(arr, 5);
	assert(capacity(arr) == 20);
	assert(length(arr) == 1);
	assert(arr[0] == 5);

	pushFront(arr, 6);
	assert(capacity(arr) == 20);
	assert(length(arr) == 2);
	assert(arr[0] == 6);
	assert(arr[1] == 5);
	assert(*front(arr) == 6);
	assert(*back(arr) == 5);

	pushBack(arr, 7);
	assert(capacity(arr) == 20);
	assert(length(arr) == 3);
	assert(arr[0] == 6);
	assert(arr[1] == 5);
	assert(arr[2] == 7);
	assert(*front(arr) == 6);
	assert(*back(arr) == 7);

	removeAt(arr, 1);
	assert(capacity(arr) == 20);
	assert(length(arr) == 2);
	assert(arr[0] == 6);
	assert(arr[1] == 7);

	swap(arr, 0, 1);
	assert(capacity(arr) == 20);
	assert(length(arr) == 2);
	assert(arr[0] == 7);
	assert(arr[1] == 6);

	int* arr2 = null;
	scope(exit) assert(arr2 is null); // Scope exits run in reverse order!
	scope(exit) free(arr2);

	cloneTo(arr2, arr);
	assert(arr2 != arr);
	assert(capacity(arr) == 20);
	assert(capacity(arr2) == 20);
	assert(length(arr) == 2);
	assert(length(arr2) == 2);
	assert(arr[0] == 7);
	assert(arr2[0] == 7);
	assert(arr[1] == 6);
	assert(arr2[1] == 6);

	shrinkToFit(arr);
	assert(capacity(arr) == 2);
	assert(length(arr) == 2);
	assert(arr[0] == 7);
	assert(arr[1] == 6);
}

unittest {
	int* arr = null;
	scope(exit) assert(arr is null); // Scope exits run in reverse order!
	scope(exit) free(arr);

	foreach (i; 0 .. 5)
		pushBack(arr, i);

	int[3] extra = [5, 6, 7];
	concatenate(arr, extra[]);
	assert(length(arr) == 8);
	foreach (i, v; slice(arr))
		assert(v == i);

	popBack(arr);
	assert(length(arr) == 7);

	clear(arr);
	assert(length(arr) == 0);
	assert(capacity(arr) >= 7);
}

unittest {
	// deleteRange(..., matchCapacity: true) with start > 0: exercises the
	// "copy the surviving prefix before the deleted range" path, which
	// shrinkToFit (start == 0 always) never reaches.
	int* arr = null;
	scope(exit) assert(arr is null); // Scope exits run in reverse order!
	scope(exit) free(arr);

	foreach (i; 0 .. 5)
		pushBack(arr, i);

	deleteRange(arr, 1, 2, true);
	assert(capacity(arr) == 3);
	assert(length(arr) == 3);
	assert(arr[0] == 0);
	assert(arr[1] == 3);
	assert(arr[2] == 4);
}

unittest {
	// The `const T*` overload of `free` (as opposed to the `ref T*` one):
	// a `const(int)*` *lvalue* would still bind to `ref T*` with `T`
	// deduced as `const(int)`, so this needs a genuine rvalue (an
	// unaddressable cast expression) to force the by-value overload.
	int* arr = null;
	pushBack(arr, 1);
	free(cast(const int*) arr);
}

version(unittest) {
	private __gshared AllocFunction rationedUnderlying;
	private __gshared size_t rationedRemaining;

	private void* rationedAlloc(void* p, size_t size) @nogc nothrow {
		// Frees are always forwarded, or a test could not clean up after itself.
		if (size == 0) return rationedUnderlying(p, 0);
		if (rationedRemaining == 0) return null;
		--rationedRemaining;
		return rationedUnderlying(p, size);
	}

	/**
	* Installs an allocator that lets the next `n` allocations through and
	* refuses every one after that, so the out-of-memory paths can be walked
	* without being out of memory. `n` of 0 refuses everything; a larger `n`
	* reaches a failure that only a *later* allocation can produce.
	*
	* `allocFunction` is a plain global, so this is a save/restore pair: hand
	* what it returns to `endRationedAllocator`, from a `scope(exit)`.
	*/
	package AllocFunction beginRationedAllocator(size_t n = 0) @nogc nothrow {
		AllocFunction previous = allocFunction;
		rationedUnderlying = previous;
		rationedRemaining = n;
		allocFunction = &rationedAlloc;
		return previous;
	}

	/// Ditto.
	package void endRationedAllocator(AllocFunction previous) @nogc nothrow {
		allocFunction = previous;
	}
}

unittest {
	// Every growth path under an allocator that refuses. Before these, a
	// refused allocation was not reported at all: `headerOf(null)` hands back
	// a shared dummy header instead of faulting, so `maybeGrow` would carry
	// on and the failure surfaced later as a null dereference (or, with
	// asserts on, as `assert(valid(da))` firing three lines further down).

	// Growing from nothing.
	auto previous = beginRationedAllocator();
	int* fresh = null;
	assert(growToSize(fresh, 4) is null);
	assert(fresh is null);     // And nothing was half-built.
	assert(create!int(4) is null);
	assert(!pushBack(fresh, 1));
	endRationedAllocator(previous);

	// Growing something that already exists: the old array has to survive.
	int* existing = null;
	assert(pushBack(existing, 11));
	assert(pushBack(existing, 22));
	scope(exit) free(existing);
	// Fill the spare capacity `pushBack` left, so that everything below has
	// to reallocate and a refusal is the only reason it could fail.
	while (length(existing) < capacity(existing))
		assert(pushBack(existing, 0));
	immutable filled = length(existing);
	int* before = existing;

	previous = beginRationedAllocator();
	// Big enough that it cannot come out of the spare capacity pushBack left.
	assert(reserve(existing, 4096) is null);
	assert(!pushBack(existing, 33));
	static immutable int[2] more = [44, 55];
	assert(!concatenate(existing, more[]));
	assert(insertUninitialized(existing, 0, 4096) is null);
	assert(!insert(existing, 0, 66));
	assert(!pushFront(existing, 77));
	assert(clone(existing) is null);
	endRationedAllocator(previous);

	// Untouched: same allocation, same contents, same length.
	assert(existing is before);
	assert(length(existing) == filled);
	assert(existing[0] == 11 && existing[1] == 22);
}

unittest {
	// `swapRange` needs a scratch buffer, and used to memcpy into it without
	// checking that it got one.
	int* array = null;
	assert(pushBack(array, 1));
	assert(pushBack(array, 2));
	scope(exit) free(array);

	auto previous = beginRationedAllocator();
	assert(!swap(array, 0, 1));
	endRationedAllocator(previous);

	assert(array[0] == 1 && array[1] == 2); // Refused, not half-swapped.
	assert(swap(array, 0, 1));
	assert(array[0] == 2 && array[1] == 1);
}

unittest {
	// create()'s happy path: every other test either builds an array with
	// pushBack/growToSize directly or exercises create() only under a
	// refusing allocator, so its own `return da;` was never reached.
	int* arr = create!int(3);
	scope(exit) free(arr);

	assert(arr !is null);
	assert(length(arr) == 3);
	assert(capacity(arr) == 3);
}

unittest {
	// clone()'s happy path, likewise only ever exercised under a refusing
	// allocator elsewhere.
	int* src = null;
	scope(exit) free(src);
	foreach (i; 0 .. 3)
		assert(pushBack(src, i * 10));

	int* copy = clone(src);
	scope(exit) free(copy);

	assert(copy !is null);
	assert(copy != src);
	assert(length(copy) == 3);
	assert(copy[0] == 0 && copy[1] == 10 && copy[2] == 20);
}

/// Growable arrays on top of `fp.pointer`. A dynarray is a plain `T*` whose header also records its capacity, so it indexes like any pointer and grows like a vector. A null `T*` is an empty dynarray, ready to grow.
///
/// Every function that can allocate reports a refused allocation, or a size whose byte count would overflow, by returning null or false, and leaves the array as it was.
///
/// Examples:
/// ---
/// int* arr = null;
/// scope(exit) free(arr);
/// foreach (i; 0 .. 4)
/// 	assert(pushBack(arr, i));
/// assert(length(arr) == 4 && arr[3] == 3);
/// ---
module fp.dynarray;

import core.stdc.string;
static import core.checkedint;

static import fp.pointer;
public import fp.pointer : length, size, empty, front, back, slice; // As aliases that can be applied to dynarrays


/// A dynarray's header: its capacity in front of the `fp.pointer.Header` every fat pointer has.
package struct Header {
	size_t capacity; /// Elements storable without reallocating.
	fp.pointer.Header base; /// The fat pointer header, with the length.
}

private enum size_t defaultSizeBytes = 16;

private __gshared Header nullHeaderRef;


@nogc nothrow:


/// The header in front of dynarray `p`. For null it returns a zeroed shared dummy, so every query on a null dynarray reads as empty rather than faulting; writes to the dummy are discarded by the next call.
///
/// Examples:
/// ---
/// int* arr = null;
/// assert(headerOf(arr).capacity == 0);
/// assert(reserve(arr, 4) !is null);
/// scope(exit) free(arr);
/// assert(headerOf(arr).capacity == 4);
/// ---
package Header* headerOf(inout void* p) @trusted {
	if (p is null) {
		nullHeaderRef = Header.init;
		return &nullHeaderRef;
	}
	return cast(Header*)(cast(const(ubyte)*) p - Header.sizeof);
}

private void* rawAlloc(size_t payloadBytes) @trusted {
	bool overflow = false;
	immutable total = core.checkedint.addu(core.checkedint.addu(Header.sizeof, payloadBytes, overflow), 1, overflow);
	if (overflow) return null;
	ubyte* raw = cast(ubyte*) fp.pointer.allocFunction(null, total);
	if (raw is null) return null;

	ubyte* data = raw + Header.sizeof;
	Header* h = headerOf(data);
	h.capacity = 0;
	h.base.type = fp.pointer.PointerType.dynarray;
	h.base.size = 0;
	data[payloadBytes] = 0;
	return data;
}


/// Whether `p` is a dynarray (as opposed to null or another kind of fat pointer).
///
/// Examples:
/// ---
/// int* arr = null;
/// assert(!validDynarray(arr));
/// assert(pushBack(arr, 1));
/// scope(exit) free(arr);
/// assert(validDynarray(arr));
/// ---
bool validDynarray(inout void* p) {
	return headerOf(p).base.type == fp.pointer.PointerType.dynarray;
}

/// Ditto
alias valid = validDynarray;

/// The number of elements `p` can hold without reallocating.
///
/// Examples:
/// ---
/// int* arr = null;
/// assert(capacity(arr) == 0);
/// assert(reserve(arr, 8) !is null);
/// scope(exit) free(arr);
/// assert(capacity(arr) == 8 && length(arr) == 0);
/// ---
size_t capacity(inout void* p) {
	if (!valid(p)) return 0;
	return headerOf(p).capacity;
}


// Smears the highest set bit of `v - 1` into every lower bit; adding one then gives the smallest power of two not below `v`.
private size_t upperPowerOfTwo(size_t v) pure {
	--v;
	for (size_t shift = 1; shift < size_t.sizeof * 8; shift <<= 1)
		v |= v >> shift;
	return v + 1;
}

/// The growth engine behind every function that adds elements: makes room for `newSize` elements, reallocating only if the capacity is short. `updateUtilized` raises the length to `newSize` (it never lowers it); `exactSizing` makes a reallocation exactly `newSize` rather than the next power of two. Returns a pointer to element `newSize - 1`, or null if the allocator refused or the new capacity's byte count would overflow, in which case `da` is unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// int* last = maybeGrow(arr, 3, true, false);
/// scope(exit) free(arr);
/// assert(last is arr + 2);
/// assert(length(arr) == 3 && capacity(arr) == 4);
/// ---
package T* maybeGrow(T)(ref T* da, size_t newSize, bool updateUtilized, bool exactSizing) @trusted {
	if (da !is null) {
		assert(valid(da));
		Header* h = headerOf(da);
		if (h.capacity >= newSize) {
			if (updateUtilized)
				h.base.size = h.base.size > newSize ? h.base.size : newSize;
			return da + (newSize - 1);
		}
	}

	// Even a null array gets a capacity of at least one, so `create!T(0)` is a real allocation.
	size_t newCapacity = exactSizing ? newSize : upperPowerOfTwo(newSize);
	if (da is null && !exactSizing && newCapacity < defaultSizeBytes / T.sizeof)
		newCapacity = defaultSizeBytes / T.sizeof;
	if (newCapacity == 0) newCapacity = 1;
	if (newCapacity < newSize) return null; // `upperPowerOfTwo` wrapped past the top bit
	bool overflow = false;
	immutable bytes = core.checkedint.mulu(newCapacity, T.sizeof, overflow);
	if (overflow) return null;

	immutable oldSize = headerOf(da).base.size; // the zeroed dummy's for null
	T* newData = cast(T*) rawAlloc(bytes);
	if (newData is null) return null;
	Header* newH = headerOf(newData);
	newH.capacity = newCapacity;
	newH.base.size = updateUtilized ? newSize : oldSize;
	if (da !is null) {
		core.stdc.string.memcpy(newData, da, T.sizeof * oldSize);
		cast(void)fp.pointer.allocFunction(headerOf(da), 0);
	}
	da = newData;
	return da + (newSize - 1);
}


/// Makes room for at least `size` elements without changing the length. Returns null if the allocator refused or `size` elements' byte count would overflow, leaving `da` unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// assert(reserve(arr, 100) !is null);
/// scope(exit) free(arr);
/// assert(capacity(arr) == 100 && length(arr) == 0);
/// ---
T* reserve(T)(ref T* da, size_t size) {
	return maybeGrow(da, size, false, true);
}

/// Grows `da` to at least `size` elements, reallocating to exactly `size` if it must reallocate at all. New elements are uninitialized. Returns a pointer to element `size - 1`, or null if the allocator refused or `size` elements' byte count would overflow, leaving `da` unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// int* last = growToSize(arr, 5);
/// scope(exit) free(arr);
/// assert(last is arr + 4);
/// assert(length(arr) == 5 && capacity(arr) == 5);
/// ---
T* growToSize(T)(ref T* da, size_t size) {
	return maybeGrow(da, size, true, true);
}

/// Appends `toAdd` uninitialized elements, rounding any reallocation up to a power of two. Returns a pointer to the new last element, or null if the allocator refused or the new length would overflow, leaving `da` unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// int* last = grow(arr, 3);
/// scope(exit) free(arr);
/// *last = 9;
/// assert(length(arr) == 3 && arr[2] == 9);
/// ---
T* grow(T)(ref T* da, size_t toAdd) {
	bool overflow = false;
	immutable newSize = core.checkedint.addu(length(da), toAdd, overflow);
	return overflow ? null : maybeGrow(da, newSize, true, false);
}

/// Appends `value`. Returns false if the array could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// scope(exit) free(arr);
/// assert(pushBack(arr, 1) && pushBack(arr, 2));
/// assert(slice(arr) == [1, 2]);
/// ---
bool pushBack(T)(ref T* da, T value) {
	T* slot = maybeGrow(da, length(da) + 1, true, false);
	if (slot is null) return false;
	*slot = value;
	return true;
}

/// Inserts `count` uninitialized elements before element `pos`, returning a pointer to the first of them, or null if the array could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// scope(exit) free(arr);
/// assert(pushBack(arr, 1) && pushBack(arr, 4));
/// int* gap = insertUninitialized(arr, 1, 2);
/// gap[0] = 2;
/// gap[1] = 3;
/// assert(slice(arr) == [1, 2, 3, 4]);
/// ---
T* insertUninitialized(T)(ref T* da, size_t pos, size_t count) @trusted {
	assert(count > 0);
	assert(pos <= length(da));

	bool overflow = false;
	immutable newSize = core.checkedint.addu(length(da), count, overflow);
	if (overflow || maybeGrow(da, newSize, true, false) is null) return null;

	ubyte* raw = cast(ubyte*) da;
	ubyte* oldStart = raw + pos * T.sizeof;
	ubyte* newStart = oldStart + count * T.sizeof;
	immutable bytesToMove = (raw + length(da) * T.sizeof) - newStart;
	core.stdc.string.memmove(newStart, oldStart, bytesToMove);
	return cast(T*) oldStart;
}

/// Inserts `value` before element `pos`. Returns false if the array could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// scope(exit) free(arr);
/// assert(pushBack(arr, 1) && pushBack(arr, 3));
/// assert(insert(arr, 1, 2));
/// assert(slice(arr) == [1, 2, 3]);
/// ---
bool insert(T)(ref T* da, size_t pos, T value) {
	T* slot = insertUninitialized(da, pos, 1);
	if (slot is null) return false;
	*slot = value;
	return true;
}

/// Inserts `value` before element 0, moving every element up one. Returns false if the array could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// scope(exit) free(arr);
/// assert(pushBack(arr, 2) && pushFront(arr, 1));
/// assert(slice(arr) == [1, 2]);
/// ---
bool pushFront(T)(ref T* da, T value) {
	return insert(da, 0, value);
}

/// Appends a copy of every element of `src`. Returns false if the array could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// scope(exit) free(arr);
/// int[3] more = [1, 2, 3];
/// assert(concatenate(arr, more[]));
///
/// int* copy = clone(arr);
/// scope(exit) free(copy);
/// assert(concatenate(arr, copy));
/// assert(length(arr) == 6 && arr[5] == 3);
/// ---
bool concatenate(T)(ref T* dest, inout(T)[] src) @trusted {
	immutable preSize = length(dest);
	if (maybeGrow(dest, preSize + src.length, true, false) is null) return false;
	core.stdc.string.memcpy(dest + preSize, src.ptr, src.length * T.sizeof);
	return true;
}
/// Ditto
bool concatenate(T)(ref T* dest, inout T* src) {
	return concatenate(dest, slice(src));
}


/// Allocates a dynarray of `size` uninitialized elements, with no spare capacity. Returns null if the allocator refused.
///
/// Examples:
/// ---
/// int* arr = create!int(3);
/// scope(exit) free(arr);
/// assert(length(arr) == 3 && capacity(arr) == 3);
/// ---
T* create(T)(size_t size) {
	T* da = null;
	if (growToSize(da, size) is null) return null;
	return da;
}

/// Copies `src`'s elements into `dest`, with `src`'s capacity unless `shrink` is set. Returns false if `dest` could not be sized to hold them, leaving it unchanged.
///
/// Examples:
/// ---
/// int* src = null;
/// scope(exit) free(src);
/// assert(reserve(src, 10) !is null);
/// assert(pushBack(src, 1));
///
/// int* dest = null;
/// scope(exit) free(dest);
/// assert(cloneTo(dest, src));
/// assert(length(dest) == 1 && capacity(dest) == 10);
/// ---
bool cloneTo(T)(ref T* dest, inout T* src, bool shrink = false) @trusted {
	immutable newCapacity = shrink ? length(src) : capacity(src);
	if (growToSize(dest, newCapacity) is null) return false;
	core.stdc.string.memcpy(dest, src, length(src) * T.sizeof);
	Header* h = headerOf(dest);
	h.capacity = newCapacity;
	h.base.size = length(src);
	return true;
}

/// A new dynarray holding a copy of `src`'s elements and no spare capacity, or null if `src` is null or the allocator refused.
///
/// Examples:
/// ---
/// int* src = null;
/// scope(exit) free(src);
/// assert(pushBack(src, 5));
///
/// int* copy = clone(src);
/// scope(exit) free(copy);
/// assert(copy !is src && length(copy) == 1 && copy[0] == 5);
/// ---
T* clone(T)(inout T* src) {
	if (src is null) return null;
	T* result = null;
	if (!cloneTo(result, src, true)) return null;
	return result;
}

/// Frees dynarray `da`, which may be null. The `ref` overload also sets `da` to null.
///
/// Examples:
/// ---
/// int* arr = null;
/// assert(pushBack(arr, 1));
/// free(arr);
/// assert(arr is null);
/// ---
void free(T)(ref T* da) @trusted {
	free(cast(const T*) da);
	da = null;
}
/// Ditto
void free(T)(const T* da) @trusted {
	if (da !is null) cast(void)fp.pointer.allocFunction(headerOf(da), 0);
}


/// Removes the last `count` elements, keeping their capacity. Returns a pointer to where the first of them was.
///
/// Examples:
/// ---
/// int* arr = create!int(5);
/// scope(exit) free(arr);
/// assert(popBackCount(arr, 3) is arr + 2);
/// assert(length(arr) == 2 && capacity(arr) == 5);
/// ---
T* popBackCount(T)(T* da, size_t count) @trusted {
	assert(count <= length(da));
	Header* h = headerOf(da);
	h.base.size = h.base.size <= count ? 0 : h.base.size - count;
	return da + h.base.size;
}

/// Removes the last element, keeping its capacity. Returns a pointer to where it was.
///
/// Examples:
/// ---
/// int* arr = null;
/// scope(exit) free(arr);
/// assert(pushBack(arr, 1) && pushBack(arr, 2));
/// assert(*popBack(arr) == 2);
/// assert(length(arr) == 1);
/// ---
T* popBack(T)(T* da) {
	return popBackCount(da, 1);
}

/// Removes `count` elements starting at `start`, moving every later element down. With `matchCapacity`, it also reallocates so capacity equals the new length. Returns a pointer to element `start`, or null if that reallocation was refused, in which case the array is unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// scope(exit) free(arr);
/// int[5] values = [0, 1, 2, 3, 4];
/// assert(concatenate(arr, values[]));
/// assert(deleteRange(arr, 1, 2, true) !is null);
/// assert(slice(arr) == [0, 3, 4] && capacity(arr) == 3);
/// ---
T* deleteRange(T)(ref T* da, size_t start, size_t count, bool matchCapacity = false) @trusted {
	immutable oldSize = length(da);
	assert(count <= oldSize && start <= oldSize - count);

	ubyte* raw = cast(ubyte*) da;
	ubyte* newStart = raw + start * T.sizeof;
	ubyte* oldStart = newStart + count * T.sizeof;
	immutable bytesToMove = (raw + oldSize * T.sizeof) - oldStart;

	if (matchCapacity) {
		immutable newLength = oldSize - count;
		T* newData = null;
		if (growToSize(newData, newLength) is null) return null;
		Header* newH = headerOf(newData);
		newH.capacity = newLength;

		ubyte* newRaw = cast(ubyte*) newData;
		ubyte* insertedStart = newRaw + start * T.sizeof;
		if (oldStart != raw)
			core.stdc.string.memcpy(newRaw, raw, insertedStart - newRaw);
		core.stdc.string.memcpy(insertedStart, oldStart, bytesToMove);

		// `headerOf(null)` is the shared dummy, not an allocation.
		if (da !is null) cast(void)fp.pointer.allocFunction(headerOf(da), 0);
		da = newData;
		newStart = insertedStart;
	} else if (count > 0) {
		headerOf(da).base.size -= count;
		core.stdc.string.memmove(newStart, oldStart, bytesToMove);
	}

	return cast(T*) newStart;
}

/// Removes element `pos`, moving every later element down one. Returns a pointer to element `pos`, which now holds what followed it.
///
/// Examples:
/// ---
/// int* arr = null;
/// scope(exit) free(arr);
/// int[3] values = [1, 2, 3];
/// assert(concatenate(arr, values[]));
/// assert(*removeAt(arr, 0) == 2);
/// assert(slice(arr) == [2, 3]);
/// ---
T* removeAt(T)(ref T* da, size_t pos) {
	return deleteRange(da, pos, 1, false);
}

/// Sets the length to 0, keeping the capacity.
///
/// Examples:
/// ---
/// int* arr = create!int(4);
/// scope(exit) free(arr);
/// clear(arr);
/// assert(length(arr) == 0 && capacity(arr) == 4);
/// ---
void clear(T)(T* da) @trusted {
	headerOf(da).base.size = 0;
}

/// Reallocates so capacity equals length. Returns null if the allocator refused, in which case the array is unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// scope(exit) free(arr);
/// assert(reserve(arr, 50) !is null && pushBack(arr, 1));
/// assert(shrinkToFit(arr) !is null);
/// assert(capacity(arr) == 1 && arr[0] == 1);
/// ---
T* shrinkToFit(T)(ref T* da) {
	return deleteRange(da, 0, 0, true);
}


/// Swaps the `count` elements starting at `start1` with the `count` starting at `start2`; the ranges must not overlap. Returns false if the scratch buffer the swap needs could not be allocated, leaving both untouched.
///
/// Examples:
/// ---
/// int* arr = null;
/// scope(exit) free(arr);
/// int[4] values = [1, 2, 3, 4];
/// assert(concatenate(arr, values[]));
/// assert(swapRange(arr, 0, 2, 2));
/// assert(slice(arr) == [3, 4, 1, 2]);
/// ---
bool swapRange(T)(T* da, size_t start1, size_t start2, size_t count) @trusted {
	assert(count <= length(da) && start1 <= length(da) - count);
	assert(start2 <= length(da) - count);
	if (start1 == start2 || count == 0) return true;

	immutable bytes = count * T.sizeof;
	ubyte* scratch = cast(ubyte*) fp.pointer.allocFunction(null, bytes);
	if (scratch is null) return false;

	ubyte* a = cast(ubyte*)(da + start1);
	ubyte* b = cast(ubyte*)(da + start2);
	core.stdc.string.memcpy(scratch, a, bytes);
	core.stdc.string.memcpy(a, b, bytes);
	core.stdc.string.memcpy(b, scratch, bytes);

	cast(void)fp.pointer.allocFunction(scratch, 0);
	return true;
}

/// Swaps elements `pos1` and `pos2`. Returns false if the scratch buffer the swap needs could not be allocated, leaving both untouched.
///
/// Examples:
/// ---
/// int* arr = null;
/// scope(exit) free(arr);
/// assert(pushBack(arr, 1) && pushBack(arr, 2));
/// assert(swap(arr, 0, 1));
/// assert(slice(arr) == [2, 1]);
/// ---
bool swap(T)(T* da, size_t pos1, size_t pos2) {
	return swapRange(da, pos1, pos2, 1);
}


version(unittest) {
	private __gshared fp.pointer.AllocFunction rationedUnderlying;
	private __gshared size_t rationedRemaining;

	private void* rationedAlloc(void* p, size_t size) {
		// Frees are always forwarded, or a test could not clean up after itself.
		if (size == 0) return rationedUnderlying(p, 0);
		if (rationedRemaining == 0) return null;
		--rationedRemaining;
		return rationedUnderlying(p, size);
	}

	/// For tests of refused allocations: `beginRationedAllocator` makes `fp.pointer.allocFunction` grant only the next `n` allocations and refuse the rest, while still freeing; `endRationedAllocator` restores the allocator it returned.
	///
	/// Examples:
	/// ---
	/// auto previous = beginRationedAllocator(1);
	/// int* granted = create!int(1);
	/// assert(granted !is null && create!int(1) is null);
	/// free(granted);
	/// endRationedAllocator(previous);
	/// ---
	package fp.pointer.AllocFunction beginRationedAllocator(size_t n = 0) {
		fp.pointer.AllocFunction previous = fp.pointer.allocFunction;
		rationedUnderlying = previous;
		rationedRemaining = n;
		fp.pointer.allocFunction = &rationedAlloc;
		return previous;
	}

	/// Ditto
	package void endRationedAllocator(fp.pointer.AllocFunction previous) {
		fp.pointer.allocFunction = previous;
	}
}


unittest {
	int* neverAllocated = null;
	assert(!validDynarray(neverAllocated));
	assert(capacity(neverAllocated) == 0);
	assert(length(neverAllocated) == 0);

	enum size_t topBit = size_t(1) << (size_t.sizeof * 8 - 1);
	assert(upperPowerOfTwo(1) == 1 && upperPowerOfTwo(5) == 8 && upperPowerOfTwo(8) == 8);
	assert(upperPowerOfTwo((topBit >> 1) + 1) == topBit);
}

unittest {
	int* arr = null;
	scope(exit) assert(arr is null); // Scope exits run in reverse order!
	scope(exit) free(arr);

	assert(reserve(arr, 20) !is null);
	assert(capacity(arr) == 20); // NOTE: dynarrays aren't "valid" until they have had at least one element added!
	assert(length(arr) == 0);

	assert(pushBack(arr, 5));
	assert(pushFront(arr, 6));
	assert(pushBack(arr, 7));
	assert(capacity(arr) == 20);
	assert(slice(arr) == [6, 5, 7]);
	assert(*front(arr) == 6 && *back(arr) == 7);

	int[2] extra = [8, 9];
	assert(concatenate(arr, extra[]));
	assert(slice(arr) == [6, 5, 7, 8, 9]);

	assert(removeAt(arr, 1) !is null);
	assert(*popBack(arr) == 9);
	assert(swap(arr, 0, 1));
	assert(capacity(arr) == 20);
	assert(slice(arr) == [7, 6, 8]);

	int* copy = null;
	scope(exit) free(copy);
	assert(cloneTo(copy, arr));
	assert(copy != arr && capacity(copy) == 20 && slice(copy) == [7, 6, 8]);

	int* cloned = clone(arr);
	scope(exit) free(cloned);
	assert(cloned !is null && cloned != arr && slice(cloned) == [7, 6, 8]);

	assert(shrinkToFit(arr) !is null);
	assert(capacity(arr) == 3 && slice(arr) == [7, 6, 8]);

	// With `start > 0`, the elements before the deleted range have to be copied too, which `shrinkToFit` (always `start == 0`) never needs.
	assert(pushBack(arr, 0) && pushBack(arr, 1));
	assert(deleteRange(arr, 1, 2, true) !is null);
	assert(capacity(arr) == 3 && slice(arr) == [7, 0, 1]);

	int* none = null;
	assert(shrinkToFit(none) !is null);
	assert(length(none) == 0 && capacity(none) == 0);
	free(none);

	clear(arr);
	assert(length(arr) == 0 && capacity(arr) == 3);

	// Only `src`'s two elements are copied: reading more would overrun `src` and overwrite `dest`'s spare slots.
	int* dest = create!int(8);
	assert(dest !is null);
	scope(exit) free(dest);
	assert(length(dest) == 8 && capacity(dest) == 8);
	dest[0 .. 8] = -1;
	int* src = null;
	assert(pushBack(src, 1) && pushBack(src, 2));
	assert(cloneTo(dest, src, true));
	assert(slice(dest) == [1, 2]);
	foreach (i; 2 .. 8)
		assert(dest[i] == -1);

	// A `const(int)*` lvalue would still bind to `ref T*`, with `T` deduced as `const(int)`, so only an rvalue reaches the by-value overload.
	free(cast(const int*) src);
}

unittest {
	// Every growth path, under an allocator that refuses.
	auto previous = beginRationedAllocator();
	int* fresh = null;
	assert(growToSize(fresh, 4) is null);
	assert(fresh is null);     // And nothing was half-built.
	assert(create!int(4) is null);
	assert(!pushBack(fresh, 1));
	endRationedAllocator(previous);

	int* existing = null;
	assert(pushBack(existing, 11));
	assert(pushBack(existing, 22));
	scope(exit) free(existing);
	// Use up the spare capacity, so that everything below has to reallocate.
	while (length(existing) < capacity(existing))
		assert(pushBack(existing, 0));
	immutable filled = length(existing);
	int* before = existing;

	previous = beginRationedAllocator();
	assert(reserve(existing, 4096) is null);
	assert(!pushBack(existing, 33));
	static immutable int[2] more = [44, 55];
	assert(!concatenate(existing, more[]));
	assert(!concatenate(existing, existing));
	assert(insertUninitialized(existing, 0, 4096) is null);
	assert(!insert(existing, 0, 66));
	assert(!pushFront(existing, 77));
	assert(clone(existing) is null);
	assert(!swap(existing, 0, 1));
	endRationedAllocator(previous);

	// Growing a null array past its default capacity takes one allocation, not a default-sized one that a refused second leaves behind.
	previous = beginRationedAllocator(1);
	assert(grow(fresh, 100) !is null);
	endRationedAllocator(previous);
	assert(length(fresh) == 100 && capacity(fresh) == 128);
	free(fresh);

	// Sizes whose byte counts wrap are refused before reaching the allocator.
	assert(grow(existing, size_t.max) is null);
	assert(insertUninitialized(existing, 0, size_t.max) is null);
	assert(reserve(existing, size_t.max / 4 + 2) is null); // 4 bytes past the top
	assert(growToSize(fresh, size_t.max / 4 + 2) is null && fresh is null);
	ubyte* bytes = null;
	assert(reserve(bytes, size_t.max) is null);
	assert(maybeGrow(bytes, (size_t.max >> 1) + 2, true, false) is null);
	assert(bytes is null);

	assert(existing is before);
	assert(length(existing) == filled);
	assert(existing[0] == 11 && existing[1] == 22); // Refused, not half-swapped.
	assert(swap(existing, 0, 1));
	assert(existing[0] == 22 && existing[1] == 11);
}

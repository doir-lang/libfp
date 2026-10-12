/// Growable arrays on top of `fp.pointer`. A dynarray is a plain `T*` whose header also records its capacity, so it indexes like any pointer and grows like a vector. A null `T*` is an empty dynarray, ready to grow.
///
/// Elements are copied, moved and ended by `fp.lifecycle`'s convention, so a dynarray of elements with lifetimes ends them when it is freed, cleared, shrunk or has elements removed; element types whose lifetime is their bytes still move with `memcpy`.
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

static import fp.lifecycle;
static import fp.pointer;
public import fp.pointer : length, size, empty, front, back, slice; // As aliases that can be applied to dynarrays


/// A dynarray's header: its capacity in front of the `fp.pointer.Header` every fat pointer has, after the padding that aligns the elements.
package struct Header {
	private ubyte[fp.pointer.headerPadding!(size_t.sizeof + fp.pointer.Header.sizeof)] padding;
	size_t capacity; /// Elements storable without reallocating.
	fp.pointer.Header base; /// The fat pointer header, with the length.

	static assert(base.offsetof == capacity.offsetof + size_t.sizeof, "fp.dynarray: fp.pointer.valid reads the capacity just before the base header");
}

private enum size_t defaultSizeBytes = 16;


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
package Header* headerOf(inout void* p) {
	return fp.pointer.containerHeaderOf!Header(p);
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
bool validDynarray(inout void* p) @trusted {
	// The tag check reads only the shared 16-byte header: this module's is larger and would overrun a fat pointer that is not a dynarray.
	return fp.pointer.valid(p) && fp.pointer.headerOf(p).type == fp.pointer.PointerType.dynarray;
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
size_t capacity(inout void* p) @trusted {
	if (!valid(p)) return 0;
	return headerOf(p).capacity;
}

/// Whether the non-empty slice `view` starts inside the elements of fat pointer `da`, which may be null. Functions that grow or shift `da` use it to find such a view again afterwards.
///
/// Examples:
/// ---
/// int* arr = create!int(4);
/// scope(exit) free(arr);
/// assert(overlaps(arr, slice(arr)[1 .. 3]));
/// int[2] other;
/// assert(!overlaps(arr, other[]));
/// ---
package bool overlaps(T)(const T* da, const(T)[] view) @trusted {
	return view.length != 0 && da !is null && view.ptr >= da && view.ptr < da + length(da);
}


// Smears the highest set bit of `v - 1` into every lower bit; adding one then gives the smallest power of two not below `v`.
private size_t upperPowerOfTwo(size_t v) pure {
	--v;
	for (size_t shift = 1; shift < size_t.sizeof * 8; shift <<= 1)
		v |= v >> shift;
	return v + 1;
}

/// The growth engine behind every function that adds elements: makes room for `newSize` elements, reallocating only if the capacity is short. `updateUtilized` raises the length to `newSize` (it never lowers it); `exactSizing` makes a reallocation exactly `newSize` rather than the next power of two. Returns a pointer to element `newSize - 1`, or `da` itself when `newSize` is 0 since it then has no last element; returns null if the allocator refused or the new capacity's byte count would overflow, in which case `da` is unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// int* last = maybeGrow(arr, 3, true, false);
/// scope(exit) free(arr);
/// assert(last is arr + 2);
/// assert(length(arr) == 3 && capacity(arr) == 4);
///
/// assert(maybeGrow(arr, 0, false, true) is arr);
/// ---
package T* maybeGrow(T)(ref T* da, size_t newSize, bool updateUtilized, bool exactSizing) @trusted {
	mixin fp.pointer.requireAlignable!T;
	if (da !is null) {
		assert(valid(da));
		Header* h = headerOf(da);
		if (h.capacity >= newSize) {
			if (updateUtilized)
				h.base.size = h.base.size > newSize ? h.base.size : newSize;
			return newSize == 0 ? da : da + (newSize - 1);
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
	T* newData = cast(T*) fp.pointer.allocContainer!Header(bytes, fp.pointer.PointerType.dynarray);
	if (newData is null) return null;
	fp.lifecycle.initSlots(newData, newCapacity);
	Header* newH = headerOf(newData);
	newH.capacity = newCapacity;
	newH.base.size = updateUtilized ? newSize : oldSize;
	if (da !is null) {
		fp.lifecycle.moveRange(newData, da, oldSize);
		cast(void)fp.pointer.allocFunction(headerOf(da), 0);
	}
	da = newData;
	return newSize == 0 ? da : da + (newSize - 1);
}


/// Makes room for at least `size` elements without changing the length. Returns null if the allocator refused or `size` elements' byte count would overflow, leaving `da` unchanged. Returns `da` itself when `size` is 0.
///
/// Examples:
/// ---
/// int* arr = null;
/// assert(reserve(arr, 100) !is null);
/// scope(exit) free(arr);
/// assert(capacity(arr) == 100 && length(arr) == 0);
///
/// assert(reserve(arr, 0) is arr);
/// ---
T* reserve(T)(ref T* da, size_t size) {
	return maybeGrow(da, size, false, true);
}

/// Grows `da` to at least `size` elements, reallocating to exactly `size` if it must reallocate at all. New elements are uninitialized, or empty when the element type has a lifetime. Returns a pointer to element `size - 1`, or `da` itself when `size` is 0, or null if the allocator refused or `size` elements' byte count would overflow, leaving `da` unchanged.
///
/// Examples:
/// ---
/// int* arr = null;
/// int* last = growToSize(arr, 5);
/// scope(exit) free(arr);
/// assert(last is arr + 4);
/// assert(length(arr) == 5 && capacity(arr) == 5);
///
/// assert(growToSize(arr, 0) is arr);
/// ---
T* growToSize(T)(ref T* da, size_t size) {
	return maybeGrow(da, size, true, true);
}

/// Appends `toAdd` uninitialized elements, rounding any reallocation up to a power of two. Returns a pointer to the new last element, or null if the allocator refused or the new length would overflow, leaving `da` unchanged. With `toAdd` 0 nothing is appended, so a null `da` is left null and otherwise the last element is returned.
///
/// Examples:
/// ---
/// int* arr = null;
/// int* last = grow(arr, 3);
/// scope(exit) free(arr);
/// *last = 9;
/// assert(length(arr) == 3 && arr[2] == 9);
///
/// assert(grow(arr, 0) is arr + 2);
/// ---
T* grow(T)(ref T* da, size_t toAdd) {
	bool overflow = false;
	immutable newSize = core.checkedint.addu(length(da), toAdd, overflow);
	if (overflow) return null;
	if (newSize == 0) return da; // Nothing was appended, so there is no last element to point at.
	return maybeGrow(da, newSize, true, false);
}

/// Appends `value`, taking its lifetime over: the copy of it made for the call is left empty. Returns false if the array could not grow, leaving it unchanged; the copy's lifetime is ended either way.
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
	if (slot is null) { fp.lifecycle.endLifetime(value); return false; }
	fp.lifecycle.moveInto(*slot, value);
	return true;
}

/// Inserts `count` elements before element `pos`, their bytes uninitialized when the element type's lifetime is its bytes and empty otherwise. `count` must be greater than zero and `pos` no greater than the length. Returns a pointer to the first of them, or null if the array could not grow, leaving it unchanged.
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
	static if (fp.lifecycle.isBitMoveable!T) core.stdc.string.memmove(newStart, oldStart, bytesToMove);
	else {
		for (size_t i = length(da) - count; i > pos; --i) // shifting up, so move from the back
			fp.lifecycle.moveInto(da[i - 1 + count], da[i - 1]);
		fp.lifecycle.initSlots(da + pos, count); // the gap holds no lifetime, so removing it later finalizes nothing
	}
	return cast(T*) oldStart;
}

/// Inserts `value` before element `pos`. Returns false if the array could not grow, leaving it unchanged; `value`'s lifetime is taken over either way.
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
	if (slot is null) { fp.lifecycle.endLifetime(value); return false; }
	fp.lifecycle.moveInto(*slot, value);
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

/// Appends a copy of every element of `src`, which may view `dest` itself. Returns false if the array could not grow or its length would overflow, leaving it unchanged.
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
	bool overflow = false;
	immutable newSize = core.checkedint.addu(preSize, src.length, overflow);
	// Growing frees the old block, so a `src` viewing `dest` is found again by its offset.
	immutable ptrdiff_t selfOffset = overlaps(dest, src) ? src.ptr - dest : -1;
	if (overflow || maybeGrow(dest, newSize, true, false) is null) return false;
	const(T)* from = selfOffset >= 0 ? dest + selfOffset : src.ptr;
	fp.lifecycle.copyRange(dest + preSize, cast(T*) from, src.length);
	return true;
}
/// Ditto
bool concatenate(T)(ref T* dest, inout T* src) {
	return concatenate(dest, slice(src));
}


/// Allocates a dynarray of `size` uninitialized elements, or empty ones when the element type has a lifetime, with no spare capacity. Returns null if the allocator refused. `size` 0 still allocates room for one element, so the result is a valid empty dynarray rather than null.
///
/// Examples:
/// ---
/// int* arr = create!int(3);
/// scope(exit) free(arr);
/// assert(length(arr) == 3 && capacity(arr) == 3);
///
/// int* empty = create!int(0);
/// scope(exit) free(empty);
/// assert(length(empty) == 0 && capacity(empty) == 1);
/// ---
T* create(T)(size_t size) {
	T* da = null;
	if (growToSize(da, size) is null) return null;
	return da;
}

/// Copies `src`'s elements into `dest`, with at least `src`'s capacity unless `shrink` is set or `src` is a fat pointer other than a dynarray. Elements `dest` held past `src`'s length are dropped, their lifetimes ended. Returns false if `dest` could not be sized to hold them, leaving it unchanged.
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
	immutable srcLength = length(src);
	immutable self = dest is src;
	immutable previousSize = headerOf(dest).base.size;
	// Only a dynarray has a capacity; any other fat pointer reports 0.
	immutable newCapacity = shrink || capacity(src) < srcLength ? srcLength : capacity(src);
	if (growToSize(dest, newCapacity) is null) return false;
	if (previousSize > srcLength) fp.lifecycle.endLifetimes(dest + srcLength, previousSize - srcLength);
	headerOf(dest).base.size = srcLength; // `growToSize` raises the length to the capacity, which for a dynarray is usually more than the elements copied.
	if (self) return true; // growing already moved the elements over
	fp.lifecycle.copyRange(dest, cast(T*) src, srcLength);
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

/// Frees dynarray `da`, which may be null but must not be another kind of fat pointer, ending the lifetimes of its elements first. The `ref` overload also sets `da` to null.
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
	if (da is null) return;
	assert(valid(da));
	fp.lifecycle.endLifetimes(cast(T*) da, length(da));
	cast(void)fp.pointer.allocFunction(headerOf(da), 0);
}


/// Removes the last `count` elements, keeping their capacity, and ends their lifetimes. `count` must be no greater than the length. Returns a pointer to where the first of them was.
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
	fp.lifecycle.endLifetimes(da + h.base.size, count);
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

/// Removes `count` elements starting at `start`, which must fit within the length, moving every later element down and ending the removed ones' lifetimes. With `matchCapacity`, it also reallocates so capacity equals the new length, or 1 if that is 0, since a zero-capacity empty dynarray is not `fp.pointer.valid`. Returns a pointer to element `start`, or null if that reallocation was refused, in which case the array is unchanged.
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

		if (da !is null) {
			fp.lifecycle.moveRange(newData, da, start);
			fp.lifecycle.moveRange(newData + start, da + start + count, oldSize - start - count);
			fp.lifecycle.endLifetimes(da + start, count); // the removed ones are dropped with the old block
			// `headerOf(null)` is the shared dummy, not an allocation.
			cast(void)fp.pointer.allocFunction(headerOf(da), 0);
		}
		da = newData;
		newStart = cast(ubyte*) da + start * T.sizeof;
	} else if (count > 0) {
		headerOf(da).base.size -= count;
		static if (fp.lifecycle.isBitMoveable!T) core.stdc.string.memmove(newStart, oldStart, bytesToMove);
		else {
			// Ending them first: only the first removed slot is a shift destination, so the rest would otherwise be zeroed with their lifetimes still running.
			fp.lifecycle.endLifetimes(da + start, count);
			for (size_t i = start; i < oldSize - count; ++i) // shifting down, so move from the front
				fp.lifecycle.moveInto(da[i], da[i + count]);
		}
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

/// Sets the length to 0, keeping the capacity and ending the elements' lifetimes.
///
/// Examples:
/// ---
/// int* arr = create!int(4);
/// scope(exit) free(arr);
/// clear(arr);
/// assert(length(arr) == 0 && capacity(arr) == 4);
/// ---
void clear(T)(T* da) @trusted {
	fp.lifecycle.endLifetimes(da, length(da));
	headerOf(da).base.size = 0;
}

/// Reallocates so capacity equals length, or 1 for an empty array. Returns null if the allocator refused, in which case the array is unchanged.
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


/// Swaps the `count` elements starting at `start1` with the `count` starting at `start2`; both ranges must lie within the length and must not overlap. Returns false if the scratch buffer the swap needs could not be allocated, leaving both untouched.
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
	assert(start1 + count <= start2 || start2 + count <= start1);

	static if (fp.lifecycle.isBitMoveable!T) {
		immutable bytes = count * T.sizeof;
		ubyte* scratch = cast(ubyte*) fp.pointer.allocFunction(null, bytes);
		if (scratch is null) return false;

		ubyte* a = cast(ubyte*)(da + start1);
		ubyte* b = cast(ubyte*)(da + start2);
		core.stdc.string.memcpy(scratch, a, bytes);
		core.stdc.string.memcpy(a, b, bytes);
		core.stdc.string.memcpy(b, scratch, bytes);

		cast(void)fp.pointer.allocFunction(scratch, 0);
	} else foreach (i; 0 .. count) fp.lifecycle.swapInto(da[start1 + i], da[start2 + i]);
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

	private __gshared fp.pointer.AllocFunction poisonUnderlying;

	private void* poisoningAlloc(void* p, size_t size) @trusted {
		enum prefix = fp.pointer.maxAlignment; // holds the size and keeps the memory aligned
		if (size == 0) {
			if (p !is null) {
				size_t* block = cast(size_t*)(cast(ubyte*) p - prefix);
				core.stdc.string.memset(p, 0xAA, *block);
				cast(void)poisonUnderlying(block, 0);
			}
			return null;
		}
		// Dynarrays grow by allocating, copying and freeing, so nothing under test reallocates in place.
		assert(p is null);
		size_t* fresh = cast(size_t*) poisonUnderlying(null, size + prefix);
		if (fresh is null) return null;
		*fresh = size;
		return cast(ubyte*) fresh + prefix;
	}

	/// For tests of reads through stale pointers: `beginPoisoningAllocator` makes `fp.pointer.allocFunction` overwrite each block as it is freed, so such a read sees garbage rather than the old contents; `endPoisoningAllocator` restores the allocator it returned. Memory allocated while it is active must be freed while it is, so register the restoring `scope(exit)` first.
	///
	/// Examples:
	/// ---
	/// auto previous = beginPoisoningAllocator();
	/// scope(exit) endPoisoningAllocator(previous);
	/// int* arr = create!int(1);
	/// scope(exit) free(arr);
	/// assert(arr !is null);
	/// ---
	package fp.pointer.AllocFunction beginPoisoningAllocator() {
		poisonUnderlying = fp.pointer.allocFunction;
		fp.pointer.allocFunction = &poisoningAlloc;
		return poisonUnderlying;
	}

	/// Ditto
	package void endPoisoningAllocator(fp.pointer.AllocFunction previous) {
		fp.pointer.allocFunction = previous;
	}

	private __gshared fp.pointer.AllocFunction dirtyUnderlying;

	private void* dirtyAlloc(void* p, size_t size) {
		void* block = dirtyUnderlying(p, size);
		if (p is null && block !is null) core.stdc.string.memset(block, 0x55, size);
		return block;
	}

	/// For tests of uninitialized memory: `beginDirtyAllocator` makes `fp.pointer.allocFunction` fill every newly allocated block with `0x55` bytes, so a container that leaves a slot unset reads garbage rather than the zeros a fresh page usually has; `endDirtyAllocator` restores the allocator it returned.
	///
	/// Examples:
	/// ---
	/// auto previous = beginDirtyAllocator();
	/// scope(exit) endDirtyAllocator(previous);
	/// int* arr = create!int(1);
	/// scope(exit) free(arr);
	/// assert(arr[0] == 0x55555555);
	/// ---
	package fp.pointer.AllocFunction beginDirtyAllocator() {
		dirtyUnderlying = fp.pointer.allocFunction;
		fp.pointer.allocFunction = &dirtyAlloc;
		return dirtyUnderlying;
	}

	/// Ditto
	package void endDirtyAllocator(fp.pointer.AllocFunction previous) {
		fp.pointer.allocFunction = previous;
	}

	private __gshared size_t finalizeCount;
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
	assert(capacity(arr) == 20);
	assert(length(arr) == 0);

	// A zero size has no last element to point at, so the array itself is returned rather than one slot before its start.
	assert(reserve(arr, 0) is arr && growToSize(arr, 0) is arr && grow(arr, 0) is arr);
	assert(maybeGrow(arr, 0, true, false) is arr && length(arr) == 0);

	// Nothing appended means nothing allocated: a null array stays null rather than getting a first page.
	int* untouched = null;
	assert(grow(untouched, 0) is null && untouched is null);

	int* zeroed = create!int(0);
	assert(zeroed !is null);
	scope(exit) free(zeroed);
	assert(length(zeroed) == 0 && capacity(zeroed) == 1);

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

	// Cloning into itself keeps the elements it had, not the spare capacity the grow rounded up to.
	assert(cloneTo(arr, arr) && length(arr) == 3 && capacity(arr) == 20 && slice(arr) == [7, 6, 8]);

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
	assert(length(none) == 0 && capacity(none) == 1);
	free(none);

	clear(arr);
	assert(length(arr) == 0 && capacity(arr) == 3);

	// An emptied array keeps a capacity, which is what makes it `fp.pointer.valid` with no elements.
	int* emptied = create!int(3);
	assert(emptied !is null);
	scope(exit) free(emptied);
	assert(cloneTo(emptied, arr, true));
	assert(fp.pointer.valid(emptied) && length(emptied) == 0 && capacity(emptied) == 3);
	assert(shrinkToFit(arr) !is null);
	assert(fp.pointer.valid(arr) && length(arr) == 0 && capacity(arr) == 1);

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

	// A heap fat pointer has no capacity to copy, so its length sizes the clone.
	int* heap = fp.pointer.malloc!int(10);
	assert(heap !is null);
	scope(exit) fp.pointer.free(heap);
	heap[0 .. 10] = 4;
	int* fromHeap = null;
	scope(exit) free(fromHeap);
	assert(cloneTo(fromHeap, heap));
	assert(length(fromHeap) == 10 && capacity(fromHeap) == 10 && fromHeap[9] == 4);

	// Checking a dynarray handle against a heap pointer reads only the shared 16-byte header; this module's larger header would overrun a foreign allocation.
	assert(!validDynarray(heap) && capacity(heap) == 0 && length(heap) == 10);

	// Appending an array to itself must read it from where growing moved it, not the freed block.
	auto previous = beginPoisoningAllocator();
	scope(exit) endPoisoningAllocator(previous);
	int* doubled = create!int(4);
	assert(doubled !is null);
	scope(exit) free(doubled);
	foreach (i; 0 .. 4)
		doubled[i] = i;
	assert(concatenate(doubled, doubled));
	assert(concatenate(doubled, slice(doubled)[1 .. 3]));
	assert(slice(doubled) == [0, 1, 2, 3, 0, 1, 2, 3, 1, 2]);

	static struct Wide { align(fp.pointer.maxAlignment) ubyte b; }
	Wide* wides = null;
	scope(exit) free(wides);
	foreach (i; 0 .. 20)
		assert(pushBack(wides, Wide(cast(ubyte) i)));
	assert(cast(size_t) wides % Wide.alignof == 0 && wides[19].b == 19);
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

unittest {
	static struct Handle {
		int* data;
		void finalize() @nogc nothrow { if (data !is null) ++finalizeCount; data = null; }
		void moveTo(ref Handle dest) @nogc nothrow { dest.data = data; data = null; }
		void copyTo(ref Handle dest) @nogc nothrow { dest.data = data; }
	}

	static assert(fp.lifecycle.isBitMoveable!int && !fp.lifecycle.isBitMoveable!Handle);

	Handle* arr = null;
	scope(exit) free(arr);
	finalizeCount = 0;

	assert(pushBack(arr, Handle(cast(int*) 1)) && pushBack(arr, Handle(cast(int*) 2)));
	assert(length(arr) == 2 && arr[1].data == cast(int*) 2 && finalizeCount == 0);

	// Growing moves the elements without ending their lifetimes.
	assert(reserve(arr, 100) !is null && length(arr) == 2 && arr[0].data == cast(int*) 1 && finalizeCount == 0);

	assert(insertUninitialized(arr, 1, 1) !is null);
	assert(arr[1].data is null); // the gap is left empty, so removing it without filling it finalizes nothing
	arr[1].data = cast(int*) 3;
	assert(length(arr) == 3 && arr[0].data == cast(int*) 1 && arr[1].data == cast(int*) 3 && arr[2].data == cast(int*) 2);

	assert(deleteRange(arr, 0, 1) !is null);
	assert(finalizeCount == 1 && arr[0].data == cast(int*) 3 && arr[1].data == cast(int*) 2);

	assert(swap(arr, 0, 1));
	assert(arr[0].data == cast(int*) 2 && arr[1].data == cast(int*) 3);

	// With `matchCapacity`, `deleteRange` reallocates, so the removed element's lifetime ends as its block is freed.
	assert(deleteRange(arr, 0, 1, true) !is null);
	assert(finalizeCount == 2 && length(arr) == 1 && arr[0].data == cast(int*) 3);

	// A middle range of more than one element: only the first removed slot is a shift destination.
	assert(pushBack(arr, Handle(cast(int*) 4)) && pushBack(arr, Handle(cast(int*) 5)) && pushBack(arr, Handle(cast(int*) 6)));
	assert(deleteRange(arr, 1, 2) !is null);
	assert(finalizeCount == 4 && length(arr) == 2 && arr[0].data == cast(int*) 3 && arr[1].data == cast(int*) 6);

	Handle* copy = null;
	scope(exit) free(copy);
	assert(cloneTo(copy, arr));
	assert(length(copy) == 2 && copy[0].data == cast(int*) 3 && copy[1].data == cast(int*) 6);

	// Cloning into an array longer than the source drops the extra elements, ending their lifetimes.
	Handle* longer = null;
	scope(exit) free(longer);
	assert(pushBack(longer, Handle(cast(int*) 7)) && pushBack(longer, Handle(cast(int*) 8)) && pushBack(longer, Handle(cast(int*) 9)));
	assert(cloneTo(longer, arr));
	assert(length(longer) == 2 && longer[0].data == cast(int*) 3 && longer[1].data == cast(int*) 6 && finalizeCount == 7);

	assert(popBackCount(arr, 1) is arr + 1);
	assert(finalizeCount == 8 && arr[0].data == cast(int*) 3);

	clear(arr);
	assert(finalizeCount == 9 && length(arr) == 0);

	free(arr); // every slot was already empty
	assert(finalizeCount == 9);

	// A refused append ends the value's lifetime, since the call took it over.
	finalizeCount = 0;
	Handle* tight = create!Handle(1);
	assert(tight !is null && pushBack(tight, Handle(cast(int*) 5)));
	auto rationed = beginRationedAllocator();
	assert(!pushBack(tight, Handle(cast(int*) 4)) && finalizeCount == 1 && length(tight) == 2);
	endRationedAllocator(rationed);
	assert(insert(tight, 1, Handle(cast(int*) 6)) && length(tight) == 3);

	// The `matchCapacity` path reallocates, so a middle range's lifetimes end before the old block is freed.
	assert(deleteRange(tight, 1, 1, true) !is null);
	assert(finalizeCount == 2 && length(tight) == 2 && tight[0].data is null && tight[1].data == cast(int*) 5);

	free(tight);
	assert(finalizeCount == 3 && tight is null);
}

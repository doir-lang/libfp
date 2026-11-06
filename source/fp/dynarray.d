/// Growable arrays on top of `fp.pointer`. A dynarray is a plain `T*` whose header also records its capacity, so it indexes like any pointer and grows like a vector. A null `T*` is an empty dynarray, ready to grow.
///
/// Elements are copied, moved and ended by `fp.lifecycle`'s convention, so a dynarray of elements with lifetimes ends them when it is freed, cleared, shrunk or has elements removed; element types whose lifetime is their bytes still move with `memcpy`.
///
/// Every function that can allocate reports a refused allocation, or a size whose byte count would overflow, by returning null or false, and leaves the array as it was.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// foreach (i; 0 .. 4)
/// 	assert(pushBack(array, i));
/// assert(length(array) == 4 && array[3] == 3);
/// ---
module fp.dynarray;

static import core.stdc.string;
static import core.checkedint;

static import fp.lifecycle;
static import fp.pointer;
public import fp.pointer : length, empty, back, slice; // As aliases that can be applied to dynarrays


/// A dynarray's header: its capacity in front of the `fp.pointer.Header` every fat pointer has, after the padding that aligns the elements.
package struct Header {
	private ubyte[fp.pointer.headerPadding!(size_t.sizeof + fp.pointer.Header.sizeof)] padding;
	size_t capacity; /// Elements storable without reallocating.
	fp.pointer.Header base; /// The fat pointer header, with the length.

	static assert(base.offsetof == capacity.offsetof + size_t.sizeof, "fp.dynarray: fp.pointer.valid reads the capacity just before the base header");
}

private enum size_t defaultSizeBytes = 16;


@nogc nothrow:


// wrapper: names the header lookup for a dynarray header
/// The header in front of dynarray `p`. For null it returns a zeroed shared dummy, so every query on a null dynarray reads as empty rather than faulting; writes to the dummy are discarded by the next call.
///
/// Examples:
/// ---
/// int* array = null;
/// assert(headerOf(array).capacity == 0);
/// assert(reserve(array, 4) !is null);
/// scope(exit) free(array);
/// assert(headerOf(array).capacity == 4);
/// ---
package Header* headerOf(inout void* p) {
	return fp.pointer.containerHeaderOf!Header(p);
}


/// Whether `p` is a dynarray (as opposed to null or another kind of fat pointer).
///
/// Examples:
/// ---
/// int* array = null;
/// assert(!valid(array));
/// assert(pushBack(array, 1));
/// scope(exit) free(array);
/// assert(valid(array));
/// ---
bool valid(inout void* p) @trusted {
	// The tag check reads only the shared 16-byte header: this module's is larger and would overrun a fat pointer that is not a dynarray.
	return fp.pointer.valid(p) && fp.pointer.headerOf(p).type == fp.pointer.PointerType.dynarray;
}


/// The number of elements `p` can hold without reallocating.
///
/// Examples:
/// ---
/// int* array = null;
/// assert(capacity(array) == 0);
/// assert(reserve(array, 8) !is null);
/// scope(exit) free(array);
/// assert(capacity(array) == 8 && length(array) == 0);
/// ---
size_t capacity(inout void* p) @trusted {
	if (!valid(p)) return 0;
	return headerOf(p).capacity;
}

/// Whether the non-empty slice `view` starts inside the elements of fat pointer `array`, which may be null. Functions that grow or shift `array` use it to find such a view again afterwards.
///
/// Examples:
/// ---
/// int* array = create!int(4);
/// scope(exit) free(array);
/// assert(overlaps(array, slice(array)[1 .. 3]));
/// int[2] other;
/// assert(!overlaps(array, other[]));
/// ---
package bool overlaps(T)(const T* array, const(T)[] view) @trusted {
	return view.length != 0 && array !is null && view.ptr >= array && view.ptr < array + length(array);
}


// Smears the highest set bit of `v - 1` into every lower bit; adding one then gives the smallest power of two not below `v`.
private size_t upperPowerOfTwo(size_t v) pure {
	--v;
	for (size_t shift = 1; shift < size_t.sizeof * 8; shift <<= 1)
		v |= v >> shift;
	return v + 1;
}

/// The growth engine behind every function that adds elements: makes room for `newSize` elements, reallocating only if the capacity is short. `updateUtilized` raises the length to `newSize` (it never lowers it); `exactSizing` makes a reallocation exactly `newSize` rather than the next power of two. Returns a pointer to element `newSize - 1`, or `array` itself when `newSize` is 0 since it then has no last element; returns null if the allocator refused or the new capacity's byte count would overflow, in which case `array` is unchanged.
///
/// Examples:
/// ---
/// int* array = null;
/// int* last = maybeGrow(array, 3, true, false);
/// scope(exit) free(array);
/// assert(last is array + 2);
/// assert(length(array) == 3 && capacity(array) == 4);
///
/// assert(maybeGrow(array, 0, false, true) is array);
/// ---
package T* maybeGrow(T)(ref T* array, size_t newSize, bool updateUtilized, bool exactSizing) @trusted {
	mixin fp.pointer.requireAlignable!T;
	if (array !is null) {
		assert(valid(array));
		Header* header = headerOf(array);
		if (header.capacity >= newSize) {
			if (updateUtilized)
				header.base.size = header.base.size > newSize ? header.base.size : newSize;
			return newSize == 0 ? array : array + (newSize - 1);
		}
	}

	// Even a null array gets a capacity of at least one, so `create!T(0)` is a real allocation.
	size_t newCapacity = exactSizing ? newSize : upperPowerOfTwo(newSize);
	if (array is null && !exactSizing && newCapacity < defaultSizeBytes / T.sizeof)
		newCapacity = defaultSizeBytes / T.sizeof;
	if (newCapacity == 0) newCapacity = 1;
	if (newCapacity < newSize) return null; // `upperPowerOfTwo` wrapped past the top bit
	bool overflow = false;
	immutable bytes = core.checkedint.mulu(newCapacity, T.sizeof, overflow);
	if (overflow) return null;

	immutable oldSize = headerOf(array).base.size; // the zeroed dummy's for null
	T* newData = cast(T*) fp.pointer.allocateContainer!Header(bytes, fp.pointer.PointerType.dynarray);
	if (newData is null) return null;
	fp.lifecycle.emptySlots(newData, newCapacity);
	Header* newHeader = headerOf(newData);
	newHeader.capacity = newCapacity;
	newHeader.base.size = updateUtilized ? newSize : oldSize;
	if (array !is null) {
		fp.lifecycle.moveRange(newData, array, oldSize);
		cast(void)fp.pointer.allocator(headerOf(array), 0);
	}
	array = newData;
	return newSize == 0 ? array : array + (newSize - 1);
}


// wrapper: names one setting of maybeGrow's flags
/// Makes room for at least `size` elements without changing the length. Returns null if the allocator refused or `size` elements' byte count would overflow, leaving `array` unchanged. Returns `array` itself when `size` is 0.
///
/// Examples:
/// ---
/// int* array = null;
/// assert(reserve(array, 100) !is null);
/// scope(exit) free(array);
/// assert(capacity(array) == 100 && length(array) == 0);
///
/// assert(reserve(array, 0) is array);
/// ---
T* reserve(T)(ref T* array, size_t size) {
	return maybeGrow(array, size, false, true);
}

// wrapper: names one setting of maybeGrow's flags
/// Ensures capacity for at least `size` elements, as `reserve` does, but rounds a reallocation up to a power of two, so reserving in a loop of growing sizes reallocates only logarithmically often. Returns a pointer to the first element, or null if the allocator refused or `size` elements' byte count would overflow, leaving `array` unchanged.
///
/// Examples:
/// ---
/// int* array = null;
/// assert(reserveAtLeast(array, 100) !is null);
/// scope(exit) free(array);
/// assert(capacity(array) == 128 && length(array) == 0);
/// ---
T* reserveAtLeast(T)(ref T* array, size_t size) {
	return maybeGrow(array, size, false, false);
}

// wrapper: names one setting of maybeGrow's flags
/// Grows `array` to at least `size` elements, never shrinking it (`resize` shrinks as well), reallocating to exactly `size` if it must reallocate at all. New elements are uninitialized, or empty when the element type has a lifetime. Returns a pointer to element `size - 1`, or `array` itself when `size` is 0, or null if the allocator refused or `size` elements' byte count would overflow, leaving `array` unchanged.
///
/// Examples:
/// ---
/// int* array = null;
/// int* last = growToSize(array, 5);
/// scope(exit) free(array);
/// assert(last is array + 4);
/// assert(length(array) == 5 && capacity(array) == 5);
///
/// assert(growToSize(array, 0) is array);
/// ---
T* growToSize(T)(ref T* array, size_t size) {
	return maybeGrow(array, size, true, true);
}

/// Sets the length of `array` to exactly `size`: a shorter `size` ends the lifetimes of the elements past it and keeps the capacity, as `removeLast` does; a longer one grows it as `growToSize` does. Returns a pointer to element `size - 1`, or `array` itself when `size` is 0, or null if growing was refused or `size` elements' byte count would overflow, leaving `array` unchanged.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// assert(resize(array, 5) is array + 4 && length(array) == 5);
/// assert(resize(array, 2) is array + 1 && length(array) == 2 && capacity(array) == 5);
/// assert(resize(array, 0) is array && length(array) == 0);
/// ---
T* resize(T)(ref T* array, size_t size) {
	immutable current = length(array);
	if (size >= current) return growToSize(array, size);
	cast(void) removeLast(array, current - size);
	return size == 0 ? array : array + size - 1;
}

/// Appends `toAdd` uninitialized elements, rounding any reallocation up to a power of two. Returns a pointer to the new last element, or null if the allocator refused or the new length would overflow, leaving `array` unchanged. With `toAdd` 0 nothing is appended, so a null `array` is left null and otherwise the last element is returned.
///
/// Examples:
/// ---
/// int* array = null;
/// int* last = grow(array, 3);
/// scope(exit) free(array);
/// *last = 9;
/// assert(length(array) == 3 && array[2] == 9);
///
/// assert(grow(array, 0) is array + 2);
/// ---
T* grow(T)(ref T* array, size_t toAdd) {
	bool overflow = false;
	immutable newSize = core.checkedint.addu(length(array), toAdd, overflow);
	if (overflow) return null;
	if (newSize == 0) return array; // Nothing was appended, so there is no last element to point at.
	return maybeGrow(array, newSize, true, false);
}

/// Appends `value`, taking its lifetime over: the copy of it made for the call is left empty. Returns false if the array could not grow, leaving it unchanged; the copy's lifetime is ended either way.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// assert(pushBack(array, 1) && pushBack(array, 2));
/// assert(slice(array) == [1, 2]);
/// ---
bool pushBack(T)(ref T* array, T value) {
	T* slot = maybeGrow(array, length(array) + 1, true, false);
	if (slot is null) { fp.lifecycle.endLifetime(value); return false; }
	fp.lifecycle.moveInto(*slot, value);
	return true;
}

/// Inserts `count` elements before element `position`, their bytes uninitialized when the element type's lifetime is its bytes and empty otherwise. `count` must be greater than zero and `position` no greater than the length. Returns a pointer to the first of them, or null if the array could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// assert(pushBack(array, 1) && pushBack(array, 4));
/// int* gap = insertUninitialized(array, 1, 2);
/// gap[0] = 2;
/// gap[1] = 3;
/// assert(slice(array) == [1, 2, 3, 4]);
/// ---
T* insertUninitialized(T)(ref T* array, size_t position, size_t count) @trusted {
	assert(count > 0);
	assert(position <= length(array));

	bool overflow = false;
	immutable newSize = core.checkedint.addu(length(array), count, overflow);
	if (overflow || maybeGrow(array, newSize, true, false) is null) return null;

	ubyte* raw = cast(ubyte*) array;
	ubyte* oldStart = raw + position * T.sizeof;
	ubyte* newStart = oldStart + count * T.sizeof;
	immutable bytesToMove = (raw + length(array) * T.sizeof) - newStart;
	static if (fp.lifecycle.isBitMoveable!T) core.stdc.string.memmove(newStart, oldStart, bytesToMove);
	else {
		for (size_t i = length(array) - count; i > position; --i) // shifting up, so move from the back
			fp.lifecycle.moveInto(array[i - 1 + count], array[i - 1]);
		fp.lifecycle.emptySlots(array + position, count); // the gap holds no lifetime, so removing it later finalizes nothing
	}
	return cast(T*) oldStart;
}

/// Inserts `value` before element `position`. Returns false if the array could not grow, leaving it unchanged; `value`'s lifetime is taken over either way.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// assert(pushBack(array, 1) && pushBack(array, 3));
/// assert(insert(array, 1, 2));
/// assert(slice(array) == [1, 2, 3]);
/// ---
bool insert(T)(ref T* array, size_t position, T value) {
	T* slot = insertUninitialized(array, position, 1);
	if (slot is null) { fp.lifecycle.endLifetime(value); return false; }
	fp.lifecycle.moveInto(*slot, value);
	return true;
}

// wrapper: container vocabulary every reader knows
/// Inserts `value` before element 0, moving every element up one. Returns false if the array could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// assert(pushBack(array, 2) && pushFront(array, 1));
/// assert(slice(array) == [1, 2]);
/// ---
bool pushFront(T)(ref T* array, T value) {
	return insert(array, 0, value);
}

/// Appends a copy of every element of `source`, which may view `destination` itself. Returns false if the array could not grow or its length would overflow, leaving it unchanged, or an element's copy was refused, ending the elements copied before the failure and restoring the previous length, though the capacity may still have grown.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// int[3] more = [1, 2, 3];
/// assert(concatenate(array, more[]));
///
/// int* copy = clone(array);
/// scope(exit) free(copy);
/// assert(concatenate(array, copy));
/// assert(length(array) == 6 && array[5] == 3);
/// ---
bool concatenate(T)(ref T* destination, inout(T)[] source) @trusted {
	if (source.length == 0) return true;
	immutable preSize = length(destination);
	bool overflow = false;
	immutable newSize = core.checkedint.addu(preSize, source.length, overflow);
	// Growing frees the old block, so a `source` viewing `destination` is found again by its offset.
	immutable ptrdiff_t selfOffset = overlaps(destination, source) ? source.ptr - destination : -1;
	if (overflow || maybeGrow(destination, newSize, true, false) is null) return false;
	const(T)* from = selfOffset >= 0 ? destination + selfOffset : source.ptr;
	if (!fp.lifecycle.copyRange(destination + preSize, cast(T*) from, source.length)) {
		fp.lifecycle.endLifetimes(destination + preSize, source.length); // the ones copied before the failure, the rest already empty
		headerOf(destination).base.size = preSize;
		return false;
	}
	return true;
}
// wrapper: takes a fat pointer where the other overload takes a slice
/// Ditto
bool concatenate(T)(ref T* destination, inout T* source) {
	return concatenate(destination, slice(source));
}


/// Allocates a dynarray of `size` uninitialized elements, or empty ones when the element type has a lifetime, with no spare capacity. Returns null if the allocator refused. `size` 0 still allocates room for one element, so the result is a valid empty dynarray rather than null.
///
/// Examples:
/// ---
/// int* array = create!int(3);
/// scope(exit) free(array);
/// assert(length(array) == 3 && capacity(array) == 3);
///
/// int* empty = create!int(0);
/// scope(exit) free(empty);
/// assert(length(empty) == 0 && capacity(empty) == 1);
/// ---
T* create(T)(size_t size) {
	T* array = null;
	if (growToSize(array, size) is null) return null;
	return array;
}

/// Copies `source`'s elements into `destination`, with at least `source`'s capacity unless `shrink` is set or `source` is a fat pointer other than a dynarray. Elements `destination` held past `source`'s length are dropped, their lifetimes ended. Returns false if `destination` could not be sized to hold them, leaving it unchanged, or one of the copies was refused, leaving `destination` empty.
///
/// Examples:
/// ---
/// int* source = null;
/// scope(exit) free(source);
/// assert(reserve(source, 10) !is null);
/// assert(pushBack(source, 1));
///
/// int* destination = null;
/// scope(exit) free(destination);
/// assert(cloneTo(destination, source));
/// assert(length(destination) == 1 && capacity(destination) == 10);
/// ---
bool cloneTo(T)(ref T* destination, inout T* source, bool shrink = false) @trusted {
	immutable sourceLength = length(source);
	immutable self = destination is source;
	immutable previousSize = headerOf(destination).base.size;
	// Only a dynarray has a capacity; any other fat pointer reports 0.
	immutable newCapacity = shrink || capacity(source) < sourceLength ? sourceLength : capacity(source);
	if (growToSize(destination, newCapacity) is null) return false;
	if (previousSize > sourceLength) fp.lifecycle.endLifetimes(destination + sourceLength, previousSize - sourceLength);
	headerOf(destination).base.size = sourceLength; // `growToSize` raises the length to the capacity, which for a dynarray is usually more than the elements copied.
	if (self) return true; // growing already moved the elements over
	if (!fp.lifecycle.copyRange(destination, cast(T*) source, sourceLength)) {
		fp.lifecycle.endLifetimes(destination, sourceLength); // the elements copied before the failure; the rest are already empty
		headerOf(destination).base.size = 0;
		return false;
	}
	return true;
}

/// A new dynarray holding a copy of `source`'s elements and no spare capacity, or null if `source` is null or the allocator refused.
///
/// Examples:
/// ---
/// int* source = null;
/// scope(exit) free(source);
/// assert(pushBack(source, 5));
///
/// int* copy = clone(source);
/// scope(exit) free(copy);
/// assert(copy !is source && length(copy) == 1 && copy[0] == 5);
/// ---
T* clone(T)(inout T* source) {
	if (source is null) return null;
	T* result = null;
	if (!cloneTo(result, source, true)) return null;
	return result;
}

/// Frees dynarray `array`, which may be null but must not be another kind of fat pointer, ending the lifetimes of its elements first. The `ref` overload also sets `array` to null.
///
/// Examples:
/// ---
/// int* array = null;
/// assert(pushBack(array, 1));
/// free(array);
/// assert(array is null);
/// ---
void free(T)(ref T* array) @trusted {
	free(cast(const T*) array);
	array = null;
}
/// Ditto
void free(T)(const T* array) @trusted {
	if (array is null) return;
	assert(valid(array));
	fp.lifecycle.endLifetimes(cast(T*) array, length(array));
	cast(void)fp.pointer.allocator(headerOf(array), 0);
}


/// Removes the last `count` elements, one by default, keeping their capacity, and ends their lifetimes. `count` must be no greater than the length. Returns a pointer to where the first of them was.
///
/// Examples:
/// ---
/// int* array = create!int(5);
/// scope(exit) free(array);
/// assert(removeLast(array, 3) is array + 2);
/// assert(length(array) == 2 && capacity(array) == 5);
/// cast(void) removeLast(array);
/// assert(length(array) == 1);
/// ---
T* removeLast(T)(T* array, size_t count = 1) @trusted {
	assert(count <= length(array));
	Header* header = headerOf(array);
	header.base.size = header.base.size <= count ? 0 : header.base.size - count;
	fp.lifecycle.endLifetimes(array + header.base.size, count);
	return array + header.base.size;
}

/// Removes `count` elements starting at `start`, which must fit within the length, moving every later element down and ending the removed ones' lifetimes. The capacity is kept; `shrinkToFit` releases it. Returns a pointer to element `start`. It cannot fail.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// int[5] values = [0, 1, 2, 3, 4];
/// assert(concatenate(array, values[]));
/// immutable before = capacity(array);
/// assert(*removeRange(array, 1, 2) == 3);
/// assert(slice(array) == [0, 3, 4] && capacity(array) == before);
/// ---
T* removeRange(T)(ref T* array, size_t start, size_t count) @trusted {
	immutable oldSize = length(array);
	assert(count <= oldSize && start <= oldSize - count);
	if (count > 0) {
		headerOf(array).base.size -= count;
		static if (fp.lifecycle.isBitMoveable!T) core.stdc.string.memmove(array + start, array + start + count, (oldSize - start - count) * T.sizeof);
		else {
			// Ending them first: only the first removed slot is a shift destination, so the rest would otherwise be zeroed with their lifetimes still running.
			fp.lifecycle.endLifetimes(array + start, count);
			for (size_t i = start; i < oldSize - count; ++i) // shifting down, so move from the front
				fp.lifecycle.moveInto(array[i], array[i + count]);
		}
	}
	return array + start;
}

// wrapper: container vocabulary every reader knows
/// Removes element `position`, moving every later element down one. Returns a pointer to element `position`, which now holds what followed it.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// int[3] values = [1, 2, 3];
/// assert(concatenate(array, values[]));
/// assert(*removeAt(array, 0) == 2);
/// assert(slice(array) == [2, 3]);
/// ---
T* removeAt(T)(ref T* array, size_t position) {
	return removeRange(array, position, 1);
}

/// Removes element `position` by moving the last element into its place, which is O(1) but does not keep the order. Ends the removed element's lifetime. It cannot fail.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// int[4] values = [1, 2, 3, 4];
/// assert(concatenate(array, values[]));
/// swapRemove(array, 0);
/// assert(slice(array) == [4, 2, 3]);
/// ---
void swapRemove(T)(T* array, size_t position) @trusted {
	immutable last = length(array) - 1;
	assert(position <= last);
	if (position != last) {
		fp.lifecycle.endLifetime(array[position]);
		fp.lifecycle.moveInto(array[position], array[last]);
	}
	cast(void) removeLast(array);
}

/// Keeps the elements for which `keep` returns true, in order, ending the others' lifetimes; the capacity is kept. Returns how many were removed. It cannot fail.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// int[5] values = [1, 2, 3, 4, 5];
/// assert(concatenate(array, values[]));
/// assert(retain!(x => x % 2 == 1)(array) == 2);
/// assert(slice(array) == [1, 3, 5]);
/// ---
size_t retain(alias keep, T)(T* array) @trusted {
	immutable before = length(array);
	size_t kept = 0;
	foreach (i; 0 .. before) {
		if (!keep(array[i])) {
			fp.lifecycle.endLifetime(array[i]);
			continue;
		}
		if (kept != i) fp.lifecycle.moveInto(array[kept], array[i]);
		++kept;
	}
	headerOf(array).base.size = kept;
	return before - kept;
}

/// Removes every element equal (`fp.lifecycle.equal`) to the one before it, so a sorted array holds each value once; the capacity is kept. Returns how many were removed. It cannot fail.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// int[6] values = [1, 1, 2, 3, 3, 3];
/// assert(concatenate(array, values[]));
/// assert(unique(array) == 3);
/// assert(slice(array) == [1, 2, 3]);
/// ---
size_t unique(T)(T* array) @trusted {
	immutable before = length(array);
	if (before == 0) return 0;
	size_t kept = 1;
	foreach (i; 1 .. before) {
		if (fp.lifecycle.equal(array[i], array[kept - 1])) {
			fp.lifecycle.endLifetime(array[i]);
			continue;
		}
		if (kept != i) fp.lifecycle.moveInto(array[kept], array[i]);
		++kept;
	}
	headerOf(array).base.size = kept;
	return before - kept;
}

/// Sets the length to 0, keeping the capacity and ending the elements' lifetimes.
///
/// Examples:
/// ---
/// int* array = create!int(4);
/// scope(exit) free(array);
/// clear(array);
/// assert(length(array) == 0 && capacity(array) == 4);
/// ---
void clear(T)(T* array) @trusted {
	fp.lifecycle.endLifetimes(array, length(array));
	headerOf(array).base.size = 0;
}

/// Reallocates so capacity equals length, or 1 for an empty array. Returns null if the allocator refused, in which case the array is unchanged.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// assert(reserve(array, 50) !is null && pushBack(array, 1));
/// assert(shrinkToFit(array) !is null);
/// assert(capacity(array) == 1 && array[0] == 1);
/// ---
T* shrinkToFit(T)(ref T* array) @trusted {
	immutable size = length(array);
	T* fitted = null;
	if (growToSize(fitted, size) is null) return null;
	if (array !is null) {
		fp.lifecycle.moveRange(fitted, array, size);
		// `headerOf(null)` is the shared dummy, not an allocation.
		cast(void)fp.pointer.allocator(headerOf(array), 0);
	}
	array = fitted;
	return array;
}


/// Swaps the `count` elements starting at `start1` with the `count` starting at `start2`; both ranges must lie within the length and must not overlap.
///
/// Examples:
/// ---
/// int* array = null;
/// scope(exit) free(array);
/// int[4] values = [1, 2, 3, 4];
/// assert(concatenate(array, values[]));
/// swapRange(array, 0, 2, 2);
/// assert(slice(array) == [3, 4, 1, 2]);
/// ---
void swapRange(T)(T* array, size_t start1, size_t start2, size_t count) @trusted {
	assert(count <= length(array) && start1 <= length(array) - count);
	assert(start2 <= length(array) - count);
	if (start1 == start2 || count == 0) return;
	assert(start1 + count <= start2 || start2 + count <= start1);

	static if (fp.lifecycle.isBitMoveable!T) {
		ubyte[1024] scratch = void;
		ubyte* a = cast(ubyte*)(array + start1);
		ubyte* b = cast(ubyte*)(array + start2);
		for (size_t done = 0, bytes = count * T.sizeof; done < bytes; done += scratch.length) {
			immutable chunk = bytes - done < scratch.length ? bytes - done : scratch.length;
			core.stdc.string.memcpy(scratch.ptr, a + done, chunk);
			core.stdc.string.memcpy(a + done, b + done, chunk);
			core.stdc.string.memcpy(b + done, scratch.ptr, chunk);
		}
	} else foreach (i; 0 .. count) fp.lifecycle.swapInto(array[start1 + i], array[start2 + i]);
}



version(unittest) {
	static import fp.testing;

	private __gshared fp.pointer.Allocator poisonUnderlying;

	private void* poisoningAllocator(void* p, size_t size) @trusted {
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

	/// For tests of reads through stale pointers: `beginPoisoningAllocator` makes `fp.pointer.allocator` overwrite each block as it is freed, so such a read sees garbage rather than the old contents; `endPoisoningAllocator` restores the allocator it returned. Memory allocated while it is active must be freed while it is, so register the restoring `scope(exit)` first.
	///
	/// Examples:
	/// ---
	/// auto previous = beginPoisoningAllocator();
	/// scope(exit) endPoisoningAllocator(previous);
	/// int* array = create!int(1);
	/// scope(exit) free(array);
	/// assert(array !is null);
	/// ---
	package fp.pointer.Allocator beginPoisoningAllocator() {
		poisonUnderlying = fp.pointer.allocator;
		fp.pointer.allocator = &poisoningAllocator;
		return poisonUnderlying;
	}

	/// Ditto
	package void endPoisoningAllocator(fp.pointer.Allocator previous) {
		fp.pointer.allocator = previous;
	}

	private __gshared fp.pointer.Allocator dirtyUnderlying;

	private void* dirtyAllocator(void* p, size_t size) {
		void* block = dirtyUnderlying(p, size);
		if (p is null && block !is null) core.stdc.string.memset(block, 0x55, size);
		return block;
	}

	/// For tests of uninitialized memory: `beginDirtyAllocator` makes `fp.pointer.allocator` fill every newly allocated block with `0x55` bytes, so a container that leaves a slot unset reads garbage rather than the zeros a fresh page usually has; `endDirtyAllocator` restores the allocator it returned.
	///
	/// Examples:
	/// ---
	/// auto previous = beginDirtyAllocator();
	/// scope(exit) endDirtyAllocator(previous);
	/// int* array = create!int(1);
	/// scope(exit) free(array);
	/// assert(array[0] == 0x55555555);
	/// ---
	package fp.pointer.Allocator beginDirtyAllocator() {
		dirtyUnderlying = fp.pointer.allocator;
		fp.pointer.allocator = &dirtyAllocator;
		return dirtyUnderlying;
	}

	/// Ditto
	package void endDirtyAllocator(fp.pointer.Allocator previous) {
		fp.pointer.allocator = previous;
	}

	private __gshared size_t finalizeCount;
}


unittest {
	int* neverAllocated = null;
	assert(!valid(neverAllocated));
	assert(capacity(neverAllocated) == 0);
	assert(length(neverAllocated) == 0);

	enum size_t topBit = size_t(1) << (size_t.sizeof * 8 - 1);
	assert(upperPowerOfTwo(1) == 1 && upperPowerOfTwo(5) == 8 && upperPowerOfTwo(8) == 8);
	assert(upperPowerOfTwo((topBit >> 1) + 1) == topBit);
}

unittest {
	int* array = null;
	scope(exit) assert(array is null); // Scope exits run in reverse order!
	scope(exit) free(array);

	assert(reserve(array, 20) !is null);
	assert(capacity(array) == 20);
	assert(length(array) == 0);

	// A zero size has no last element to point at, so the array itself is returned rather than one slot before its start.
	assert(reserve(array, 0) is array && growToSize(array, 0) is array && grow(array, 0) is array);
	assert(maybeGrow(array, 0, true, false) is array && length(array) == 0);

	// Nothing appended means nothing allocated: a null array stays null rather than getting a first page.
	int* untouched = null;
	assert(grow(untouched, 0) is null && untouched is null);

	int* zeroed = create!int(0);
	assert(zeroed !is null);
	scope(exit) free(zeroed);
	assert(length(zeroed) == 0 && capacity(zeroed) == 1);

	assert(pushBack(array, 5));
	assert(pushFront(array, 6));
	assert(pushBack(array, 7));
	assert(capacity(array) == 20);
	assert(slice(array) == [6, 5, 7]);
	assert(array[0] == 6 && *back(array) == 7);

	int[2] extra = [8, 9];
	assert(concatenate(array, extra[]));
	assert(slice(array) == [6, 5, 7, 8, 9]);

	assert(removeAt(array, 1) !is null);
	assert(*removeLast(array) == 9);
	swapRange(array, 0, 1, 1);
	assert(capacity(array) == 20);
	assert(slice(array) == [7, 6, 8]);

	// 300 ints span two scratch chunks, the second one partial.
	int* wide = null;
	scope(exit) free(wide);
	foreach (i; 0 .. 601) assert(pushBack(wide, i));
	swapRange(wide, 1, 301, 300);
	assert(wide[0] == 0 && wide[1] == 301 && wide[300] == 600 && wide[301] == 1 && wide[600] == 300);

	int* copy = null;
	scope(exit) free(copy);
	assert(cloneTo(copy, array));
	assert(copy != array && capacity(copy) == 20 && slice(copy) == [7, 6, 8]);

	// Cloning into itself keeps the elements it had, not the spare capacity the grow rounded up to.
	assert(cloneTo(array, array) && length(array) == 3 && capacity(array) == 20 && slice(array) == [7, 6, 8]);

	int* cloned = clone(array);
	scope(exit) free(cloned);
	assert(cloned !is null && cloned != array && slice(cloned) == [7, 6, 8]);

	assert(shrinkToFit(array) !is null);
	assert(capacity(array) == 3 && slice(array) == [7, 6, 8]);

	// Removing a middle range keeps the elements on both sides, and shrinking afterwards keeps them too.
	assert(pushBack(array, 0) && pushBack(array, 1));
	assert(removeRange(array, 1, 2) !is null && shrinkToFit(array) !is null);
	assert(capacity(array) == 3 && slice(array) == [7, 0, 1]);

	int* none = null;
	assert(shrinkToFit(none) !is null);
	assert(length(none) == 0 && capacity(none) == 1);
	free(none);

	clear(array);
	assert(length(array) == 0 && capacity(array) == 3);

	// An emptied array keeps a capacity, which is what makes it `fp.pointer.valid` with no elements.
	int* emptied = create!int(3);
	assert(emptied !is null);
	scope(exit) free(emptied);
	assert(cloneTo(emptied, array, true));
	assert(fp.pointer.valid(emptied) && length(emptied) == 0 && capacity(emptied) == 3);
	assert(shrinkToFit(array) !is null);
	assert(fp.pointer.valid(array) && length(array) == 0 && capacity(array) == 1);

	// Only `source`'s two elements are copied: reading more would overrun `source` and overwrite `destination`'s spare slots.
	int* destination = create!int(8);
	assert(destination !is null);
	scope(exit) free(destination);
	assert(length(destination) == 8 && capacity(destination) == 8);
	destination[0 .. 8] = -1;
	int* source = null;
	assert(pushBack(source, 1) && pushBack(source, 2));
	assert(cloneTo(destination, source, true));
	assert(slice(destination) == [1, 2]);
	foreach (i; 2 .. 8)
		assert(destination[i] == -1);

	// A `const(int)*` lvalue would still bind to `ref T*`, with `T` deduced as `const(int)`, so only an rvalue reaches the by-value overload.
	free(cast(const int*) source);

	// A heap fat pointer has no capacity to copy, so its length sizes the clone.
	int* heap = fp.pointer.allocate!int(10);
	assert(heap !is null);
	scope(exit) fp.pointer.free(heap);
	heap[0 .. 10] = 4;
	int* fromHeap = null;
	scope(exit) free(fromHeap);
	assert(cloneTo(fromHeap, heap));
	assert(length(fromHeap) == 10 && capacity(fromHeap) == 10 && fromHeap[9] == 4);

	// Checking a dynarray handle against a heap pointer reads only the shared 16-byte header; this module's larger header would overrun a foreign allocation.
	assert(!valid(heap) && capacity(heap) == 0 && length(heap) == 10);

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
	auto previous = fp.testing.limitAllocations();
	int* fresh = null;
	assert(growToSize(fresh, 4) is null);
	assert(fresh is null);     // And nothing was half-built.
	assert(create!int(4) is null);
	assert(!pushBack(fresh, 1));
	fp.testing.restoreAllocator(previous);

	int* existing = null;
	assert(pushBack(existing, 11));
	assert(pushBack(existing, 22));
	scope(exit) free(existing);
	// Use up the spare capacity, so that everything below has to reallocate.
	while (length(existing) < capacity(existing))
		assert(pushBack(existing, 0));
	immutable filled = length(existing);
	int* before = existing;

	previous = fp.testing.limitAllocations();
	assert(reserve(existing, 4096) is null);
	assert(!pushBack(existing, 33));
	static immutable int[2] more = [44, 55];
	assert(!concatenate(existing, more[]));
	assert(!concatenate(existing, existing));
	assert(insertUninitialized(existing, 0, 4096) is null);
	assert(!insert(existing, 0, 66));
	assert(!pushFront(existing, 77));
	assert(clone(existing) is null);
	swapRange(existing, 0, 1, 1); // needs no allocation
	swapRange(existing, 0, 1, 1);
	fp.testing.restoreAllocator(previous);

	// Growing a null array past its default capacity takes one allocation, not a default-sized one that a refused second leaves behind.
	previous = fp.testing.limitAllocations(1);
	assert(grow(fresh, 100) !is null);
	fp.testing.restoreAllocator(previous);
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
	assert(existing[0] == 11 && existing[1] == 22);
	swapRange(existing, 0, 1, 1);
	assert(existing[0] == 22 && existing[1] == 11);
}

unittest {
	static struct Handle {
		int* data;
		void finalize() @nogc nothrow { if (data !is null) ++finalizeCount; data = null; }
		void moveTo(ref Handle destination) @nogc nothrow { destination.data = data; data = null; }
		void copyTo(ref Handle destination) @nogc nothrow { destination.data = data; }
	}

	static assert(fp.lifecycle.isBitMoveable!int && !fp.lifecycle.isBitMoveable!Handle);

	Handle* array = null;
	scope(exit) free(array);
	finalizeCount = 0;

	assert(pushBack(array, Handle(cast(int*) 1)) && pushBack(array, Handle(cast(int*) 2)));
	assert(length(array) == 2 && array[1].data == cast(int*) 2 && finalizeCount == 0);

	// Growing moves the elements without ending their lifetimes.
	assert(reserve(array, 100) !is null && length(array) == 2 && array[0].data == cast(int*) 1 && finalizeCount == 0);

	assert(insertUninitialized(array, 1, 1) !is null);
	assert(array[1].data is null); // the gap is left empty, so removing it without filling it finalizes nothing
	array[1].data = cast(int*) 3;
	assert(length(array) == 3 && array[0].data == cast(int*) 1 && array[1].data == cast(int*) 3 && array[2].data == cast(int*) 2);

	assert(removeRange(array, 0, 1) !is null);
	assert(finalizeCount == 1 && array[0].data == cast(int*) 3 && array[1].data == cast(int*) 2);

	swapRange(array, 0, 1, 1);
	assert(array[0].data == cast(int*) 2 && array[1].data == cast(int*) 3);

	// Shrinking after a removal moves the survivors into the new block without ending them again.
	assert(removeRange(array, 0, 1) !is null && shrinkToFit(array) !is null);
	assert(finalizeCount == 2 && length(array) == 1 && array[0].data == cast(int*) 3);

	// A middle range of more than one element: only the first removed slot is a shift destination.
	assert(pushBack(array, Handle(cast(int*) 4)) && pushBack(array, Handle(cast(int*) 5)) && pushBack(array, Handle(cast(int*) 6)));
	assert(removeRange(array, 1, 2) !is null);
	assert(finalizeCount == 4 && length(array) == 2 && array[0].data == cast(int*) 3 && array[1].data == cast(int*) 6);

	Handle* copy = null;
	scope(exit) free(copy);
	assert(cloneTo(copy, array));
	assert(length(copy) == 2 && copy[0].data == cast(int*) 3 && copy[1].data == cast(int*) 6);

	// Cloning into an array longer than the source drops the extra elements, ending their lifetimes.
	Handle* longer = null;
	scope(exit) free(longer);
	assert(pushBack(longer, Handle(cast(int*) 7)) && pushBack(longer, Handle(cast(int*) 8)) && pushBack(longer, Handle(cast(int*) 9)));
	assert(cloneTo(longer, array));
	assert(length(longer) == 2 && longer[0].data == cast(int*) 3 && longer[1].data == cast(int*) 6 && finalizeCount == 7);

	// A deep copy refused partway reports false, ends the elements it did copy, and leaves the container as it was.
	static int deepEnded = 0;
	static struct Deep {
		int* data;
		bool copyTo(ref Deep destination) @nogc nothrow { destination.data = fp.pointer.allocate!int(1); return destination.data !is null; }
		void finalize() @nogc nothrow { if (data !is null) { fp.pointer.free(data); ++deepEnded; } }
	}
	Deep* deep = null;
	scope(exit) free(deep);
	assert(pushBack(deep, Deep(null)) && pushBack(deep, Deep(null)));
	Deep* roomy = null;
	scope(exit) free(roomy);
	assert(reserve(roomy, 8) !is null && pushBack(roomy, Deep(null)) && length(roomy) == 1);
	deepEnded = 0;
	auto oneCopy = fp.testing.limitAllocations(1); // only the first deep copy is granted
	assert(!concatenate(roomy, deep));
	assert(length(roomy) == 1 && roomy[0].data is null && deepEnded == 1); // the copied element was ended, the length restored
	assert(!cloneTo(roomy, deep, true));
	assert(length(roomy) == 0 && deepEnded == 1);
	fp.testing.restoreAllocator(oneCopy);
	assert(concatenate(roomy, deep) && length(roomy) == 2 && roomy[0].data !is null);
	assert(cloneTo(roomy, deep) && length(roomy) == 2);

	assert(removeLast(array, 1) is array + 1);
	assert(finalizeCount == 8 && array[0].data == cast(int*) 3);

	clear(array);
	assert(finalizeCount == 9 && length(array) == 0);

	free(array); // every slot was already empty
	assert(finalizeCount == 9);

	// A refused append ends the value's lifetime, since the call took it over.
	finalizeCount = 0;
	Handle* tight = create!Handle(1);
	assert(tight !is null && pushBack(tight, Handle(cast(int*) 5)));
	auto rationed = fp.testing.limitAllocations();
	assert(!pushBack(tight, Handle(cast(int*) 4)) && finalizeCount == 1 && length(tight) == 2);
	fp.testing.restoreAllocator(rationed);
	assert(insert(tight, 1, Handle(cast(int*) 6)) && length(tight) == 3);

	// A middle range's lifetimes end at the removal, so shrinking afterwards ends nothing more.
	assert(removeRange(tight, 1, 1) !is null && shrinkToFit(tight) !is null);
	assert(finalizeCount == 2 && length(tight) == 2 && tight[0].data is null && tight[1].data == cast(int*) 5);

	free(tight);
	assert(finalizeCount == 3 && tight is null);
}

unittest { // swapRemove, retain and unique end exactly the removed elements' lifetimes, and an empty concatenate allocates nothing
	static int ended = 0;
	static struct Handle {
		int id;
		void finalize() @nogc nothrow { if (id != 0) ++ended; id = 0; }
		static bool equal(ref const Handle a, ref const Handle b) @nogc nothrow { return a.id / 10 == b.id / 10; }
	}
	Handle* array = null;
	scope(exit) free(array);
	foreach (id; [11, 12, 21, 31, 32, 33, 41]) assert(pushBack(array, Handle(id)));

	assert(unique(array) == 3 && ended == 3);
	assert(length(array) == 4 && array[0].id == 11 && array[1].id == 21 && array[2].id == 31 && array[3].id == 41);

	assert(retain!(header => header.id != 21)(array) == 1 && ended == 4);
	assert(length(array) == 3 && array[1].id == 31);

	swapRemove(array, 0);
	assert(ended == 5 && length(array) == 2 && array[0].id == 41 && array[1].id == 31);
	swapRemove(array, 1);
	assert(ended == 6 && length(array) == 1 && array[0].id == 41);

	int* none = null;
	auto rationed = fp.testing.limitAllocations(0);
	assert(concatenate(none, (int[]).init) && none is null);
	fp.testing.restoreAllocator(rationed);
}

unittest { // resize shrinks as well as grows, ending exactly the dropped elements' lifetimes; growToSize never shrinks
	static int ended = 0;
	static struct Handle { int id; void finalize() @nogc nothrow { if (id) ++ended; id = 0; } }
	Handle* array = null;
	scope(exit) free(array);
	foreach (id; 1 .. 5) assert(pushBack(array, Handle(id)));
	assert(growToSize(array, 2) !is null && length(array) == 4 && ended == 0);
	assert(resize(array, 2) is array + 1 && length(array) == 2 && ended == 2 && array[1].id == 2);
	assert(resize(array, 3) is array + 2 && length(array) == 3 && array[2].id == 0);
}

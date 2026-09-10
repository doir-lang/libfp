module fp.dynarray;

import core.stdc.string : cMemcpy = memcpy, cMemmove = memmove;

import fp.pointer : allocFunction, PointerHeader = Header, PointerType, Array;
public import fp.pointer : length, size, empty, front, back, slice;

package struct Header {
    size_t capacity;
    PointerHeader base;
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
    Header* newH = headerOf(newData);
    newH.capacity = newCapacity;
    newH.base.size = updateUtilized ? (h.base.size > newSize ? h.base.size : newSize) : h.base.size;
    cMemcpy(newData, oldData, T.sizeof * h.base.size);

    allocFunction(headerOf(oldData), 0);
    da = newData;
    return da + (newSize - 1);
}

/// Grows array to exactly `size` elements (capacity matches size exactly).
T* growToSize(T)(ref T* da, size_t size) {
    return maybeGrow(da, size, true, true);
}

/// Grows array by `toAdd` elements; new elements are uninitialized.
T* grow(T)(ref T* da, size_t toAdd) {
    return maybeGrow(da, length(da) + toAdd, true, false);
}

/// Reserves capacity for at least `size` elements without changing length.
T* reserve(T)(ref T* da, size_t size) {
    return maybeGrow(da, size, false, true);
}

void pushBack(T)(ref T* da, T value) {
    *maybeGrow(da, length(da) + 1, true, false) = value;
}

/// Inserts `count` uninitialized elements at `pos`, returning a pointer to the first of them.
T* insertUninitialized(T)(ref T* da, size_t pos, size_t count) @trusted {
    assert(count > 0);
    assert(pos <= length(da));

    immutable oldSize = length(da);
    maybeGrow(da, oldSize + count, true, false);

    ubyte* raw = cast(ubyte*) da;
    ubyte* oldStart = raw + pos * T.sizeof;
    ubyte* newStart = oldStart + count * T.sizeof;
    immutable bytesToMove = (raw + length(da) * T.sizeof) - newStart;
    cMemmove(newStart, oldStart, bytesToMove);
    return cast(T*) oldStart;
}

void insert(T)(ref T* da, size_t pos, T value) {
    *insertUninitialized(da, pos, 1) = value;
}

void pushFront(T)(ref T* da, T value) {
    insert(da, 0, value);
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
        growToSize(newData, newLength);
        Header* newH = headerOf(newData);
        newH.capacity = newLength;

        ubyte* newRaw = cast(ubyte*) newData;
        ubyte* insertedStart = newRaw + start * T.sizeof;
        if (oldStart != raw)
            cMemcpy(newRaw, raw, insertedStart - newRaw);
        cMemcpy(insertedStart, oldStart, bytesToMove);

        allocFunction(headerOf(da), 0);
        da = newData;
        newStart = insertedStart;
    } else if (count > 0) {
        headerOf(da).base.size -= count;
        cMemmove(newStart, oldStart, bytesToMove);
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

void swapRange(T)(T* da, size_t start1, size_t start2, size_t count) @trusted {
    assert(start1 + count <= length(da));
    assert(start2 + count <= length(da));
    if (start1 == start2 || count == 0) return;

    immutable bytes = count * T.sizeof;
    pragma(inline, true);
    ubyte* scratch = cast(ubyte*) allocFunction(null, bytes);

    ubyte* a = cast(ubyte*)(da + start1);
    ubyte* b = cast(ubyte*)(da + start2);
    cMemcpy(scratch, a, bytes);
    cMemcpy(a, b, bytes);
    cMemcpy(b, scratch, bytes);

    pragma(inline, true);
    allocFunction(scratch, 0);
}

void swap(T)(T* da, size_t pos1, size_t pos2) {
    swapRange(da, pos1, pos2, 1);
}

/// Copies `src`'s elements (and, unless `shrink`, its spare capacity) into `dest`.
void cloneTo(T)(ref T* dest, inout T* src, bool shrink = false) @trusted {
    immutable newCapacity = shrink ? length(src) : capacity(src);
    growToSize(dest, newCapacity);
    cMemcpy(dest, src, length(dest) * T.sizeof);
    Header* h = headerOf(dest);
    h.capacity = newCapacity;
    h.base.size = length(src);
}

T* clone(T)(inout T* src) {
    if (src is null) return null;
    T* result = null;
    cloneTo(result, src, true);
    return result;
}

void concatenate(T)(ref T* dest, inout(T)[] src) @trusted {
    immutable preSize = length(dest);
    maybeGrow(dest, preSize + src.length, true, false);
    cMemcpy(dest + preSize, src.ptr, src.length * T.sizeof);
}

void concatenate(T)(ref T* dest, inout T* src) {
    concatenate(dest, slice(src));
}

void free(T)(const T* da) @trusted {
    if (headerOf(da) != &nullHeaderRef)
        allocFunction(headerOf(da), 0);
}
void free(T)(ref T* da) @trusted {
    if (headerOf(da) != &nullHeaderRef)
        allocFunction(headerOf(da), 0);
    da = null;
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

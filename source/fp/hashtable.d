module fp.hashtable;

import core.stdc.string : cMemcpy = memcpy, cMemcmp = memcmp, cMemset = memset;

import fp.pointer : allocFunction, PointerType, notFound;
import fp.dynarray : length, grow, growToSize, swap;
import fp.dynarray : dynFree = free;
import fp.dynarray : DynarrayHeader = Header;
import fp.fnv1a;


@nogc nothrow: // every declaration below is @nogc nothrow unless stated otherwise


alias HashFn = size_t function(inout(ubyte)[]) @nogc nothrow;
alias EqualFn = bool function(inout(ubyte)[], inout(ubyte)[]) @nogc nothrow;
alias CopyFn = void* function(void*, inout(void)*, size_t) @nogc nothrow;
alias FinalizeFn = void function(inout(ubyte)[]) @nogc nothrow;

private size_t defaultHash(inout(ubyte)[] data) @nogc nothrow {
    return fp.fnv1a.hash(data);
}

private bool defaultEqual(inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
    if (a.length != b.length) return false;
    return cMemcmp(a.ptr, b.ptr, a.length) == 0;
}

private void* defaultCopy(void* dest, inout(void)* src, size_t n) @trusted {
    return cMemcpy(dest, src, n);
}

struct Config {
    HashFn hashFn = &defaultHash;
    EqualFn equalFn = &defaultEqual;
    CopyFn copyFn = &defaultCopy;
    FinalizeFn finalizeFn = null;
    size_t baseSize = 8;
    size_t neighborhoodSize = 8;
    size_t maxFailRetries = 8;
}

package struct Header {
    size_t* entryInfos;
    Config config;
    DynarrayHeader base;
}

private enum size_t occupiedBit = size_t(1) << 31;

private __gshared Header nullHeaderRef;

package Header* headerOf(inout void* p) @trusted {
    if (p is null) {
        nullHeaderRef = Header.init;
        return &nullHeaderRef;
    }
    return cast(Header*)(cast(const(ubyte)*) p - Header.sizeof);
}

bool valid_hashtable(inout void* p) @trusted {
    return headerOf(p).base.base.type == PointerType.hashTable;
}

alias valid = valid_hashtable;

size_t capacity(inout void* p) @trusted {
    if (!valid_hashtable(p)) return 0;
    return headerOf(p).base.capacity;
}

private void* rawAlloc(size_t payloadBytes) @trusted {
    immutable total = Header.sizeof + payloadBytes + 1;
    ubyte* raw = cast(ubyte*) allocFunction(null, total);
    if (raw is null) return null;

    ubyte* data = raw + Header.sizeof;
    Header* h = headerOf(data);
    h.base.capacity = 0;
    h.base.base.type = PointerType.hashTable;
    h.base.base.size = 0;
    data[payloadBytes] = 0;
    return data;
}

private T* growExact(T)(ref T* table, size_t newSize) @trusted {
    Header* h = headerOf(table);
    if (h.base.capacity >= newSize) {
        h.base.base.size = h.base.base.size > newSize ? h.base.base.size : newSize;
        return table + (newSize - 1);
    }

    T* oldData = table;
    T* newData = cast(T*) rawAlloc(newSize * T.sizeof);
    Header* newH = headerOf(newData);
    newH.base.capacity = newSize;
    newH.base.base.size = h.base.base.size > newSize ? h.base.base.size : newSize;
    newH.entryInfos = h.entryInfos;
    newH.config = h.config;

    cMemcpy(newData, oldData, T.sizeof * h.base.base.size);
    allocFunction(headerOf(oldData), 0);
    table = newData;
    return table + (newSize - 1);
}

private void growAndInitialize(T)(ref T* da, size_t toAdd, T value) @trusted {
    immutable oldSize = length(da);
    grow(da, toAdd);
    foreach (i; oldSize .. length(da))
        da[i] = value;
}

private void growToSizeAndInitialize(T)(ref T* da, size_t size, T value) @trusted {
    immutable oldSize = length(da);
    growToSize(da, size);
    foreach (i; oldSize .. length(da))
        da[i] = value;
}

/// Creates a table with `config.baseSize` slots.
T* create(T)(Config config = Config.init) @trusted {
    T* outp = cast(T*) rawAlloc(T.sizeof * config.baseSize);
    Header* h = headerOf(outp);
    h.base.capacity = config.baseSize;
    h.base.base.size = config.baseSize;
    h.config = config;
    h.entryInfos = null;
    growToSizeAndInitialize(h.entryInfos, config.baseSize, size_t(0));
    return outp;
}

private size_t* entryInfoPtr(inout void* table, size_t index) @trusted {
    assert(index < length(headerOf(table).entryInfos));
    return headerOf(table).entryInfos + index;
}

private bool entryOccupied(inout void* table, size_t index) @trusted {
    return (*entryInfoPtr(table, index) & occupiedBit) != 0;
}

private void setEntryOccupied(inout void* table, size_t index, bool state) @trusted {
    if (state) *entryInfoPtr(table, index) |= occupiedBit;
    else *entryInfoPtr(table, index) &= ~occupiedBit;
}

private size_t computeHash(inout void* table, inout(ubyte)[] key) @trusted {
    return headerOf(table).config.hashFn(key) % length(table);
}

private bool keysEqual(inout void* table, inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
    return headerOf(table).config.equalFn(a, b);
}

private void copyInto(inout void* table, void* dest, inout void* src, size_t n) @trusted {
    headerOf(table).config.copyFn(dest, src, n);
}

private size_t findEmptyHashPosition(inout void* table, size_t hash) @trusted {
    immutable neighborhoodSize = headerOf(table).config.neighborhoodSize;
    immutable size = length(table);
    foreach (i; 0 .. neighborhoodSize) {
        immutable probe = (hash + i) % size;
        if (!entryOccupied(table, probe))
            return probe;
    }
    return notFound;
}

private size_t hashDistance(inout void* table, size_t hash, size_t position) @trusted {
    immutable size = length(table);
    return position < hash ? size - hash + position : position - hash;
}

private void* insertImpl(T)(ref T* table, inout(ubyte)[] key, size_t failures) @trusted {
    immutable hash = computeHash(table, key);
    immutable position = findEmptyHashPosition(table, hash);

    if (position == notFound) {
        if (failures >= headerOf(table).config.maxFailRetries)
            return null;
        if (doubleSizeAndRehash(table, failures + 1) != notFound)
            return null;
        return insertImpl(table, key, failures + 1);
    }

    ubyte* tableP = cast(ubyte*) table;
    copyInto(table, tableP + key.length * position, key.ptr, key.length);
    *entryInfoPtr(table, hash) |= (size_t(1) << hashDistance(table, hash, position));
    setEntryOccupied(table, position, true);
    return tableP + key.length * position;
}

/// Inserts `key` without checking whether it's already present.
T* insertAssumeUnique(T)(ref T* table, T key) @trusted {
    ubyte* keyBytes = cast(ubyte*) &key;
    return cast(T*) insertImpl(table, keyBytes[0 .. T.sizeof], 0);
}

size_t rehash(T)(ref T* table, size_t failures) @trusted {
    immutable size = length(table);
    {
        immutable entriesSize = length(headerOf(table).entryInfos);
        if (entriesSize < size)
            growAndInitialize(headerOf(table).entryInfos, size - entriesSize, size_t(0));
    }

    ubyte[T.sizeof] scratch = void;
    ubyte* tableP = cast(ubyte*) table;

    foreach (i; 0 .. size) {
        immutable occupied = entryOccupied(table, i);
        *entryInfoPtr(table, i) = 0;
        if (!occupied) continue;

        copyInto(table, scratch.ptr, tableP + i * T.sizeof, T.sizeof);
        if (insertImpl(table, scratch[], failures) is null)
            return i;
        tableP = cast(ubyte*) table; // re-read: insertImpl may have reallocated on regrow
    }
    return notFound;
}

/// Doubles the table's capacity and rebuilds every bucket assignment.
/// Returns `notFound` on success, or the index rehashing failed at.
private size_t doubleSizeAndRehash(T)(ref T* table, size_t failures) @trusted {
    immutable size = length(table);
    immutable newSize = size * 2;
    growExact(table, newSize);
    growAndInitialize(headerOf(table).entryInfos, size, size_t(0));

    ubyte* tableP = cast(ubyte*) table;
    foreach (i; 0 .. size) {
        if (i % 2 == 1) {
            copyInto(table, tableP + (newSize - i) * T.sizeof, tableP + i * T.sizeof, T.sizeof);
            cMemset(tableP + i * T.sizeof, 0, T.sizeof);
            swap(headerOf(table).entryInfos, i, newSize - i);
        }
    }

    return rehash(table, failures);
}

private size_t findPositionBytes(inout void* table, inout(ubyte)[] key) @trusted {
    immutable hash = computeHash(table, key);
    immutable hashInfo = *entryInfoPtr(table, hash);
    immutable neighborhoodSize = headerOf(table).config.neighborhoodSize;
    ubyte* tableP = cast(ubyte*) table;

    foreach (i; 0 .. neighborhoodSize) {
        if ((hashInfo & (size_t(1) << i)) == 0) continue;
        immutable probe = (hash + i) % length(table);
        if (!entryOccupied(table, probe)) continue;
        if (keysEqual(table, key, tableP[probe * key.length .. probe * key.length + key.length]))
            return probe;
    }
    return notFound;
}

size_t findPosition(T)(inout T* table, T key) @trusted {
    ubyte* keyBytes = cast(ubyte*) &key;
    return findPositionBytes(table, keyBytes[0 .. T.sizeof]);
}

T* find(T)(T* table, T key)  {
    immutable pos = findPosition(table, key);
    return pos == notFound ? null : table + pos;
}

bool contains(T)(inout T* table, T key) {
    return findPosition(table, key) != notFound;
}

/// Finds `key`, inserting it if it isn't already present.
T* insert(T)(ref T* table, T key) {
    T* existing = find(table, key);
    return existing !is null ? existing : insertAssumeUnique(table, key);
}

void removeAtPosition(T)(inout T* table, size_t position) @trusted {
    setEntryOccupied(table, position, false);
    // ubyte* tableP = cast(ubyte*) table;
    // headerOf(table).config.finalizeFn(tableP[position * T.sizeof .. (position + 1) * T.sizeof]);
}

void remove(T)(T* table, T key) {
    immutable pos = findPosition(table, key);
    if (pos != notFound)
        removeAtPosition(table, pos);
}

private void finalizeAll(T)(T* table) @trusted {
    if (headerOf(table).config.finalizeFn is null) return;
    ubyte* tableP = cast(ubyte*) table;
    foreach (i; 0 .. length(table))
        if (entryOccupied(table, i))
            headerOf(table).config.finalizeFn(tableP[i * T.sizeof .. (i + 1) * T.sizeof]);
}

void free(T)(ref T* table) @trusted {
    finalizeAll(table);
    size_t* entries = headerOf(table).entryInfos;
    dynFree(entries);
    allocFunction(headerOf(table), 0);
    table = null;
}

unittest {
    int* table = create!int();
    scope(exit) assert(table is null); // Scope exits run in reverse order!
    scope(exit) free(table);

    assert(table !is null);
    assert(valid_hashtable(table));

    int key = 5;
    int* v = insertAssumeUnique(table, key);
    assert(*v == key);

    size_t p = findPosition(table, key);
    assert(p == 6);
    assert(table[p] == key);
    v = find(table, key);
    assert(*v == key);

    int* v2 = insert(table, key);
    assert(v2 == v);

    key = 6;
    v = insert(table, key);
    assert(v != v2);
    assert(*v == 6);

    size_t failedIndex = doubleSizeAndRehash(table, 0);
    assert(failedIndex == notFound);

    key = 5;
    v = find(table, key);
    assert(*v == 5);
    key = 6;
    v = find(table, key);
    assert(*v == 6);
    key = 7;
    v = find(table, key);
    assert(v is null);

    key = 5;
    remove(table, key);
    v = find(table, key);
    assert(v is null);
}

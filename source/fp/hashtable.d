module fp.hashtable;

import core.stdc.string;

import fp.pointer;
import fp.dynarray;
import fp.fnv1a;


@nogc nothrow: // every declaration below is @nogc nothrow unless stated otherwise


alias HashFunction = size_t function(inout(ubyte)[]) @nogc nothrow;
alias EqualFunction = bool function(inout(ubyte)[], inout(ubyte)[]) @nogc nothrow;
alias CopyFunction = void* function(void*, inout(void)*, size_t) @nogc nothrow;
alias FinalizeFunction = void function(inout(ubyte)[]) @nogc nothrow;

private size_t defaultHash(inout(ubyte)[] data) @nogc nothrow {
	return fp.fnv1a.hash(data);
}

private bool defaultEqual(inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
	if (a.length != b.length) return false;
	return core.stdc.string.memcmp(a.ptr, b.ptr, a.length) == 0;
}

private void* defaultCopy(void* dest, inout(void)* src, size_t n) @trusted {
	return core.stdc.string.memcpy(dest, src, n);
}

struct Config {
	HashFunction hashFunction = &defaultHash;
	EqualFunction equalFunction = &defaultEqual;
	CopyFunction copyFunction = &defaultCopy;
	FinalizeFunction finalizeFunction = null;
	size_t baseSize = 8;
	size_t neighborhoodSize = 8;
	size_t maxFailRetries = 8;
}

package struct Header {
	size_t* entryInfos;
	Config config;
	fp.dynarray.Header base;
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
	// Bail before freeing `oldData`: the table is still usable at its old size.
	if (newData is null) return null;
	Header* newH = headerOf(newData);
	newH.base.capacity = newSize;
	newH.base.base.size = h.base.base.size > newSize ? h.base.base.size : newSize;
	newH.entryInfos = h.entryInfos;
	newH.config = h.config;

	core.stdc.string.memcpy(newData, oldData, T.sizeof * h.base.base.size);
	allocFunction(headerOf(oldData), 0);
	table = newData;
	return table + (newSize - 1);
}

/// Grows `da` to `newSize` and sets the slots that adds, which the dynarray
/// itself leaves uninitialized. `exactSizing` means what `maybeGrow` means by
/// it: the capacity matches the size rather than rounding up to a power of two.
private bool growAndInitialize(T)(ref T* da, size_t newSize, T value, bool exactSizing) @trusted {
	immutable oldSize = length(da);
	if (maybeGrow(da, newSize, true, exactSizing) is null) return false;
	foreach (i; oldSize .. length(da))
		da[i] = value;
	return true;
}

/// Creates a table with `config.baseSize` slots.
T* create(T)(Config config = Config.init) @trusted {
	T* outp = cast(T*) rawAlloc(T.sizeof * config.baseSize);
	if (outp is null) return null;
	Header* h = headerOf(outp);
	h.base.capacity = config.baseSize;
	h.base.base.size = config.baseSize;
	h.config = config;
	h.entryInfos = null;
	if (!growAndInitialize(h.entryInfos, config.baseSize, size_t(0), true)) {
		allocFunction(headerOf(outp), 0);
		return null;
	}
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
	return headerOf(table).config.hashFunction(key) % length(table);
}

private bool keysEqual(inout void* table, inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
	return headerOf(table).config.equalFunction(a, b);
}

private void copyInto(inout void* table, void* dest, inout void* src, size_t n) @trusted {
	headerOf(table).config.copyFunction(dest, src, n);
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
	if (length(headerOf(table).entryInfos) < size)
		if (!growAndInitialize(headerOf(table).entryInfos, size, size_t(0), false))
			return 0;

	// Snapshot every occupied slot's data *before* touching any entryInfos
	// bits. Clearing entryInfos[i] one index at a time while reinserting (as
	// we scan) is unsound: an entry's hash-home index and its physical
	// position frequently differ, so an earlier reinsertion in this same
	// pass can legitimately write a hash-home bit into an index this loop
	// hasn't reached yet -- which the "clear this index" step then wipes out
	// once the loop reaches it, silently losing that entry even though its
	// data is still physically present elsewhere in the table. Snapshotting
	// first and clearing everything in one shot means every reinsertion
	// starts from a consistent, fully zeroed bitmap.
	ubyte* tableP = cast(ubyte*) table;
	T* snapshot = null;
	size_t* positions = null;
	scope(exit) { fp.dynarray.free(snapshot); fp.dynarray.free(positions); }
	if (growToSize(snapshot, size) is null) return 0;
	if (growToSize(positions, size) is null) return 0;

	size_t occupiedCount = 0;
	ubyte* snapshotP = cast(ubyte*) snapshot;
	foreach (i; 0 .. size) {
		if (entryOccupied(table, i)) {
			copyInto(table, snapshotP + occupiedCount * T.sizeof, tableP + i * T.sizeof, T.sizeof);
			positions[occupiedCount] = i;
			occupiedCount++;
		}
	}

	foreach (i; 0 .. size)
		*entryInfoPtr(table, i) = 0;

	foreach (idx; 0 .. occupiedCount) {
		ubyte* keyPtr = snapshotP + idx * T.sizeof;
		if (insertImpl(table, keyPtr[0 .. T.sizeof], failures) is null)
			return positions[idx];
	}
	return notFound;
}

/// Doubles the table's capacity and rebuilds every bucket assignment.
/// Returns `notFound` on success, or the index rehashing failed at — or 0 if
/// an allocation it needed was refused, which is not an index but is likewise
/// not `notFound`, so callers already read it as failure.
private size_t doubleSizeAndRehash(T)(ref T* table, size_t failures) @trusted {
	immutable size = length(table);
	immutable newSize = size * 2;
	if (growExact(table, newSize) is null) return 0;
	if (!growAndInitialize(headerOf(table).entryInfos, newSize, size_t(0), false)) return 0;

	ubyte* tableP = cast(ubyte*) table;
	foreach (i; 0 .. size) {
		if (i % 2 == 1) {
			copyInto(table, tableP + (newSize - i) * T.sizeof, tableP + i * T.sizeof, T.sizeof);
			core.stdc.string.memset(tableP + i * T.sizeof, 0, T.sizeof);
			if (!swap(headerOf(table).entryInfos, i, newSize - i)) return 0;
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
	if (headerOf(table).config.finalizeFunction !is null) {
		ubyte* tableP = cast(ubyte*) table;
		headerOf(table).config.finalizeFunction(tableP[position * T.sizeof .. (position + 1) * T.sizeof]);
	}
	setEntryOccupied(table, position, false);
}

void remove(T)(T* table, T key) {
	immutable pos = findPosition(table, key);
	if (pos != notFound)
		removeAtPosition(table, pos);
}

struct HashtableIterator(T) {
	private const(T)* table;
	private size_t index;

	private this(const(T)* table, size_t startIndex) @nogc nothrow {
		this.table = table;
		index = startIndex;
		skipEmpty();
	}

	private void skipEmpty() @trusted @nogc nothrow {
		while (index < length(table) && !entryOccupied(table, index))
			index++;
	}

	bool empty() const @trusted @nogc nothrow { return index >= length(table); }
	const(T)* front() const @nogc nothrow { return table + index; }
	void popFront() @nogc nothrow { index++; skipEmpty(); }
}

HashtableIterator!T occupied(T)(const(T)* table) @trusted @nogc nothrow {
	return HashtableIterator!T(table, 0);
}

private void finalizeAll(T)(T* table) @trusted {
	if (headerOf(table).config.finalizeFunction is null) return;
	ubyte* tableP = cast(ubyte*) table;
	foreach (i; 0 .. length(table))
		if (entryOccupied(table, i))
			headerOf(table).config.finalizeFunction(tableP[i * T.sizeof .. (i + 1) * T.sizeof]);
}

void free(T)(ref T* table) @trusted {
	// `headerOf(null)` hands back the shared dummy header, so without this a
	// freed-twice (or never-created) table would free that instead. Matches
	// `fp.dynarray.free`/`fp.string.free`, both of which take null.
	if (table is null) return;
	finalizeAll(table);
	size_t* entries = headerOf(table).entryInfos;
	fp.dynarray.free(entries);
	allocFunction(headerOf(table), 0);
	table = null;
}

unittest {
	// headerOf(null) / valid / capacity on a never-created table, which is
	// also safe to free.
	int* neverCreated = null;
	assert(!valid_hashtable(neverCreated));
	assert(capacity(neverCreated) == 0);
	free(neverCreated);
	assert(neverCreated is null);
}

unittest {
	// growExact when the table already has enough capacity: the "grow" is a
	// no-op that just widens the logical size in place, never reallocating.
	int* table = create!int();
	scope(exit) free(table);

	assert(capacity(table) == 8);
	growExact(table, 4);
	assert(capacity(table) == 8);
}

unittest {
	// rehash() catching entryInfos up to a table whose data capacity was
	// grown without growing entryInfos in lockstep (doubleSizeAndRehash
	// normally keeps them synced; here we desync them on purpose).
	int* table = create!int();
	scope(exit) free(table);

	growExact(table, 20);
	assert(rehash(table, 0) == notFound);
}

unittest {
	// rehash()'s own out-of-memory report: catching entryInfos up to the
	// (already desynced) table capacity needs an allocation, and a refused
	// one is reported as 0, not mistaken for `notFound`.
	int* table = create!int();
	scope(exit) free(table);

	growExact(table, 20);
	auto previous = beginRationedAllocator();
	assert(rehash(table, 0) == 0);
	endRationedAllocator(previous);

	// Nothing was left half-caught-up: retrying with memory available
	// still succeeds.
	assert(rehash(table, 0) == notFound);
}

unittest {
	// create()'s own cleanup path: growing entryInfos to match baseSize is
	// a second allocation after the table's own, and if it's refused, the
	// table just allocated is freed rather than leaked, and null reported.
	auto previous = beginRationedAllocator(1); // the table's own alloc succeeds, entryInfos' doesn't
	int* table = create!int();
	endRationedAllocator(previous);

	assert(table is null);
}

unittest {
	// Filling a table completely (default baseSize == neighborhoodSize, so
	// the neighborhood covers every slot) and then inserting one more forces
	// findEmptyHashPosition to fail and insertImpl to grow-and-retry.
	int* table = create!int();
	scope(exit) free(table);

	foreach (i; 0 .. 8)
		cast(void) insert(table, i);
	assert(capacity(table) == 8);

	int* v = insert(table, 100);
	assert(*v == 100);
	assert(capacity(table) > 8);
	foreach (i; 0 .. 8)
		assert(*find(table, i) == i);
}

private __gshared int finalizeCallCount = 0;
private void countingFinalize(inout(ubyte)[] data) @nogc nothrow {
	finalizeCallCount++;
}

unittest {
	// finalizeAll: free() invokes config.finalizeFunction on every occupied entry
	// (a no-op when finalizeFunction is null, as in every other test in this file).
	Config cfg;
	cfg.finalizeFunction = &countingFinalize;
	int* table = create!int(cfg);

	foreach (i; 0 .. 3)
		cast(void) insert(table, i);

	finalizeCallCount = 0;
	free(table);
	assert(finalizeCallCount == 3);
}

unittest {
	// removeAtPosition: remove() finalizes exactly the entry it retires, and
	// finalizes nothing at all when the key isn't in the table.
	Config cfg;
	cfg.finalizeFunction = &countingFinalize;
	int* table = create!int(cfg);
	scope(exit) free(table);

	foreach (i; 0 .. 3)
		cast(void) insert(table, i);

	finalizeCallCount = 0;
	assert(contains(table, 1));
	remove(table, 1);
	assert(finalizeCallCount == 1);
	assert(!contains(table, 1));

	remove(table, 99);
	assert(finalizeCallCount == 1);
	assert(contains(table, 0) && contains(table, 2));
}

private size_t parityHash(inout(ubyte)[] data) @trusted {
	int v = *cast(const int*) data.ptr;
	return v & 1;
}

unittest {
	// Forces genuine, unrecoverable insertImpl/rehash failure: a hash
	// function whose buckets don't scale with table size (odd/even, rather
	// than spread across the full range) combined with a minimal retry
	// budget means growing the table never actually relieves the collision
	// between the two buckets' overlapping neighborhoods. This exercises
	// insertImpl's both `return null` branches (exhausted retries; a nested
	// doubleSizeAndRehash itself failing) and rehash's own failure return.
	//
	// Note: on this kind of catastrophic, unrecoverable failure some
	// earlier-inserted keys can end up lost even though later ones report
	// the failure correctly (insert() returns null) -- a pre-existing
	// limitation of the "give up partway through a rehash" design, not
	// something this test asserts around.
	Config cfg;
	cfg.hashFunction = &parityHash;
	cfg.baseSize = 8;
	cfg.neighborhoodSize = 4;
	cfg.maxFailRetries = 1;
	int* table = create!int(cfg);
	scope(exit) free(table);

	foreach (k; [0, 2, 4, 6, 1])
		assert(insert(table, k) !is null);
	assert(insert(table, 3) is null); // exhausts maxFailRetries: insertImpl's first `return null`
	assert(insert(table, 5) !is null); // succeeds after growing further
	assert(insert(table, 7) is null); // rehash itself fails mid-grow: the other two `return null`/`return positions[idx]` paths
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

unittest {
	// occupied(): iterates every occupied slot and skips holes left by remove().
	int* table = create!int();
	scope(exit) free(table);

	foreach (i; 0 .. 5)
		cast(void) insert(table, i);
	remove(table, 2);

	bool[5] seen;
	size_t count = 0;
	foreach (v; occupied(table)) {
		seen[*v] = true;
		count++;
	}

	assert(count == 4);
	foreach (i; [0, 1, 3, 4])
		assert(seen[i]);
	assert(!seen[2]);
}

unittest {
	// occupied() on a freshly created (empty) table yields nothing -- asserted
	// through the range's own `empty` rather than a foreach, whose body would
	// by definition never run and so would sit here permanently uncovered.
	int* table = create!int();
	scope(exit) free(table);

	assert(occupied(table).empty);
}

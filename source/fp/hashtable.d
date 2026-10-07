/// A hopscotch-hashing, open-addressing hash set on top of `fp.dynarray`. A table is a plain `T*` to its slots, so it indexes like any fat pointer; every key sits within `Config.neighborhoodSize` slots of the slot its hash selects.
///
/// Keys are compared and hashed by their bytes unless `Config` says otherwise. A null `T*` is not a table: make one with `create`.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(insert(table, 42) !is null);
/// assert(contains(table, 42));
/// assert(!contains(table, 7));
/// ---
module fp.hashtable;

import core.stdc.string;
static import core.checkedint;

static import fp.pointer;
static import fp.dynarray;
static import fp.fnv1a;
public import fp.pointer : notFound;


@nogc nothrow:


/// Hashes a key's bytes.
alias HashFunction = size_t function(inout(ubyte)[]);
/// Whether two keys' bytes denote the same key.
alias EqualFunction = bool function(inout(ubyte)[], inout(ubyte)[]);
/// Copies `n` bytes of a key into its slot, like `memcpy`. Called once per insert; growing the table moves keys without it.
alias CopyFunction = void* function(void*, inout(void)*, size_t);
/// Releases whatever a key owns, when it leaves the table.
alias FinalizeFunction = void function(inout(ubyte)[]);

private size_t defaultHash(inout(ubyte)[] data) {
	return fp.fnv1a.hash(data);
}

private bool defaultEqual(inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
	if (a.length != b.length) return false;
	return core.stdc.string.memcmp(a.ptr, b.ptr, a.length) == 0;
}

private void* defaultCopy(void* dest, inout(void)* src, size_t n) @trusted {
	return core.stdc.string.memcpy(dest, src, n);
}

/// How a table hashes, compares, copies and finalizes its keys, and how it is sized. The defaults treat keys as plain bytes.
///
/// Examples:
/// ---
/// Config config;
/// config.baseSize = 16;
/// int* table = create!int(config);
/// scope(exit) free(table);
/// assert(capacity(table) == 16);
/// ---
struct Config {
	HashFunction hashFunction = &defaultHash; /// FNV-1a by default.
	EqualFunction equalFunction = &defaultEqual; /// `memcmp` by default.
	CopyFunction copyFunction = &defaultCopy; /// `memcpy` by default.
	FinalizeFunction finalizeFunction = null; /// Called on each key removed or freed with the table; null for none.
	size_t baseSize = 8; /// The number of slots `create` allocates.
	size_t neighborhoodSize = 8; /// How far past its home slot a key may sit: from 1 to `maxNeighborhoodSize`.
	size_t maxFailRetries = 8; /// How many times one insert may grow the table before giving up.
}


/// A hash table's header, in front of the dynarray header its slots have, after the padding that aligns the slots. `entryInfos` holds one word per slot: bit `i` set means slot `home + i` holds a key whose hash selects this slot, and `occupiedBit` means this slot itself holds a key.
package struct Header {
	private ubyte[fp.pointer.headerPadding!((size_t*).sizeof + Config.sizeof + fp.dynarray.Header.sizeof)] padding;
	size_t* entryInfos; /// A dynarray parallel to the slots.
	Config config; /// The configuration the table was created with.
	fp.dynarray.Header base; /// The slots' dynarray header.
}

/// The largest `Config.neighborhoodSize`: each slot's `entryInfos` word needs one bit per neighborhood offset, below `occupiedBit`.
enum size_t maxNeighborhoodSize = 31;

private enum size_t occupiedBit = size_t(1) << maxNeighborhoodSize;

/// The header in front of table `p`. For null it returns a zeroed shared dummy, so queries on a null table read as empty rather than faulting.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(headerOf(table).config.baseSize == 8);
/// assert(headerOf(null).entryInfos is null);
/// ---
package Header* headerOf(inout void* p) {
	return fp.pointer.containerHeaderOf!Header(p);
}


private size_t* entryInfoPtr(inout void* table, size_t index) @trusted {
	assert(index < fp.pointer.length(headerOf(table).entryInfos));
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
	return headerOf(table).config.hashFunction(key) % fp.pointer.length(table);
}

private bool keysEqual(inout void* table, inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
	return headerOf(table).config.equalFunction(a, b);
}

private void copyInto(inout void* table, void* dest, inout void* src, size_t n) @trusted {
	headerOf(table).config.copyFunction(dest, src, n);
}

private size_t findEmptyHashPosition(inout void* table, size_t hash) @trusted {
	immutable neighborhoodSize = headerOf(table).config.neighborhoodSize;
	immutable size = fp.pointer.length(table);
	foreach (i; 0 .. neighborhoodSize) {
		immutable probe = (hash + i) % size;
		if (!entryOccupied(table, probe))
			return probe;
	}
	return fp.pointer.notFound;
}

private size_t hashDistance(inout void* table, size_t hash, size_t position) @trusted {
	immutable size = fp.pointer.length(table);
	return position < hash ? size - hash + position : position - hash;
}


/// Whether `p` is a hash table (as opposed to null or another kind of fat pointer).
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(validHashtable(table));
/// assert(!validHashtable(null));
/// ---
bool validHashtable(inout void* p) @trusted {
	return headerOf(p).base.base.type == fp.pointer.PointerType.hashTable;
}

/// Ditto
alias valid = validHashtable;

/// The number of slots in table `p`, occupied or not.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(capacity(table) == 8);
/// ---
size_t capacity(inout void* p) @trusted {
	if (!validHashtable(p)) return 0;
	return headerOf(p).base.capacity;
}


/// Creates an empty table with `config.baseSize` slots, or returns null if the allocator refused or the slots' byte count would overflow.
///
/// Examples:
/// ---
/// long* table = create!long();
/// scope(exit) free(table);
/// assert(table !is null && capacity(table) == 8);
/// ---
T* create(T)(Config config = Config.init) @trusted {
	mixin fp.pointer.requireAlignable!T;
	assert(config.baseSize > 0);
	assert(config.neighborhoodSize > 0 && config.neighborhoodSize <= maxNeighborhoodSize);
	bool overflow = false;
	immutable slotBytes = core.checkedint.mulu(T.sizeof, config.baseSize, overflow);
	if (overflow) return null;
	T* outp = cast(T*) fp.pointer.allocContainer!Header(slotBytes, fp.pointer.PointerType.hashTable);
	if (outp is null) return null;
	Header* h = headerOf(outp);
	h.base.capacity = config.baseSize;
	h.base.base.size = config.baseSize;
	h.config = config;
	h.entryInfos = fp.dynarray.create!size_t(config.baseSize);
	if (h.entryInfos is null) {
		cast(void)fp.pointer.allocFunction(h, 0);
		return null;
	}
	core.stdc.string.memset(h.entryInfos, 0, size_t.sizeof * config.baseSize);
	return outp;
}

private void finalizeAll(T)(T* table) @trusted {
	if (headerOf(table).config.finalizeFunction is null) return;
	ubyte* tableP = cast(ubyte*) table;
	foreach (i; 0 .. fp.pointer.length(table))
		if (entryOccupied(table, i))
			headerOf(table).config.finalizeFunction(tableP[i * T.sizeof .. (i + 1) * T.sizeof]);
}

// Frees `table` without finalizing its keys, for when they have been copied elsewhere.
private void release(T)(T* table) @trusted {
	fp.dynarray.free(headerOf(table).entryInfos);
	cast(void)fp.pointer.allocFunction(headerOf(table), 0);
}

/// Finalizes every key (if the table has a `finalizeFunction`), frees the table and sets `table` to null. Freeing null is a no-op.
///
/// Examples:
/// ---
/// int* table = create!int();
/// free(table);
/// assert(table is null);
/// free(table);
/// ---
void free(T)(ref T* table) {
	// `headerOf(null)` is the shared dummy, so without this check a null table would free it.
	if (table is null) return;
	finalizeAll(table);
	release(table);
	table = null;
}


// `moving` places a key already owned by a table being rebuilt, so its bytes move rather than going through `copyFunction`.
private void* insertImpl(T)(ref T* table, inout(ubyte)[] key, size_t failures, bool moving) @trusted {
	assert(validHashtable(table), "fp.hashtable: not a table; make one with create");
	immutable hash = computeHash(table, key);
	immutable position = findEmptyHashPosition(table, hash);

	if (position == fp.pointer.notFound) {
		if (failures >= headerOf(table).config.maxFailRetries)
			return null;
		if (rebuild(table, 2 * fp.pointer.length(table), failures + 1) != fp.pointer.notFound)
			return null;
		return insertImpl(table, key, failures + 1, moving);
	}

	ubyte* tableP = cast(ubyte*) table;
	if (moving) core.stdc.string.memcpy(tableP + key.length * position, key.ptr, key.length);
	else copyInto(table, tableP + key.length * position, key.ptr, key.length);
	*entryInfoPtr(table, hash) |= (size_t(1) << hashDistance(table, hash, position));
	setEntryOccupied(table, position, true);
	return tableP + key.length * position;
}

// Moves every key into a fresh table of `newSize` slots, which replaces `table` only once all are placed. Returns what `rehash` does.
private size_t rebuild(T)(ref T* table, size_t newSize, size_t failures) @trusted {
	Config config = headerOf(table).config;
	config.baseSize = newSize;
	T* fresh = create!T(config);
	if (fresh is null) return fp.pointer.allocationRefused;

	ubyte* tableP = cast(ubyte*) table;
	foreach (i; 0 .. fp.pointer.length(table)) {
		if (entryOccupied(table, i) && insertImpl(fresh, tableP[i * T.sizeof .. (i + 1) * T.sizeof], failures, true) is null) {
			release(fresh);
			return i;
		}
	}
	release(table);
	table = fresh;
	return fp.pointer.notFound;
}

/// Rebuilds the table by moving every key into a fresh one of the same size, which may grow if a key cannot be placed; `failures` counts the growths already spent against `Config.maxFailRetries`. Returns `fp.pointer.notFound` on success. On failure it leaves the table as it was, returning `fp.pointer.allocationRefused` if the fresh table could not be allocated, or else the slot of a key that could not be placed.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(insert(table, 1) !is null);
/// assert(rehash(table, 0) == fp.pointer.notFound);
/// assert(contains(table, 1));
/// ---
size_t rehash(T)(ref T* table, size_t failures) {
	return rebuild(table, fp.pointer.length(table), failures);
}


/// Inserts `key` without checking whether it is already present, so a duplicate is stored twice. Returns a pointer to the stored key, or null if the table could not make room, in which case it holds the same keys as before, though it may have grown.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(*insertAssumeUnique(table, 3) == 3);
/// assert(contains(table, 3));
/// ---
T* insertAssumeUnique(T)(ref T* table, T key) @trusted {
	ubyte* keyBytes = cast(ubyte*) &key;
	return cast(T*) insertImpl(table, keyBytes[0 .. T.sizeof], 0, false);
}

/// Finds `key`, inserting it if it is not already present. Returns a pointer to the stored key, or null if the table could not make room, in which case it holds the same keys as before, though it may have grown.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// int* first = insert(table, 5);
/// assert(*first == 5);
/// assert(insert(table, 5) is first);
/// ---
T* insert(T)(ref T* table, T key) {
	T* existing = find(table, key);
	return existing !is null ? existing : insertAssumeUnique(table, key);
}


pragma(inline, true)
private size_t findPositionBytes(inout void* table, inout(ubyte)[] key) @trusted {
	// A null table has no slots, so `computeHash` would divide by zero.
	if (fp.pointer.length(table) == 0) return fp.pointer.notFound;
	immutable hash = computeHash(table, key);
	immutable hashInfo = *entryInfoPtr(table, hash);
	immutable neighborhoodSize = headerOf(table).config.neighborhoodSize;
	ubyte* tableP = cast(ubyte*) table;

	foreach (i; 0 .. neighborhoodSize) {
		if ((hashInfo & (size_t(1) << i)) == 0) continue;
		immutable probe = (hash + i) % fp.pointer.length(table);
		if (!entryOccupied(table, probe)) continue;
		if (keysEqual(table, key, tableP[probe * key.length .. probe * key.length + key.length]))
			return probe;
	}
	return fp.pointer.notFound;
}

/// The slot index holding `key`, or `fp.pointer.notFound`.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// int* stored = insert(table, 1);
/// assert(table + findPosition(table, 1) is stored);
/// assert(findPosition(table, 2) == fp.pointer.notFound);
/// ---
size_t findPosition(T)(inout T* table, T key) @trusted {
	ubyte* keyBytes = cast(ubyte*) &key;
	return findPositionBytes(table, keyBytes[0 .. T.sizeof]);
}

/// A pointer to the stored copy of `key`, or null if it is absent. Changing the key through it so that it hashes differently corrupts the table.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(insert(table, 1) !is null);
/// assert(*find(table, 1) == 1);
/// assert(find(table, 2) is null);
/// ---
T* find(T)(T* table, T key) {
	immutable pos = findPosition(table, key);
	return pos == fp.pointer.notFound ? null : table + pos;
}

/// Whether `key` is in the table.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(!contains(table, 1));
/// assert(insert(table, 1) !is null);
/// assert(contains(table, 1));
/// ---
bool contains(T)(inout T* table, T key) {
	return findPosition(table, key) != fp.pointer.notFound;
}


/// Finalizes and removes the key in slot `position`, which must be occupied, and clears its bit in its home slot's neighborhood.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(insert(table, 1) !is null);
/// removeAtPosition(table, findPosition(table, 1));
/// assert(!contains(table, 1));
/// ---
void removeAtPosition(T)(T* table, size_t position) @trusted {
	assert(entryOccupied(table, position));
	ubyte* tableP = cast(ubyte*) table;
	ubyte[] key = tableP[position * T.sizeof .. (position + 1) * T.sizeof];
	// Hashed before finalizing, which may release what the hash function reads.
	immutable hash = computeHash(table, key);
	if (headerOf(table).config.finalizeFunction !is null)
		headerOf(table).config.finalizeFunction(key);
	*entryInfoPtr(table, hash) &= ~(size_t(1) << hashDistance(table, hash, position));
	setEntryOccupied(table, position, false);
}

/// Removes `key`, finalizing it, if it is present.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(insert(table, 1) !is null);
/// remove(table, 1);
/// assert(!contains(table, 1));
/// remove(table, 1); // absent: a no-op
/// ---
void remove(T)(T* table, T key) {
	immutable pos = findPosition(table, key);
	if (pos != fp.pointer.notFound)
		removeAtPosition(table, pos);
}


/// An input range over the occupied slots of a table, from `occupied`. It yields a pointer to each key, in slot order.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(insert(table, 1) !is null);
/// HashtableIterator!int keys = occupied(table);
/// assert(!keys.empty && *keys.front == 1);
/// ---
struct HashtableIterator(T) {
	private const(T)* table;
	private size_t index;

	/// Whether every occupied slot has been visited, the current key, and moving to the next one: the input range primitives.
	///
	/// Examples:
	/// ---
	/// int* table = create!int();
	/// scope(exit) free(table);
	/// assert(insert(table, 1) !is null);
	/// auto keys = occupied(table);
	/// assert(*keys.front == 1);
	/// keys.popFront();
	/// assert(keys.empty);
	/// ---
	bool empty() const @trusted { return index >= fp.pointer.length(table); }
	/// Ditto
	const(T)* front() const { return table + index; }
	/// Ditto
	void popFront() @trusted {
		do ++index;
		while (!empty && !entryOccupied(table, index));
	}
}

/// Iterates the keys in `table`.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// foreach (i; 0 .. 3)
/// 	assert(insert(table, i) !is null);
/// int sum = 0;
/// foreach (key; occupied(table))
/// 	sum += *key;
/// assert(sum == 3);
/// ---
HashtableIterator!T occupied(T)(const(T)* table) {
	HashtableIterator!T keys;
	keys.table = table;
	if (!keys.empty && !entryOccupied(table, 0)) keys.popFront();
	return keys;
}


version(unittest) {
	private __gshared int finalizeCallCount = 0;
	private void countingFinalize(inout(ubyte)[] data) {
		finalizeCallCount++;
	}

	private size_t identityHash(inout(ubyte)[] data) @trusted {
		return *cast(const int*) data.ptr;
	}

	private size_t parityHash(inout(ubyte)[] data) {
		return identityHash(data) & 1;
	}
}


unittest {
	int* neverCreated = null;
	assert(!validHashtable(neverCreated));
	assert(capacity(neverCreated) == 0);
	assert(!contains(neverCreated, 1) && find(neverCreated, 1) is null);
	remove(neverCreated, 1);
	free(neverCreated);
	assert(neverCreated is null);

	int* table = create!int();
	scope(exit) assert(table is null); // Scope exits run in reverse order!
	scope(exit) free(table);
	assert(table !is null);
	assert(validHashtable(table));

	int* v = insertAssumeUnique(table, 5);
	assert(*v == 5);
	immutable p = findPosition(table, 5);
	assert(p == 6 && table[p] == 5);
	assert(find(table, 5) is v);
	assert(insert(table, 5) is v);

	int* six = insert(table, 6);
	assert(six !is v && *six == 6);

	assert(rebuild(table, 2 * capacity(table), 0) == fp.pointer.notFound);
	assert(capacity(table) == 16);
	assert(*find(table, 5) == 5 && *find(table, 6) == 6);
	assert(find(table, 7) is null);

	remove(table, 5);
	assert(find(table, 5) is null);

	// Removing clears the key's neighborhood bit, so lookups in its home slot stop probing the empty slot.
	Config cfg;
	cfg.hashFunction = &identityHash;
	int* homes = create!int(cfg);
	assert(homes !is null);
	scope(exit) free(homes);
	assert(insert(homes, 3) !is null && insert(homes, 11) !is null && insert(homes, 4) !is null);
	assert(*entryInfoPtr(homes, 3) == (occupiedBit | 0b11));
	remove(homes, 11);
	assert(*entryInfoPtr(homes, 3) == (occupiedBit | 0b1));
	assert(*entryInfoPtr(homes, 4) == 0b10 && entryOccupied(homes, 5)); // 4 sits in slot 5, one past its home
	remove(homes, 4);
	assert(*entryInfoPtr(homes, 4) == 0 && !entryOccupied(homes, 5));
	remove(homes, 3);
	foreach (i; 0 .. capacity(homes))
		assert(*entryInfoPtr(homes, i) == 0);

	static struct Wide { align(fp.pointer.maxAlignment) int key; }
	Wide* wides = create!Wide();
	assert(wides !is null);
	scope(exit) free(wides);
	assert(cast(size_t) wides % Wide.alignof == 0 && insert(wides, Wide(1)) !is null);
}

unittest {
	// With the default config the neighborhood spans the whole table, so a ninth key must grow it.
	int* table = create!int();
	assert(table !is null);
	scope(exit) free(table);
	foreach (i; 0 .. 8)
		assert(insert(table, i) !is null);
	assert(capacity(table) == 8);

	auto previous = fp.dynarray.beginRationedAllocator();
	assert(insert(table, 100) is null);
	assert(rehash(table, 0) == fp.pointer.allocationRefused);
	fp.dynarray.endRationedAllocator(previous);
	assert(capacity(table) == 8 && !contains(table, 100));
	foreach (i; 0 .. 8)
		assert(contains(table, i));

	assert(rehash(table, 0) == fp.pointer.notFound);
	foreach (i; 0 .. 8)
		assert(contains(table, i));

	assert(*insert(table, 100) == 100);
	assert(capacity(table) > 8);
	foreach (i; 0 .. 8)
		assert(*find(table, i) == i);

	// The slots' allocation succeeds and `entryInfos`' is refused: the slots must be freed, not leaked.
	previous = fp.dynarray.beginRationedAllocator(1);
	assert(create!int() is null);
	fp.dynarray.endRationedAllocator(previous);

	// A slot count whose byte count wraps is refused before the allocator sees a wrapped, too-small request.
	static size_t requests;
	static fp.pointer.AllocFunction underlying;
	static void* counting(void* p, size_t size) @nogc nothrow {
		if (size > 0) ++requests;
		return underlying(p, size);
	}
	requests = 0;
	underlying = fp.pointer.allocFunction;
	fp.pointer.allocFunction = &counting;
	scope(exit) fp.pointer.allocFunction = underlying;
	Config huge;
	huge.baseSize = size_t.max / 4 + 2; // 4 bytes past the top
	assert(create!int(huge) is null);
	assert(requests == 0);
	int* counted = create!int(); // the slots and `entryInfos`, so the counter is live
	scope(exit) free(counted);
	assert(counted !is null && requests == 2);
}

unittest {
	// 15 wrapped into slot 0 from home 7, so slot-order reinsertion places it at 7 first, and 7 then has no room or retries left.
	Config cfg;
	cfg.hashFunction = &identityHash;
	cfg.neighborhoodSize = 2;
	cfg.maxFailRetries = 0;
	int* wrapped = create!int(cfg);
	assert(wrapped !is null);
	scope(exit) free(wrapped);
	foreach (k; [7, 15, 0])
		assert(insert(wrapped, k) !is null);

	assert(rehash(wrapped, 0) == 7);
	assert(capacity(wrapped) == 8);
	foreach (k; [7, 15, 0])
		assert(contains(wrapped, k));

	// Only two home slots whatever the table size, so growing never relieves the collisions and inserts genuinely fail.
	cfg.hashFunction = &parityHash;
	cfg.neighborhoodSize = 4;
	cfg.maxFailRetries = 1;
	int* crowded = create!int(cfg);
	assert(crowded !is null);
	scope(exit) free(crowded);

	foreach (k; [0, 2, 4, 6, 1])
		assert(insert(crowded, k) !is null);
	assert(insert(crowded, 3) is null);
	foreach (k; [0, 2, 4, 6, 1])
		assert(contains(crowded, k));
}

unittest {
	Config cfg;
	cfg.finalizeFunction = &countingFinalize;
	int* table = create!int(cfg);
	assert(table !is null);
	assert(occupied(table).empty);

	foreach (i; 0 .. 5)
		assert(insert(table, i) !is null);

	finalizeCallCount = 0;
	remove(table, 2);
	assert(finalizeCallCount == 1);
	assert(!contains(table, 2));
	remove(table, 99);
	assert(finalizeCallCount == 1);

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

	finalizeCallCount = 0;
	free(table);
	assert(finalizeCallCount == 4);

	// Growing moves keys, so a deep-copying `copyFunction` runs once per insert and no key is copied without being finalized.
	static size_t copies;
	static void* countingCopy(void* dest, inout(void)* src, size_t n) @nogc nothrow {
		++copies;
		return core.stdc.string.memcpy(dest, src, n);
	}
	cfg.copyFunction = &countingCopy;
	copies = 0;
	finalizeCallCount = 0;
	int* grown = create!int(cfg);
	assert(grown !is null);
	foreach (i; 0 .. 9)
		assert(insert(grown, i) !is null);
	assert(capacity(grown) > 8 && copies == 9);
	free(grown);
	assert(finalizeCallCount == 9);
}

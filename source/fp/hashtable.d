/// A hopscotch-hashing, open-addressing hash set on top of `fp.dynarray`. A table is a plain `T*` to its slots, so it indexes like any fat pointer; every key sits within `Config.neighborhoodSize` slots of the slot its hash selects. An insert whose neighborhood is full moves other keys, each within its own neighborhood, to free a slot in it, and grows the table only when no such moves exist; so an insert may move keys, and a pointer into the table lasts only until the next insert.
///
/// Keys are compared and hashed by their bytes unless `Config` says otherwise. A key type that declares a lifetime (see `fp.lifecycle`) is moved into its slot and finalized when it is removed or the table freed, unless the config names other functions. Keys are passed by value: `insert` and `insertAssumeUnique` take over the copy they are given, moving it into the table or ending it when it is not stored, while `find`, `contains` and `remove` leave the caller's key alone and end only the copy they make to read it. An owning key type should end its lifetime with `finalize` rather than `~this`, since a `~this` would run on the copy every call makes. A key type whose `this(this)` postblit changes its bytes, as a deep copy does, cannot be looked up by value, since the copy every call makes is no longer byte-equal to the stored key; such a type needs a `Config` with a `hashFunction` and `equalFunction` that read its contents. A null `T*` is not a table: make one with `create`.
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

static import fp.lifecycle;
static import fp.pointer;
static import fp.dynarray;
static import fp.fnv1a;
public import fp.pointer : notFound;
public import fp.lifecycle : FinalizeFunction;


@nogc nothrow:


/// Hashes a key's bytes.
alias HashFunction = size_t function(inout(ubyte)[]);
/// Whether two keys' bytes denote the same key.
alias EqualFunction = bool function(inout(ubyte)[], inout(ubyte)[]);
/// Puts a key into its slot. Called once per insert; growing the table moves keys without it. It must leave the slot holding the bytes it was given, since the table hashes those bytes before placing them, and for a key type with a lifetime it must take that lifetime over: `insert` ends the call's copy only when the insert fails.
alias CopyFunction = void* function(void*, inout(void)*, size_t);

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

// For a key type with a lifetime, `create!T` uses this instead of `defaultCopy`: a move, so the call's temporary does not also release the key.
private void* moveSlot(T)(void* dest, inout(void)* src, size_t n) @trusted {
	fp.lifecycle.moveInto(*cast(T*) dest, *cast(T*) src);
	return dest;
}


// Struct keys can hold garbage in the bytes between their fields, so two keys with the same fields may hash differently. `tupleof` lists fields only, never methods, accessors, aliases or imports.
private void normalizePadding(T)(ref T key) @trusted {
	static if (is(T == struct)) {
		ubyte* raw = cast(ubyte*)&key;
		ubyte[T.sizeof] field;
		static foreach (i; 0 .. T.tupleof.length)
			field[T.tupleof[i].offsetof .. T.tupleof[i].offsetof + typeof(T.tupleof[i]).sizeof] = 1;
		for (size_t i = 0; i < T.sizeof; ++i)
			if (!field[i]) raw[i] = 0;
		static foreach (i; 0 .. T.tupleof.length) {{
			alias Member = typeof(T.tupleof[i]);
			static if (is(Member == struct))
				normalizePadding(key.tupleof[i]);
			else static if (__traits(isStaticArray, Member))
				foreach (ref element; key.tupleof[i])
					normalizePadding(element);
		}}
	}
}

/// How a table hashes, compares, copies and finalizes its keys, and how it is sized. The defaults treat keys as plain bytes; struct keys have the padding between their fields zeroed first, so two keys with the same fields match however their padding was left.
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
	CopyFunction copyFunction = &defaultCopy; /// `memcpy` by default; `create!T` replaces it with a move for a key type that declares a lifetime.
	FinalizeFunction finalizeFunction = null; /// Called on each key removed or freed with the table; null for none. `create!T` sets it for key types that declare a lifetime.
	size_t baseSize = 8; /// The number of slots `create` allocates, which must be greater than zero.
	size_t neighborhoodSize = maxNeighborhoodSize; /// How far past its home slot a key may sit: from 1 to `maxNeighborhoodSize`. The widest lets a table fill to about 90% before it grows; 8 grows it at about half.
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

private size_t hashDistance(inout void* table, size_t hash, size_t position) @trusted {
	immutable size = fp.pointer.length(table);
	return position < hash ? size - hash + position : position - hash;
}

// How far past its home an insert looks for a free slot to hop back into its neighborhood; beyond it the table grows.
private enum size_t maxProbe = 1024;

// A free slot in `hash`'s neighborhood, or `fp.pointer.notFound`. When the nearest free slot is beyond it, keys of `keySize` bytes nearer their own homes hop into it, moving it back, as hopscotch hashing does.
private size_t findEmptyHashPosition(void* table, size_t hash, size_t keySize) @trusted {
	immutable neighborhoodSize = headerOf(table).config.neighborhoodSize;
	immutable size = fp.pointer.length(table);
	immutable reach = neighborhoodSize < size ? neighborhoodSize : size;
	foreach (i; 0 .. reach) {
		immutable probe = (hash + i) % size;
		if (!entryOccupied(table, probe))
			return probe;
	}
	if (neighborhoodSize >= size) return fp.pointer.notFound;

	size_t free = fp.pointer.notFound;
	foreach (i; reach .. (size < maxProbe ? size : maxProbe)) {
		immutable probe = (hash + i) % size;
		if (entryOccupied(table, probe)) continue;
		free = probe;
		break;
	}
	if (free == fp.pointer.notFound) return fp.pointer.notFound;
	ubyte* tableP = cast(ubyte*) table;
	while (hashDistance(table, hash, free) >= neighborhoodSize) {
		// The farthest-back home within reach of `free` with a key before it: moving that key frees the earliest slot.
		size_t from = fp.pointer.notFound;
		foreach_reverse (back; 1 .. neighborhoodSize) {
			immutable home = (free + size - back) % size;
			immutable info = *entryInfoPtr(table, home);
			foreach (i; 0 .. back) {
				if ((info & (size_t(1) << i)) == 0) continue;
				from = (home + i) % size;
				core.stdc.string.memcpy(tableP + free * keySize, tableP + from * keySize, keySize);
				*entryInfoPtr(table, home) = (info & ~(size_t(1) << i)) | (size_t(1) << back);
				setEntryOccupied(table, free, true);
				setEntryOccupied(table, from, false);
				break;
			}
			if (from != fp.pointer.notFound) break;
		}
		if (from == fp.pointer.notFound) return fp.pointer.notFound;
		free = from;
	}
	return free;
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
	// The tag check reads only the shared 16-byte header: this module's is larger and would overrun a fat pointer that is not a table.
	return fp.pointer.valid(p) && fp.pointer.headerOf(p).type == fp.pointer.PointerType.hashTable;
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


/// Creates an empty table with `config.baseSize` slots, or returns null if the allocator refused or the slots' byte count would overflow. A key type with a lifetime gets `copyFunction` and `finalizeFunction` for it, unless the config already names them.
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
	if (config.copyFunction is &defaultCopy && !fp.lifecycle.isBitMoveable!T) config.copyFunction = &moveSlot!T;
	if (config.finalizeFunction is null) config.finalizeFunction = fp.lifecycle.finalizeFunction!T();
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
	fp.lifecycle.initSlots(outp, config.baseSize);
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

/// Finalizes every key (if the table has a `finalizeFunction`), frees the table and sets `table` to null. Freeing null, or a pointer that is not a table, is a no-op.
///
/// Examples:
/// ---
/// int* table = create!int();
/// free(table);
/// assert(table is null);
/// free(table);
/// ---
void free(T)(ref T* table) {
	// Neither null nor a non-table can be freed through `headerOf`: the shared dummy, or a header too small for this module's.
	if (!validHashtable(table)) return;
	finalizeAll(table);
	release(table);
	table = null;
}


// `place` says how the key enters its slot: `copyFunction` for a caller's key, `defaultCopy` for a rebuilt table's own key, `moveSlot!T` for a clone's copy.
private void* insertImpl(T)(ref T* table, inout(ubyte)[] key, size_t failures, CopyFunction place) @trusted {
	assert(validHashtable(table), "fp.hashtable: not a table; make one with create");
	immutable hash = computeHash(table, key);
	immutable position = findEmptyHashPosition(table, hash, key.length);

	if (position == fp.pointer.notFound) {
		if (failures >= headerOf(table).config.maxFailRetries)
			return null;
		if (rebuild(table, 2 * fp.pointer.length(table), failures + 1) != fp.pointer.notFound)
			return null;
		return insertImpl(table, key, failures + 1, place);
	}

	ubyte* tableP = cast(ubyte*) table;
	place(tableP + key.length * position, key.ptr, key.length);
	*entryInfoPtr(table, hash) |= (size_t(1) << hashDistance(table, hash, position));
	setEntryOccupied(table, position, true);
	return tableP + key.length * position;
}

/// A new table with the same config as `src` holding a copy of every key in it, or null if `src` is not a table or the allocator refused. Keys are copied through `fp.lifecycle.copyInto`, so a key type that owns something deep-copies it and `src` keeps its own.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(insert(table, 3) !is null);
/// int* copy = clone(table);
/// scope(exit) free(copy);
/// assert(copy !is table && contains(copy, 3));
/// ---
T* clone(T)(inout T* src) {
	if (!validHashtable(src)) return null;
	T* fresh = create!T(headerOf(src).config);
	if (fresh is null) return null;
	ubyte* srcP = cast(ubyte*) src;
	foreach (i; 0 .. fp.pointer.length(src)) {
		if (!entryOccupied(src, i)) continue;
		// The copy is hashed before it is placed, so a key whose copy differs in bytes still lands in the neighborhood its own hash selects.
		T copy;
		fp.lifecycle.copyInto(copy, *cast(T*)(srcP + i * T.sizeof));
		ubyte* key = cast(ubyte*)&copy;
		if (insertImpl(fresh, key[0 .. T.sizeof], 0, &moveSlot!T) is null) {
			fp.lifecycle.endCopiedLifetime(copy); // the copy was never placed, so the call must end it
			free(fresh);
			return null;
		}
	}
	return fresh;
}

// Moves every key into a fresh table of `newSize` slots, which replaces `table` only once all are placed. Returns what `rehash` does.
private size_t rebuild(T)(ref T* table, size_t newSize, size_t failures) @trusted {
	Config config = headerOf(table).config;
	config.baseSize = newSize;
	T* fresh = create!T(config);
	if (fresh is null) return fp.pointer.allocationRefused;

	ubyte* tableP = cast(ubyte*) table;
	foreach (i; 0 .. fp.pointer.length(table)) {
		if (entryOccupied(table, i) && insertImpl(fresh, tableP[i * T.sizeof .. (i + 1) * T.sizeof], failures, &defaultCopy) is null) {
			release(fresh);
			return i;
		}
	}
	release(table);
	table = fresh;
	return fp.pointer.notFound;
}

/// Rebuilds the table by moving every key into a fresh one of the same size, which may grow if a key cannot be placed; `failures` counts the growths already spent against `Config.maxFailRetries`. Returns `fp.pointer.notFound` on success. On failure it leaves the table as it was, returning `fp.pointer.allocationRefused` if the fresh table could not be allocated, or else the slot of a key that could not be placed. A null `table` is not a table, so it is left alone and reported as success.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(insert(table, 1) !is null);
/// assert(rehash(table, 0) == fp.pointer.notFound);
/// assert(contains(table, 1));
///
/// int* nothing = null;
/// assert(rehash(nothing, 0) == fp.pointer.notFound);
/// ---
size_t rehash(T)(ref T* table, size_t failures) {
	if (!validHashtable(table)) return fp.pointer.notFound;
	return rebuild(table, fp.pointer.length(table), failures);
}


// Places `key`, taking its lifetime over, without checking for a duplicate. By `ref` so `insert` can hand its own copy over without making another.
private T* insertUnique(T)(ref T* table, ref T key) @trusted {
	normalizePadding(key);
	ubyte* keyBytes = cast(ubyte*) &key;
	T* stored = cast(T*) insertImpl(table, keyBytes[0 .. T.sizeof], 0, headerOf(table).config.copyFunction);
	if (stored is null) fp.lifecycle.endLifetime(key);
	return stored;
}

/// Inserts `key` without checking whether it is already present, so a duplicate is stored twice. Returns a pointer to the stored key, valid until the next insert, or null if the table could not make room, in which case it holds the same keys as before, though it may have grown. Either way the call takes over `key`'s lifetime: the copy made for it is moved into the table, or ended when it is not stored.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(*insertAssumeUnique(table, 3) == 3);
/// assert(contains(table, 3));
/// ---
T* insertAssumeUnique(T)(ref T* table, T key) {
	return insertUnique(table, key);
}

// Finds `key`'s slot after clearing the copy's padding, without ending its lifetime: the lookup that made the copy does.
pragma(inline, true)
private size_t positionOf(T)(inout T* table, ref T key) @trusted {
	normalizePadding(key);
	ubyte[] bytes = (cast(ubyte*) &key)[0 .. T.sizeof];
	// Null has no slots, so `computeHash` would divide by zero; a non-table's header is too small for this module's size to read.
	if (!validHashtable(table)) return fp.pointer.notFound;
	immutable hash = computeHash(table, bytes);
	immutable hashInfo = *entryInfoPtr(table, hash);
	immutable config = headerOf(table).config;
	ubyte* tableP = cast(ubyte*) table;

	foreach (i; 0 .. config.neighborhoodSize) {
		if ((hashInfo & (size_t(1) << i)) == 0) continue;
		immutable probe = (hash + i) % fp.pointer.length(table);
		if (!entryOccupied(table, probe)) continue;
		if (config.equalFunction(bytes, tableP[probe * T.sizeof .. probe * T.sizeof + T.sizeof]))
			return probe;
	}
	return fp.pointer.notFound;
}

// Looks up the call's own copy of `key` and ends its lifetime, since a lookup never stores it.
private size_t findPositionOf(T)(inout T* table, ref T copy) @trusted {
	immutable pos = positionOf(table, copy);
	fp.lifecycle.endCopyLifetime(copy);
	return pos;
}

/// The slot index holding `key`, or `fp.pointer.notFound`. The call takes over the lifetime of the copy made for it, leaving it empty; the caller's own key is left alone.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// int* stored = insert(table, 1);
/// assert(table + findPosition(table, 1) is stored);
/// assert(findPosition(table, 2) == fp.pointer.notFound);
/// ---
size_t findPosition(T)(inout T* table, const(T) key) @trusted {
	return findPositionOf(table, *cast(T*)&key); // the call's own copy, so writing to it and ending it is safe
}

/// A pointer to the stored copy of `key`, valid until the next insert, or null if it is absent. Changing the key through it so that it hashes differently corrupts the table. The call takes over the lifetime of the copy made for it, leaving the caller's key alone.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(insert(table, 1) !is null);
/// assert(*find(table, 1) == 1);
/// assert(find(table, 2) is null);
/// ---
T* find(T)(T* table, const(T) key) @trusted {
	immutable pos = findPositionOf(table, *cast(T*)&key); // the call's own copy, so writing to it and ending it is safe
	return pos == fp.pointer.notFound ? null : table + pos;
}

/// Finds `key`, inserting it if it is not already present. Returns a pointer to the stored key, valid until the next insert, or null if the table could not make room, in which case it holds the same keys as before, though it may have grown. Either way the call takes over `key`'s lifetime: the copy made for it is moved into the table, or ended when it is already there or cannot be stored.
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
	immutable pos = positionOf(table, key); // the call's own copy, so reading it does not end anything the caller owns
	if (pos != fp.pointer.notFound) { fp.lifecycle.endLifetime(key); return table + pos; }
	return insertUnique(table, key);
}

/// Whether `key` is in the table. The call takes over the lifetime of the copy made for it, leaving the caller's key alone.
///
/// Examples:
/// ---
/// int* table = create!int();
/// scope(exit) free(table);
/// assert(!contains(table, 1));
/// assert(insert(table, 1) !is null);
/// assert(contains(table, 1));
/// ---
bool contains(T)(inout T* table, const(T) key) @trusted {
	return findPositionOf(table, *cast(T*)&key) != fp.pointer.notFound; // the call's own copy, so ending it is safe
}


/// Finalizes and removes the key in slot `position` of table `table`, which must be occupied, clears its bit in its home slot's neighborhood, and leaves the slot empty. A `table` that is not a table is left alone, since this module's header does not fit in front of it.
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
	if (!validHashtable(cast(void*) table)) return;
	assert(entryOccupied(table, position));
	ubyte* tableP = cast(ubyte*) table;
	ubyte[] key = tableP[position * T.sizeof .. (position + 1) * T.sizeof];
	// Hashed before finalizing, which may release what the hash function reads.
	immutable hash = computeHash(table, key);
	if (headerOf(table).config.finalizeFunction !is null)
		headerOf(table).config.finalizeFunction(key);
	fp.lifecycle.initSlots(cast(T*)(tableP + position * T.sizeof), 1);
	*entryInfoPtr(table, hash) &= ~(size_t(1) << hashDistance(table, hash, position));
	setEntryOccupied(table, position, false);
}

/// Removes the stored copy of `key`, finalizing it, if it is present. The call takes over the lifetime of the copy made for it, leaving the caller's own key alone.
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
void remove(T)(T* table, const(T) key) @trusted {
	immutable pos = findPositionOf(table, *cast(T*)&key); // the call's own copy, so writing to it and ending it is safe
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
		// `cast(void*)`: for a struct `T`, `const(T)*` is not implicitly convertible to the helpers' `inout void*`.
		do ++index;
		while (!empty && !entryOccupied(cast(void*) table, index));
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
	// A non-table has no slots to probe, so the range is empty rather than reading past a header too small for this module's.
	if (!validHashtable(cast(void*) table)) { keys.index = fp.pointer.length(cast(void*) table); return keys; }
	if (!keys.empty && !entryOccupied(cast(void*) table, 0)) keys.popFront();
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

	// `identityHash` until set, then sends every key home to slot 0.
	private __gshared bool collapseHashes;
	private size_t collapsibleHash(inout(ubyte)[] data) {
		return collapseHashes ? 0 : identityHash(data);
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

	// Another kind of fat pointer is not a table, and finding that out reads only the shared 16-byte header, not this module's larger one.
	int* dynarrayHandle = fp.dynarray.create!int(4);
	assert(dynarrayHandle !is null);
	assert(!validHashtable(dynarrayHandle) && capacity(dynarrayHandle) == 0);
	assert(find(dynarrayHandle, 1) is null && findPosition(dynarrayHandle, 1) == fp.pointer.notFound && !contains(dynarrayHandle, 1));
	remove(dynarrayHandle, 1);
	removeAtPosition(dynarrayHandle, 0); // a no-op, rather than a read past a header too small for this module's
	assert(occupied(dynarrayHandle).empty);
	free(dynarrayHandle); // not a table, so this module leaves it for its own `free`
	assert(dynarrayHandle !is null && fp.dynarray.valid(dynarrayHandle));
	fp.dynarray.free(dynarrayHandle);
	int* heapHandle = fp.pointer.malloc!int(4);
	assert(!validHashtable(heapHandle) && capacity(heapHandle) == 0);
	assert(find(heapHandle, 1) is null && !contains(heapHandle, 1));
	removeAtPosition(heapHandle, 0);
	free(heapHandle);
	assert(heapHandle !is null && fp.pointer.valid(heapHandle));
	fp.pointer.free(heapHandle);

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

	// Struct padding is garbage, so two keys with the same fields must still be the same key.
	static struct Padded { align(fp.pointer.maxAlignment) char pad; int key; }
	static struct Nested { int a; char c; Wide inner; }
	Padded* padded = create!Padded();
	assert(padded !is null);
	scope(exit) free(padded);
	Padded first = Padded(1, 2);
	core.stdc.string.memset(cast(ubyte*)&first, 0xAA, Padded.sizeof);
	first.pad = 1; first.key = 2;
	Padded second = Padded(1, 2);
	core.stdc.string.memset(cast(ubyte*)&second, 0xBB, Padded.sizeof);
	second.pad = 1; second.key = 2;
	Padded* stored = insert(padded, first);
	assert(stored !is null && insert(padded, second) is stored);
	assert(find(padded, second) is stored && contains(padded, second));
	remove(padded, second);
	assert(!contains(padded, first));

	Nested* nested = create!Nested();
	assert(nested !is null);
	scope(exit) free(nested);
	Nested outer;
	outer.a = 1; outer.c = 2; outer.inner.key = 3;
	core.stdc.string.memset(cast(ubyte*)&outer.inner, 0xDD, Wide.sizeof);
	outer.inner.key = 3;
	assert(insert(nested, outer) !is null && contains(nested, outer));
	Nested twin;
	twin.a = 1; twin.c = 2; twin.inner.key = 3;
	core.stdc.string.memset(cast(ubyte*)&twin.inner, 0xEE, Wide.sizeof);
	twin.inner.key = 3;
	assert(insert(nested, twin) is find(nested, outer)); // padding inside a nested key is normalized too

	static struct Pair { Padded[2] items; }
	Pair* pairs = create!Pair();
	assert(pairs !is null);
	scope(exit) free(pairs);
	Pair one, other;
	core.stdc.string.memset(cast(ubyte*)&one, 0xAA, Pair.sizeof);
	core.stdc.string.memset(cast(ubyte*)&other, 0xBB, Pair.sizeof);
	one.items[0].pad = 1; one.items[0].key = 2; one.items[1].pad = 3; one.items[1].key = 4;
	other.items[0].pad = 1; other.items[0].key = 2; other.items[1].pad = 3; other.items[1].key = 4;
	Pair* held = insert(pairs, one);
	assert(held !is null && insert(pairs, other) is held && find(pairs, other) is held);

	// A key whose members include a type alias, an import and a ref accessor still hashes by its fields alone.
	static struct Aliased {
		static import core.stdc.string;
		alias Slot = int;
		char pad;
		Slot key;
		@property ref inout(Slot) slot() inout return @nogc nothrow { return key; }
	}
	Aliased* aliased = create!Aliased();
	assert(aliased !is null);
	scope(exit) free(aliased);
	Aliased left, right;
	core.stdc.string.memset(cast(ubyte*)&left, 0xAA, Aliased.sizeof);
	core.stdc.string.memset(cast(ubyte*)&right, 0xBB, Aliased.sizeof);
	left.pad = right.pad = 1;
	left.slot = right.slot = 2;
	assert(insert(aliased, left) is find(aliased, right));
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

	// A null table is not a table, so rehashing it is a no-op rather than an assertion.
	int* nothing = null;
	assert(rehash(nothing, 0) == fp.pointer.notFound && nothing is null);

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
	static void* counting(void* p, size_t size) {
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
	// 15 wrapped into slot 0 from home 7, so slot-order reinsertion places it at 7 first; 7 then wraps to slot 0 only by hopping 0 on to slot 1.
	Config cfg;
	cfg.hashFunction = &identityHash;
	cfg.neighborhoodSize = 2;
	cfg.maxFailRetries = 0;
	int* wrapped = create!int(cfg);
	assert(wrapped !is null);
	scope(exit) free(wrapped);
	foreach (k; [7, 15, 0])
		assert(insert(wrapped, k) !is null);

	assert(rehash(wrapped, 0) == fp.pointer.notFound);
	assert(capacity(wrapped) == 8 && wrapped[0] == 7 && wrapped[1] == 0 && wrapped[7] == 15);
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

	// A key the fresh table cannot place fails the rehash with its slot, and the table keeps its keys where they were.
	cfg.hashFunction = &collapsibleHash;
	cfg.neighborhoodSize = 1;
	cfg.maxFailRetries = 0;
	int* homed = create!int(cfg);
	assert(homed !is null);
	scope(exit) free(homed);
	foreach (k; [0, 1, 2])
		assert(insert(homed, k) !is null);
	collapseHashes = true;
	immutable stuck = rehash(homed, 0);
	collapseHashes = false;
	assert(stuck == 1 && homed[0] == 0 && homed[1] == 1 && homed[2] == 2);
	foreach (k; [0, 1, 2])
		assert(contains(homed, k));
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
	static void* countingCopy(void* dest, inout(void)* src, size_t n) {
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

	// A key type with a lifetime needs no config: `create!T` installs the element hooks for it.
	static struct Key {
		int* data;
		void finalize() @nogc nothrow { if (data !is null) ++finalizeCallCount; data = null; }
		void moveTo(ref Key dest) @nogc nothrow { dest.data = data; data = null; }
	}
	static assert(!fp.lifecycle.isBitMoveable!Key);

	Key* owned = create!Key();
	assert(owned !is null);
	scope(exit) free(owned);
	finalizeCallCount = 0;
	assert(insert(owned, Key(cast(int*) 1)) !is null && insert(owned, Key(cast(int*) 2)) !is null);
	assert(contains(owned, Key(cast(int*) 2)));

	remove(owned, Key(cast(int*) 1));
	assert(finalizeCallCount == 1 && owned[findPosition(owned, Key(cast(int*) 2))].data == cast(int*) 2);
	free(owned);
	assert(finalizeCallCount == 2 && owned is null);

	// Struct key types reach the lookups as const values, as the iterator yields them.
	Key* keyed = create!Key();
	assert(keyed !is null);
	foreach (i; 0 .. 3)
		assert(insert(keyed, Key(cast(int*) (i + 1))) !is null);
	size_t iterated = 0;
	foreach (k; occupied(keyed)) {
		assert(k.data !is null);
		++iterated;
	}
	assert(iterated == 3);
	remove(keyed, *find(keyed, Key(cast(int*) 2)));
	assert(finalizeCallCount == 3);
	free(keyed);
	assert(finalizeCallCount == 5 && keyed is null);

	// A lookup copies the key once to clear its padding; the copy is not stored, so its lifetime ends with the call.
	static size_t copyCount;
	static struct CopiedKey {
		int* data;
		this(this) @nogc nothrow { ++copyCount; data = cast(int*) 1; }
		void finalize() @nogc nothrow { if (data !is null) ++finalizeCallCount; data = null; }
	}
	CopiedKey* copied = create!CopiedKey();
	assert(copied !is null);
	CopiedKey key = CopiedKey(cast(int*) 1);
	copyCount = 0;
	finalizeCallCount = 0;
	assert(insert(copied, key) !is null);
	assert(copyCount == 1 && finalizeCallCount == 0); // the call's copy was moved into the table, `key` left alone
	assert(contains(copied, key) && find(copied, key) !is null);
	assert(copyCount == 3 && finalizeCallCount == 2); // one copy per lookup, each ended
	remove(copied, key);
	assert(copyCount == 4 && finalizeCallCount == 4); // the copy that looked it up, and the stored key
	free(copied);
	assert(copyCount == finalizeCallCount && copied is null); // every copy made was ended, so none leaked

	// Cloning copies keys rather than moving them, so the source keeps every one of its own.
	static struct DeepKey {
		int id;
		int* data;
		void finalize() @nogc nothrow { if (data !is null) ++finalizeCallCount; data = null; }
		void copyTo(ref DeepKey dest) @nogc nothrow { dest.id = id + 10; dest.data = cast(int*) 1; }
	}
	Config cloning;
	cloning.hashFunction = &identityHash;
	cloning.neighborhoodSize = 2;
	DeepKey* source = create!DeepKey(cloning);
	assert(source !is null);
	assert(insert(source, DeepKey(1, cast(int*) 1)) !is null && insert(source, DeepKey(2, cast(int*) 2)) !is null);
	finalizeCallCount = 0;
	DeepKey* twin = clone(source);
	assert(twin !is null && twin !is source && finalizeCallCount == 0);
	// Each copy is hashed from its own bytes, so every key in the twin is findable by them.
	size_t twinKeys = 0;
	for (auto it = occupied(twin); !it.empty; it.popFront()) {
		++twinKeys;
		assert(contains(twin, *it.front));
	}
	assert(twinKeys == 2);
	free(twin);
	assert(finalizeCallCount == 2);
	free(source);
	assert(finalizeCallCount == 4 && source is null);

	// A clone that runs out of room frees the fresh table and ends the copy it was placing, rather than leaking it.
	static struct ClonedKey {
		int id;
		int* data;
		void finalize() @nogc nothrow { if (data !is null) ++finalizeCallCount; data = null; }
		// Every copy hashes home to slot 0, where a neighborhood of one slot holds only one of them.
		void copyTo(ref ClonedKey dest) @nogc nothrow { dest.id = 0; dest.data = cast(int*) 1; }
	}
	Config colliding;
	colliding.hashFunction = &identityHash;
	colliding.neighborhoodSize = 1;
	colliding.maxFailRetries = 0;
	ClonedKey* crowded = create!ClonedKey(colliding);
	assert(crowded !is null);
	foreach (id; [1, 2, 3])
		assert(insert(crowded, ClonedKey(id, cast(int*) 1)) !is null);
	finalizeCallCount = 0;
	assert(clone(crowded) is null);
	assert(finalizeCallCount == 2); // the copy the fresh table took, and the one it had no room for
	free(crowded);
	assert(finalizeCallCount == 5 && crowded is null);

	// A key the table does not keep — already there, or no room for it — has its lifetime ended by the call.
	finalizeCallCount = 0;
	Config tiny;
	tiny.baseSize = 1;
	Key* tight = create!Key(tiny);
	assert(tight !is null);
	assert(insert(tight, Key(cast(int*) 1)) !is null);
	assert(insert(tight, Key(cast(int*) 1)) !is null && finalizeCallCount == 1);
	auto rationed = fp.dynarray.beginRationedAllocator(0);
	assert(insert(tight, Key(cast(int*) 2)) is null && finalizeCallCount == 2);
	fp.dynarray.endRationedAllocator(rationed);
	free(tight);
	assert(finalizeCallCount == 3);
}

unittest {
	// Hopscotch displacement: with the default neighborhood a table is mostly full before it grows, and keys stay findable through interleaved inserts and removals that move them.
	ulong* table = create!ulong();
	assert(table !is null);
	scope(exit) free(table);
	size_t slots = capacity(table);
	foreach (ulong k; 0 .. 1 << 15) {
		assert(insert(table, k * 0x9E3779B97F4A7C15) !is null);
		if (capacity(table) == slots) continue;
		assert(slots < 1024 || k >= slots * 4 / 5);
		slots = capacity(table);
	}

	enum n = 4096;
	bool[n] present;
	ulong* churn = create!ulong();
	assert(churn !is null);
	scope(exit) free(churn);
	uint seed = 1;
	foreach (step; 0 .. 20 * n) {
		seed = seed * 1103515245 + 12345;
		immutable k = (seed >> 8) % n;
		if (present[k] && step % 3 == 0) {
			remove(churn, cast(ulong) k);
			present[k] = false;
		} else {
			assert(insert(churn, cast(ulong) k) !is null);
			present[k] = true;
		}
		if (step % 512 == 0)
			foreach (size_t j; 0 .. n) assert(contains(churn, j) == present[j]);
	}
	foreach (size_t j; 0 .. n) assert(contains(churn, j) == present[j]);
}

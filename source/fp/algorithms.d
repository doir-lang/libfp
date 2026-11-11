/// Algorithms over plain data: hashing bytes (`hashBytes`, MurmurHash3 and the default for `fp.hashtable`; `hashShortBytes`, FNV-1a; `combine`, for chaining a hash over several values), searching (`find`, `findIf`, `lowerBound`, `upperBound`, `findSorted`), sorting (`sortUnique`, `radixSort`, `applyPermutation`), and differences (`commonSubsequence`, Myers' O(ND) diff in linear space).
///
/// They share conventions.
/// Inputs are slices; pass a dynarray as `fp.dynarray.slice(array)`, except to a function that changes its length, which takes the dynarray first.
/// An order is the template parameter `less`, `(a, b) => a < b` by default.
/// A search returns an index or `fp.pointer.notFound`.
/// Output that grows is appended to a dynarray passed last by `ref`, with a `bool` result; on failure it is left as it was.
/// A hash is a `ulong`.
///
/// Comparison sorting, `isSorted` and `reverse` are `std.algorithm`'s, which work under `-betterC`; these cover what they do not.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// assert(hashBytes("abc") != hashBytes("abd"));
/// int* values = null;
/// scope(exit) fp.dynarray.free(values);
/// int[5] input = [3, 1, 3, 2, 1];
/// assert(fp.dynarray.concatenate(values, input[]));
/// sortUnique(values);
/// assert(fp.dynarray.slice(values) == [1, 2, 3]);
/// assert(lowerBound(fp.dynarray.slice(values), 2) == 1 && findSorted(fp.dynarray.slice(values), 4) == fp.pointer.notFound);
/// ---
module fp.algorithms;

static import core.bitop;
static import core.stdc.string;
static import fp.dynarray;
static import fp.lifecycle;
static import fp.pointer;
static import std.algorithm.sorting;
version(unittest) static import fp.testing;


@nogc nothrow:


// === hashing ===================================================================

/// The hash `combine` chains start from: the FNV-1a offset basis, so a chain of `combine` over bytes computes FNV-1a.
enum ulong chainStart = 14695981039346656037UL;

/// The 64-bit FNV-1a hash of the bytes of `data`, a slice of scalars, matching reference FNV-1a values on every host.
/// It reads one byte at a time, so it suits short inputs; use `hashBytes` for long ones.
/// It cannot fail.
///
/// Examples:
/// ---
/// ubyte[2] a = [1, 2];
/// ubyte[2] b = [2, 1];
/// assert(hashShortBytes(a[]) != hashShortBytes(b[]));
/// assert(hashShortBytes("a") == hashShortBytes(cast(const(ubyte)[]) "a"));
/// assert(hashShortBytes("a") == 0xAF63DC4C8601EC8C);
/// ---
ulong hashShortBytes(T)(const(T)[] data) @trusted if (__traits(isScalar, T)) {
	enum ulong prime = 1099511628211UL;
	ulong hash = chainStart;
	foreach (b; cast(const(ubyte)[]) data) {
		hash ^= cast(ulong) b;
		hash *= prime;
	}
	return hash;
}

/// Folds `value` into `hash`, one FNV-1a step over a whole word rather than a byte, for a hash chained over several values.
/// A multiply carries bits only upward, so high bits of `value` never reach the low bits of the result; pass the result through `hashBytes` if they must.
/// It cannot fail.
///
/// Examples:
/// ---
/// assert(combine(combine(0, 1), 2) != combine(combine(0, 2), 1));
/// ---
pragma(inline, true)
ulong combine(ulong hash, ulong value) {
	enum ulong prime = 1099511628211UL;
	return (hash ^ value) * prime;
}

// Reads up to eight bytes as a little-endian word, zero-extended, whatever the host's byte order.
pragma(inline, true)
private ulong loadLittleEndian(const(ubyte)[] bytes) @trusted {
	assert(bytes.length <= ulong.sizeof, "fp.algorithms: more bytes than a word holds");
	assert(bytes.ptr !is null || bytes.length == 0, "fp.algorithms: bytes with a length but no address");
	ulong word = 0;
	core.stdc.string.memcpy(&word, bytes.ptr, bytes.length);
	version(BigEndian) word = core.bitop.bswap(word);
	return word;
}

pragma(inline, true)
private ulong finalMix(ulong k) {
	k ^= k >> 33;
	k *= 0xff51afd7ed558ccd;
	k ^= k >> 33;
	k *= 0xc4ceb9fe1a85ec53;
	return k ^ (k >> 33);
}

/// The first 64 bits of MurmurHash3_x64_128 of the bytes of `data`, a slice of scalars, with `seed`, matching the reference implementation on every host.
/// It reads sixteen bytes at a time, so it is faster than `hashShortBytes` over long inputs, and its result is well mixed in its top bits as well as its bottom ones.
/// It cannot fail.
///
/// Examples:
/// ---
/// assert(hashBytes(cast(const(ubyte)[]) "hello") == 0xCBD8A7B341BD9B02);
/// assert(hashBytes(cast(const(ubyte)[]) "abc") != hashBytes(cast(const(ubyte)[]) "abd"));
/// assert(hashBytes(cast(const(ubyte)[]) "abc", 1) != hashBytes(cast(const(ubyte)[]) "abc", 2));
/// assert(hashBytes("abc") == hashBytes(cast(const(ubyte)[]) "abc"));
/// ---
ulong hashBytes(T)(const(T)[] data, uint seed = 0) @trusted if (__traits(isScalar, T)) {
	const bytes = cast(const(ubyte)[]) data;
	enum ulong c1 = 0x87c37b91114253d5;
	enum ulong c2 = 0x4cf5ad432745937f;

	ulong h1 = seed, h2 = seed;
	immutable tailStart = bytes.length & ~size_t(15);
	assert(tailStart <= bytes.length && bytes.length - tailStart < 16, "fp.algorithms: a tail longer than a block");
	for (size_t i = 0; i < tailStart; i += 16) {
		immutable k1 = core.bitop.rol(loadLittleEndian(bytes[i .. i + 8]) * c1, 31) * c2;
		h1 = (core.bitop.rol(h1 ^ k1, 27) + h2) * 5 + 0x52dce729;
		immutable k2 = core.bitop.rol(loadLittleEndian(bytes[i + 8 .. i + 16]) * c2, 33) * c1;
		h2 = (core.bitop.rol(h2 ^ k2, 31) + h1) * 5 + 0x38495ab5;
	}

	const tail = bytes[tailStart .. $];
	if (tail.length > 8) h2 ^= core.bitop.rol(loadLittleEndian(tail[8 .. $]) * c2, 33) * c1;
	if (tail.length > 0) h1 ^= core.bitop.rol(loadLittleEndian(tail[0 .. tail.length < 8 ? tail.length : 8]) * c1, 31) * c2;

	h1 ^= bytes.length;
	h2 ^= bytes.length;
	h1 += h2;
	h2 += h1;
	h1 = finalMix(h1);
	h2 = finalMix(h2);
	return h1 + h2;
}


unittest {
	ubyte[3] a = [1, 2, 3];
	ubyte[3] b = [1, 2, 3];
	ubyte[3] c = [3, 2, 1];

	assert(hashShortBytes(a[]) == hashShortBytes(b[]));
	assert(hashShortBytes(a[]) != hashShortBytes(c[]));

	// Reference FNV-1a of the bytes 01 00 00 00 02 00 00 00, the same on every host.
	int[2] ints = [1, 2];
	version(LittleEndian) assert(hashShortBytes(ints[]) == 0xC9C28939C99668C6);
	assert(hashShortBytes!ubyte(null) == chainStart);

	// A combine is one FNV-1a step over a word, so chaining it over bytes from `chainStart` is FNV-1a.
	assert(combine(0x10, 0x01) == 0x11 * 1099511628211UL);
	ulong chained = chainStart;
	foreach (byte_; cast(const(ubyte)[]) ints[]) chained = combine(chained, byte_);
	assert(chained == hashShortBytes(ints[]));
}

unittest { // lengths around a word apart differ, as do inputs differing only past the last whole word, or by trailing zeros
	ubyte[17] zeros = 0;
	foreach (n; 0 .. zeros.length)
		foreach (m; n + 1 .. zeros.length) assert(hashBytes(zeros[0 .. n]) != hashBytes(zeros[0 .. m]));
	assert(hashBytes(cast(const(ubyte)[]) "abcdefgh1") != hashBytes(cast(const(ubyte)[]) "abcdefgh2"));
	// MurmurHash3_x64_128's first word, covering an empty input, a tail in each word, a whole block, blocks with a tail, and seeds.
	assert(hashBytes!ubyte(null) == 0);
	assert(hashBytes(cast(const(ubyte)[]) "foo") == 0xE271865701F54561);
	assert(hashBytes(cast(const(ubyte)[]) "interned text") == 0x3AEF0836FCDACE9A);
	assert(hashBytes(cast(const(ubyte)[]) "abcdefgh12345678") == 0x2D3FB5F16994C330);
	assert(hashBytes(cast(const(ubyte)[]) "foo", 42) == 0xF4569D51637053F2);
	assert(hashBytes(cast(const(ubyte)[]) "interned text", 0xDEADBEEF) == 0xA9E8FF826BCFE622);
	assert(hashBytes(cast(const(ubyte)[]) "The quick brown fox jumps over the lazy dog") == 0xE34BBC7BBC071B6C);
}


// === random numbers ============================================================

/// A seeded pseudo-random generator (xoshiro256**), for tests and simulations that replay from a seed.
/// It is not for secrets: its output is predictable.
/// Make one with `createRandom`; a default-initialized one is all zeros and only ever yields zero.
///
/// Examples:
/// ---
/// Random a = createRandom(7), b = createRandom(7);
/// assert(nextRandom(a) == nextRandom(b));
/// ---
struct Random {
	ulong[4] state;
}

/// A generator whose sequence `seed` alone decides, the same on every platform.
/// Every seed, zero included, gives a usable one (SplitMix64 fills the state).
///
/// Examples:
/// ---
/// Random random = createRandom(0);
/// assert(nextRandom(random) == 0x99EC5F36CB75F2B4);
/// ---
Random createRandom(ulong seed) {
	Random random;
	foreach (ref word; random.state) {
		seed += 0x9E3779B97F4A7C15;
		ulong mixed = seed;
		mixed = (mixed ^ (mixed >> 30)) * 0xBF58476D1CE4E5B9;
		mixed = (mixed ^ (mixed >> 27)) * 0x94D049BB133111EB;
		word = mixed ^ (mixed >> 31);
	}
	// xoshiro256** never leaves the all-zero state, so a seed that reached it would give only zeros.
	assert((random.state[0] | random.state[1] | random.state[2] | random.state[3]) != 0, "fp.algorithms: a seed reached the all-zero state");
	return random;
}

/// The next 64 bits of `random`'s sequence.
///
/// Examples:
/// ---
/// Random random = createRandom(1);
/// assert(nextRandom(random) != nextRandom(random));
/// ---
ulong nextRandom(ref Random random) {
	assert((random.state[0] | random.state[1] | random.state[2] | random.state[3]) != 0, "fp.algorithms: a Random not made by createRandom");
	immutable result = core.bitop.rol(random.state[1] * 5, 7) * 9;
	immutable shifted = random.state[1] << 17;
	random.state[2] ^= random.state[0];
	random.state[3] ^= random.state[1];
	random.state[1] ^= random.state[2];
	random.state[0] ^= random.state[3];
	random.state[2] ^= shifted;
	random.state[3] = core.bitop.rol(random.state[3], 45);
	assert((random.state[0] | random.state[1] | random.state[2] | random.state[3]) != 0, "fp.algorithms: the generator reached the all-zero state");
	return result;
}

/// A number from 0 up to but not including `n`, each equally likely; `n` must not be zero.
///
/// Examples:
/// ---
/// Random random = createRandom(1);
/// assert(randomBelow(random, 6) < 6);
/// ---
size_t randomBelow(ref Random random, size_t n) {
	assert(n != 0, "fp.algorithms.randomBelow: there is no number below zero to pick");
	// The lowest `2^64 % n` values are rejected so every remainder is as likely; a draw is kept more often than not.
	immutable ulong rejected = (0 - cast(ulong) n) % n;
	assert(rejected < n, "fp.algorithms.randomBelow: rejecting a whole range of draws");
	for (;;) {
		immutable drawn = nextRandom(random);
		if (drawn < rejected) continue;
		assert(drawn % n < n, "fp.algorithms.randomBelow: a draw at or above the bound");
		return cast(size_t) (drawn % n);
	}
}

/// True `numerator` times in `denominator`, which must not be zero or less than `numerator`.
///
/// Examples:
/// ---
/// Random random = createRandom(1);
/// assert(randomChance(random, 1, 1) && !randomChance(random, 0, 4));
/// ---
bool randomChance(ref Random random, size_t numerator, size_t denominator) {
	assert(numerator <= denominator, "fp.algorithms.randomChance: a chance cannot be more than certain");
	assert(denominator > 0, "fp.algorithms.randomChance: a chance out of nothing");
	return randomBelow(random, denominator) < numerator;
}

/// A number from 0 to 1, both included, drawn from 2^53 evenly spaced values so every one is exactly representable as a `double`.
///
/// Examples:
/// ---
/// Random random = createRandom(1);
/// immutable fraction = randomFraction(random);
/// assert(fraction >= 0 && fraction <= 1);
/// ---
double randomFraction(ref Random random) {
	enum mantissaBits = double.mant_dig;
	enum ulong largest = (1UL << mantissaBits) - 1;
	immutable drawn = nextRandom(random) >> (64 - mantissaBits);
	assert(drawn <= largest, "fp.algorithms.randomFraction: a draw wider than a double's mantissa");
	immutable fraction = cast(double) drawn / cast(double) largest;
	assert(fraction >= 0 && fraction <= 1, "fp.algorithms.randomFraction: a fraction outside [0, 1]");
	return fraction;
}

unittest { // the reference sequence; seeds decide the sequence; every number below a bound turns up, none at or above it; chances at both ends and between; fractions spread over [0, 1]
	Random random = createRandom(0);
	assert(random.state[0] == 0xE220A8397B1DCDAF);
	assert(nextRandom(random) == 0x99EC5F36CB75F2B4 && nextRandom(random) == 0xBF6E1F784956452A);

	Random same = createRandom(0), other = createRandom(1);
	cast(void) nextRandom(same);
	cast(void) nextRandom(same);
	assert(nextRandom(same) == nextRandom(random) && nextRandom(same) != nextRandom(other));

	size_t[7] seen;
	foreach (i; 0 .. 7000) ++seen[randomBelow(random, 7)];
	foreach (count; seen) assert(count > 800 && count < 1200);
	foreach (i; 0 .. 100) assert(randomBelow(random, 1) == 0);
	assert(randomBelow(random, size_t.max) < size_t.max);

	size_t hits = 0;
	foreach (i; 0 .. 4000) {
		assert(randomChance(random, 3, 3) && !randomChance(random, 0, 3));
		hits += randomChance(random, 1, 4);
	}
	assert(hits > 800 && hits < 1200);

	size_t[10] tenths;
	double sum = 0;
	foreach (i; 0 .. 10_000) {
		immutable fraction = randomFraction(random);
		assert(fraction >= 0 && fraction <= 1);
		++tenths[fraction == 1 ? 9 : cast(size_t) (fraction * 10)];
		sum += fraction;
	}
	foreach (count; tenths) assert(count > 850 && count < 1150);
	assert(sum / 10_000 > 0.48 && sum / 10_000 < 0.52);

	// nextRandom returns rol(state[1] * 5, 7) * 9, so inverting 5 and 9 mod 2^64 picks the state giving each endpoint.
	ulong inverse(ulong odd) { ulong x = odd; foreach (i; 0 .. 6) x *= 2 - odd * x; return x; }
	Random lowest = createRandom(0), highest = createRandom(0);
	lowest.state[1] = 0;
	highest.state[1] = core.bitop.ror(ulong.max * inverse(9), 7) * inverse(5);
	assert(randomFraction(lowest) == 0 && randomFraction(highest) == 1);
}


// === searching =================================================================

// --- linear --------------------------------------------------------------------

/// The index of the first element of `values` equal (`fp.lifecycle.equal`) to `value`, or `fp.pointer.notFound`.
/// O(n); it cannot fail.
///
/// Examples:
/// ---
/// static import fp.pointer;
/// int[4] values = [4, 2, 7, 2];
/// assert(find(values[], 2) == 1 && find(values[], 5) == fp.pointer.notFound);
/// ---
size_t find(T)(const(T)[] values, auto ref const T value) {
	assert(values.length < fp.pointer.allocationRefused, "fp.algorithms.find: an index could be read as a sentinel");
	foreach (i, ref element; values)
		if (fp.lifecycle.equal(element, value)) return i;
	return fp.pointer.notFound;
}

/// The index of the first element of `values` for which `predicate` returns true, or `fp.pointer.notFound`.
/// O(n); it cannot fail.
///
/// Examples:
/// ---
/// static import fp.pointer;
/// int[4] values = [4, 2, 7, 2];
/// assert(findIf!(x => x > 5)(values[]) == 2 && findIf!(x => x > 9)(values[]) == fp.pointer.notFound);
/// ---
size_t findIf(alias predicate, T)(const(T)[] values) {
	assert(values.length < fp.pointer.allocationRefused, "fp.algorithms.findIf: an index could be read as a sentinel");
	foreach (i, ref element; values)
		if (predicate(element)) return i;
	return fp.pointer.notFound;
}

// wrapper: container vocabulary every reader knows
/// Whether `values` holds an element equal (`fp.lifecycle.equal`) to `value`.
/// O(n); it cannot fail.
///
/// Examples:
/// ---
/// int[3] values = [4, 2, 7];
/// assert(contains(values[], 7) && !contains(values[], 5));
/// ---
bool contains(T)(const(T)[] values, auto ref const T value) {
	return find(values, value) != fp.pointer.notFound;
}


// --- sorted --------------------------------------------------------------------

/// The index of the first element of `sorted` for which `less(element, key)` is false, `sorted.length` if there is none: where `key` would be inserted before any equal elements to keep `sorted` in order.
/// `sorted` must be ordered by `less`.
/// O(log n); it cannot fail.
///
/// Examples:
/// ---
/// int[5] values = [1, 3, 3, 5, 7];
/// assert(lowerBound(values[], 3) == 1);
/// assert(lowerBound(values[], 4) == 3);
/// assert(lowerBound!((a, b) => a < b)(values[], 9) == 5);
/// ---
size_t lowerBound(alias less = (a, b) => a < b, T, K)(const(T)[] sorted, auto ref const K key) {
	size_t low = 0, high = sorted.length;
	while (low < high) {
		immutable middle = low + (high - low) / 2;
		if (less(sorted[middle], key)) low = middle + 1;
		else high = middle;
	}
	assert(low == sorted.length || !less(sorted[low], key), "fp.algorithms.lowerBound: stopped before the key; is the slice sorted by `less`?");
	assert(low == 0 || less(sorted[low - 1], key), "fp.algorithms.lowerBound: stopped past the key; is the slice sorted by `less`?");
	return low;
}

/// The index of the first element of `sorted` for which `less(key, element)` is true, `sorted.length` if there is none: where `key` would be inserted after any equal elements to keep `sorted` in order.
/// `sorted` must be ordered by `less`, which here takes the key first.
/// O(log n); it cannot fail.
///
/// Examples:
/// ---
/// int[5] values = [1, 3, 3, 5, 7];
/// assert(upperBound(values[], 3) == 3 && upperBound(values[], 0) == 0 && upperBound(values[], 7) == 5);
/// ---
size_t upperBound(alias less = (a, b) => a < b, T, K)(const(T)[] sorted, auto ref const K key) {
	size_t low = 0, high = sorted.length;
	while (low < high) {
		immutable middle = low + (high - low) / 2;
		if (less(key, sorted[middle])) high = middle;
		else low = middle + 1;
	}
	assert(low == sorted.length || less(key, sorted[low]), "fp.algorithms.upperBound: stopped before the key; is the slice sorted by `less`?");
	assert(low == 0 || !less(key, sorted[low - 1]), "fp.algorithms.upperBound: stopped past the key; is the slice sorted by `less`?");
	return low;
}

/// The index of the first element of `sorted` equivalent to `key` under `less` (neither orders before the other), or `fp.pointer.notFound`.
/// `sorted` must be ordered by `less`, which is called both ways round, element first and key first.
/// O(log n); it cannot fail.
///
/// Examples:
/// ---
/// static import fp.pointer;
/// int[5] values = [1, 3, 3, 5, 7];
/// assert(findSorted(values[], 3) == 1 && findSorted(values[], 4) == fp.pointer.notFound);
/// ---
size_t findSorted(alias less = (a, b) => a < b, T, K)(const(T)[] sorted, auto ref const K key) {
	immutable at = lowerBound!less(sorted, key);
	assert(at <= sorted.length, "fp.algorithms.findSorted: a bound past the slice");
	return at < sorted.length && !less(key, sorted[at]) ? at : fp.pointer.notFound;
}


unittest { // linear searches through lifetimes' equality; bounds at both ends and between repeats
	static struct Named { const(char)[] name; }
	Named[3] named = [Named("a"), Named("b"), Named("a")];
	assert(find(named[], Named("a")) == 0 && find(named[], Named("c")) == fp.pointer.notFound);
	assert(findIf!(x => x.name == "b")(named[]) == 1 && contains(named[], Named("b")));
	int[0] none;
	assert(find(none[], 1) == fp.pointer.notFound && !contains(none[], 1) && findIf!(x => true)(none[]) == fp.pointer.notFound);

	assert(lowerBound(none[], 1) == 0 && upperBound(none[], 1) == 0 && findSorted(none[], 1) == fp.pointer.notFound);
	static struct Entry { uint name; uint index; }
	Entry[4] entries = [Entry(1, 0), Entry(2, 5), Entry(2, 7), Entry(4, 1)];
	assert(lowerBound!((a, b) => a.name < b)(entries[], 2u) == 1);
	assert(lowerBound!((a, b) => a.name < b)(entries[], 0u) == 0);
	assert(lowerBound!((a, b) => a.name < b)(entries[], 5u) == 4);
	assert(upperBound!((key, a) => key < a.name)(entries[], 2u) == 3);
	assert(upperBound!((key, a) => key < a.name)(entries[], 4u) == 4);
	int[6] repeats = [1, 1, 2, 2, 2, 9];
	foreach (key; 0 .. 11) {
		size_t below = 0, through = 0;
		foreach (x; repeats) {
			if (x < key) ++below;
			if (x <= key) ++through;
		}
		assert(lowerBound(repeats[], key) == below && upperBound(repeats[], key) == through);
		assert(findSorted(repeats[], key) == (below == through ? fp.pointer.notFound : below));
	}
	int[3] descending = [9, 5, 1];
	assert(findSorted!((a, b) => a > b)(descending[], 5) == 1 && lowerBound!((a, b) => a > b)(descending[], 6) == 1);
}


// === sorting ===================================================================

/// Sorts the dynarray `array` by `less` and drops all but the first of each run of elements `less` cannot tell apart, keeping its capacity.
/// It cannot fail.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// size_t* lines = null;
/// scope(exit) fp.dynarray.free(lines);
/// foreach (line; [9, 2, 9, 4]) assert(fp.dynarray.pushBack(lines, size_t(line)));
/// sortUnique(lines);
/// assert(fp.dynarray.slice(lines) == [2, 4, 9]);
/// sortUnique!((a, b) => a > b)(lines);
/// assert(fp.dynarray.slice(lines) == [9, 4, 2]);
/// ---
void sortUnique(alias less = (a, b) => a < b, T)(T* array) {
	std.algorithm.sorting.sort!less(fp.dynarray.slice(array));
	cast(void) fp.dynarray.unique!((kept, element) => !less(kept, element))(array);
	foreach (i; 1 .. fp.dynarray.length(array))
		assert(less(array[i - 1], array[i]), "fp.algorithms.sortUnique: left elements out of order or repeated");
}

/// The most bits `radixSort` sorts in one pass, so its counting table holds `1 << radixDigitBits` entries.
enum size_t radixDigitBits = 12;

/// Sorts `keys`, unsigned integers each below `1 << bits`, by an LSD radix sort in as few passes of at most `radixDigitBits` bits as cover them, skipping a pass whose digit every key shares.
/// `buffer` must be as long as `keys`; the passes alternate between the two.
/// Returns whichever of `keys` and `buffer` holds the sorted result.
/// O(n * bits / radixDigitBits), so faster than a comparison sort for many keys of few bits; it cannot fail.
///
/// Examples:
/// ---
/// ulong[5] keys = [40, 3, 17, 3, 0];
/// ulong[5] buffer;
/// auto sorted = radixSort(keys[], buffer[], 6);
/// assert(sorted == [0, 3, 3, 17, 40]);
/// ---
T[] radixSort(T)(T[] keys, T[] buffer, size_t bits) if (__traits(isUnsigned, T)) {
	assert(buffer.length == keys.length && bits <= T.sizeof * 8, "fp.algorithms.radixSort: buffer too short or keys too wide");
	if (bits == 0 || keys.length == 0) return keys;
	immutable passes = (bits + radixDigitBits - 1) / radixDigitBits;
	immutable digit = (bits + passes - 1) / passes;
	assert(digit <= radixDigitBits && digit * passes >= bits, "fp.algorithms.radixSort: digits that do not cover the keys");
	immutable size_t mask = (size_t(1) << digit) - 1;
	size_t[1 << radixDigitBits] counts;
	auto from = keys, to = buffer;
	foreach (pass; 0 .. passes) {
		immutable shift = pass * digit;
		foreach (ref c; counts[0 .. mask + 1]) c = 0;
		foreach (key; from) ++counts[(key >> shift) & mask];
		if (counts[(from[0] >> shift) & mask] == from.length) continue;
		size_t sum = 0;
		foreach (ref c; counts[0 .. mask + 1]) {
			immutable count = c;
			c = sum;
			sum += count;
		}
		foreach (key; from) to[counts[(key >> shift) & mask]++] = key;
		auto swap = from;
		from = to;
		to = swap;
	}
	foreach (i; 1 .. from.length) assert(from[i - 1] <= from[i], "fp.algorithms.radixSort: left keys out of order; are they wider than `bits`?");
	return from;
}


// --- permutations ----------------------------------------------------------------

/// Walks the cycles of the permutation `order`, handing each transposition it needs to `swapPair`, so a caller can permute storage it alone knows how to swap.
/// `order[i]` is the index of whatever ends up at `i`, not where `i` goes.
///
/// Returns false, calling `swapPair` never, if its scratch buffer cannot be allocated.
///
/// Examples:
/// ---
/// int[3] values = [10, 20, 30];
/// immutable size_t[3] order = [2, 0, 1];
/// assert(applyPermutation(order[], (a, b) { immutable t = values[a]; values[a] = values[b]; values[b] = t; }));
/// assert(values == [30, 10, 20]);
/// ---
bool applyPermutation(const(size_t)[] order, scope void delegate(size_t, size_t) @nogc nothrow swapPair) @trusted {
	immutable n = order.length;
	if (n <= 1) return true;

	assert(n <= size_t.max / size_t.sizeof, "fp.algorithms.applyPermutation: an order longer than memory holds");
	auto swaps = cast(size_t*) fp.pointer.allocator(null, n * size_t.sizeof);
	if (swaps is null) return false;
	scope(exit) cast(void) fp.pointer.allocator(swaps, 0);
	version(assert) foreach (i; 0 .. n) swaps[i] = n; // unwritten, so a repeated position shows
	foreach (i; 0 .. n) {
		assert(order[i] < n, "fp.algorithms.applyPermutation: an order naming a position past its end");
		assert(swaps[order[i]] == n, "fp.algorithms.applyPermutation: an order naming a position twice");
		swaps[order[i]] = i;
	}

	foreach (i; 0 .. n)
		while (swaps[i] != i) {
			assert(swaps[i] < n, "fp.algorithms.applyPermutation: the order is not a permutation");
			swapPair(swaps[i], i);
			immutable t = swaps[swaps[i]];
			swaps[swaps[i]] = swaps[i];
			swaps[i] = t;
		}
	return true;
}


unittest { // sorts by other orders; radix sorts of several passes and of narrow keys; permutations
	static struct Pair { int key; int value; }
	Pair* pairs = null;
	scope(exit) fp.dynarray.free(pairs);
	Pair[5] input = [Pair(3, 0), Pair(1, 1), Pair(3, 2), Pair(2, 3), Pair(1, 4)];
	assert(fp.dynarray.concatenate(pairs, input[]));
	sortUnique!((a, b) => a.key < b.key)(pairs);
	assert(fp.dynarray.length(pairs) == 3 && pairs[0].key == 1 && pairs[1].key == 2 && pairs[2].key == 3);
	int* empty = null;
	sortUnique(empty);
	assert(empty is null);
	int* plain = null;
	scope(exit) fp.dynarray.free(plain);
	foreach (n; [3, 1, 3]) assert(fp.dynarray.pushBack(plain, n));
	sortUnique(plain); // the default order
	assert(fp.dynarray.slice(plain) == [1, 3]);

	ulong[600] keys, buffer, expected;
	Random random = createRandom(7);
	foreach (i, ref key; keys) {
		key = nextRandom(random) & ((1UL << 40) - 1);
		expected[i] = key;
	}
	std.algorithm.sorting.sort(expected[]);
	assert(radixSort(keys[], buffer[], 40) == expected[]);
	ulong[3] same = [5, 5, 5];
	ulong[3] spare;
	assert(radixSort(same[], spare[], 3).ptr is same.ptr); // every pass skipped
	ushort[6] narrow = [65535, 0, 300, 7, 300, 1];
	ushort[6] narrowBuffer;
	assert(radixSort(narrow[], narrowBuffer[], 16) == [0, 1, 7, 300, 300, 65535]);

	immutable size_t[4] order = [3, 2, 1, 0];
	int[4] values = [0, 1, 2, 3];
	assert(applyPermutation(order[], (a, b) { immutable t = values[a]; values[a] = values[b]; values[b] = t; }));
	assert(values == [3, 2, 1, 0]);
	auto rationed = fp.testing.limitAllocations(0);
	assert(!applyPermutation(order[], (a, b) { assert(false); }));
	fp.testing.restoreAllocator(rationed);
}


// === differences ===============================================================

// Where an optimal path crosses from the first half of the edit to the second, or none if it lies past the budget.
private struct Split {
	size_t x, y;
	bool found;
}

// Myers' bisection over `a` and `b`, which share no first or last element, searching at most `halfBudget` steps from each end.
private Split bisect(T)(const(T)[] a, const(T)[] b, size_t halfBudget, ref bool refused) @trusted {
	immutable ptrdiff_t n = a.length, m = b.length;
	immutable ptrdiff_t limit = (n + m + 1) / 2 < cast(ptrdiff_t) halfBudget ? (n + m + 1) / 2 : cast(ptrdiff_t) halfBudget;
	immutable ptrdiff_t offset = limit + 1, width = 2 * limit + 3;
	assert(n > 0 && m > 0 && a[0] != b[0] && a[$ - 1] != b[$ - 1], "fp.algorithms: bisecting sequences that share an end");
	assert(limit >= 0 && limit <= (n + m + 1) / 2, "fp.algorithms: a search limit past the edit distance's bound");
	ptrdiff_t* forward = null, backward = null;
	scope(exit) {
		fp.dynarray.free(forward);
		fp.dynarray.free(backward);
	}
	if (fp.dynarray.growToSize(forward, width) is null || fp.dynarray.growToSize(backward, width) is null) {
		refused = true;
		return Split.init;
	}
	foreach (i; 0 .. width) forward[i] = backward[i] = -1;
	forward[offset + 1] = backward[offset + 1] = 0;
	immutable delta = n - m;
	immutable bool odd = (delta & 1) != 0;
	ptrdiff_t forwardStart = 0, forwardEnd = 0, backwardStart = 0, backwardEnd = 0;

	foreach (d; 0 .. limit + 1) {
		for (ptrdiff_t k = -d + forwardStart; k <= d - forwardEnd; k += 2) {
			immutable at = offset + k;
			ptrdiff_t x = (k == -d || (k != d && forward[at - 1] < forward[at + 1])) ? forward[at + 1] : forward[at - 1] + 1;
			ptrdiff_t y = x - k;
			while (x < n && y < m && a[x] == b[y]) { ++x; ++y; }
			forward[at] = x;
			if (x > n) forwardEnd += 2;
			else if (y > m) forwardStart += 2;
			else if (odd) {
				immutable other = offset + delta - k;
				if (other >= 0 && other < width && backward[other] != -1 && x >= n - backward[other])
					return Split(cast(size_t) x, cast(size_t) y, true);
			}
		}
		for (ptrdiff_t k = -d + backwardStart; k <= d - backwardEnd; k += 2) {
			immutable at = offset + k;
			ptrdiff_t x = (k == -d || (k != d && backward[at - 1] < backward[at + 1])) ? backward[at + 1] : backward[at - 1] + 1;
			ptrdiff_t y = x - k;
			while (x < n && y < m && a[n - x - 1] == b[m - y - 1]) { ++x; ++y; }
			backward[at] = x;
			if (x > n) backwardEnd += 2;
			else if (y > m) backwardStart += 2;
			else if (!odd) {
				immutable other = offset + delta - k;
				if (other >= 0 && other < width && forward[other] != -1) {
					immutable forwardX = forward[other], forwardY = offset + forwardX - other;
					if (forwardX >= n - x) return Split(cast(size_t) forwardX, cast(size_t) forwardY, true);
				}
			}
		}
	}
	return Split.init;
}

// How deep `align_` can go: each split halves the edits left, and two sequences differ by fewer edits than a `size_t` can count twice over.
private enum size_t maxAlignDepth = 8 * size_t.sizeof + 2;

// bounded: maxAlignDepth
// Appends the common pairs of `a` and `b`, which start at `aStart` and `bStart` in the whole sequences.
private bool align_(T)(const(T)[] a, const(T)[] b, size_t aStart, size_t bStart, size_t halfBudget, ref size_t[2]* pairs, size_t depth = 0) {
	assert(depth <= maxAlignDepth, "fp.algorithms.commonSubsequence: a split that did not halve the edits");
	size_t prefix = 0;
	for (; prefix < a.length && prefix < b.length && a[prefix] == b[prefix]; ++prefix)
		if (!fp.dynarray.pushBack(pairs, cast(size_t[2]) [aStart + prefix, bStart + prefix])) return false;
	size_t suffix = 0;
	while (suffix < a.length - prefix && suffix < b.length - prefix && a[$ - 1 - suffix] == b[$ - 1 - suffix]) ++suffix;

	const middleA = a[prefix .. $ - suffix], middleB = b[prefix .. $ - suffix];
	if (middleA.length != 0 && middleB.length != 0) {
		bool refused = false;
		immutable split = bisect(middleA, middleB, halfBudget, refused);
		if (refused) return false;
		if (split.found) {
			assert(split.x <= middleA.length && split.y <= middleB.length, "fp.algorithms.commonSubsequence: a split past the sequences");
			if (!align_(middleA[0 .. split.x], middleB[0 .. split.y], aStart + prefix, bStart + prefix, halfBudget, pairs, depth + 1)) return false;
			if (!align_(middleA[split.x .. $], middleB[split.y .. $], aStart + prefix + split.x, bStart + prefix + split.y, halfBudget, pairs, depth + 1)) return false;
		}
	}

	foreach (s; 0 .. suffix)
		if (!fp.dynarray.pushBack(pairs, cast(size_t[2]) [aStart + a.length - suffix + s, bStart + b.length - suffix + s])) return false;
	return true;
}

/// Appends to `pairs`, in increasing order, the index pairs `[i, j]` of a longest common subsequence of `a` and `b`: `a[i] == b[j]` for each, and no longer list of such pairs exists.
/// A common first and last run is always matched; between them, if `a` and `b` differ by more than about `maxEdits` insertions and deletions, the middle is left unmatched rather than searched further.
///
/// Returns false if an allocation was refused, leaving `pairs` as it was.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// size_t[2]* pairs = null;
/// scope(exit) fp.dynarray.free(pairs);
/// assert(commonSubsequence("abcabba", "cbabac", 64, pairs));
/// assert(fp.dynarray.length(pairs) == 4); // a longest common subsequence has length 4, such as "baba"
/// ---
bool commonSubsequence(T)(const(T)[] a, const(T)[] b, size_t maxEdits, ref size_t[2]* pairs) {
	immutable wasNull = pairs is null;
	immutable before = fp.dynarray.length(pairs);
	if (align_(a, b, 0, 0, maxEdits / 2 + 1, pairs)) {
		immutable found = fp.dynarray.length(pairs) - before;
		assert(found <= a.length && found <= b.length, "fp.algorithms.commonSubsequence: more pairs than elements");
		foreach (i; before + 1 .. fp.dynarray.length(pairs))
			assert(pairs[i][0] > pairs[i - 1][0] && pairs[i][1] > pairs[i - 1][1], "fp.algorithms.commonSubsequence: pairs out of order");
		return true;
	}
	if (wasNull) fp.dynarray.free(pairs);
	else cast(void) fp.dynarray.removeLast(pairs, fp.dynarray.length(pairs) - before);
	return false;
}


version(unittest) {
	// Whether `pairs` is a common subsequence of `a` and `b`, strictly increasing in both.
	private bool isCommon(T)(const(T)[] a, const(T)[] b, const(size_t[2])[] pairs) {
		foreach (i, pair; pairs) {
			if (pair[0] >= a.length || pair[1] >= b.length || a[pair[0]] != b[pair[1]]) return false;
			if (i > 0 && (pair[0] <= pairs[i - 1][0] || pair[1] <= pairs[i - 1][1])) return false;
		}
		return true;
	}

	// The length of a longest common subsequence, by the quadratic dynamic program, for inputs up to 32 long.
	private size_t lcsLength(T)(const(T)[] a, const(T)[] b) {
		size_t[33][33] table;
		foreach (i; 0 .. a.length + 1) foreach (j; 0 .. b.length + 1) table[i][j] = 0;
		foreach (i; 1 .. a.length + 1)
			foreach (j; 1 .. b.length + 1)
				table[i][j] = a[i - 1] == b[j - 1] ? table[i - 1][j - 1] + 1 : (table[i - 1][j] > table[i][j - 1] ? table[i - 1][j] : table[i][j - 1]);
		return table[a.length][b.length];
	}
}

unittest { // optimal on random inputs; empty sides; the budget; refusals
	Random random = createRandom(3);
	foreach (round; 0 .. 400) {
		ubyte[32] a, b;
		immutable n = randomBelow(random, 33), m = randomBelow(random, 33);
		foreach (i; 0 .. n) a[i] = cast(ubyte) randomBelow(random, 4);
		foreach (i; 0 .. m) b[i] = cast(ubyte) randomBelow(random, 4);
		size_t[2]* pairs = null;
		scope(exit) fp.dynarray.free(pairs);
		assert(commonSubsequence(a[0 .. n], b[0 .. m], 1000, pairs));
		assert(isCommon(a[0 .. n], b[0 .. m], fp.dynarray.slice(pairs)));
		assert(fp.dynarray.length(pairs) == lcsLength(a[0 .. n], b[0 .. m]));
	}

	size_t[2]* pairs = null;
	scope(exit) fp.dynarray.free(pairs);
	immutable int[3] some = [1, 2, 3];
	assert(commonSubsequence(some[0 .. 0], some[], 8, pairs) && fp.dynarray.length(pairs) == 0);
	immutable size_t[2][3] diagonal = [[0, 0], [1, 1], [2, 2]];
	assert(commonSubsequence(some[], some[], 0, pairs) && fp.dynarray.slice(pairs) == diagonal[]);

	// Past the budget, only the common ends are matched.
	fp.dynarray.clear(pairs);
	int[200] left, right;
	foreach (i; 0 .. 200) { left[i] = i % 2 ? i : -1; right[i] = i % 2 ? -i : i; }
	left[0] = right[0] = 7;
	left[199] = right[199] = 9;
	assert(commonSubsequence(left[], right[], 4, pairs));
	immutable size_t[2][2] ends = [[0, 0], [199, 199]];
	assert(fp.dynarray.slice(pairs) == ends[]);

	foreach (budget; 0 .. 8) {
		size_t[2]* rationedPairs = null;
		scope(exit) fp.dynarray.free(rationedPairs);
		auto rationed = fp.testing.limitAllocations(budget);
		immutable done = commonSubsequence("xaby", "xbay", 16, rationedPairs);
		fp.testing.restoreAllocator(rationed);
		if (done) assert(fp.dynarray.length(rationedPairs) == 3);
		else assert(rationedPairs is null);
	}
	// A refusal leaves pairs already held in place, and none of the new ones.
	foreach (budget; 0 .. 8) {
		size_t[2]* held = null;
		scope(exit) fp.dynarray.free(held);
		assert(fp.dynarray.pushBack(held, cast(size_t[2]) [7, 7]));
		auto rationed = fp.testing.limitAllocations(budget);
		immutable done = commonSubsequence("xabyxabyxaby", "xbayxbayxbay", 16, held);
		fp.testing.restoreAllocator(rationed);
		if (!done) assert(fp.dynarray.length(held) == 1 && held[0] == [7, 7]);
	}
}

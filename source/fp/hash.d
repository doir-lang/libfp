/// Hashing over bytes: `murmur`, MurmurHash3 and the default for `fp.hashtable`; `fnv1a`, a byte-at-a-time hash; and `mix`, for chaining a hash over several values.
///
/// Examples:
/// ---
/// assert(murmur(cast(const(ubyte)[]) "abc") != murmur(cast(const(ubyte)[]) "abd"));
/// ---
module fp.hash;

static import core.bitop;
static import core.stdc.string;


@nogc nothrow:


/// The 64-bit FNV-1a hash of `data`, truncated to `size_t`. Bytes are mixed in from last to first, so results differ from reference FNV-1a values. It cannot fail.
///
/// Examples:
/// ---
/// ubyte[2] a = [1, 2];
/// ubyte[2] b = [2, 1];
/// assert(fnv1a(a[]) != fnv1a(b[]));
/// ---
size_t fnv1a(inout(ubyte)[] data) @trusted {
	enum ulong offsetBasis = 14695981039346656037UL;
	enum ulong prime = 1099511628211UL;

	ulong h = offsetBasis;
	foreach_reverse (b; data) {
		h ^= cast(ulong) b;
		h *= prime;
	}
	return cast(size_t) h;
}

/// FNV-1a over the bytes of any slice's elements.
///
/// Examples:
/// ---
/// int[2] values = [1, 2];
/// assert(fnv1a(values[]) == fnv1a(cast(ubyte[]) values[]));
/// ---
size_t fnv1a(T)(inout(T)[] data) @trusted {
	return fnv1a(cast(inout(ubyte)[]) data);
}

/// Folds `value` into hash `h`, one FNV-1a step over a whole word rather than a byte, for a hash chained over several values. A multiply carries bits only upward, so high bits of `value` never reach the low bits of the result; pass the result through `murmur` if they must. It cannot fail.
///
/// Examples:
/// ---
/// assert(mix(mix(0, 1), 2) != mix(mix(0, 2), 1));
/// ---
ulong mix(ulong h, ulong value) {
	enum ulong prime = 1099511628211UL;
	return (h ^ value) * prime;
}

// Reads up to eight bytes as a little-endian word, zero-extended, whatever the host's byte order.
private ulong loadLittleEndian(const(ubyte)[] bytes) @trusted {
	ulong word = 0;
	core.stdc.string.memcpy(&word, bytes.ptr, bytes.length);
	version(BigEndian) word = core.bitop.bswap(word);
	return word;
}

private ulong finalMix(ulong k) {
	k ^= k >> 33;
	k *= 0xff51afd7ed558ccd;
	k ^= k >> 33;
	k *= 0xc4ceb9fe1a85ec53;
	return k ^ (k >> 33);
}

/// The first 64 bits of MurmurHash3_x64_128 of `bytes` with `seed`, matching the reference implementation on every host. It reads sixteen bytes at a time, so it is faster than `fnv1a` over long inputs, and its result is well mixed in its top bits as well as its bottom ones. It cannot fail.
///
/// Examples:
/// ---
/// assert(murmur(cast(const(ubyte)[]) "hello") == 0xCBD8A7B341BD9B02);
/// assert(murmur(cast(const(ubyte)[]) "abc") != murmur(cast(const(ubyte)[]) "abd"));
/// assert(murmur(cast(const(ubyte)[]) "abc", 1) != murmur(cast(const(ubyte)[]) "abc", 2));
/// ---
ulong murmur(const(ubyte)[] bytes, uint seed = 0) {
	enum ulong c1 = 0x87c37b91114253d5;
	enum ulong c2 = 0x4cf5ad432745937f;

	ulong h1 = seed, h2 = seed;
	immutable tailStart = bytes.length & ~size_t(15);
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

	assert(fnv1a(a[]) == fnv1a(b[]));
	assert(fnv1a(a[]) != fnv1a(c[]));

	// The 64-bit hash, truncated to the host's pointer size.
	int[2] ints = [1, 2];
	static if (size_t.sizeof == 8) assert(fnv1a(ints[]) == 0x8F6A30DD2D7B634C);
	else static if (size_t.sizeof == 4) assert(fnv1a(ints[]) == 0x2D7B634C);
	else static assert(0, "fp.hash: no test value for a " ~ size_t.sizeof.stringof ~ "-byte size_t");

	// A mix is one step of the 64-bit hash, whatever the pointer size.
	assert(mix(0x10, 0x01) == 0x11 * 1099511628211UL);
}

unittest { // lengths around a word apart differ, as do inputs differing only past the last whole word, or by trailing zeros
	ubyte[17] zeros = 0;
	foreach (n; 0 .. zeros.length)
		foreach (m; n + 1 .. zeros.length) assert(murmur(zeros[0 .. n]) != murmur(zeros[0 .. m]));
	assert(murmur(cast(const(ubyte)[]) "abcdefgh1") != murmur(cast(const(ubyte)[]) "abcdefgh2"));
	// MurmurHash3_x64_128's first word, covering an empty input, a tail in each word, a whole block, blocks with a tail, and seeds.
	assert(murmur(null) == 0);
	assert(murmur(cast(const(ubyte)[]) "foo") == 0xE271865701F54561);
	assert(murmur(cast(const(ubyte)[]) "interned text") == 0x3AEF0836FCDACE9A);
	assert(murmur(cast(const(ubyte)[]) "abcdefgh12345678") == 0x2D3FB5F16994C330);
	assert(murmur(cast(const(ubyte)[]) "foo", 42) == 0xF4569D51637053F2);
	assert(murmur(cast(const(ubyte)[]) "interned text", 0xDEADBEEF) == 0xA9E8FF826BCFE622);
	assert(murmur(cast(const(ubyte)[]) "The quick brown fox jumps over the lazy dog") == 0xE34BBC7BBC071B6C);
}

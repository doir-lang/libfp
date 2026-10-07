/// FNV-1a hashing over a byte slice: the default hash for `fp.hashtable`.
///
/// Examples:
/// ---
/// ubyte[3] bytes = [1, 2, 3];
/// assert(hash(bytes[]) == hash(bytes[]));
/// ---
module fp.fnv1a;

/// The 64-bit FNV-1a hash of `data`, truncated to `size_t`. Bytes are mixed in from last to first, so results differ from reference FNV-1a values.
///
/// Examples:
/// ---
/// ubyte[2] a = [1, 2];
/// ubyte[2] b = [2, 1];
/// assert(hash(a[]) != hash(b[]));
/// ---
size_t hash(inout(ubyte)[] data) @nogc nothrow @trusted {
	enum ulong offsetBasis = 14695981039346656037UL;
	enum ulong prime = 1099511628211UL;

	ulong h = offsetBasis;
	foreach_reverse (b; data) {
		h ^= cast(ulong) b;
		h *= prime;
	}
	return cast(size_t) h;
}

/// Hashes the bytes of any slice's elements.
///
/// Examples:
/// ---
/// int[2] values = [1, 2];
/// assert(hash(values[]) == hash(cast(ubyte[]) values[]));
/// ---
size_t hash(T)(inout(T)[] data) @nogc nothrow @trusted {
	return hash(cast(inout(ubyte)[]) data);
}


unittest {
	ubyte[3] a = [1, 2, 3];
	ubyte[3] b = [1, 2, 3];
	ubyte[3] c = [3, 2, 1];

	assert(hash(a[]) == hash(b[]));
	assert(hash(a[]) != hash(c[]));

	int[2] ints = [1, 2];
	assert(hash(ints[]) == -8112618052245560500);
}

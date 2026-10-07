/// FNV-1a hashing over a byte slice: the default hash for `fp.hashtable`.
///
/// Examples:
/// ---
/// ubyte[3] bytes = [1, 2, 3];
/// assert(hash(bytes[]) == hash(bytes[]));
/// ---
module fp.fnv1a;


@nogc nothrow:


/// The 64-bit FNV-1a hash of `data`, truncated to `size_t`. Bytes are mixed in from last to first, so results differ from reference FNV-1a values.
///
/// Examples:
/// ---
/// ubyte[2] a = [1, 2];
/// ubyte[2] b = [2, 1];
/// assert(hash(a[]) != hash(b[]));
/// ---
size_t hash(inout(ubyte)[] data) @trusted {
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
size_t hash(T)(inout(T)[] data) @trusted {
	return hash(cast(inout(ubyte)[]) data);
}


unittest {
	ubyte[3] a = [1, 2, 3];
	ubyte[3] b = [1, 2, 3];
	ubyte[3] c = [3, 2, 1];

	assert(hash(a[]) == hash(b[]));
	assert(hash(a[]) != hash(c[]));

	// The 64-bit hash, truncated to the host's pointer size.
	int[2] ints = [1, 2];
	static if (size_t.sizeof == 8) assert(hash(ints[]) == 0x8F6A30DD2D7B634C);
	else static if (size_t.sizeof == 4) assert(hash(ints[]) == 0x2D7B634C);
	else static assert(0, "fp.fnv1a: no test value for a " ~ size_t.sizeof.stringof ~ "-byte size_t");
}

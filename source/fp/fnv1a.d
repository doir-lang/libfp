module fp.fnv1a;

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

size_t hash(T)(inout(T)[] data) @nogc nothrow @trusted {
    return hash(cast(inout(ubyte)[]) data);
}

unittest {
    ubyte[3] a = [1, 2, 3];
    ubyte[3] b = [1, 2, 3];
    ubyte[3] c = [3, 2, 1];

    assert(hash(a[]) == hash(b[]));
    assert(hash(a[]) != hash(c[]));

    import std.stdio : printf;

    int[2] ints = [1, 2];
    assert(hash(ints[]) == -8112618052245560500);
}

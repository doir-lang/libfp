# libfp

A `-betterC` D library of "fat pointers": `malloc`-backed allocations that
hide a small header (a pointer-type tag + length, and for dynarrays/hash
tables, capacity/config) immediately before the pointer handed back to the
caller — so the result is still a plain `T*`, usable with ordinary
indexing, while `pointer.length(p)`, `pointer.valid(p)`, etc. recover the
metadata by walking backward from the pointer.

Ported from an earlier C/C++ implementation (parallel C-macro and C++
template APIs) into a single D API, using D's templates and module system
in place of the old macro/prefix conventions.

## Modules

- `fp.pointer` — the fat pointer core: `malloc`/`realloc`/`free`, stack
  allocation (`Array!(T, N)`), `valid`/`length`/`stackAllocated`/etc.
  Non-owning views are just native D slices (`pointer.slice(p)` or
  `p[a .. b]`) rather than a separate view type.
- `fp.dynarray` — growable arrays on top of `fp.pointer`
  (`reserve`, `pushBack`, `pushFront`, `insert`, `removeAt`, `clone`, ...).
- `fp.fnv1a` — FNV-1a hashing over a byte slice.
- `fp.hashtable` — a hopscotch-hashing open-addressing hash table on top of
  `fp.dynarray`.
- `fp.string` — null-terminated dynamic strings on top of `fp.dynarray`,
  with UTF-8 ⇄ UTF-32 conversion.


## Building

Requires [dub](https://dub.pm) and a D compiler — either DMD or LDC works
for compile-time-sized stack allocation (`Array!(T, N)`, a plain struct
with inline storage). The runtime-sized `pointer.alloca` mixin, however,
needs a real `alloca()` call, and DMD fails to inline it under `-betterC`
on Linux (a known compiler bug, [dlang/dmd#18276](https://github.com/dlang/dmd/issues/18276)),
so use LDC to build and test:

```sh
dub build --config=library --compiler=ldc2   # build the static library
dub test --compiler=ldc2                     # build and run the unittests
```

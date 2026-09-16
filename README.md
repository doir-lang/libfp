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

## Testing

`-betterC` has no unittest runner of its own, so
[tests/runner.d](tests/runner.d) walks each `fp` module with
`__traits(getUnitTests)` and calls the tests itself. It reports each
module and test index to `stderr` as it goes — `stderr` is unbuffered, so
a test that hangs or aborts still leaves a record of how far the run got —
and prints the total at the end.

The `unittest` configuration is the default for `dub test`, so a bare
`dub test --compiler=ldc2` picks up the runner. Note that `dub test -c`
with a *non-default* configuration substitutes dub's own druntime-based
`main`, which registers nothing under `-betterC` and then reports success
having run no tests; build and run such a configuration directly instead.

## Coverage

```sh
tools/coverage.sh        # per-module summary
tools/coverage.sh -v     # ... and every uncovered line
DC=dmd tools/coverage.sh # measure with DMD instead of the default LDC
```

`-cov` records its line counts through druntime, which `-betterC` does not
have, so the script builds the same sources and the same tests as ordinary
D — `tests/runner.d` supplies a druntime `main` when `LibfpCoverage` is
set, and disables druntime's own test pass so the tests still run exactly
once. It asks `dub describe` where the sources and import paths are rather
than repeating `dub.json`, and drops any dependency's `.lst` files from the
report so the numbers cover libfp only.

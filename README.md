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
- `fp.pagedarray` — a growable array of fixed-size pages whose elements
  never move, for pointers that must survive further appends. A plain
  struct with a runtime element size rather than a fat pointer.
- `fp.fnv1a` — FNV-1a hashing over a byte slice.
- `fp.hashtable` — a hopscotch-hashing open-addressing hash table on top of
  `fp.dynarray`.
- `fp.string` — null-terminated dynamic strings on top of `fp.dynarray`,
  with UTF-8 ⇄ UTF-32 conversion.


## Building

Requires [dub](https://dub.pm) and LDC. DMD is refused at compile time by a
`static assert` in `fp.pointer`, which covers everything built on libfp too:
the stack it serves (Mizu, and the DOIR compiler on top of it) is LDC-only,
and the `alloca` mixin needs a real `alloca()` call that DMD cannot emit
under `-betterC` ([dlang/dmd#18276](https://github.com/dlang/dmd/issues/18276)).
`-version=FpAllowDMD` lowers the error for tools that only analyse the
sources (`dmd -o-` syntax checks, ddoc) and never run what they build.

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
```

`-cov` records its line counts through druntime, which `-betterC` does not
have, so the script builds the same sources and the same tests as ordinary
D — `tests/runner.d` supplies a druntime `main` when `LibfpCoverage` is
set, and disables druntime's own test pass so the tests still run exactly
once. It asks `dub describe` where the sources and import paths are rather
than repeating `dub.json`, and drops any dependency's `.lst` files from the
report so the numbers cover libfp only.

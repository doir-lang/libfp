# libfp

A `-betterC` D library of "fat pointers": `malloc`-backed allocations that hide a small header (a pointer-type tag + length, and for dynarrays/hash tables, capacity/config) immediately before the pointer handed back to the caller — so the result is still a plain `T*`, usable with ordinary indexing, while `pointer.length(p)`, `pointer.valid(p)`, etc. recover the metadata by walking backward from the pointer.

Ported from an earlier C/C++ implementation (parallel C-macro and C++ template APIs) into a single D API, using D's templates and module system in place of the old macro/prefix conventions.

## Modules

- `fp.pointer` — the fat pointer core: `malloc`/`realloc`/`free`, stack allocation (`Array!(T, N)`), `valid`/`length`/`stackAllocated`/etc.
  Non-owning views are just native D slices (`pointer.slice(p)` or `p[a .. b]`) rather than a separate view type.
- `fp.lifecycle` — how containers copy, move and end their elements: `isBitMoveable`, `moveInto`, `copyInto`, `swapInto`, `endLifetime`, and the `Owned` wrapper for a container that should free its fat pointer elements.
- `fp.dynarray` — growable arrays on top of `fp.pointer` (`reserve`, `pushBack`, `pushFront`, `insert`, `removeAt`, `clone`, ...).
- `fp.pagedarray` — a growable array of fixed-size pages whose elements never move, for pointers that must survive further appends.
  A plain struct with a runtime element size rather than a fat pointer.
- `fp.hash` — `murmur`, MurmurHash3 and the hash table's default; `fnv1a`; and `mix`, for chaining a hash over several values.
- `fp.hashtable` — a hopscotch-hashing open-addressing hash table on top of `fp.dynarray`.
- `fp.string` — null-terminated dynamic strings on top of `fp.dynarray`, with UTF-8 ⇄ UTF-32 conversion and UTF-16 lengths.
- `fp.file` — whole files: reading one into an `fp.string`, writing or appending to one, and mapping one into memory, read-only or writable; on WASI, which has no real mapping, a mapped file is read into memory instead.
- `fp.rope` — text as a persistent rope: immutable versions sharing the leaves an edit leaves alone, with edits and line lookups in O(log n).
- `fp.testing` — helpers for tests of code built on libfp, such as an allocator that refuses after a given number of allocations.

## Imports

`import fp;` brings in every module, so `fp.dynarray.pushBack(arr, 1)` and `fp.string.free(text)` both work. The names several modules share (`free`, `length`, `create`, `capacity`, `find`, `insert`, ...) are ambiguous unqualified and must be written with their module. Importing one module on its own, `import fp.dynarray;`, gives its names unqualified but leaves the other layers out of scope until they are imported too.


## Building

Requires [dub](https://dub.pm) and LDC.
DMD is refused at compile time by a `static assert` in `fp.pointer`, which covers everything built on libfp too: the stack it serves (Mizu, and the DOIR compiler on top of it) is LDC-only, and the `alloca` mixin needs a real `alloca()` call that DMD cannot emit under `-betterC` ([dlang/dmd#18276](https://github.com/dlang/dmd/issues/18276)).
`-version=FpAllowDMD` lowers the error for tools that only analyse the sources (`dmd -o-` syntax checks, ddoc) and never run what they build.

```sh
dub build --config=library --compiler=ldc2   # build the static library
dub test --compiler=ldc2                     # build and run the unittests
```

## Testing

`-betterC` has no unittest runner of its own, so [tests/runner.d](tests/runner.d) walks each `fp` module with `__traits(getUnitTests)` and calls the tests itself.
It reports each module and test index to `stderr` as it goes — `stderr` is unbuffered, so a test that hangs or aborts still leaves a record of how far the run got — and prints the total at the end.

The `unittest` configuration is the default for `dub test`, so a bare `dub test --compiler=ldc2` picks up the runner.
Note that `dub test -c` with a *non-default* configuration substitutes dub's own druntime-based `main`, which registers nothing under `-betterC` and then reports success having run no tests; build and run such a configuration directly instead.

## WebAssembly

```sh
python3 tools/wasi.py --serve    # build for wasm32-wasi and serve a page that runs the tests in a browser
python3 tools/wasi.py --node     # build and run the same tests headlessly under Node
```

The script builds the unittests with LDC for `wasm32-wasip1-threads`, linking against [wasi-sdk](https://github.com/WebAssembly/wasi-sdk)'s libc, which it downloads into `bin/wasi-sdk` on first use (or set `WASI_SYSROOT` and `WASI_BUILTINS`).
The tests run through [@bjorn3/browser_wasi_shim](https://github.com/bjorn3/browser_wasi_shim)'s WASI, whose in-memory filesystem gives the file tests an empty `/tmp`, and [@emnapi/wasi-threads](https://github.com/toyobayashi/emnapi/tree/main/packages/wasi-threads); the script installs both into `bin/wasi`, where the page and [tests/wasi/node.mjs](tests/wasi/node.mjs) import them alike, so CI covers the browser path's WASI layer too.
[tests/wasi/run.mjs](tests/wasi/run.mjs) runs the tests on a worker, which reports its output and exit status over a `BroadcastChannel`, and `--serve` sends the cross-origin isolation headers that the build's shared memory needs.
Output arrives a line at a time.
A failed assertion aborts, which in wasm is a trap; the runner reports it as exit status 134.

## Coverage

```sh
python3 tools/coverage.py        # per-module summary
python3 tools/coverage.py -v     # ... and every uncovered line
```

`-cov` records its line counts through druntime, which `-betterC` does not have, so the script builds the same sources and the same tests as ordinary D — `tests/runner.d` supplies a druntime `main` when `LibfpCoverage` is set, and disables druntime's own test pass so the tests still run exactly once.
It asks `dub describe` where the sources and import paths are rather than repeating `dub.json`, and drops any dependency's `.lst` files from the report so the numbers cover libfp only.

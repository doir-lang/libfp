/// Helpers for tests of code built on libfp: an allocator that refuses on demand, so every path that handles a refused allocation can be reached, and temporary files.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// int* list = null;
/// auto previous = limitAllocations(0);
/// assert(!fp.dynarray.pushBack(list, 1));
/// restoreAllocator(previous);
/// assert(fp.dynarray.pushBack(list, 1));
/// fp.dynarray.free(list);
/// ---
module fp.testing;

static import core.stdc.stdio;
static import std.typecons;

static import fp.dynarray;
static import fp.io;
static import fp.pointer;
static import fp.string;
static import fp.string.utf;


// --- running tests ---------------------------------------------------------------

/// Runs every unittest of each module named in `modules`, in order, printing each module's name and test count and each test's index to stderr as it goes, then `<project>: all N tests passed.` to stdout. A failing test aborts through its assert. Returns how many tests ran. It is outside this module's `@nogc nothrow` label, so it runs tests with any attributes.
///
/// Examples:
/// ---
/// // tests/runner.d of a project whose modules are `app.parse` and `app.check`:
/// // extern(C) int main() { cast(void) fp.testing.runTests!("app.parse", "app.check")("app"); return 0; }
/// static assert(__traits(compiles, runTests!("fp.algorithms")("libfp")));
/// ---
size_t runTests(modules...)(const(char)[] project) {
	static import core.stdc.stdio;
	size_t total = 0;
	static foreach (name; modules) {{
		alias mod = imported!name;
		alias tests = __traits(getUnitTests, mod);
		cast(void) core.stdc.stdio.fprintf(core.stdc.stdio.stderr, "%s (%d tests)\n", name.ptr, cast(int) tests.length);
		static foreach (i, test; tests) {
			cast(void) core.stdc.stdio.fprintf(core.stdc.stdio.stderr, "  [%d] ", cast(int) i);
			test();
			cast(void) core.stdc.stdio.fprintf(core.stdc.stdio.stderr, "ok\n");
			++total;
		}
	}}
	cast(void) core.stdc.stdio.printf("%.*s: all %d tests passed.\n", cast(int) project.length, project.ptr, cast(int) total);
	return total;
}


@nogc nothrow:


// --- refused allocations -----------------------------------------------------

private __gshared fp.pointer.Allocator rationedUnderlying;
private __gshared size_t rationedRemaining;

private void* rationedAllocator(void* p, size_t size) {
	// Frees are always forwarded, or a test could not clean up after itself.
	if (size == 0) return rationedUnderlying(p, 0);
	if (rationedRemaining == 0) return null;
	--rationedRemaining;
	return rationedUnderlying(p, size);
}

/// Makes `fp.pointer.allocator` grant only the next `n` allocations and refuse the rest, while still freeing, and returns the allocator it replaced; pass that to `restoreAllocator` to restore it. It is one global for every thread, so tests using it must not run concurrently with anything that allocates.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// auto previous = limitAllocations(1);
/// int* granted = fp.dynarray.create!int(1);
/// assert(granted !is null && fp.dynarray.create!int(1) is null);
/// fp.dynarray.free(granted);
/// restoreAllocator(previous);
/// ---
fp.pointer.Allocator limitAllocations(size_t n = 0) {
	fp.pointer.Allocator previous = fp.pointer.allocator;
	rationedUnderlying = previous;
	rationedRemaining = n;
	fp.pointer.allocator = &rationedAllocator;
	return previous;
}

/// Restores the allocator `limitAllocations` returned.
///
/// Examples:
/// ---
/// static import fp.pointer;
/// auto previous = limitAllocations();
/// restoreAllocator(previous);
/// assert(fp.pointer.allocator is previous);
/// ---
void restoreAllocator(fp.pointer.Allocator previous) {
	fp.pointer.allocator = previous;
}


// --- temporary files ---------------------------------------------------------

/// The directory for temporary files, as a new fp string the caller frees, without a trailing separator: `GetTempPathW`'s on Windows, `/tmp` on WASI, and `TMPDIR` or else `/tmp` elsewhere.
///
/// Returns null if Windows cannot name it or an allocation is refused.
///
/// Examples:
/// ---
/// static import fp.string;
/// char* directory = temporaryDirectory();
/// assert(directory !is null && fp.string.length(directory) > 0);
/// fp.string.free(directory);
/// ---
char* temporaryDirectory() @trusted {
	version(Windows) {
		static import core.sys.windows.winbase;
		static import core.sys.windows.windef;
		wchar[core.sys.windows.windef.MAX_PATH + 1] buffer;
		// A result as long as the buffer is the length it would need, not a path.
		immutable length = core.sys.windows.winbase.GetTempPathW(cast(uint) buffer.length, buffer.ptr);
		if (length == 0 || length >= buffer.length) return null;
		const(wchar)[] path = buffer[0 .. length];
		while (path.length > 1 && (path[$ - 1] == '\\' || path[$ - 1] == '/')) path = path[0 .. $ - 1];
		return fp.string.utf.fromUtf16(path).get(null);
	} else {
		version(WASI) const(char)[] path = "/tmp";
		else {
			static import core.stdc.stdlib;
			static import core.stdc.string;
			const(char)* variable = core.stdc.stdlib.getenv("TMPDIR");
			const(char)[] path = variable is null || *variable == 0 ? "/tmp" : variable[0 .. core.stdc.string.strlen(variable)];
		}
		while (path.length > 1 && path[$ - 1] == '/') path = path[0 .. $ - 1];
		return fp.string.clone(path).get(null);
	}
}

version(WASI) private __gshared size_t temporaryFiles;

/// Creates an empty file with a name no other file has in `temporaryDirectory`, and returns its path as a new fp string. The caller removes the file, as with `fp.io.removeFile`, and frees the path.
///
/// Returns null if the file cannot be created or an allocation is refused, leaving no file behind.
///
/// Examples:
/// ---
/// static import fp.io;
/// static import fp.string;
/// char* path = temporaryFile();
/// assert(path !is null && fp.io.removeFile(fp.string.slice(path)));
/// fp.string.free(path);
/// ---
char* temporaryFile() @trusted {
	char* directory = temporaryDirectory();
	if (directory is null) return null;
	scope(exit) fp.string.free(directory);
	version(Windows) {
		static import core.sys.windows.winbase;
		static import core.sys.windows.windef;
		wchar* wideDirectory = fp.string.utf.toUtf16(directory).get(null);
		if (wideDirectory is null) return null;
		scope(exit) fp.dynarray.free(wideDirectory);
		wchar[core.sys.windows.windef.MAX_PATH + 1] wide = 0;
		// GetTempFileNameW creates the file, so the name is ours.
		if (core.sys.windows.winbase.GetTempFileNameW(wideDirectory, "fp"w.ptr, 0, wide.ptr) == 0) return null;
		size_t length = 0;
		while (wide[length] != 0) ++length;
		char* path = fp.string.utf.fromUtf16(wide[0 .. length]).get(null);
		if (path is null) cast(void) core.sys.windows.winbase.DeleteFileW(wide.ptr);
		return path;
	} else version(WASI) {
		static import core.stdc.stdio;
		// Without mkstemp, a counter names candidates, and opening with "x" refuses one that exists.
		foreach (attempt; 0 .. 1000) {
			auto made = fp.string.joined(directory, "/fp-", temporaryFiles++);
			if (made.isNull) return null;
			char* path = made.get;
			auto f = core.stdc.stdio.fopen(path, "wbx");
			if (f !is null) {
				cast(void) core.stdc.stdio.fclose(f);
				return path;
			}
			fp.string.free(path);
		}
		return null;
	} else {
		static import core.sys.posix.stdlib;
		static import core.sys.posix.unistd;
		auto made = fp.string.joined(directory, "/fp-XXXXXX");
		if (made.isNull) return null;
		char* path = made.get;
		immutable descriptor = core.sys.posix.stdlib.mkstemp(path);
		if (descriptor < 0) {
			fp.string.free(path);
			return null;
		}
		cast(void) core.sys.posix.unistd.close(descriptor);
		return path;
	}
}

/// A temporary file open for writing, as `openScratchFile` makes it, for a test to print into through `descriptor` and read back from `path`; `free` closes and removes it.
struct ScratchFile {
	char* path; /// The file's path, an fp string.
	int descriptor; /// A descriptor writing to the file, from its start.
	private core.stdc.stdio.FILE* file;
}

/// Creates a temporary file, as `temporaryFile` does, and opens it for writing.
///
/// Returns null if the file cannot be created or opened or an allocation is refused, leaving no file behind.
///
/// Examples:
/// ---
/// static import fp.io;
/// auto scratch = openScratchFile();
/// assert(!scratch.isNull);
/// scope(exit) free(scratch.get);
/// assert(fp.io.writeAll(scratch.get.descriptor, "printed"));
/// ---
std.typecons.Nullable!ScratchFile openScratchFile() @trusted {
	ScratchFile scratch;
	scratch.path = temporaryFile();
	if (scratch.path is null) return typeof(return).init;
	scratch.file = core.stdc.stdio.fopen(scratch.path, "wb");
	if (scratch.file is null) {
		cast(void) fp.io.removeFile(fp.string.slice(scratch.path));
		fp.string.free(scratch.path);
		return typeof(return).init;
	}
	scratch.descriptor = core.stdc.stdio.fileno(scratch.file);
	return typeof(return)(scratch);
}

/// Closes and removes the file `scratch` names, and frees its path, leaving `scratch` empty. It cannot fail.
///
/// Examples:
/// ---
/// auto scratch = openScratchFile();
/// assert(!scratch.isNull);
/// free(scratch.get);
/// assert(scratch.get.path is null);
/// ---
void free(ref ScratchFile scratch) @trusted {
	cast(void) core.stdc.stdio.fclose(scratch.file);
	cast(void) fp.io.removeFile(fp.string.slice(scratch.path));
	fp.string.free(scratch.path);
	scratch = ScratchFile.init;
}


// --- catching abort ----------------------------------------------------------

/// Whether `aborts` exists: on WASI `abort` traps, ending every thread, so nothing can catch it.
///
/// Examples:
/// ---
/// static if (catchesAborts) assert(!aborts(() {}));
/// ---
version(WASI) enum bool catchesAborts = false;
else enum bool catchesAborts = true;

// druntime passes `sigjmp_buf` by value and lacks it on Darwin, so these take an oversized buffer by pointer.
version(WASI) {} else version(Posix) {
	static import core.sys.posix.signal;

	// glibc and uClibc export only `__sigsetjmp`, their `sigsetjmp` being a macro around it.
	version(CRuntime_Glibc) version = FpUnderscoredSigsetjmp;
	else version(CRuntime_UClibc) version = FpUnderscoredSigsetjmp;

	version(FpUnderscoredSigsetjmp) private extern(C) int __sigsetjmp(void* buffer, int saveMask);
	else private extern(C) int sigsetjmp(void* buffer, int saveMask);
	private extern(C) void siglongjmp(void* buffer, int value);

	// Larger than any C library's `sigjmp_buf`: glibc's on PowerPC, the biggest, is just under 600 bytes.
	private __gshared align(16) ubyte[1024] abortEscape;
} else version(Windows) {
	// The MS C runtime calls a `SIGABRT` handler from inside `abort`, so a plain `longjmp` leaves it; a null frame skips SEH unwinding.
	private extern(C) int _setjmp(void* buffer, void* frame);
	private extern(C) void longjmp(void* buffer, int value);

	// `core.stdc.signal` declares `signal` without `@nogc nothrow`, so bind it here. `SIGABRT` is 22 on Windows.
	private alias AbortHandler = extern(C) void function(int) @nogc nothrow;
	private extern(C) AbortHandler signal(int sig, AbortHandler handler);
	private enum int windowsSigabrt = 22;

	// x86-64's `jmp_buf`, the largest, is 256 bytes.
	private __gshared align(16) ubyte[512] abortEscape;
}

version(WASI) {} else {
	private extern(C) void onAbort(int) {
		// Windows resets a handler to the default as it raises, so reinstall it to keep one arming good for any number of aborts.
		version(Windows) cast(void) signal(windowsSigabrt, &onAbort);
		version(Posix) siglongjmp(abortEscape.ptr, 1);
		else version(Windows) longjmp(abortEscape.ptr, 1);
	}

	/// Runs `attempt` and reports whether it called C's `abort`, as `fp.io.abort` does, by catching its `SIGABRT` and jumping back out of the handler. An abort abandons `attempt` where it stood: its `scope(exit)` blocks do not run and what it allocated leaks, so keep it small. It cannot fail; it asserts if the handler cannot be installed. It exists only where `catchesAborts` is true.
	///
	/// Examples:
	/// ---
	/// static import fp.io;
	/// static if (catchesAborts) {
	/// 	assert(aborts(() { fp.io.abort("fp.testing: an expected abort\n"); }));
	/// 	assert(!aborts(() {}));
	/// }
	/// ---
	bool aborts(scope void delegate() @nogc nothrow attempt) @trusted {
		version(Posix) {
			core.sys.posix.signal.sigaction_t action, saved;
			assert(core.sys.posix.signal.sigemptyset(&action.sa_mask) == 0);
			action.sa_handler = &onAbort;
			assert(core.sys.posix.signal.sigaction(core.sys.posix.signal.SIGABRT, &action, &saved) == 0);
		} else version(Windows) {
			auto saved = signal(windowsSigabrt, &onAbort);
		}

		// `setjmp` records the frame it was called from, so it must be called here, in the frame being returned to.
		version(FpUnderscoredSigsetjmp) immutable landed = __sigsetjmp(abortEscape.ptr, 1) != 0;
		else version(Posix) immutable landed = sigsetjmp(abortEscape.ptr, 1) != 0;
		else version(Windows) immutable landed = _setjmp(abortEscape.ptr, null) != 0;

		// `__gshared` because a local's value across a `longjmp` is whatever the optimiser left in its register.
		__gshared bool aborted;
		aborted = true;
		if (!landed) {
			attempt();
			aborted = false;
		}

		version(Posix) assert(core.sys.posix.signal.sigaction(core.sys.posix.signal.SIGABRT, &saved, null) == 0);
		else version(Windows) cast(void) signal(windowsSigabrt, saved);
		return aborted;
	}
}


unittest { // a ration counts allocations, never frees, and ends with the allocator it replaced
	static import fp.dynarray;
	auto previous = limitAllocations(2);
	int* a = fp.dynarray.create!int(1), b = fp.dynarray.create!int(1);
	assert(a !is null && b !is null && fp.dynarray.create!int(1) is null);
	fp.dynarray.free(a);
	assert(fp.dynarray.create!int(1) is null);
	restoreAllocator(previous);
	assert(fp.pointer.allocator is previous);
	fp.dynarray.free(b);
}

unittest { // temporary files are new, empty and distinct, inside a directory named without a trailing separator, and scratch files print into one
	char* directory = temporaryDirectory();
	assert(directory !is null);
	scope(exit) fp.string.free(directory);
	immutable last = fp.string.slice(directory)[$ - 1];
	assert(last != '/' && last != '\\');

	char* first = temporaryFile(), second = temporaryFile();
	assert(first !is null && second !is null && !fp.string.equal(first, second));
	assert(fp.string.slice(first)[0 .. fp.string.length(directory)] == fp.string.slice(directory));
	auto empty = fp.io.readFile(fp.string.slice(first));
	assert(!empty.isNull && empty.get is null);
	assert(fp.io.removeFile(fp.string.slice(first)) && fp.io.removeFile(fp.string.slice(second)));
	fp.string.free(first);
	fp.string.free(second);

	auto scratch = openScratchFile();
	assert(!scratch.isNull);
	char* scratchPath = fp.string.clone(scratch.get.path).get;
	scope(exit) fp.string.free(scratchPath);
	assert(fp.io.writeAll(scratch.get.descriptor, "printed"));
	auto printed = fp.io.readFile(fp.string.slice(scratchPath));
	assert(!printed.isNull && fp.string.equal(printed.get, "printed"));
	fp.string.free(printed.get);
	free(scratch.get);
	assert(scratch.get.path is null && fp.io.readFile(fp.string.slice(scratchPath)).isNull);
	auto refused = limitAllocations(0);
	immutable refusedScratch = openScratchFile().isNull;
	restoreAllocator(refused);
	assert(refusedScratch);

	for (size_t budget = 0;; ++budget) {
		auto previous = limitAllocations(budget);
		char* rationed = temporaryFile();
		restoreAllocator(previous);
		if (rationed is null) continue;
		assert(fp.io.removeFile(fp.string.slice(rationed)));
		fp.string.free(rationed);
		break;
	}

	// A directory that does not exist holds no file.
	version(Posix) { version(WASI) {} else {
		static import core.stdc.stdlib;
		static import core.sys.posix.stdlib;
		const(char)* saved = core.stdc.stdlib.getenv("TMPDIR");
		char* kept = saved is null ? null : fp.string.clone(fp.string.slice(saved)).get(null);
		scope(exit) fp.string.free(kept);
		assert(saved is null || kept !is null);
		assert(core.sys.posix.stdlib.setenv("TMPDIR", "/nonexistent-fp-directory", 1) == 0);
		assert(temporaryFile() is null && openScratchFile().isNull);
		assert((kept is null ? core.sys.posix.stdlib.unsetenv("TMPDIR") : core.sys.posix.stdlib.setenv("TMPDIR", kept, 1)) == 0);
	}}
}

version(WASI) {} else unittest { // aborts are caught one after another, each putting the handler back, and an attempt that returns did not abort
	static import fp.io;
	assert(aborts(() { fp.io.abort("fp.testing: an expected abort\n"); }));
	assert(aborts(() { fp.io.abort("fp.testing: another expected abort\n"); }));
	assert(!aborts(() {}));
}

/// Helpers for tests of code built on libfp: an allocator that refuses on demand, so every path that handles a refused allocation can be reached, and temporary files.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// int* list = null;
/// auto previous = beginRationedAllocator(0);
/// assert(!fp.dynarray.pushBack(list, 1));
/// endRationedAllocator(previous);
/// assert(fp.dynarray.pushBack(list, 1));
/// fp.dynarray.free(list);
/// ---
module fp.testing;

static import fp.dynarray;
static import fp.pointer;
static import fp.string;

@nogc nothrow:


// --- refused allocations -----------------------------------------------------

private __gshared fp.pointer.AllocFunction rationedUnderlying;
private __gshared size_t rationedRemaining;

private void* rationedAlloc(void* p, size_t size) {
	// Frees are always forwarded, or a test could not clean up after itself.
	if (size == 0) return rationedUnderlying(p, 0);
	if (rationedRemaining == 0) return null;
	--rationedRemaining;
	return rationedUnderlying(p, size);
}

/// Makes `fp.pointer.allocFunction` grant only the next `n` allocations and refuse the rest, while still freeing, and returns the allocator it replaced; pass that to `endRationedAllocator` to restore it. It is one global for every thread, so tests using it must not run concurrently with anything that allocates.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// auto previous = beginRationedAllocator(1);
/// int* granted = fp.dynarray.create!int(1);
/// assert(granted !is null && fp.dynarray.create!int(1) is null);
/// fp.dynarray.free(granted);
/// endRationedAllocator(previous);
/// ---
fp.pointer.AllocFunction beginRationedAllocator(size_t n = 0) {
	fp.pointer.AllocFunction previous = fp.pointer.allocFunction;
	rationedUnderlying = previous;
	rationedRemaining = n;
	fp.pointer.allocFunction = &rationedAlloc;
	return previous;
}

/// Restores the allocator `beginRationedAllocator` returned.
///
/// Examples:
/// ---
/// static import fp.pointer;
/// auto previous = beginRationedAllocator();
/// endRationedAllocator(previous);
/// assert(fp.pointer.allocFunction is previous);
/// ---
void endRationedAllocator(fp.pointer.AllocFunction previous) {
	fp.pointer.allocFunction = previous;
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
		return fp.string.fromUtf16(path);
	} else {
		version(WASI) const(char)[] path = "/tmp";
		else {
			static import core.stdc.stdlib;
			static import core.stdc.string;
			const(char)* variable = core.stdc.stdlib.getenv("TMPDIR");
			const(char)[] path = variable is null || *variable == 0 ? "/tmp" : variable[0 .. core.stdc.string.strlen(variable)];
		}
		while (path.length > 1 && path[$ - 1] == '/') path = path[0 .. $ - 1];
		return fp.string.makeDynamic(path);
	}
}

version(WASI) private __gshared size_t temporaryFiles;

/// Creates an empty file with a name no other file has in `temporaryDirectory`, and returns its path as a new fp string. The caller removes the file, as with `fp.file.removeFile`, and frees the path.
///
/// Returns null if the file cannot be created or an allocation is refused, leaving no file behind.
///
/// Examples:
/// ---
/// static import fp.file;
/// static import fp.string;
/// char* path = temporaryFile();
/// assert(path !is null && fp.file.removeFile(fp.string.slice(path)));
/// fp.string.free(path);
/// ---
char* temporaryFile() @trusted {
	char* directory = temporaryDirectory();
	if (directory is null) return null;
	scope(exit) fp.string.free(directory);
	version(Windows) {
		static import core.sys.windows.winbase;
		static import core.sys.windows.windef;
		wchar* wideDirectory = fp.string.utf16(directory);
		if (wideDirectory is null) return null;
		scope(exit) fp.dynarray.free(wideDirectory);
		wchar[core.sys.windows.windef.MAX_PATH + 1] wide = 0;
		// GetTempFileNameW creates the file, so the name is ours.
		if (core.sys.windows.winbase.GetTempFileNameW(wideDirectory, "fp"w.ptr, 0, wide.ptr) == 0) return null;
		size_t length = 0;
		while (wide[length] != 0) ++length;
		char* path = fp.string.fromUtf16(wide[0 .. length]);
		if (path is null) cast(void) core.sys.windows.winbase.DeleteFileW(wide.ptr);
		return path;
	} else version(WASI) {
		static import core.stdc.stdio;
		// Without mkstemp, a counter names candidates, and opening with "x" refuses one that exists.
		foreach (attempt; 0 .. 1000) {
			char* path = fp.string.createFromConcatenation(directory, "/fp-", temporaryFiles++);
			if (path is null) return null;
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
		char* path = fp.string.createFromConcatenation(directory, "/fp-XXXXXX");
		if (path is null) return null;
		immutable fd = core.sys.posix.stdlib.mkstemp(path);
		if (fd < 0) {
			fp.string.free(path);
			return null;
		}
		cast(void) core.sys.posix.unistd.close(fd);
		return path;
	}
}


unittest { // a ration counts allocations, never frees, and ends with the allocator it replaced
	static import fp.dynarray;
	auto previous = beginRationedAllocator(2);
	int* a = fp.dynarray.create!int(1), b = fp.dynarray.create!int(1);
	assert(a !is null && b !is null && fp.dynarray.create!int(1) is null);
	fp.dynarray.free(a);
	assert(fp.dynarray.create!int(1) is null);
	endRationedAllocator(previous);
	assert(fp.pointer.allocFunction is previous);
	fp.dynarray.free(b);
}

unittest { // temporary files are new, empty and distinct, inside a directory named without a trailing separator
	static import fp.file;
	char* directory = temporaryDirectory();
	assert(directory !is null);
	scope(exit) fp.string.free(directory);
	immutable last = fp.string.slice(directory)[$ - 1];
	assert(last != '/' && last != '\\');

	char* first = temporaryFile(), second = temporaryFile();
	assert(first !is null && second !is null && !fp.string.equal(first, second));
	assert(fp.string.slice(first)[0 .. fp.string.length(directory)] == fp.string.slice(directory));
	auto empty = fp.file.readFile(fp.string.slice(first));
	assert(!empty.isNull && empty.get is null);
	assert(fp.file.removeFile(fp.string.slice(first)) && fp.file.removeFile(fp.string.slice(second)));
	fp.string.free(first);
	fp.string.free(second);

	for (size_t budget = 0;; ++budget) {
		auto previous = beginRationedAllocator(budget);
		char* rationed = temporaryFile();
		endRationedAllocator(previous);
		if (rationed is null) continue;
		assert(fp.file.removeFile(fp.string.slice(rationed)));
		fp.string.free(rationed);
		break;
	}

	// A directory that does not exist holds no file.
	version(Posix) { version(WASI) {} else {
		static import core.stdc.stdlib;
		static import core.sys.posix.stdlib;
		const(char)* saved = core.stdc.stdlib.getenv("TMPDIR");
		char* kept = saved is null ? null : fp.string.makeDynamic(fp.string.slice(saved));
		scope(exit) fp.string.free(kept);
		assert(saved is null || kept !is null);
		assert(core.sys.posix.stdlib.setenv("TMPDIR", "/nonexistent-fp-directory", 1) == 0);
		assert(temporaryFile() is null);
		assert((kept is null ? core.sys.posix.stdlib.unsetenv("TMPDIR") : core.sys.posix.stdlib.setenv("TMPDIR", kept, 1)) == 0);
	}}
}

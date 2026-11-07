/// Whole files: reading one into an fp string, writing, appending to or removing one, and mapping one into memory, read-only or writable. And open descriptors, such as stdin and stdout: reading what has arrived, and writing.
///
/// Examples:
/// ---
/// static import fp.string;
/// auto text = readFile("dub.json");
/// assert(!text.isNull && fp.string.length(text.get) > 0);
/// fp.string.free(text.get);
/// auto mapped = map("dub.json");
/// assert(!mapped.isNull && mapped.get.bytes.length > 0);
/// free(mapped.get);
/// ---
module fp.file;

static import core.stdc.errno;
static import core.stdc.stdio;

static import std.typecons;

static import fp.dynarray;
static import fp.string;
static import fp.string.utf;

version(Windows) {} else static import core.sys.posix.unistd;

// WASI's mmap only emulates a mapping by reading the file, which the fallback here does without an extra library.
version(WASI) {} else version(Posix) {
	version = memoryMapping;
	version = posixMapping;
} else version(Windows) {
	version = memoryMapping;
	version = windowsMapping;
}

@nogc nothrow:


// --- reading -----------------------------------------------------------------

version(Windows) private extern(C) core.stdc.stdio.FILE* _wfopen(const(wchar)* path, const(wchar)* mode);

// The file at `path` opened in C `mode`, or null if it cannot be or the path's copy is refused.
private core.stdc.stdio.FILE* open(const(char)[] path, const(char)* mode) @trusted {
	version(Windows) {
		// fopen would read `path` in the ANSI code page rather than as UTF-8.
		wchar* name = fp.string.utf.toUtf16(path).get(null);
		if (name is null) return null;
		scope(exit) fp.dynarray.free(name);
		wchar[4] wideMode = 0;
		for (size_t i = 0; mode[i] != 0; ++i) {
			assert(i < wideMode.length - 1);
			wideMode[i] = mode[i];
		}
		return _wfopen(name, wideMode.ptr);
	} else {
		char* name = fp.string.clone(path).get(null);
		if (name is null) return null;
		scope(exit) fp.string.free(name);
		return core.stdc.stdio.fopen(name, mode);
	}
}

/// The whole of the file at `path`, as a new fp string the caller frees; an empty file is a null string.
///
/// Returns null if the file cannot be opened or read, `path` names a directory, or an allocation is refused.
///
/// Examples:
/// ---
/// assert(readFile("no/such/file").isNull);
/// ---
std.typecons.Nullable!(char*) readFile(const(char)[] path) {
	auto f = open(path, "rb");
	if (f is null) return typeof(return).init;
	scope(exit) cast(void) core.stdc.stdio.fclose(f); // reading only: a failed close changes nothing here
	// Read straight into the string, since a buffer of any useful size would overflow WASI's 64 KiB stack.
	size_t chunk = 65536;
	// Sized from the file's length where it has one, with a byte to spare so one read also meets the end.
	if (core.stdc.stdio.fseek(f, 0, core.stdc.stdio.SEEK_END) == 0) {
		immutable size = core.stdc.stdio.ftell(f);
		if (core.stdc.stdio.fseek(f, 0, core.stdc.stdio.SEEK_SET) != 0) return typeof(return).init;
		if (size > 0) chunk = size + 1;
	}
	char* out_ = null;
	for (;;) {
		immutable used = fp.dynarray.length(out_);
		if ((used == 0 ? fp.dynarray.growToSize(out_, chunk) : fp.dynarray.grow(out_, chunk)) is null) break;
		immutable n = core.stdc.stdio.fread(out_ + used, 1, chunk, f);
		cast(void) fp.dynarray.removeLast(out_, chunk - n);
		// Every allocation keeps a byte past its capacity for this terminator.
		out_[used + n] = 0;
		if (n < chunk) {
			if (core.stdc.stdio.ferror(f)) break;
			if (used + n == 0) fp.string.free(out_);
			return typeof(return)(out_);
		}
	}
	fp.string.free(out_);
	return typeof(return).init;
}


// --- writing -----------------------------------------------------------------

/// How `writeFile` treats a file that already exists.
enum WriteMode {
	replace, /// Its contents are replaced.
	append, /// `text` is added at its end.
}

/// Writes `text` to the file at `path`, creating the file if there is none; `mode` says whether an existing file's contents are replaced, the default, or appended to.
///
/// Returns false if the file cannot be opened, written or closed, or the path's copy is refused; a file that was opened may then hold part of `text`.
///
/// Examples:
/// ---
/// assert(writeFile("bin/fp-file-write-example", "a"));
/// assert(writeFile("bin/fp-file-write-example", "b", WriteMode.append));
/// static import fp.string;
/// auto written = readFile("bin/fp-file-write-example").get;
/// assert(fp.string.equal(written, "ab"));
/// fp.string.free(written);
/// assert(removeFile("bin/fp-file-write-example"));
/// assert(!writeFile("no/such/directory/file", "text"));
/// ---
bool writeFile(const(char)[] path, const(char)[] text, WriteMode mode = WriteMode.replace) {
	auto f = open(path, mode == WriteMode.append ? "ab" : "wb");
	if (f is null) return false;
	immutable wrote = core.stdc.stdio.fwrite(text.ptr, 1, text.length, f) == text.length;
	// A close can report a failed write the buffer was still holding.
	return (core.stdc.stdio.fclose(f) == 0) & wrote;
}

/// Switches the Windows console to UTF-8 output and ANSI escape processing, so colored UTF-8 text such as rendered diagnostics prints as intended; terminals elsewhere already handle both, so there it does nothing.
///
/// Returns false on Windows if standard output is not a console, such as when it is redirected, or the console refused either setting.
///
/// Examples:
/// ---
/// cast(void) enableAnsiColorsAndUTF8();
/// ---
bool enableAnsiColorsAndUTF8() @trusted {
	version(Windows) {
		static import core.sys.windows.windows;
		if (!core.sys.windows.windows.SetConsoleOutputCP(core.sys.windows.windows.CP_UTF8)) return false;
		auto output = core.sys.windows.windows.GetStdHandle(core.sys.windows.windows.STD_OUTPUT_HANDLE);
		core.sys.windows.windows.DWORD mode = 0;
		if (output == core.sys.windows.windows.INVALID_HANDLE_VALUE || !core.sys.windows.windows.GetConsoleMode(output, &mode)) return false;
		return core.sys.windows.windows.SetConsoleMode(output, mode | core.sys.windows.windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0;
	} else return true;
}

version(Windows) private extern(C) int _wremove(const(wchar)* path);

/// Removes the file at `path`.
///
/// Returns false if it cannot be removed, such as when there is none, or the path's copy is refused.
///
/// Examples:
/// ---
/// assert(writeFile("bin/fp-file-remove-example", "x"));
/// assert(removeFile("bin/fp-file-remove-example"));
/// assert(!removeFile("bin/fp-file-remove-example"));
/// ---
bool removeFile(const(char)[] path) @trusted {
	version(Windows) {
		wchar* name = fp.string.utf.toUtf16(path).get(null);
		if (name is null) return false;
		scope(exit) fp.dynarray.free(name);
		return _wremove(name) == 0;
	} else {
		char* name = fp.string.clone(path).get(null);
		if (name is null) return false;
		scope(exit) fp.string.free(name);
		return core.stdc.stdio.remove(name) == 0;
	}
}


// --- mapping -----------------------------------------------------------------

/// A file mapped into memory read-only, released by `free`. Where memory mapping is unavailable, as on WASI, the file is read into memory instead, which a reader cannot tell apart.
struct MappedFile {
	const(char)[] bytes; /// The file's contents; null for an empty file.
	private bool read; // whether `bytes` is an fp string `readFile` made rather than a mapping
}

/// A file mapped into memory for reading and writing, released by `free`. Where memory mapping is unavailable, as on WASI, the file is read into memory instead, and what is written reaches the file only through `sync` or `free`.
struct WritableMappedFile {
	char[] bytes; /// The file's contents, whose changes are written to it; null for an empty file.
	private char* path; // the fp string copy of the path that `sync` writes `bytes` back to, when they were read rather than mapped
	version(windowsMapping) private void* file; // the open file, which `sync` flushes to disk
}

version(posixMapping) {
	// The whole file at `path`, opened with `access` and mapped with `protection` and `flags`; empty for an empty file, null on failure.
	private std.typecons.Nullable!WritableMappedFile mapWith(const(char)[] path, int access, int protection, int flags) @trusted {
		static import core.sys.posix.fcntl;
		static import core.sys.posix.sys.mman;
		static import core.sys.posix.sys.stat;
		static import core.sys.posix.unistd;
		char* name = fp.string.clone(path).get(null);
		if (name is null) return typeof(return).init;
		scope(exit) fp.string.free(name);
		immutable descriptor = core.sys.posix.fcntl.open(name, access);
		if (descriptor < 0) return typeof(return).init;
		// The mapping keeps the file alive once it is made.
		scope(exit) cast(void) core.sys.posix.unistd.close(descriptor);
		core.sys.posix.sys.stat.stat_t status;
		if (core.sys.posix.sys.stat.fstat(descriptor, &status) != 0 || !core.sys.posix.sys.stat.S_ISREG(status.st_mode)) return typeof(return).init;
		if (status.st_size == 0) return typeof(return)(WritableMappedFile.init);
		auto p = core.sys.posix.sys.mman.mmap(null, cast(size_t) status.st_size, protection, flags, descriptor, 0);
		if (p == core.sys.posix.sys.mman.MAP_FAILED) return typeof(return).init;
		return typeof(return)(WritableMappedFile((cast(char*) p)[0 .. cast(size_t) status.st_size]));
	}
}

version(windowsMapping) {
	// Maps `path` opened with `access`, viewed with `protection` and `view`: empty for an empty file, null on failure; `keepFile` keeps the file open.
	private std.typecons.Nullable!WritableMappedFile mapWith(const(char)[] path, uint access, uint protection, uint view, bool keepFile) @trusted {
		static import core.sys.windows.winbase;
		static import core.sys.windows.winnt;
		wchar* name = fp.string.utf.toUtf16(path).get(null);
		if (name is null) return typeof(return).init;
		scope(exit) fp.dynarray.free(name);
		// Sharing everything matches POSIX, where a mapping locks nothing. Without backup semantics a directory does not open.
		auto file = core.sys.windows.winbase.CreateFileW(name, access, core.sys.windows.winnt.FILE_SHARE_READ | core.sys.windows.winnt.FILE_SHARE_WRITE | core.sys.windows.winnt.FILE_SHARE_DELETE, null, core.sys.windows.winbase.OPEN_EXISTING, core.sys.windows.winnt.FILE_ATTRIBUTE_NORMAL, null);
		if (file == core.sys.windows.winbase.INVALID_HANDLE_VALUE) return typeof(return).init;
		bool kept = false;
		scope(exit) if (!kept) cast(void) core.sys.windows.winbase.CloseHandle(file);
		long size;
		if (!core.sys.windows.winbase.GetFileSizeEx(file, cast(core.sys.windows.winnt.LARGE_INTEGER*) &size) || cast(ulong) size > size_t.max) return typeof(return).init;
		if (size == 0) return typeof(return)(WritableMappedFile.init);
		auto mapping = core.sys.windows.winbase.CreateFileMappingW(file, null, protection, 0, 0, null);
		if (mapping is null) return typeof(return).init;
		// The view keeps the mapping alive once it is made.
		scope(exit) cast(void) core.sys.windows.winbase.CloseHandle(mapping);
		auto p = core.sys.windows.winbase.MapViewOfFile(mapping, view, 0, 0, cast(size_t) size);
		if (p is null) return typeof(return).init;
		WritableMappedFile mapped;
		mapped.bytes = (cast(char*) p)[0 .. cast(size_t) size];
		if (keepFile) {
			mapped.file = file;
			kept = true;
		}
		return typeof(return)(mapped);
	}
}

/// The file at `path` mapped into memory read-only. Writes to the file while it is mapped may show through `bytes`. On POSIX, truncating it makes reading past its new end raise `SIGBUS`; on Windows, a write that would truncate it, such as `writeFile`, fails while it is mapped.
///
/// Returns null if the file cannot be opened, measured or mapped, `path` names a directory, or an allocation is refused.
///
/// Examples:
/// ---
/// assert(map("no/such/file").isNull);
/// ---
std.typecons.Nullable!MappedFile map(const(char)[] path) @trusted {
	version(posixMapping) {
		static import core.sys.posix.fcntl;
		static import core.sys.posix.sys.mman;
		auto mapped = mapWith(path, core.sys.posix.fcntl.O_RDONLY, core.sys.posix.sys.mman.PROT_READ, core.sys.posix.sys.mman.MAP_PRIVATE);
	} else version(windowsMapping) {
		static import core.sys.windows.winbase;
		static import core.sys.windows.winnt;
		auto mapped = mapWith(path, core.sys.windows.winnt.GENERIC_READ, core.sys.windows.winnt.PAGE_READONLY, core.sys.windows.winbase.FILE_MAP_READ, false);
	}
	version(memoryMapping) {
		if (mapped.isNull) return typeof(return).init;
		return typeof(return)(MappedFile(mapped.get.bytes));
	} else {
		auto text = readFile(path);
		if (text.isNull) return typeof(return).init;
		return typeof(return)(MappedFile(fp.string.slice(text.get), true));
	}
}

/// Releases what `map` mapped, leaving `file` empty.
///
/// Examples:
/// ---
/// auto file = map("dub.json");
/// assert(!file.isNull);
/// free(file.get);
/// assert(file.get.bytes is null);
/// ---
void free(ref MappedFile file) @trusted {
	if (file.read) {
		auto text = cast(char*) file.bytes.ptr;
		fp.string.free(text);
	} else if (file.bytes.length) {
		version(posixMapping) {
			static import core.sys.posix.sys.mman;
			cast(void) core.sys.posix.sys.mman.munmap(cast(void*) file.bytes.ptr, file.bytes.length);
		} else version(windowsMapping) {
			static import core.sys.windows.winbase;
			cast(void) core.sys.windows.winbase.UnmapViewOfFile(file.bytes.ptr);
		}
	}
	file = MappedFile.init;
}

/// The file at `path` mapped into memory for reading and writing. The mapping is shared, so other readers of the file see what is written to it, and it has the file's size, so it cannot grow the file.
///
/// Returns null if the file cannot be opened for writing, measured or mapped, `path` names a directory, or an allocation is refused.
///
/// Examples:
/// ---
/// static import fp.string;
/// assert(writeFile("bin/fp-file-example", "cat"));
/// auto file = mapForWriting("bin/fp-file-example");
/// file.get.bytes[0] = 'b';
/// assert(free(file.get));
/// auto text = readFile("bin/fp-file-example");
/// assert(fp.string.slice(text.get) == "bat");
/// fp.string.free(text.get);
/// assert(mapForWriting("no/such/file").isNull);
/// ---
std.typecons.Nullable!WritableMappedFile mapForWriting(const(char)[] path) @trusted {
	version(posixMapping) {
		static import core.sys.posix.fcntl;
		static import core.sys.posix.sys.mman;
		return mapWith(path, core.sys.posix.fcntl.O_RDWR, core.sys.posix.sys.mman.PROT_READ | core.sys.posix.sys.mman.PROT_WRITE, core.sys.posix.sys.mman.MAP_SHARED);
	} else version(windowsMapping) {
		static import core.sys.windows.winbase;
		static import core.sys.windows.winnt;
		return mapWith(path, core.sys.windows.winnt.GENERIC_READ | core.sys.windows.winnt.GENERIC_WRITE, core.sys.windows.winnt.PAGE_READWRITE, core.sys.windows.winbase.FILE_MAP_WRITE, true);
	} else {
		// Opened for update only to learn that the file can be written back.
		auto f = open(path, "r+b");
		if (f is null) return typeof(return).init;
		cast(void) core.stdc.stdio.fclose(f);
		char* name = fp.string.clone(path).get(null);
		if (name is null) return typeof(return).init;
		auto text = readFile(path);
		if (text.isNull) {
			fp.string.free(name);
			return typeof(return).init;
		}
		return typeof(return)(WritableMappedFile(fp.string.slice(text.get), name));
	}
}

/// Writes what was changed in `file` to the file it maps, waiting until it is written.
///
/// Returns false if it could not be written, leaving `file` mapped as it was; where the file was read rather than mapped, the file may then hold part of `file.bytes`, or nothing.
///
/// Examples:
/// ---
/// static import fp.string;
/// assert(writeFile("bin/fp-file-example", "cat"));
/// auto file = mapForWriting("bin/fp-file-example");
/// file.get.bytes[2] = 'r';
/// assert(sync(file.get));
/// auto text = readFile("bin/fp-file-example");
/// assert(fp.string.slice(text.get) == "car");
/// fp.string.free(text.get);
/// assert(free(file.get));
/// ---
bool sync(ref WritableMappedFile file) @trusted {
	if (file.path !is null) return writeFile(fp.string.slice(file.path), file.bytes);
	if (file.bytes.length == 0) return true;
	version(posixMapping) {
		static import core.sys.posix.sys.mman;
		return core.sys.posix.sys.mman.msync(file.bytes.ptr, file.bytes.length, core.sys.posix.sys.mman.MS_SYNC) == 0;
	} else version(windowsMapping) {
		static import core.sys.windows.winbase;
		// FlushViewOfFile only starts the write; FlushFileBuffers waits for it to reach the disk.
		return core.sys.windows.winbase.FlushViewOfFile(file.bytes.ptr, file.bytes.length) && core.sys.windows.winbase.FlushFileBuffers(file.file);
	} else return true;
}

/// Releases what `mapForWriting` mapped, leaving `file` empty. Where the file was read rather than mapped, it is first written back.
///
/// Returns false if that write failed, in which case the file may hold part of `file.bytes`, or nothing; `file` is released either way.
///
/// Examples:
/// ---
/// assert(writeFile("bin/fp-file-example", "cat"));
/// auto file = mapForWriting("bin/fp-file-example");
/// assert(free(file.get));
/// assert(file.get.bytes is null);
/// ---
bool free(ref WritableMappedFile file) @trusted {
	bool wrote = true;
	if (file.path !is null) {
		wrote = writeFile(fp.string.slice(file.path), file.bytes);
		auto text = file.bytes.ptr;
		fp.string.free(text);
		fp.string.free(file.path);
	} else if (file.bytes.length) {
		version(posixMapping) {
			static import core.sys.posix.sys.mman;
			cast(void) core.sys.posix.sys.mman.munmap(file.bytes.ptr, file.bytes.length);
		} else version(windowsMapping) {
			static import core.sys.windows.winbase;
			cast(void) core.sys.windows.winbase.UnmapViewOfFile(file.bytes.ptr);
			cast(void) core.sys.windows.winbase.CloseHandle(file.file);
		}
	}
	file = WritableMappedFile.init;
	return wrote;
}


// --- descriptors -------------------------------------------------------------

version(Windows) {
	// The C runtime's descriptor I/O, which druntime does not declare.
	private extern(C) {
		int _read(int descriptor, void* into, uint length);
		int _write(int descriptor, const(void)* from, uint length);
		int _setmode(int descriptor, int mode);
		void function(const(wchar)*, const(wchar)*, const(wchar)*, uint, size_t) @nogc nothrow _set_thread_local_invalid_parameter_handler(void function(const(wchar)*, const(wchar)*, const(wchar)*, uint, size_t) @nogc nothrow handler);
	}

	private enum int binaryMode = 0x8000;

	// The runtime ends the process on a bad descriptor unless a handler for it returns, which makes the call fail instead.
	private extern(C) void ignoreInvalidParameter(const(wchar)*, const(wchar)*, const(wchar)*, uint, size_t) {}

	// Runs `transfer` on `descriptor` in binary mode, failing rather than ending the process if `descriptor` is bad.
	private int guarded(int descriptor, scope int delegate() @nogc nothrow transfer) @trusted {
		auto previous = _set_thread_local_invalid_parameter_handler(&ignoreInvalidParameter);
		scope(exit) cast(void) _set_thread_local_invalid_parameter_handler(previous);
		if (_setmode(descriptor, binaryMode) < 0) return -1;
		return transfer();
	}
}

/// Reads up to `into.length` bytes from the open descriptor `descriptor` into `into`, in one read, and returns how many: 0 once the stream has ended, or when `into` is empty. It retries a read a signal interrupts. On Windows `descriptor` is a C runtime descriptor, which this leaves in binary mode, so the runtime neither adds nor drops carriage returns.
///
/// Returns -1 if `descriptor` is not open for reading or the read fails; `into` may then have changed.
///
/// Examples:
/// ---
/// char[16] buffer;
/// assert(readSome(-1, buffer[]) == -1);
/// ---
ptrdiff_t readSome(int descriptor, char[] into) @trusted {
	for (;;) {
		version(Windows) immutable got = guarded(descriptor, () => _read(descriptor, into.ptr, cast(uint) (into.length < int.max ? into.length : int.max)));
		else immutable got = core.sys.posix.unistd.read(descriptor, into.ptr, into.length);
		if (got >= 0 || core.stdc.errno.errno != core.stdc.errno.EINTR) return got;
	}
}

/// Writes up to all of `bytes` to the open descriptor `descriptor`, in one write, and returns how many it took. It retries a write a signal interrupts. On Windows `descriptor` is a C runtime descriptor, which this leaves in binary mode, as `readSome` does.
///
/// Returns -1 if `descriptor` is not open for writing or the write fails.
///
/// Examples:
/// ---
/// assert(writeSome(-1, "text") == -1);
/// ---
ptrdiff_t writeSome(int descriptor, const(char)[] bytes) @trusted {
	for (;;) {
		version(Windows) immutable wrote = guarded(descriptor, () => _write(descriptor, bytes.ptr, cast(uint) (bytes.length < int.max ? bytes.length : int.max)));
		else immutable wrote = core.sys.posix.unistd.write(descriptor, bytes.ptr, bytes.length);
		if (wrote >= 0 || core.stdc.errno.errno != core.stdc.errno.EINTR) return wrote;
	}
}

/// Writes all of `bytes` to the open descriptor `descriptor`, in as many writes as it takes, as `writeSome` does each. Writing nothing always succeeds.
///
/// Returns false if a write fails or takes nothing, perhaps after some of `bytes` were written.
///
/// Examples:
/// ---
/// assert(!writeAll(-1, "text") && writeAll(-1, ""));
/// ---
bool writeAll(int descriptor, const(char)[] bytes) {
	while (bytes.length) {
		immutable wrote = writeSome(descriptor, bytes);
		if (wrote <= 0) return false;
		bytes = bytes[wrote .. $];
	}
	return true;
}


unittest { // reading, writing, appending and mapping one file: what is written reads and maps back, and failures leave nothing behind
	static import fp.testing;
	char* path = fp.testing.temporaryFile();
	assert(path !is null);
	scope(exit) fp.string.free(path);
	const name = fp.string.slice(path);
	scope(exit) cast(void) removeFile(name);
	char* directoryPath = fp.testing.temporaryDirectory();
	assert(directoryPath !is null);
	scope(exit) fp.string.free(directoryPath);
	const directory = fp.string.slice(directoryPath);
	auto empty = readFile(name);
	assert(!empty.isNull && empty.get is null);

	static char[100_000] content;
	foreach (i, ref c; content) c = cast(char) ('a' + i % 26);
	assert(writeFile(name, content[]));
	auto read = readFile(name);
	assert(!read.isNull && fp.string.slice(read.get) == content[]);
	fp.string.free(read.get);

	// Refusals reach both the path's copy and the text.
	for (size_t budget = 0;; ++budget) {
		auto previous = fp.testing.limitAllocations(budget);
		auto rationed = readFile(name);
		fp.testing.restoreAllocator(previous);
		if (rationed.isNull) continue;
		assert(fp.string.slice(rationed.get) == content[]);
		fp.string.free(rationed.get);
		break;
	}
	assert(readFile(directory).isNull);

	// Mapping sees the same bytes; an empty file maps to nothing, and a directory does not map.
	auto mapped = map(name);
	assert(!mapped.isNull && mapped.get.bytes == content[]);
	version(windowsMapping) assert(!writeFile(name, "x") && mapped.get.bytes == content[]);
	free(mapped.get);
	assert(map(directory).isNull);

	// A writable mapping's changes reach the file through sync and free.
	auto writable = mapForWriting(name);
	assert(!writable.isNull && writable.get.bytes == content[]);
	writable.get.bytes[0] = '<';
	assert(sync(writable.get));
	auto synced = readFile(name);
	assert(fp.string.slice(synced.get)[0 .. 2] == "<b");
	fp.string.free(synced.get);
	writable.get.bytes[$ - 1] = '>';
	assert(free(writable.get) && writable.get.bytes is null);
	auto changed = readFile(name);
	assert(fp.string.slice(changed.get)[0] == '<' && fp.string.slice(changed.get)[$ - 1] == '>');
	assert(fp.string.slice(changed.get)[1 .. $ - 1] == content[1 .. $ - 1]);
	fp.string.free(changed.get);
	assert(mapForWriting(directory).isNull);
	for (size_t budget = 0;; ++budget) {
		auto previous = fp.testing.limitAllocations(budget);
		auto rationed = mapForWriting(name);
		fp.testing.restoreAllocator(previous);
		if (rationed.isNull) continue;
		assert(rationed.get.bytes.length == content.length);
		assert(free(rationed.get));
		break;
	}

	// Writing replaces, appending adds, and both create the file.
	assert(writeFile(name, "first") && writeFile(name, " second", WriteMode.append));
	auto both = readFile(name);
	assert(fp.string.slice(both.get) == "first second");
	fp.string.free(both.get);
	assert(writeFile(name, ""));
	auto cleared = map(name);
	assert(!cleared.isNull && cleared.get.bytes is null);
	free(cleared.get);
	auto clearedWritable = mapForWriting(name);
	assert(!clearedWritable.isNull && clearedWritable.get.bytes is null);
	assert(sync(clearedWritable.get) && free(clearedWritable.get));
	assert(removeFile(name) && !removeFile(name));
	assert(mapForWriting(name).isNull);
	assert(writeFile(name, "new", WriteMode.append) && writeFile(name, "newer"));
	mapped = map(name);
	assert(mapped.get.bytes == "newer");
	free(mapped.get);

	// The read-in-place fallback's free and sync, which WASI reaches through mapping, run here too.
	version(memoryMapping) {
		auto text = readFile(name);
		auto readIn = MappedFile(fp.string.slice(text.get), true);
		free(readIn);
		assert(readIn.bytes is null);
		auto writableText = readFile(name);
		char* copiedName = fp.string.clone(name).get(null);
		assert(copiedName !is null);
		auto writableReadIn = WritableMappedFile(fp.string.slice(writableText.get), copiedName);
		writableReadIn.bytes[0] = 'N';
		assert(sync(writableReadIn));
		writableReadIn.bytes[1] = 'E';
		assert(free(writableReadIn) && writableReadIn.bytes is null);
		mapped = map(name);
		assert(mapped.get.bytes == "NEwer");
		free(mapped.get);
		assert(writeFile(name, "newer"));
	}

	// A UTF-8 path names the same file everywhere, rather than being read in Windows' ANSI code page.
	char* unicodePath = fp.string.joined(name, "-é😀").get;
	assert(unicodePath !is null);
	scope(exit) fp.string.free(unicodePath);
	const unicodeName = fp.string.slice(unicodePath);
	assert(writeFile(unicodeName, "uni") && writeFile(unicodeName, "code", WriteMode.append));
	auto unicodeText = readFile(unicodeName);
	assert(!unicodeText.isNull && fp.string.slice(unicodeText.get) == "unicode");
	fp.string.free(unicodeText.get);
	auto unicodeMapped = map(unicodeName);
	assert(!unicodeMapped.isNull && unicodeMapped.get.bytes == "unicode");
	free(unicodeMapped.get);
	auto unicodeWritable = mapForWriting(unicodeName);
	assert(!unicodeWritable.isNull && unicodeWritable.get.bytes == "unicode");
	assert(free(unicodeWritable.get));
	version(Windows) {
		static import core.sys.windows.winbase;
		wchar* wideName = fp.string.utf.toUtf16(unicodeName).get(null);
		assert(wideName !is null);
		assert(core.sys.windows.winbase.DeleteFileW(wideName));
		fp.dynarray.free(wideName);
	} else assert(removeFile(unicodeName));

	// A refused copy of the path writes nothing.
	auto previous = fp.testing.limitAllocations(0);
	immutable refused = !writeFile(name, "x") && !writeFile(name, "x", WriteMode.append) && !removeFile(name) && map(name).isNull && mapForWriting(name).isNull;
	fp.testing.restoreAllocator(previous);
	assert(refused);
	auto unchanged = readFile(name);
	assert(fp.string.slice(unchanged.get) == "newer");
	fp.string.free(unchanged.get);

	assert(readFile("").isNull && readFile("no/such/file").isNull && map("no/such/file").isNull);
	assert(!writeFile("", "x") && !writeFile("no/such/directory/file", "x", WriteMode.append));
}

unittest { // descriptors: bytes written read back in pieces and whole, line ends untouched, and a descriptor open the wrong way, or not at all, failing
	static import core.stdc.string;
	static import fp.testing;
	char* path = fp.testing.temporaryFile();
	assert(path !is null);
	scope(exit) fp.string.free(path);
	scope(exit) cast(void) removeFile(fp.string.slice(path));
	auto file = core.stdc.stdio.fopen(path, "w+b");
	assert(file !is null);
	scope(exit) cast(void) core.stdc.stdio.fclose(file);
	immutable descriptor = core.stdc.stdio.fileno(file);

	static char[100_000] content;
	foreach (i, ref c; content) c = cast(char) (i % 7 == 0 ? '\n' : 'a' + i % 26);
	assert(writeAll(descriptor, content[]) && writeAll(descriptor, ""));
	core.stdc.stdio.rewind(file);
	static char[content.length] back;
	size_t n = 0;
	char[4096] piece;
	for (ptrdiff_t got; (got = readSome(descriptor, piece[])) > 0; n += got) core.stdc.string.memcpy(back.ptr + n, piece.ptr, got);
	assert(n == content.length && back[] == content[]);
	assert(readSome(descriptor, piece[]) == 0 && readSome(descriptor, piece[0 .. 0]) == 0);

	// A descriptor the runtime would translate is switched to binary first, and stays so.
	version(Windows) {
		enum int textMode = 0x4000;
		core.stdc.stdio.rewind(file);
		cast(void) _setmode(descriptor, textMode);
		assert(writeSome(descriptor, "a\r\nb\n") == 5);
		core.stdc.stdio.rewind(file);
		cast(void) _setmode(descriptor, textMode);
		assert(readSome(descriptor, piece[0 .. 5]) == 5 && piece[0 .. 5] == "a\r\nb\n");
		assert(_setmode(descriptor, binaryMode) == binaryMode);
	}

	// Open for writing only, it cannot be read; open for reading only, it cannot be written.
	auto writeOnly = core.stdc.stdio.fopen(path, "ab");
	assert(writeOnly !is null);
	scope(exit) cast(void) core.stdc.stdio.fclose(writeOnly);
	assert(readSome(core.stdc.stdio.fileno(writeOnly), piece[]) == -1);
	auto readOnly = core.stdc.stdio.fopen(path, "rb");
	assert(readOnly !is null);
	scope(exit) cast(void) core.stdc.stdio.fclose(readOnly);
	assert(writeSome(core.stdc.stdio.fileno(readOnly), "x") == -1 && !writeAll(core.stdc.stdio.fileno(readOnly), "x"));
	assert(readSome(-1, piece[]) == -1 && writeSome(-1, "x") == -1 && !writeAll(-1, "x"));
}

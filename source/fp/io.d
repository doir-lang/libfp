/// Input and output. Whole files: reading one into an fp string, writing, appending to or removing one, and mapping one into memory, read-only or writable. Open descriptors: reading what has arrived, and writing. And the console: printing values to it, and reading it, or any descriptor, a line, word or token at a time, with an optional history.
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
module fp.io;

static import core.stdc.errno;
static import core.stdc.stdio;

static import std.typecons;

static import fp.algorithms;
static import fp.dynarray;
static import fp.lifecycle;
static import fp.pointer;
static import fp.string;
static import fp.string.ascii;
static import fp.string.numbers;
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
		char[256] small;
		char* copy = null;
		scope(exit) fp.string.free(copy);
		char* name = small.ptr;
		if (path.length < small.length) {
			fp.pointer.copy(small[0 .. path.length], path);
			small[path.length] = 0;
		} else {
			copy = fp.string.clone(path).get(null);
			if (copy is null) return null;
			name = copy;
		}
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
/// assert(writeFile("bin/fp-io-write-example", "a"));
/// assert(writeFile("bin/fp-io-write-example", "b", WriteMode.append));
/// static import fp.string;
/// auto written = readFile("bin/fp-io-write-example").get;
/// assert(fp.string.equal(written, "ab"));
/// fp.string.free(written);
/// assert(removeFile("bin/fp-io-write-example"));
/// assert(!writeFile("no/such/directory/file", "text"));
/// ---
bool writeFile(const(char)[] path, const(char)[] text, WriteMode mode = WriteMode.replace) {
	auto f = open(path, mode == WriteMode.append ? "ab" : "wb");
	if (f is null) return false;
	immutable wrote = core.stdc.stdio.fwrite(text.ptr, 1, text.length, f) == text.length;
	// A close can report a failed write the buffer was still holding.
	return (core.stdc.stdio.fclose(f) == 0) & wrote;
}

version(Windows) private extern(C) int _wremove(const(wchar)* path);

/// Removes the file at `path`.
///
/// Returns false if it cannot be removed, such as when there is none, or the path's copy is refused.
///
/// Examples:
/// ---
/// assert(writeFile("bin/fp-io-remove-example", "x"));
/// assert(removeFile("bin/fp-io-remove-example"));
/// assert(!removeFile("bin/fp-io-remove-example"));
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
/// assert(writeFile("bin/fp-io-example", "cat"));
/// auto file = mapForWriting("bin/fp-io-example");
/// file.get.bytes[0] = 'b';
/// assert(free(file.get));
/// auto text = readFile("bin/fp-io-example");
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
/// assert(writeFile("bin/fp-io-example", "cat"));
/// auto file = mapForWriting("bin/fp-io-example");
/// file.get.bytes[2] = 'r';
/// assert(sync(file.get));
/// auto text = readFile("bin/fp-io-example");
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
/// assert(writeFile("bin/fp-io-example", "cat"));
/// auto file = mapForWriting("bin/fp-io-example");
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

version(Windows) private extern(C) {
	int _pipe(int* descriptors, uint size, int mode);
	int _close(int descriptor);
}

/// Closes the open descriptor `descriptor`.
///
/// Returns false if `descriptor` was not open or closing it failed; it is not open afterwards either way.
///
/// Examples:
/// ---
/// assert(!close(-1));
/// ---
bool close(int descriptor) @trusted {
	version(Windows) return guarded(descriptor, () => _close(descriptor)) == 0;
	else return core.sys.posix.unistd.close(descriptor) == 0;
}

/// The two ends of a pipe, as `createPipe` opens them: what is written to `writing` is read from `reading`.
struct Pipe {
	int reading = -1; /// The descriptor to read from.
	int writing = -1; /// The descriptor to write to.
}

/// Opens a pipe, both of whose ends the caller closes with `close`; on Windows they are C runtime descriptors in binary mode, with a 64 KiB buffer.
///
/// Returns an empty `Nullable` if the system refused, as it does when the process has too many descriptors open, and always on WASI, which has no pipes.
///
/// Examples:
/// ---
/// version(WASI) {} else {
/// 	auto pipe = createPipe().get;
/// 	char[2] read;
/// 	assert(writeAll(pipe.writing, "hi") && readSome(pipe.reading, read[]) == 2 && read == "hi");
/// 	assert(close(pipe.writing) && readSome(pipe.reading, read[]) == 0 && close(pipe.reading));
/// }
/// ---
std.typecons.Nullable!Pipe createPipe() @trusted {
	int[2] descriptors;
	version(WASI) return typeof(return).init;
	else {
		version(Windows) immutable made = _pipe(descriptors.ptr, 65_536, binaryMode) == 0;
		else immutable made = core.sys.posix.unistd.pipe(descriptors) == 0;
		return made ? typeof(return)(Pipe(descriptors[0], descriptors[1])) : typeof(return).init;
	}
}


// --- the console -------------------------------------------------------------

/// The descriptors every process starts with, on POSIX, Windows and WASI alike, to pass wherever a descriptor is taken. Leading `print`'s values, one says where they go; any other open descriptor can lead them cast to `Console`.
enum Console : int {
	input = 0, /// Standard input.
	output = 1, /// Standard output.
	error = 2, /// Standard error.
}

/// Writes `values` to standard output, or to the descriptor a leading `Console` names, as one `writeAll`: slices and fp strings as they are, characters as UTF-8, and numbers as `fp.string.append` writes them. Nothing goes through C's buffered `stdout`, so text printed here is not reordered against later writes to the same descriptor.
///
/// Returns false if an allocation was refused, writing nothing, or the write failed, perhaps after part of the text was written.
///
/// Examples:
/// ---
/// assert(print("fp.io: ", 3, " values, ", 1.5, '\n'));
/// assert(print(Console.error, "fp.io: to standard error\n"));
/// assert(!print(cast(Console) -1, "no such descriptor"));
/// ---
bool print(Values...)(Values values) {
	static if (Values.length > 0 && is(Values[0] == Console)) {
		immutable descriptor = values[0];
		alias pieces = values[1 .. $];
	} else {
		immutable descriptor = Console.output;
		alias pieces = values;
	}
	char* text = null;
	scope(exit) fp.string.free(text);
	return fp.string.append(text, pieces) && writeAll(descriptor, fp.string.slice(text));
}

/// Writes `message` to standard error, then ends the process abnormally through C's `abort`, which raises `SIGABRT` where there are signals and traps on WASI. Its pieces are slices, characters and integers, each written as it comes without allocating, so it can report a refused allocation; a write that fails is skipped. It does not return.
///
/// Examples:
/// ---
/// static void check(bool ok, long detail) @nogc nothrow {
/// 	if (!ok) abort("check failed: ", detail, '\n');
/// }
/// check(true, 0);
/// ---
noreturn abort(Pieces...)(Pieces message) @trusted {
	foreach (piece; message) {
		alias T = typeof(piece);
		static if (is(T : const(char)[])) cast(void) writeAll(Console.error, piece);
		else static if (is(immutable T == immutable char)) cast(void) writeAll(Console.error, (&piece)[0 .. 1]);
		else static if (__traits(isUnsigned, T)) {
			char[fp.string.numbers.maxDecimalLength] buffer;
			cast(void) writeAll(Console.error, fp.string.numbers.formatUnsigned(piece, buffer));
		} else static if (__traits(isIntegral, T)) {
			char[fp.string.numbers.maxDecimalLength] buffer;
			cast(void) writeAll(Console.error, fp.string.numbers.formatSigned(piece, buffer));
		} else static assert(0, "fp.io.abort: cannot write a " ~ T.stringof);
	}
	static import core.stdc.stdlib;
	core.stdc.stdlib.abort();
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

/// How many bytes a `Reader` reads at a time.
enum size_t readerBufferLength = 1024;

/// Reads a descriptor, such as `Console.input`, a line, word or token at a time, through `read`. It reads ahead, so read the descriptor only through it once reading has begun. Set `descriptor`, and `echo` if lines edited at a terminal should show elsewhere; the rest starts empty.
struct Reader {
	int descriptor; /// What it reads.
	int echo = Console.output; /// Where a line being edited at a terminal is shown, which must be a terminal too for `read` to edit.
	bool failed; /// Whether a read failed or an allocation was refused, rather than the input ending, when `read` last returned null.
	private char[readerBufferLength] buffer;
	private size_t start, end; // `buffer[start .. end]` was read but not yet returned
	private bool afterCarriageReturn; // the last line or word ended at `\r`, so a `\n` arriving next is part of its break
	private bool ended;
}

/// How `read` splits its input.
enum Split {
	lines, /// At each line break, as `fp.string.breaksLine` says: `\n`, `\r\n` or a lone `\r`. An empty line is a line.
	words, /// At runs of ASCII whitespace (`fp.string.ascii.isWhitespace`), which are skipped, so a word is never empty.
	tokens, /// At each byte of the delimiters `read` is given, each ending one token, so two in a row end an empty one.
}

/// What reads given it have returned, a copy of each, oldest first, keeping at most `limit` of the latest when `limit` is not 0, as a shell keeps its history. Release it with `free`.
struct History {
	fp.lifecycle.Owned!char* entries; /// An fp dynarray of the entries; an empty one is a null string.
	size_t limit; /// The most entries kept; 0 keeps every one.
}

/// Releases every entry of `history`, leaving it empty with its `limit`.
///
/// Examples:
/// ---
/// History history;
/// free(history);
/// assert(history.entries is null);
/// ---
void free(ref History history) {
	fp.dynarray.free(history.entries);
}

// Whether `c` ends a piece `split` splits off; `delimiters` end tokens.
private bool endsPiece(Split split, const(char)[] delimiters, char c) {
	final switch (split) {
		case Split.lines: return c == '\n' || c == '\r';
		case Split.words: return fp.string.ascii.isWhitespace(c);
		case Split.tokens: return fp.algorithms.contains(delimiters, c);
	}
}

// Appends a copy of `piece` to `history`, dropping the oldest entry past its limit. False, leaving it as it was, if an allocation was refused.
private bool record(ref History history, const(char)[] piece) {
	auto copy = fp.string.clone(piece);
	if (copy.isNull || !fp.dynarray.pushBack(history.entries, fp.lifecycle.Owned!char(copy.get))) return false; // a refused push ends the copy
	if (history.limit != 0 && fp.dynarray.length(history.entries) > history.limit) cast(void) fp.dynarray.removeAt(history.entries, 0);
	return true;
}

version(WASI) {} else version(Posix) version = lineEditing;
else version(Windows) version = lineEditing;

version(lineEditing) {
	version(Windows) {
		private enum uint windowsLineInput = 0x0002, windowsEchoInput = 0x0004, windowsProcessedInput = 0x0001, windowsVirtualTerminalInput = 0x0200;
		private extern(C) ptrdiff_t _get_osfhandle(int descriptor);
		// The console mode `enterRawMode` replaced, for `restoreMode`.
		private struct TerminalState { uint mode; }
	} else {
		static import core.sys.posix.termios;
		// The terminal attributes `enterRawMode` replaced, for `restoreMode`.
		private struct TerminalState { core.sys.posix.termios.termios attributes; }
	}

	// Whether `descriptor` is a terminal, or on Windows a console.
	private bool isTerminal(int descriptor) @trusted {
		version(Windows) {
			static import core.sys.windows.wincon;
			uint mode;
			return core.sys.windows.wincon.GetConsoleMode(cast(void*) _get_osfhandle(descriptor), &mode) != 0;
		} else return core.sys.posix.unistd.isatty(descriptor) == 1;
	}

	// Switches terminal `descriptor` to reading each key as it is pressed, unechoed and unprocessed; returns what to restore, or null if it cannot.
	private std.typecons.Nullable!TerminalState enterRawMode(int descriptor) @trusted {
		version(Windows) {
			static import core.sys.windows.wincon;
			static import core.sys.windows.winnls;
			auto console = cast(void*) _get_osfhandle(descriptor);
			TerminalState saved;
			if (!core.sys.windows.wincon.GetConsoleMode(console, &saved.mode)) return typeof(return).init;
			// Virtual terminal input delivers keys as the escape sequences POSIX terminals send.
			immutable raw = (saved.mode & ~(windowsLineInput | windowsEchoInput | windowsProcessedInput)) | windowsVirtualTerminalInput;
			if (!core.sys.windows.wincon.SetConsoleMode(console, raw)) return typeof(return).init;
			cast(void) core.sys.windows.wincon.SetConsoleCP(core.sys.windows.winnls.CP_UTF8);
			cast(void) enableAnsiColorsAndUTF8();
			return typeof(return)(saved);
		} else {
			TerminalState saved;
			if (core.sys.posix.termios.tcgetattr(descriptor, &saved.attributes) != 0) return typeof(return).init;
			auto raw = saved.attributes;
			raw.c_lflag &= ~(core.sys.posix.termios.ICANON | core.sys.posix.termios.ECHO | core.sys.posix.termios.ISIG | core.sys.posix.termios.IEXTEN);
			raw.c_iflag &= ~(core.sys.posix.termios.ICRNL | core.sys.posix.termios.IXON);
			raw.c_cc[core.sys.posix.termios.VMIN] = 1;
			raw.c_cc[core.sys.posix.termios.VTIME] = 0;
			// TCSADRAIN rather than TCSAFLUSH, so keys typed ahead are kept.
			if (core.sys.posix.termios.tcsetattr(descriptor, core.sys.posix.termios.TCSADRAIN, &raw) != 0) return typeof(return).init;
			return typeof(return)(saved);
		}
	}

	// Puts terminal `descriptor` back as `enterRawMode` found it.
	private void restoreMode(int descriptor, ref const TerminalState saved) @trusted {
		version(Windows) {
			static import core.sys.windows.wincon;
			cast(void) core.sys.windows.wincon.SetConsoleMode(cast(void*) _get_osfhandle(descriptor), saved.mode);
		} else cast(void) core.sys.posix.termios.tcsetattr(descriptor, core.sys.posix.termios.TCSADRAIN, &saved.attributes);
	}

	// The next byte `reader` reads, -1 once the input has ended, or -2 if the read failed.
	private int nextByte(ref Reader reader) {
		if (reader.start == reader.end) {
			if (reader.ended) return -1;
			immutable got = readSome(reader.descriptor, reader.buffer[]);
			if (got < 0) return -2;
			reader.ended = got == 0;
			reader.start = 0;
			reader.end = got;
			if (got == 0) return -1;
		}
		return cast(ubyte) reader.buffer[reader.start++];
	}

	// The line being edited, and how it is shown: `cursor` is a byte offset, `shownCursor` the column the terminal's cursor is at.
	private struct Edit {
		char* text;
		size_t cursor;
		size_t shownCursor;
	}

	// Redraws `edit` on `echo`: back to the line's start, erase, the text, then back to the cursor. False if an allocation was refused.
	private bool redraw(ref Edit edit, int echo) {
		const text = fp.string.slice(edit.text);
		// A character still arriving byte by byte would be counted wrong; it is drawn once whole.
		size_t lead = edit.cursor;
		while (lead > 0 && (text[lead - 1] & 0xC0) == 0x80) --lead;
		if (lead > 0) --lead; // the byte starting the character before the cursor
		if (edit.cursor > 0 && fp.string.utf.sequenceLength(text[lead]) > edit.cursor - lead) return true;
		immutable before = fp.string.utf.codepointCount(text[0 .. edit.cursor]), after = fp.string.utf.codepointCount(text[edit.cursor .. $]);
		char* drawn = null;
		scope(exit) fp.string.free(drawn);
		bool ok = edit.shownCursor == 0 || fp.string.append(drawn, "\x1b[", edit.shownCursor, 'D');
		ok = ok && fp.string.append(drawn, "\x1b[K", text);
		ok = ok && (after == 0 || fp.string.append(drawn, "\x1b[", after, 'D'));
		if (!ok) return false;
		cast(void) writeAll(echo, fp.string.slice(drawn)); // only the display; the line is kept either way
		edit.shownCursor = before;
		return true;
	}

	// Replaces `edit`'s text with a copy of `text`, the cursor at its end. False, leaving it as it was, if the copy was refused.
	private bool replaceText(ref Edit edit, const(char)[] text) {
		auto copy = fp.string.clone(text);
		if (copy.isNull) return false;
		fp.string.free(edit.text);
		edit.text = copy.get;
		edit.cursor = fp.string.length(edit.text);
		return true;
	}

	// Reads one line from terminal `reader.descriptor`, which `enterRawMode` switched from `saved`, editing it in place with `history` to recall; `read` documents the keys.
	private std.typecons.Nullable!(char*) editLine(ref Reader reader, ref const History history, ref const TerminalState saved) @trusted {
		bool restored = false;
		void restore() {
			if (!restored) restoreMode(reader.descriptor, saved);
			restored = true;
		}
		scope(exit) restore();
		Edit edit;
		char* draft = null; // what was typed before the history was entered
		scope(exit) fp.string.free(draft);
		immutable entries = fp.dynarray.length(history.entries);
		size_t recalled = entries; // the history entry shown, `entries` for the line being typed
		bool fail() {
			reader.failed = true;
			fp.string.free(edit.text);
			return false;
		}
		// Shows history entry `to`, or the draft at `entries`, keeping the draft when leaving it.
		bool recall(size_t to) {
			if (recalled == entries) {
				auto copy = fp.string.clone(fp.string.slice(edit.text));
				if (copy.isNull) return false;
				fp.string.free(draft);
				draft = copy.get;
			}
			if (!replaceText(edit, to == entries ? fp.string.slice(draft) : fp.string.slice(history.entries[to].p))) return false;
			recalled = to;
			return true;
		}
		bool removeBytes(size_t from, size_t to) {
			if (!fp.string.replaceRange(edit.text, from, to - from, "")) return false;
			edit.cursor = from;
			return true;
		}
		size_t previousCharacter() {
			size_t at = edit.cursor;
			while (at > 0 && (edit.text[--at] & 0xC0) == 0x80) {}
			return at;
		}
		size_t nextCharacter() {
			size_t at = edit.cursor;
			if (at < fp.string.length(edit.text)) ++at;
			while (at < fp.string.length(edit.text) && (edit.text[at] & 0xC0) == 0x80) ++at;
			return at;
		}
		for (;;) {
			immutable c = nextByte(reader);
			if (c == -2) {
				cast(void) fail();
				return typeof(return).init;
			}
			if (c == -1 || (c == 0x04 && fp.string.length(edit.text) == 0)) {
				// The input ended, or Ctrl-D on an empty line ends it as the terminal's end-of-file would.
				cast(void) writeAll(reader.echo, "\r\n"); // only the display
				if (fp.string.length(edit.text) > 0) return typeof(return)(edit.text);
				return typeof(return).init;
			}
			if (reader.afterCarriageReturn) {
				reader.afterCarriageReturn = false;
				if (c == '\n') continue;
			}
			bool ok = true;
			if (c == '\r' || c == '\n') {
				reader.afterCarriageReturn = c == '\r';
				cast(void) writeAll(reader.echo, "\r\n"); // only the display
				return typeof(return)(edit.text);
			} else if (c == 0x03) {
				// Ctrl-C: the terminal is restored first, so a SIGINT that ends the process leaves it usable.
				cast(void) writeAll(reader.echo, "^C\r\n"); // only the display
				restore();
				static import core.stdc.signal;
				cast(void) core.stdc.signal.raise(core.stdc.signal.SIGINT);
				cast(void) fail();
				return typeof(return).init;
			} else if (c == 0x7F || c == 0x08) {
				if (edit.cursor > 0) ok = removeBytes(previousCharacter(), edit.cursor);
			} else if (c == 0x04) {
				immutable cursor = edit.cursor, next = nextCharacter();
				if (next > cursor) ok = removeBytes(cursor, next);
			} else if (c == 0x01) edit.cursor = 0;
			else if (c == 0x05) edit.cursor = fp.string.length(edit.text);
			else if (c == 0x1B) {
				immutable kind = nextByte(reader);
				if (kind != '[' && kind != 'O') continue;
				// A control sequence: parameter bytes, then a final byte that names the key.
				int final_ = 0, parameter = 0;
				for (;;) {
					immutable b = nextByte(reader);
					if (b < 0) break;
					if (b >= '0' && b <= '9') parameter = parameter * 10 + (b - '0');
					if (b >= 0x40 && b <= 0x7E) {
						final_ = b;
						break;
					}
				}
				if (final_ == 'A' && recalled > 0) ok = recall(recalled - 1);
				else if (final_ == 'B' && recalled < entries) ok = recall(recalled + 1);
				else if (final_ == 'C') edit.cursor = nextCharacter();
				else if (final_ == 'D') edit.cursor = previousCharacter();
				else if (final_ == 'H' || (final_ == '~' && (parameter == 1 || parameter == 7))) edit.cursor = 0;
				else if (final_ == 'F' || (final_ == '~' && (parameter == 4 || parameter == 8))) edit.cursor = fp.string.length(edit.text);
				else if (final_ == '~' && parameter == 3) {
					immutable cursor = edit.cursor, next = nextCharacter();
					if (next > cursor) ok = removeBytes(cursor, next);
				} else continue;
			} else if (c >= 0x20) {
				immutable char[1] typed = [cast(char) c];
				ok = fp.string.replaceRange(edit.text, edit.cursor, 0, typed[]);
				if (ok) ++edit.cursor;
			} else continue;
			if (!ok || !redraw(edit, reader.echo)) {
				cast(void) fail();
				return typeof(return).init;
			}
		}
	}
}

/// The next line, word or token `reader` reads, as `split` says, without what ended it, as a new fp string the caller frees; an empty one is a null string. `delimiters` are the bytes that end a token, and are given only for `Split.tokens`. If `history` is given, a copy of what is returned is recorded in it.
///
/// A line ends at a lone `\r` without waiting to see whether a `\n` follows, so a terminal that sends `\r` for Enter is answered at once; a `\n` that does follow is skipped by the next read. The input's last line, word or token needs nothing after it.
///
/// Reading lines with a `history` from a terminal, when `reader.echo` is one too, edits each line in place, as a shell does: Up and Down recall the history, Down past its newest entry returning to what was being typed; Left, Right, Home and End (or Ctrl-A and Ctrl-E) move by whole UTF-8 characters; Backspace and Delete remove one; Enter ends the line; and Ctrl-D on an empty line ends the input. Ctrl-C restores the terminal and raises `SIGINT`; if that returns, the line is abandoned as a failed read. On WASI, which has no terminal control, lines are read as from any descriptor.
///
/// Returns null once the input has ended. Returns null with `reader.failed` set if a read failed or an allocation was refused, for the piece or for its copy in `history`; that piece is then lost, and `history` is as it was.
///
/// Examples:
/// ---
/// Reader reader;
/// reader.descriptor = -1;
/// assert(read(reader, Split.lines).isNull && reader.failed);
/// History history;
/// scope(exit) free(history);
/// assert(read(reader, Split.tokens, &history, ",;").isNull && history.entries is null);
/// ---
std.typecons.Nullable!(char*) read(ref Reader reader, Split split, History* history = null, const(char)[] delimiters = null) {
	assert(split == Split.tokens || delimiters.length == 0, "fp.io.read: only tokens take delimiters");
	reader.failed = false;
	// A descriptor that is not a terminal cannot be made raw, so it is read as any other.
	version(lineEditing) if (split == Split.lines && history !is null && isTerminal(reader.echo)) {
		auto saved = enterRawMode(reader.descriptor);
		if (!saved.isNull) {
			auto edited = editLine(reader, *history, saved.get);
			if (edited.isNull || record(*history, fp.string.slice(edited.get))) return edited;
			reader.failed = true;
			fp.string.free(edited.get);
			return typeof(return).init;
		}
	}
	char* piece = null;
	bool started = false;
	while (!reader.ended || reader.start < reader.end) {
		if (reader.start == reader.end) {
			immutable got = readSome(reader.descriptor, reader.buffer[]);
			if (got < 0) {
				reader.failed = true;
				break;
			}
			reader.ended = got == 0;
			reader.start = 0;
			reader.end = got;
			continue;
		}
		if (reader.afterCarriageReturn) {
			reader.afterCarriageReturn = false;
			if (reader.buffer[reader.start] == '\n') {
				++reader.start;
				continue;
			}
		}
		if (split == Split.words && !started && fp.string.ascii.isWhitespace(reader.buffer[reader.start])) {
			++reader.start;
			continue;
		}
		const pending = reader.buffer[reader.start .. reader.end];
		size_t at = 0;
		while (at < pending.length && !endsPiece(split, delimiters, pending[at])) ++at;
		if (!fp.string.concatenate(piece, pending[0 .. at])) {
			reader.failed = true;
			break;
		}
		started = true;
		reader.start += at;
		if (at == pending.length) continue;
		reader.afterCarriageReturn = split != Split.tokens && pending[at] == '\r';
		++reader.start;
		break;
	}
	if (!reader.failed && started && (history is null || record(*history, fp.string.slice(piece)))) return typeof(return)(piece);
	reader.failed = reader.failed || started;
	fp.string.free(piece);
	return typeof(return).init;
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

	// Refusals reach both the path's copy, which only a path too long for the stack buffer needs, and the text.
	char* longPath = null;
	scope(exit) fp.string.free(longPath);
	assert(fp.string.concatenate(longPath, directory) && fp.string.concatenate(longPath, "/"));
	foreach (i; 0 .. 128) assert(fp.string.concatenate(longPath, "./")); // long without any long component
	assert(fp.string.concatenate(longPath, "long"));
	assert(fp.string.length(longPath) >= 256);
	const longName = fp.string.slice(longPath);
	assert(writeFile(longName, content[]));
	scope(exit) cast(void) removeFile(longName);
	const(char)[][2] candidates;
	candidates[0] = name;
	candidates[1] = longName;
	foreach (candidate; candidates) {
		for (size_t budget = 0;; ++budget) {
			auto previous = fp.testing.limitAllocations(budget);
			auto rationed = readFile(candidate);
			fp.testing.restoreAllocator(previous);
			if (rationed.isNull) continue;
			assert(fp.string.slice(rationed.get) == content[]);
			fp.string.free(rationed.get);
			break;
		}
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

	// A refused copy of the path writes nothing; a path short enough for the stack buffer needs no copy to be opened.
	auto previous = fp.testing.limitAllocations(0);
	immutable refused = !writeFile(longName, "x") && !writeFile(longName, "x", WriteMode.append) && !removeFile(name) && map(name).isNull && mapForWriting(name).isNull;
	fp.testing.restoreAllocator(previous);
	assert(refused);
	auto unchanged = readFile(name);
	assert(fp.string.slice(unchanged.get) == "newer");
	fp.string.free(unchanged.get);
	auto longUnchanged = readFile(longName);
	assert(fp.string.slice(longUnchanged.get) == content[]);
	fp.string.free(longUnchanged.get);

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

	// A pipe carries bytes from its writing end to its reading end, which ends once the writing end closes; a closed end is not open.
	version(WASI) assert(createPipe().isNull);
	else {
		auto pipe = createPipe().get;
		assert(writeAll(pipe.writing, "piped\n"));
		assert(readSome(pipe.reading, piece[]) == 6 && piece[0 .. 6] == "piped\n");
		assert(close(pipe.writing) && !close(pipe.writing) && !writeAll(pipe.writing, "x"));
		assert(readSome(pipe.reading, piece[]) == 0 && close(pipe.reading));
	}
	assert(!close(-1));
}

unittest { // the console: printed values read back a line, word or token at a time, every break counted once, even one split between two reads
	static import fp.testing;
	char* path = fp.testing.temporaryFile();
	assert(path !is null);
	scope(exit) fp.string.free(path);
	scope(exit) cast(void) removeFile(fp.string.slice(path));
	auto file = core.stdc.stdio.fopen(path, "w+b");
	assert(file !is null);
	scope(exit) cast(void) core.stdc.stdio.fclose(file);
	immutable descriptor = core.stdc.stdio.fileno(file);

	// The first line's `\r` is the last byte of the first read and its `\n` the first of the next.
	static char[readerBufferLength - 1] long_ = 'x';
	assert(print(cast(Console) descriptor, long_[], "\r\none\r\ntwo\n\rthree\r", 42, '\n', '€', 1.5));
	auto previous = fp.testing.limitAllocations(0);
	immutable refusedPrint = !print(cast(Console) descriptor, "lost");
	fp.testing.restoreAllocator(previous);
	assert(refusedPrint && !print(cast(Console) -1, "x"));
	assert(print() && print(Console.output)); // nothing to write

	// `abort` writes every piece to standard error before it ends with `SIGABRT`, so point standard error at a scratch file while it runs.
	version(Posix) static if (fp.testing.catchesAborts) {
		auto scratch = fp.testing.openScratchFile();
		assert(!scratch.isNull);
		scope(exit) fp.testing.free(scratch.get);
		auto redirected = fp.testing.redirect(Console.error, scratch.get.descriptor).get;
		immutable aborted = fp.testing.aborts(() { abort("fp.io: ", -5, ' ', 7u, '\n'); });
		fp.testing.restore(redirected);
		assert(aborted);
		auto reported = readFile(fp.string.slice(scratch.get.path));
		assert(!reported.isNull && fp.string.equal(reported.get, "fp.io: -5 7\n"));
		fp.string.free(reported.get);
	}

	core.stdc.stdio.rewind(file);
	Reader reader;
	reader.descriptor = descriptor;
	auto first = read(reader, Split.lines);
	assert(!first.isNull && fp.string.slice(first.get) == long_[]);
	fp.string.free(first.get);
	static immutable string[] lines = ["one", "two", "", "three", "42", "€1.5"];
	foreach (want; lines) {
		auto line = read(reader, Split.lines);
		assert(!line.isNull && !reader.failed && fp.string.slice(line.get) == want);
		fp.string.free(line.get);
	}
	assert(read(reader, Split.lines).isNull && !reader.failed && read(reader, Split.lines).isNull);

	// Words skip every whitespace run; tokens end at each delimiter, so two in a row end an empty one, and a last one needs none.
	void rewrite(const(char)[] text) {
		assert(core.stdc.stdio.fclose(file) == 0);
		assert(writeFile(fp.string.slice(path), text));
		file = core.stdc.stdio.fopen(path, "r+b");
		assert(file !is null);
	}
	void expect(Split split, const(char)[] delimiters, const(string)[] expected) {
		Reader pieces;
		pieces.descriptor = core.stdc.stdio.fileno(file);
		foreach (want; expected) {
			auto piece = read(pieces, split, null, delimiters);
			assert(!piece.isNull && !pieces.failed && fp.string.slice(piece.get) == want);
			fp.string.free(piece.get);
		}
		assert(read(pieces, split, null, delimiters).isNull && !pieces.failed);
	}
	rewrite("  one two\t\tthree\r\n\nfour ");
	static immutable string[] words = ["one", "two", "three", "four"];
	expect(Split.words, null, words);
	rewrite("a,b,,c;d");
	static immutable string[] tokens = ["a", "b", "", "c", "d"];
	expect(Split.tokens, ",;", tokens);
	rewrite("a,b,");
	static immutable string[] trailing = ["a", "b"];
	expect(Split.tokens, ",", trailing);
	rewrite("whole");
	static immutable string[] whole = ["whole"];
	expect(Split.tokens, null, whole);
	rewrite(" \n\t ");
	expect(Split.words, null, null);

	// One reader may switch between splits; a word ended by `\r` takes the `\n` after it, as a line does.
	rewrite("cmd arg\r\nrest of line\n");
	Reader mixed;
	mixed.descriptor = core.stdc.stdio.fileno(file);
	static immutable string[] switched = ["cmd", "arg", "rest of line"];
	foreach (i, want; switched) {
		auto piece = read(mixed, i < 2 ? Split.words : Split.lines);
		assert(!piece.isNull && fp.string.slice(piece.get) == want);
		fp.string.free(piece.get);
	}

	// A history keeps a copy of each piece returned, oldest first, and only the latest `limit` when it has one.
	rewrite("first\nsecond\nthird\n");
	Reader recorded;
	recorded.descriptor = core.stdc.stdio.fileno(file);
	History history;
	history.limit = 2;
	scope(exit) free(history);
	foreach (_; 0 .. 3) {
		auto line = read(recorded, Split.lines, &history);
		assert(!line.isNull);
		fp.string.free(line.get);
	}
	assert(fp.dynarray.length(history.entries) == 2 && fp.string.slice(history.entries[0].p) == "second" && fp.string.slice(history.entries[1].p) == "third");
	free(history);
	assert(history.entries is null && history.limit == 2);

	// A refused allocation, for the piece or its copy, or a failed read loses the piece, says so, and leaves the history as it was.
	History unlimited;
	scope(exit) free(unlimited);
	for (size_t n = 0;; ++n) {
		rewrite("kept\n");
		Reader rationed;
		rationed.descriptor = core.stdc.stdio.fileno(file);
		previous = fp.testing.limitAllocations(n);
		auto line = read(rationed, Split.lines, &unlimited);
		fp.testing.restoreAllocator(previous);
		if (!line.isNull) {
			fp.string.free(line.get);
			assert(fp.dynarray.length(unlimited.entries) == 1 && fp.string.slice(unlimited.entries[0].p) == "kept");
			break;
		}
		assert(rationed.failed && unlimited.entries is null);
	}
	Reader closed;
	closed.descriptor = -1;
	assert(read(closed, Split.lines).isNull && closed.failed);
	// Terminals other than Windows' console already take UTF-8 and ANSI escapes; whether a Windows test run has a console varies.
	version(Windows) cast(void) enableAnsiColorsAndUTF8();
	else assert(enableAnsiColorsAndUTF8());
}

version(lineEditing) version(Posix) unittest { // line editing at a terminal: keys edit the line, the history is recalled, and the terminal is put back as it was
	static import core.stdc.signal;
	static import core.sys.posix.fcntl;
	static import core.sys.posix.stdlib;
	static import core.sys.posix.termios;
	static import fp.testing;
	immutable master = core.sys.posix.stdlib.posix_openpt(core.sys.posix.fcntl.O_RDWR | core.sys.posix.fcntl.O_NOCTTY);
	assert(master >= 0 && core.sys.posix.stdlib.grantpt(master) == 0 && core.sys.posix.stdlib.unlockpt(master) == 0);
	bool masterOpen = true;
	scope(exit) if (masterOpen) cast(void) core.sys.posix.unistd.close(master);
	assert(core.sys.posix.fcntl.fcntl(master, core.sys.posix.fcntl.F_SETFL, core.sys.posix.fcntl.O_NONBLOCK) == 0);
	immutable terminal = core.sys.posix.fcntl.open(core.sys.posix.stdlib.ptsname(master), core.sys.posix.fcntl.O_RDWR | core.sys.posix.fcntl.O_NOCTTY);
	assert(terminal >= 0 && isTerminal(terminal) && !isTerminal(-1));
	scope(exit) cast(void) core.sys.posix.unistd.close(terminal);
	// Raw from the start, so keys written below reach the reader as typed rather than through the line discipline.
	auto cooked = enterRawMode(terminal);
	assert(!cooked.isNull);
	core.sys.posix.termios.termios before;
	assert(core.sys.posix.termios.tcgetattr(terminal, &before) == 0);
	assert(enterRawMode(-1).isNull);

	Reader reader;
	reader.descriptor = terminal;
	reader.echo = terminal;
	History history;
	scope(exit) free(history);
	assert(record(history, "first") && record(history, "second"));
	char[256] shown;
	// Types `keys` at the terminal and reads the line they edit, discarding what the editing showed.
	std.typecons.Nullable!(char*) typed(const(char)[] keys) {
		assert(writeAll(master, keys));
		auto line = read(reader, Split.lines, &history);
		while (readSome(master, shown[]) > 0) {}
		core.sys.posix.termios.termios after;
		assert(core.sys.posix.termios.tcgetattr(terminal, &after) == 0 && after.c_lflag == before.c_lflag && after.c_iflag == before.c_iflag);
		return line;
	}
	void expectLine(const(char)[] keys, const(char)[] expected) {
		auto line = typed(keys);
		assert(!line.isNull && !reader.failed);
		scope(exit) fp.string.free(line.get);
		assert(fp.string.slice(line.get) == expected);
		assert(fp.string.slice(history.entries[fp.dynarray.length(history.entries) - 1].p) == expected);
	}

	// Up and Down walk the history and back to the draft; Left and Backspace edit what was recalled.
	expectLine("x\x1b[A\x1b[A\x1b[B\x1b[B\x1b[A!\x1b[D\x1b[D\x7f\r", "secod!");
	// The `\n` after Enter's `\r` is part of that break; cursor keys move by whole characters.
	expectLine("\né\x1b[Da\x1b[H>\x1bOF<\x01\x1b[3~\r", "aé<");
	// Ctrl-D deletes inside a line; the other spellings of Home and End work; unknown keys and sequences change nothing.
	expectLine("abc\x01\x04\x1b[4~\x1b[1~\x1b[Z\x1bx\x05!\x02\x1b[7~\x1b[8~\x08\x1b[3~!\r", "bc!");
	// Up stops at the oldest entry and Down at the line being typed.
	expectLine("\x1b[A\x1b[A\x1b[A\x1b[A\x1b[A\x1b[A\x1b[A\r", "first");
	expectLine("\x1b[Bz\x1b[C\x1b[D\x1b[D\x1b[D\r", "z");

	// Ctrl-D on an empty line ends the input, recording nothing.
	immutable entries = fp.dynarray.length(history.entries);
	auto ended = typed("\x04");
	assert(ended.isNull && !reader.failed && fp.dynarray.length(history.entries) == entries);

	// Ctrl-C restores the terminal and raises SIGINT; ignored, it abandons the line.
	auto previousHandler = core.stdc.signal.signal(core.stdc.signal.SIGINT, core.stdc.signal.SIG_IGN);
	auto interrupted = typed("ab\x03");
	cast(void) core.stdc.signal.signal(core.stdc.signal.SIGINT, previousHandler);
	assert(interrupted.isNull && reader.failed && fp.dynarray.length(history.entries) == entries);

	// A refused allocation, while editing, recalling or recording, abandons the line as a failed read.
	for (size_t n = 0;; ++n) {
		assert(core.sys.posix.termios.tcflush(terminal, core.sys.posix.termios.TCIFLUSH) == 0);
		Reader rationed;
		rationed.descriptor = terminal;
		rationed.echo = terminal;
		assert(writeAll(master, "q\x1b[A\r"));
		auto previous = fp.testing.limitAllocations(n);
		auto line = read(rationed, Split.lines, &history);
		fp.testing.restoreAllocator(previous);
		while (readSome(master, shown[]) > 0) {}
		if (!line.isNull) {
			scope(exit) fp.string.free(line.get);
			assert(fp.string.slice(line.get) == "z" && fp.dynarray.length(history.entries) == entries + 1); // the newest entry, recalled
			break;
		}
		assert(rationed.failed && fp.dynarray.length(history.entries) == entries);
	}

	// A read that fails, here a terminal with nothing to read that will not wait, abandons the line.
	assert(core.sys.posix.termios.tcflush(terminal, core.sys.posix.termios.TCIFLUSH) == 0);
	immutable flags = core.sys.posix.fcntl.fcntl(terminal, core.sys.posix.fcntl.F_GETFL);
	assert(core.sys.posix.fcntl.fcntl(terminal, core.sys.posix.fcntl.F_SETFL, flags | core.sys.posix.fcntl.O_NONBLOCK) == 0);
	Reader waiting;
	waiting.descriptor = terminal;
	waiting.echo = terminal;
	assert(read(waiting, Split.lines, &history).isNull && waiting.failed);
	assert(core.sys.posix.fcntl.fcntl(terminal, core.sys.posix.fcntl.F_SETFL, flags) == 0);
	// Input that is not a terminal is read as from any descriptor, even when the echo is one.
	Reader notTerminal;
	notTerminal.descriptor = -1;
	notTerminal.echo = terminal;
	assert(read(notTerminal, Split.lines, &history).isNull && notTerminal.failed);

	// When the terminal hangs up, what was already read is the last line, and then the input has ended.
	reader.buffer[0 .. 7] = "partial";
	reader.start = 0;
	reader.end = 7;
	cast(void) core.sys.posix.unistd.close(master);
	masterOpen = false;
	auto cutOff = read(reader, Split.lines, &history);
	assert(!cutOff.isNull && fp.string.slice(cutOff.get) == "partial");
	fp.string.free(cutOff.get);
	assert(read(reader, Split.lines, &history).isNull && !reader.failed);
	restoreMode(terminal, cooked.get);
}

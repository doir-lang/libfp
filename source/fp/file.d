/// Whole files: reading one into an fp string, writing or appending to one, through C's stdio, and mapping one into memory, read-only or writable.
///
/// Examples:
/// ---
/// static import fp.string;
/// auto text = readFile("dub.json");
/// assert(!text.isNull && fp.string.length(text.get) > 0);
/// fp.string.free(text.get);
/// auto mapped = mapFile("dub.json");
/// assert(!mapped.isNull && mapped.get.bytes.length > 0);
/// free(mapped.get);
/// ---
module fp.file;

static import core.stdc.stdio;

static import std.typecons;

static import fp.dynarray;
static import fp.string;

// WASI's mmap only emulates a mapping by reading the file, which the fallback here does without an extra library.
version(WASI) {} else version(Posix) version = memoryMapping;

@nogc nothrow:


// --- reading -----------------------------------------------------------------

// The file at `path` opened in C `mode`, or null if it cannot be or the path's copy is refused.
private core.stdc.stdio.FILE* open(const(char)[] path, const(char)* mode) {
	char* name = fp.string.makeDynamic(path);
	if (name is null) return null;
	scope(exit) fp.string.free(name);
	return core.stdc.stdio.fopen(name, mode);
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
	scope(exit) core.stdc.stdio.fclose(f);
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
		cast(void) fp.dynarray.popBackCount(out_, chunk - n);
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

// Writes `text` to the file at `path` opened in C `mode`. False if it cannot be opened, written or closed.
private bool write(const(char)[] path, const(char)[] text, const(char)* mode) {
	auto f = open(path, mode);
	if (f is null) return false;
	immutable wrote = core.stdc.stdio.fwrite(text.ptr, 1, text.length, f) == text.length;
	// A close can report a failed write the buffer was still holding.
	return (core.stdc.stdio.fclose(f) == 0) & wrote;
}

/// Replaces the contents of the file at `path` with `text`, creating the file if there is none.
///
/// Returns false if the file cannot be opened or written, or the path's copy is refused; a file that was opened may then hold part of `text`, or nothing.
///
/// Examples:
/// ---
/// assert(!writeFile("no/such/directory/file", "text"));
/// ---
bool writeFile(const(char)[] path, const(char)[] text) {
	return write(path, text, "wb");
}

/// Appends `text` to the file at `path`, creating the file if there is none.
///
/// Returns false if the file cannot be opened or written, or the path's copy is refused; a file that was opened may then end with part of `text`.
///
/// Examples:
/// ---
/// assert(!appendFile("no/such/directory/file", "text"));
/// ---
bool appendFile(const(char)[] path, const(char)[] text) {
	return write(path, text, "ab");
}


// --- mapping -----------------------------------------------------------------

version(memoryMapping) {
	// The whole file at `path`, opened with `access` and mapped with `protection` and `flags`; empty for an empty file, null on failure.
	private std.typecons.Nullable!(char[]) map(const(char)[] path, int access, int protection, int flags) @trusted {
		static import core.sys.posix.fcntl;
		static import core.sys.posix.sys.mman;
		static import core.sys.posix.sys.stat;
		static import core.sys.posix.unistd;
		char* name = fp.string.makeDynamic(path);
		if (name is null) return typeof(return).init;
		scope(exit) fp.string.free(name);
		immutable fd = core.sys.posix.fcntl.open(name, access);
		if (fd < 0) return typeof(return).init;
		// The mapping keeps the file alive once it is made.
		scope(exit) cast(void) core.sys.posix.unistd.close(fd);
		core.sys.posix.sys.stat.stat_t status;
		if (core.sys.posix.sys.stat.fstat(fd, &status) != 0 || !core.sys.posix.sys.stat.S_ISREG(status.st_mode)) return typeof(return).init;
		if (status.st_size == 0) return typeof(return)(cast(char[]) null);
		auto p = core.sys.posix.sys.mman.mmap(null, cast(size_t) status.st_size, protection, flags, fd, 0);
		if (p == core.sys.posix.sys.mman.MAP_FAILED) return typeof(return).init;
		return typeof(return)((cast(char*) p)[0 .. cast(size_t) status.st_size]);
	}
}

/// A file mapped into memory read-only, released by `free`. Where memory mapping is unavailable, as on WASI and Windows, the file is read into memory instead, which a reader cannot tell apart.
struct MappedFile {
	const(char)[] bytes; /// The file's contents; null for an empty file.
	private bool read; // whether `bytes` is an fp string `readFile` made rather than a mapping
}

/// The file at `path` mapped into memory read-only. The mapping is private, so the bytes do not change if the file is written later, unless it is truncated, which on POSIX makes reading past its new end raise `SIGBUS`.
///
/// Returns null if the file cannot be opened, measured or mapped, `path` names a directory, or an allocation is refused.
///
/// Examples:
/// ---
/// assert(mapFile("no/such/file").isNull);
/// ---
std.typecons.Nullable!MappedFile mapFile(const(char)[] path) @trusted {
	version(memoryMapping) {
		static import core.sys.posix.fcntl;
		static import core.sys.posix.sys.mman;
		auto bytes = map(path, core.sys.posix.fcntl.O_RDONLY, core.sys.posix.sys.mman.PROT_READ, core.sys.posix.sys.mman.MAP_PRIVATE);
		if (bytes.isNull) return typeof(return).init;
		return typeof(return)(MappedFile(bytes.get));
	} else {
		auto text = readFile(path);
		if (text.isNull) return typeof(return).init;
		return typeof(return)(MappedFile(fp.string.slice(text.get), true));
	}
}

/// Releases what `mapFile` mapped, leaving `file` empty.
///
/// Examples:
/// ---
/// auto file = mapFile("dub.json");
/// assert(!file.isNull);
/// free(file.get);
/// assert(file.get.bytes is null);
/// ---
void free(ref MappedFile file) @trusted {
	if (file.read) {
		auto text = cast(char*) file.bytes.ptr;
		fp.string.free(text);
	} else version(memoryMapping) {
		static import core.sys.posix.sys.mman;
		if (file.bytes.length) cast(void) core.sys.posix.sys.mman.munmap(cast(void*) file.bytes.ptr, file.bytes.length);
	}
	file = MappedFile.init;
}

/// A file mapped into memory for reading and writing, released by `free`. Where memory mapping is unavailable, as on WASI and Windows, the file is read into memory instead, and what is written reaches the file only through `sync` or `free`.
struct WritableMappedFile {
	char[] bytes; /// The file's contents, whose changes are written to it; null for an empty file.
	private char* path; // the fp string copy of the path that `sync` writes `bytes` back to, when they were read rather than mapped
}

/// The file at `path` mapped into memory for reading and writing. The mapping is shared, so other readers of the file see what is written to it, and it has the file's size, so it cannot grow the file.
///
/// Returns null if the file cannot be opened for writing, measured or mapped, `path` names a directory, or an allocation is refused.
///
/// Examples:
/// ---
/// static import fp.string;
/// assert(writeFile("bin/fp-file-example", "cat"));
/// auto file = mapFileWritable("bin/fp-file-example");
/// file.get.bytes[0] = 'b';
/// assert(free(file.get));
/// auto text = readFile("bin/fp-file-example");
/// assert(fp.string.slice(text.get) == "bat");
/// fp.string.free(text.get);
/// assert(mapFileWritable("no/such/file").isNull);
/// ---
std.typecons.Nullable!WritableMappedFile mapFileWritable(const(char)[] path) @trusted {
	version(memoryMapping) {
		static import core.sys.posix.fcntl;
		static import core.sys.posix.sys.mman;
		auto bytes = map(path, core.sys.posix.fcntl.O_RDWR, core.sys.posix.sys.mman.PROT_READ | core.sys.posix.sys.mman.PROT_WRITE, core.sys.posix.sys.mman.MAP_SHARED);
		if (bytes.isNull) return typeof(return).init;
		return typeof(return)(WritableMappedFile(bytes.get));
	} else {
		// Opened for update only to learn that the file can be written back.
		auto f = open(path, "r+b");
		if (f is null) return typeof(return).init;
		cast(void) core.stdc.stdio.fclose(f);
		char* name = fp.string.makeDynamic(path);
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
/// auto file = mapFileWritable("bin/fp-file-example");
/// file.get.bytes[2] = 'r';
/// assert(sync(file.get));
/// auto text = readFile("bin/fp-file-example");
/// assert(fp.string.slice(text.get) == "car");
/// fp.string.free(text.get);
/// assert(free(file.get));
/// ---
bool sync(ref WritableMappedFile file) @trusted {
	if (file.path !is null) return writeFile(fp.string.slice(file.path), file.bytes);
	version(memoryMapping) {
		static import core.sys.posix.sys.mman;
		return file.bytes.length == 0 || core.sys.posix.sys.mman.msync(file.bytes.ptr, file.bytes.length, core.sys.posix.sys.mman.MS_SYNC) == 0;
	} else return true;
}

/// Releases what `mapFileWritable` mapped, leaving `file` empty. Where the file was read rather than mapped, it is first written back.
///
/// Returns false if that write failed, in which case the file may hold part of `file.bytes`, or nothing; `file` is released either way.
///
/// Examples:
/// ---
/// assert(writeFile("bin/fp-file-example", "cat"));
/// auto file = mapFileWritable("bin/fp-file-example");
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
	} else version(memoryMapping) {
		static import core.sys.posix.sys.mman;
		if (file.bytes.length) cast(void) core.sys.posix.sys.mman.munmap(file.bytes.ptr, file.bytes.length);
	}
	file = WritableMappedFile.init;
	return wrote;
}


unittest { // reading, writing, appending and mapping one file: what is written reads and maps back, and failures leave nothing behind
	static import fp.testing;
	version(memoryMapping) {
		static import core.sys.posix.stdlib;
		static import core.sys.posix.unistd;
		char[20] path = "/tmp/fp-file-XXXXXX\0";
		immutable fd = core.sys.posix.stdlib.mkstemp(path.ptr);
		assert(fd >= 0);
		cast(void) core.sys.posix.unistd.close(fd);
	} else {
		// The WASI runner preopens a fresh /tmp, so a fixed name cannot collide.
		char[19] path = "/tmp/fp-file-test\0\0";
		assert(writeFile(path[0 .. 17], ""));
	}
	const name = fp.string.slice(path.ptr);
	scope(exit) cast(void) core.stdc.stdio.remove(path.ptr);
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
		auto previous = fp.testing.beginRationedAllocator(budget);
		auto rationed = readFile(name);
		fp.testing.endRationedAllocator(previous);
		if (rationed.isNull) continue;
		assert(fp.string.slice(rationed.get) == content[]);
		fp.string.free(rationed.get);
		break;
	}
	assert(readFile("/tmp").isNull);

	// Mapping sees the same bytes; an empty file maps to nothing, and a directory does not map.
	auto mapped = mapFile(name);
	assert(!mapped.isNull && mapped.get.bytes == content[]);
	free(mapped.get);
	assert(mapFile("/tmp").isNull);

	// A writable mapping's changes reach the file through sync and free.
	auto writable = mapFileWritable(name);
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
	assert(mapFileWritable("/tmp").isNull);
	for (size_t budget = 0;; ++budget) {
		auto previous = fp.testing.beginRationedAllocator(budget);
		auto rationed = mapFileWritable(name);
		fp.testing.endRationedAllocator(previous);
		if (rationed.isNull) continue;
		assert(rationed.get.bytes.length == content.length);
		assert(free(rationed.get));
		break;
	}

	// Writing replaces, appending adds, and both create the file.
	assert(writeFile(name, "first") && appendFile(name, " second"));
	auto both = readFile(name);
	assert(fp.string.slice(both.get) == "first second");
	fp.string.free(both.get);
	assert(writeFile(name, ""));
	auto cleared = mapFile(name);
	assert(!cleared.isNull && cleared.get.bytes is null);
	free(cleared.get);
	auto clearedWritable = mapFileWritable(name);
	assert(!clearedWritable.isNull && clearedWritable.get.bytes is null);
	assert(sync(clearedWritable.get) && free(clearedWritable.get));
	assert(core.stdc.stdio.remove(path.ptr) == 0);
	assert(mapFileWritable(name).isNull);
	assert(appendFile(name, "new") && writeFile(name, "newer"));
	mapped = mapFile(name);
	assert(mapped.get.bytes == "newer");
	free(mapped.get);

	// The read-in-place fallback's free and sync, which WASI and Windows reach through mapping, run here too.
	version(memoryMapping) {
		auto text = readFile(name);
		auto readIn = MappedFile(fp.string.slice(text.get), true);
		free(readIn);
		assert(readIn.bytes is null);
		text = readFile(name);
		char* copiedName = fp.string.makeDynamic(name);
		assert(copiedName !is null);
		auto writableReadIn = WritableMappedFile(fp.string.slice(text.get), copiedName);
		writableReadIn.bytes[0] = 'N';
		assert(sync(writableReadIn));
		writableReadIn.bytes[1] = 'E';
		assert(free(writableReadIn) && writableReadIn.bytes is null);
		mapped = mapFile(name);
		assert(mapped.get.bytes == "NEwer");
		free(mapped.get);
		assert(writeFile(name, "newer"));
	}

	// A refused copy of the path writes nothing.
	auto previous = fp.testing.beginRationedAllocator(0);
	immutable refused = !writeFile(name, "x") && !appendFile(name, "x") && mapFile(name).isNull && mapFileWritable(name).isNull;
	fp.testing.endRationedAllocator(previous);
	assert(refused);
	auto unchanged = readFile(name);
	assert(fp.string.slice(unchanged.get) == "newer");
	fp.string.free(unchanged.get);

	assert(readFile("").isNull && readFile("no/such/file").isNull && mapFile("no/such/file").isNull);
	assert(!writeFile("", "x") && !appendFile("no/such/directory/file", "x"));
}

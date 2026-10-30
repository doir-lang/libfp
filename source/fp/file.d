/// Whole files: reading one into an fp string, writing or appending to one, through C's stdio, and mapping one into memory read-only.
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
	char* out_ = null;
	// Sized from the file's length where it has one, so a large file is not read into twice the room it needs.
	if (core.stdc.stdio.fseek(f, 0, core.stdc.stdio.SEEK_END) == 0) {
		immutable size = core.stdc.stdio.ftell(f);
		if (core.stdc.stdio.fseek(f, 0, core.stdc.stdio.SEEK_SET) != 0) return typeof(return).init;
		if (size > 0 && fp.dynarray.reserve(out_, size + 1) is null) return typeof(return).init;
	}
	char[65536] buffer;
	for (;;) {
		immutable n = core.stdc.stdio.fread(buffer.ptr, 1, buffer.length, f);
		if (n && fp.string.concatenate(out_, buffer[0 .. n]) is null) break;
		if (n < buffer.length) {
			if (core.stdc.stdio.ferror(f)) break;
			if (fp.dynarray.length(out_) == 0) fp.string.free(out_);
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
	version(Posix) {
		static import core.sys.posix.fcntl;
		static import core.sys.posix.sys.mman;
		static import core.sys.posix.sys.stat;
		static import core.sys.posix.unistd;
		char* name = fp.string.makeDynamic(path);
		if (name is null) return typeof(return).init;
		scope(exit) fp.string.free(name);
		immutable fd = core.sys.posix.fcntl.open(name, core.sys.posix.fcntl.O_RDONLY);
		if (fd < 0) return typeof(return).init;
		// The mapping keeps the file alive once it is made.
		scope(exit) cast(void) core.sys.posix.unistd.close(fd);
		core.sys.posix.sys.stat.stat_t status;
		if (core.sys.posix.sys.stat.fstat(fd, &status) != 0 || !core.sys.posix.sys.stat.S_ISREG(status.st_mode)) return typeof(return).init;
		if (status.st_size == 0) return typeof(return)(MappedFile.init);
		auto p = core.sys.posix.sys.mman.mmap(null, cast(size_t) status.st_size, core.sys.posix.sys.mman.PROT_READ, core.sys.posix.sys.mman.MAP_PRIVATE, fd, 0);
		if (p == core.sys.posix.sys.mman.MAP_FAILED) return typeof(return).init;
		return typeof(return)(MappedFile((cast(const(char)*) p)[0 .. cast(size_t) status.st_size]));
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
	} else version(Posix) {
		static import core.sys.posix.sys.mman;
		if (file.bytes.length) cast(void) core.sys.posix.sys.mman.munmap(cast(void*) file.bytes.ptr, file.bytes.length);
	}
	file = MappedFile.init;
}


unittest { // reading, writing, appending and mapping one file: what is written reads and maps back, and failures leave nothing behind
	static import fp.testing;
	char[64] path = "/tmp/fp-file-XXXXXX\0";
	version(Posix) {
		static import core.sys.posix.stdlib;
		static import core.sys.posix.unistd;
		immutable fd = core.sys.posix.stdlib.mkstemp(path.ptr);
		assert(fd >= 0);
		scope(exit) cast(void) core.sys.posix.unistd.unlink(path.ptr);
		const name = path[0 .. 19];
		auto empty = readFile(name);
		assert(!empty.isNull && empty.get is null);

		char[100_000] content;
		foreach (i, ref c; content) c = cast(char) ('a' + i % 26);
		assert(core.sys.posix.unistd.write(fd, content.ptr, content.length) == content.length);
		cast(void) core.sys.posix.unistd.close(fd);
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

		// Writing replaces, appending adds, and both create the file.
		assert(writeFile(name, "first") && appendFile(name, " second"));
		auto both = readFile(name);
		assert(fp.string.slice(both.get) == "first second");
		fp.string.free(both.get);
		assert(writeFile(name, ""));
		auto cleared = mapFile(name);
		assert(!cleared.isNull && cleared.get.bytes is null);
		free(cleared.get);
		assert(core.sys.posix.unistd.unlink(path.ptr) == 0);
		assert(appendFile(name, "new") && writeFile(name, "newer"));
		mapped = mapFile(name);
		assert(mapped.get.bytes == "newer");
		free(mapped.get);

		// A refused copy of the path writes nothing.
		auto previous = fp.testing.beginRationedAllocator(0);
		immutable refused = !writeFile(name, "x") && !appendFile(name, "x") && mapFile(name).isNull;
		fp.testing.endRationedAllocator(previous);
		assert(refused);
	}
	assert(readFile("").isNull && readFile("no/such/file").isNull && mapFile("no/such/file").isNull);
	assert(!writeFile("", "x") && !appendFile("no/such/directory/file", "x"));
}

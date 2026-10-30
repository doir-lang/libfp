/// Text as a persistent rope, such as an editor's or a compiler's copy of a file being edited: versions are immutable and share every leaf an edit does not touch, so applying an edit, keeping the previous version to compare against, and finding a line or the line of an offset all cost O(log n), and line starts are kept by the tree rather than rescanned.
///
/// A `Rope` is one version. Leaves hold at most `maxLeaf` bytes and are shared by reference count, so `share` gives another owner of a version in O(1), and each owner `free`s its own.
///
/// Examples:
/// ---
/// auto a = create("x : T\ny : T\n").get;
/// scope(exit) free(a);
/// auto b = edit(a, 6, 7, "z").get;
/// scope(exit) free(b);
/// assert(equal(a, 6, "y") && equal(b, 6, "z"));
/// assert(lineOf(b, 6) == 1 && lineStart(b, 1) == 6);
/// ---
module fp.rope;

static import core.stdc.string;
static import std.typecons;

static import fp.pointer;
version(unittest) static import fp.testing;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// The most bytes a leaf holds. An edit copies the leaves it touches, and a line lookup scans one leaf, so this bounds both.
enum size_t maxLeaf = 4096;

// A leaf has no children and its bytes follow the node; an internal node has both children. Nodes are immutable once built.
private struct Node {
	Node* left, right;
	size_t length;
	size_t newlines;
	uint refs;
	uint height;
}

// Stands for a tree an allocation refused to build: an operation given it releases its other inputs and returns it.
private __gshared Node refusedNode;
private __gshared Node* refused = &refusedNode;

/// One version of a text: a plain value, released with `free`. Copying it does not make another owner; `share` does.
struct Rope {
	private Node* root = null;
}

private char* bytesOf(Node* leaf) @trusted {
	return cast(char*) (leaf + 1);
}


// --- nodes -------------------------------------------------------------------

private void retain(Node* n) {
	if (n !is null && n !is refused) ++n.refs;
}

private void release(Node* n) @trusted {
	if (n is null || n is refused || --n.refs) return;
	release(n.left);
	release(n.right);
	cast(void) fp.pointer.allocFunction(n, 0);
}

private Node* leaf(const(char)[] bytes) @trusted {
	assert(bytes.length <= maxLeaf);
	auto n = cast(Node*) fp.pointer.allocFunction(null, Node.sizeof + bytes.length);
	if (n is null) return refused;
	*n = Node(null, null, bytes.length, 0, 1, 0);
	core.stdc.string.memcpy(bytesOf(n), bytes.ptr, bytes.length);
	for (const(char)* p = bytes.ptr, end = bytes.ptr + bytes.length; (p = cast(const(char)*) core.stdc.string.memchr(p, '\n', end - p)) !is null; ++p)
		++n.newlines;
	return n;
}

// Consumes `l` and `r`, which must be non-empty.
private Node* node(Node* l, Node* r) @trusted {
	if (l is refused || r is refused) {
		release(l);
		release(r);
		return refused;
	}
	auto n = cast(Node*) fp.pointer.allocFunction(null, Node.sizeof);
	if (n is null) {
		release(l);
		release(r);
		return refused;
	}
	*n = Node(l, r, l.length + r.length, l.newlines + r.newlines, 1, (l.height > r.height ? l.height : r.height) + 1);
	return n;
}

// `node(l, r)` rotated back into balance; consumes both, whose heights differ by at most 2.
private Node* balance(Node* l, Node* r) {
	if (l is refused || r is refused) return node(l, r);
	if (r.height > l.height + 1) {
		Node* a = r.left, b = r.right;
		retain(a);
		retain(b);
		release(r);
		if (b.height >= a.height) return node(node(l, a), b);
		retain(a.left);
		retain(a.right);
		Node* al = a.left, ar = a.right;
		release(a);
		return node(node(l, al), node(ar, b));
	}
	if (l.height > r.height + 1) {
		Node* a = l.left, b = l.right;
		retain(a);
		retain(b);
		release(l);
		if (a.height >= b.height) return node(a, node(b, r));
		retain(b.left);
		retain(b.right);
		Node* bl = b.left, br = b.right;
		release(b);
		return node(node(a, bl), node(br, r));
	}
	return node(l, r);
}

// The concatenation of `a` and `b`, either of which may be empty; consumes both.
private Node* join(Node* a, Node* b) {
	if (a is refused || b is refused) {
		release(a);
		release(b);
		return refused;
	}
	if (a is null) return b;
	if (b is null) return a;
	if (a.height > b.height + 1) {
		Node* l = a.left, r = a.right;
		retain(l);
		retain(r);
		release(a);
		return balance(l, join(r, b));
	}
	if (b.height > a.height + 1) {
		Node* l = b.left, r = b.right;
		retain(l);
		retain(r);
		release(b);
		return balance(join(a, l), r);
	}
	return node(a, b);
}

// `t`'s bytes before `at`, which must fall between leaves, into `l` and the rest into `r`; borrows `t`. Both are `refused` on refusal.
private void split(Node* t, size_t at, ref Node* l, ref Node* r) @trusted {
	if (t is null || at == 0) {
		retain(t);
		l = null;
		r = t;
		return;
	}
	if (at >= t.length) {
		retain(t);
		l = t;
		r = null;
		return;
	}
	assert(t.left !is null, "fp.rope.split: cut inside a leaf");
	if (at <= t.left.length) {
		Node* lr;
		split(t.left, at, l, lr);
		retain(t.right);
		r = join(lr, t.right);
	} else {
		Node* rl;
		split(t.right, at - t.left.length, rl, r);
		retain(t.left);
		l = join(t.left, rl);
	}
	if (l is refused || r is refused) {
		release(l);
		release(r);
		l = r = refused;
	}
}

// A balanced tree of `bytes` cut into leaves of near-equal size.
private Node* build(const(char)[] bytes, size_t leaves) {
	if (leaves == 0) return null;
	if (leaves == 1) return leaf(bytes);
	immutable half = leaves / 2;
	immutable cut = bytes.length * half / leaves;
	return node(build(bytes[0 .. cut], half), build(bytes[cut .. $], leaves - half));
}

// The start and length of the leaf holding byte `at`, which must be below `t.length`.
private void leafAround(Node* t, size_t at, out size_t start, out size_t length) {
	while (t.left !is null) {
		if (at < t.left.length) t = t.left;
		else {
			start += t.left.length;
			at -= t.left.length;
			t = t.right;
		}
	}
	length = t.length;
}

private void copyRange(Node* t, size_t start, size_t end, char* out_) @trusted {
	if (t is null || start >= end) return;
	if (t.left is null) {
		core.stdc.string.memcpy(out_, bytesOf(t) + start, end - start);
		return;
	}
	immutable mid = t.left.length;
	if (start < mid) copyRange(t.left, start, end < mid ? end : mid, out_);
	if (end > mid) copyRange(t.right, start > mid ? start - mid : 0, end - mid, out_ + (start < mid ? mid - start : 0));
}

private bool equalRange(Node* t, size_t start, const(char)[] s) @trusted {
	if (s.length == 0) return true;
	if (t.left is null) return core.stdc.string.memcmp(bytesOf(t) + start, s.ptr, s.length) == 0;
	immutable mid = t.left.length;
	if (start + s.length <= mid) return equalRange(t.left, start, s);
	if (start >= mid) return equalRange(t.right, start - mid, s);
	return equalRange(t.left, start, s[0 .. mid - start]) && equalRange(t.right, 0, s[mid - start .. $]);
}


// --- versions ----------------------------------------------------------------

/// A new version holding a copy of `bytes`.
///
/// Returns null if allocation is refused, having allocated nothing that outlives the call.
///
/// Examples:
/// ---
/// auto t = create("abc").get;
/// scope(exit) free(t);
/// assert(length(t) == 3);
/// ---
std.typecons.Nullable!Rope create(const(char)[] bytes) {
	auto root = build(bytes, (bytes.length + maxLeaf - 1) / maxLeaf);
	if (root is refused) return typeof(return).init;
	return typeof(return)(Rope(root));
}

/// Another owner of `t`'s version, which the caller `free`s. It cannot fail.
///
/// Examples:
/// ---
/// auto a = create("abc").get;
/// auto b = share(a);
/// free(a);
/// assert(equal(b, 0, "abc"));
/// free(b);
/// ---
Rope share(const Rope t) @trusted {
	retain(cast(Node*) t.root);
	return Rope(cast(Node*) t.root);
}

/// Releases `t`'s version, leaving `t` empty. Leaves another version shares stay alive with it.
///
/// Examples:
/// ---
/// auto t = create("abc").get;
/// free(t);
/// assert(length(t) == 0);
/// ---
void free(ref Rope t) {
	release(t.root);
	t.root = null;
}

/// A new version: `from` with bytes `start` to `end` replaced by `replacement`. `from` is unchanged and shares every leaf the edit does not touch with the result. `start <= end <= length(from)`.
///
/// Returns null if allocation is refused, leaving `from` as it was.
///
/// Examples:
/// ---
/// auto a = create("hello").get;
/// scope(exit) free(a);
/// auto b = edit(a, 1, 5, "i").get;
/// scope(exit) free(b);
/// assert(length(b) == 2 && equal(b, 0, "hi"));
/// ---
std.typecons.Nullable!Rope edit(const Rope from, size_t start, size_t end, const(char)[] replacement) @trusted {
	auto t = cast(Node*) from.root;
	immutable total = t is null ? 0 : t.length;
	assert(start <= end && end <= total, "fp.rope.edit: range out of bounds");
	// Widen to whole leaves so the split copies nothing, and take in a neighbour when the result would leave a small leaf.
	size_t lo = start, hi = end, at, size;
	if (start < total) {
		leafAround(t, start, at, size);
		lo = at;
	}
	if (end > 0 && end < total) {
		leafAround(t, end - 1, at, size);
		hi = at + size;
	} else if (end == 0 && total > 0) {
		leafAround(t, 0, at, size);
		hi = size;
	}
	if ((hi - lo) - (end - start) + replacement.length < maxLeaf / 2) {
		if (lo > 0) {
			leafAround(t, lo - 1, at, size);
			lo = at;
		}
		if (hi < total) {
			leafAround(t, hi, at, size);
			hi = at + size;
		}
	}

	immutable middle = (start - lo) + replacement.length + (hi - end);
	auto scratch = cast(char*) fp.pointer.allocFunction(null, middle ? middle : 1);
	if (scratch is null) return typeof(return).init;
	scope(exit) cast(void) fp.pointer.allocFunction(scratch, 0);
	copyRange(t, lo, start, scratch);
	core.stdc.string.memcpy(scratch + (start - lo), replacement.ptr, replacement.length);
	copyRange(t, end, hi, scratch + (start - lo) + replacement.length);

	Node* before, after, unused;
	split(t, lo, before, unused);
	release(unused);
	split(t, hi, unused, after);
	release(unused);
	auto root = join(join(before, build(scratch[0 .. middle], (middle + maxLeaf - 1) / maxLeaf)), after);
	if (root is refused) return typeof(return).init;
	return typeof(return)(Rope(root));
}


// --- queries -----------------------------------------------------------------

/// The number of bytes in `t`.
///
/// Examples:
/// ---
/// assert(length(Rope.init) == 0);
/// ---
size_t length(const Rope t) {
	return t.root is null ? 0 : t.root.length;
}

/// The number of newlines in `t`, one less than its number of lines.
///
/// Examples:
/// ---
/// auto t = create("a\nb\n").get;
/// scope(exit) free(t);
/// assert(newlines(t) == 2);
/// ---
size_t newlines(const Rope t) {
	return t.root is null ? 0 : t.root.newlines;
}

/// The 0-based line byte `at` lies on: the number of newlines before it. `at` may be `length(t)`.
///
/// Examples:
/// ---
/// auto t = create("a\nbc\n").get;
/// scope(exit) free(t);
/// assert(lineOf(t, 0) == 0 && lineOf(t, 2) == 1 && lineOf(t, 5) == 2);
/// ---
size_t lineOf(const Rope t, size_t at) @trusted {
	assert(at <= length(t), "fp.rope.lineOf: offset out of bounds");
	auto n = cast(Node*) t.root;
	size_t line = 0;
	if (n is null) return 0;
	while (n.left !is null) {
		if (at < n.left.length) n = n.left;
		else {
			line += n.left.newlines;
			at -= n.left.length;
			n = n.right;
		}
	}
	for (const(char)* p = bytesOf(n), end = bytesOf(n) + at; (p = cast(const(char)*) core.stdc.string.memchr(p, '\n', end - p)) !is null; ++p)
		++line;
	return line;
}

/// The byte offset where 0-based line `line` starts.
///
/// Returns `fp.pointer.notFound` if `t` has fewer lines.
///
/// Examples:
/// ---
/// static import fp.pointer;
/// auto t = create("a\nbc\n").get;
/// scope(exit) free(t);
/// assert(lineStart(t, 0) == 0 && lineStart(t, 1) == 2 && lineStart(t, 2) == 5);
/// assert(lineStart(t, 3) == fp.pointer.notFound);
/// ---
size_t lineStart(const Rope t, size_t line) @trusted {
	if (line == 0) return 0;
	if (line > newlines(t)) return fp.pointer.notFound;
	auto n = cast(Node*) t.root;
	size_t base = 0;
	while (n.left !is null) {
		if (line <= n.left.newlines) n = n.left;
		else {
			line -= n.left.newlines;
			base += n.left.length;
			n = n.right;
		}
	}
	const(char)* p = bytesOf(n);
	for (;; ++p) {
		p = cast(const(char)*) core.stdc.string.memchr(p, '\n', bytesOf(n) + n.length - p);
		if (--line == 0) return base + (p - bytesOf(n)) + 1;
	}
}

/// Copies bytes `start` to `end` of `t` into `out_`, which must hold `end - start` bytes. It cannot fail.
///
/// Examples:
/// ---
/// auto t = create("hello").get;
/// scope(exit) free(t);
/// char[3] buffer;
/// copy(t, 1, 4, buffer[]);
/// assert(buffer[] == "ell");
/// ---
void copy(const Rope t, size_t start, size_t end, char[] out_) @trusted {
	assert(start <= end && end <= length(t) && out_.length >= end - start, "fp.rope.copy: range out of bounds");
	copyRange(cast(Node*) t.root, start, end, out_.ptr);
}

/// Whether `t`'s bytes from `start` are `s`; false if `t` ends first.
///
/// Examples:
/// ---
/// auto t = create("hello").get;
/// scope(exit) free(t);
/// assert(equal(t, 1, "ell") && !equal(t, 3, "lol"));
/// ---
bool equal(const Rope t, size_t start, const(char)[] s) @trusted {
	if (start > length(t) || s.length > length(t) - start) return false;
	return equalRange(cast(Node*) t.root, start, s);
}


version(unittest) {
	static import core.stdc.stdio;
	static import fp.string;

	private size_t checkBalanced(Node* n) {
		if (n.left is null) {
			assert(n.height == 0 && n.length <= maxLeaf);
			return 0;
		}
		immutable l = checkBalanced(n.left), r = checkBalanced(n.right);
		assert((l > r ? l - r : r - l) <= 1 && n.height == (l > r ? l : r) + 1);
		assert(n.length == n.left.length + n.right.length && n.newlines == n.left.newlines + n.right.newlines);
		return n.height;
	}

	// Whether `t` reads as `s`, checked byte by byte, line by line, and through its balance.
	private bool same(const Rope t, const(char)[] s) @trusted {
		if (length(t) != s.length || !equal(t, 0, s)) return false;
		if (t.root !is null) cast(void) checkBalanced(cast(Node*) t.root);
		size_t line = 0;
		foreach (i, c; s) {
			if (c != '\n') continue;
			if (lineOf(t, i) != line || lineStart(t, line + 1) != i + 1 || lineOf(t, i + 1) != line + 1) return false;
			++line;
		}
		return lineOf(t, s.length) == line && newlines(t) == line && lineStart(t, line + 1) == fp.pointer.notFound;
	}

	private __gshared size_t liveBlocks;
	private __gshared fp.pointer.AllocFunction countedUnderlying;

	private void* countingAlloc(void* p, size_t size) {
		if (p is null && size) ++liveBlocks;
		if (p !is null && size == 0) --liveBlocks;
		return countedUnderlying(p, size);
	}
}

unittest { // versions: edits share what they leave alone, keep every older version intact, and stay balanced
	countedUnderlying = fp.pointer.allocFunction;
	fp.pointer.allocFunction = &countingAlloc;
	scope(exit) fp.pointer.allocFunction = countedUnderlying;

	assert(same(Rope.init, ""));
	char* model = fp.string.makeDynamic("");
	foreach (i; 0 .. 3000) {
		char[24] line;
		immutable n = core.stdc.stdio.snprintf(line.ptr, line.length, "x%d : T = %d\n", cast(int) i, cast(int) i);
		assert(fp.string.concatenate(model, line[0 .. n]) !is null);
	}
	scope(exit) fp.string.free(model);
	auto original = create(fp.string.slice(model)).get;
	assert(same(original, fp.string.slice(model)));

	// A deterministic walk of edits: inserts, deletes and replacements, small and spanning many leaves.
	Rope current = share(original);
	uint seed = 12345;
	uint next() { seed = seed * 1103515245 + 12345; return seed >> 8; }
	foreach (round; 0 .. 400) {
		immutable size = fp.string.length(model);
		immutable start = size ? next() % (size + 1) : 0;
		immutable span = round % 7 == 0 ? next() % (3 * maxLeaf) : next() % 8;
		immutable end = start + span > size ? size : start + span;
		const(char)[] insert = round % 5 == 0 ? "\nlong line inserted here, spanning bytes\n" : round % 3 == 0 ? "" : "q\n";
		auto edited = edit(current, start, end, insert).get;
		assert(fp.string.replaceRange(model, insert, start, end - start) !is null);
		assert(same(edited, fp.string.slice(model)));
		free(current);
		current = edited;
	}
	free(current);
	// The first version is untouched by every edit made from it and its successors.
	fp.string.free(model);
	model = fp.string.makeDynamic("");
	foreach (i; 0 .. 3000) {
		char[24] line;
		immutable n = core.stdc.stdio.snprintf(line.ptr, line.length, "x%d : T = %d\n", cast(int) i, cast(int) i);
		assert(fp.string.concatenate(model, line[0 .. n]) !is null);
	}
	assert(same(original, fp.string.slice(model)));

	// A one-byte edit to a large text copies at most a few leaves and a path of nodes.
	immutable before = liveBlocks;
	auto small = edit(original, 20_000, 20_001, "y").get;
	assert(liveBlocks - before <= 4 * (original.root.height + 2));
	free(small);
	assert(liveBlocks == before);

	// Inserting at the very start, and copying a range that spans leaves.
	auto prefixed = edit(original, 0, 0, "<<").get;
	assert(equal(prefixed, 0, "<<x0 : T = 0\n") && length(prefixed) == length(original) + 2);
	free(prefixed);
	char[2 * maxLeaf] copied;
	copy(original, maxLeaf / 2, maxLeaf / 2 + copied.length, copied[]);
	assert(equal(original, maxLeaf / 2, copied[]));
	copy(original, 5, 5, copied[0 .. 0]);
	free(original);
	assert(liveBlocks == 1); // only the model
}

unittest { // refused allocations: create and edit return null and leave every version as it was
	static immutable text = "a : T = 1\nb : T = 2\n";
	for (size_t budget = 0;; ++budget) {
		auto allocator = fp.testing.beginRationedAllocator(budget);
		auto made = create(text);
		fp.testing.endRationedAllocator(allocator);
		if (made.isNull) continue;
		auto t = made.get;
		scope(exit) free(t);
		assert(same(t, text));
		break;
	}

	char* big = fp.string.makeDynamic("");
	scope(exit) fp.string.free(big);
	foreach (i; 0 .. 10 * maxLeaf / 8) assert(fp.string.concatenate(big, "abcdefg\n") !is null);
	auto base = create(fp.string.slice(big)).get;
	scope(exit) free(base);
	for (size_t budget = 0;; ++budget) {
		auto allocator = fp.testing.beginRationedAllocator(budget);
		auto edited = edit(base, 100, 3 * maxLeaf, "edit");
		fp.testing.endRationedAllocator(allocator);
		assert(same(base, fp.string.slice(big)));
		if (edited.isNull) continue;
		auto t = edited.get;
		scope(exit) free(t);
		assert(length(t) == fp.string.length(big) - (3 * maxLeaf - 100) + 4 && equal(t, 100, "edit"));
		break;
	}
}

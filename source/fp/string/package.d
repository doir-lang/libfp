/// Null-terminated dynamic strings on top of `fp.dynarray`. An fp string is a `char*` dynarray that always ends in a zero byte, so it passes straight to C. A null `char*` is the empty string.
///
/// Every string argument is `isStringLike`: an fp string, a C string, a D slice or literal, or null. A function that creates a string returns a `Nullable!(char*)`, null if an allocation was refused and otherwise the string, itself null when empty. A function that changes a string takes it by `ref` first and returns false if it was refused, leaving the string as it was. A search returns an index or `fp.pointer.notFound`.
///
/// Character classes and case are in `fp.string.ascii`, UTF-8 and UTF-16 in `fp.string.utf`, and writing and reading numbers in `fp.string.numbers`.
///
/// Examples:
/// ---
/// char* s = clone("Hello").get;
/// scope(exit) free(s);
/// assert(concatenate(s, ", World"));
/// assert(equal(s, "Hello, World"));
/// assert(s[length(s)] == '\0');
/// assert(find(s, ',') == 5 && trim("  padded ") == "padded");
/// ---
module fp.string;

static import core.checkedint;
static import core.stdc.stdarg;
static import core.stdc.stdio;
static import core.stdc.string;
static import std.typecons;

static import fp.dynarray;
static import fp.pointer;
static import fp.string.ascii;
static import fp.string.numbers;
static import fp.string.utf;
version(unittest) static import fp.testing;


@nogc nothrow:


// === types =====================================================================

/// Whether the functions here accept an `S` as a string: a `char*` of any qualifier (an fp string or C string), a D slice or literal, or `typeof(null)`. Static arrays are excluded, since they would be copied and sliced on the stack; pass `buffer[]` instead.
///
/// Examples:
/// ---
/// static assert(isStringLike!(char*) && isStringLike!string && isStringLike!(typeof(null)));
/// static assert(!isStringLike!(char[4]) && !isStringLike!(int*) && !isStringLike!char);
/// ---
enum bool isStringLike(S) = !__traits(isStaticArray, S) && (is(S : const(char)[]) || is(S : const(char)*));

/// A D slice over the characters of `text`, keeping its qualifier: a D slice as is, an fp string's recorded length, or a C string's `strlen`. Null gives null.
///
/// Examples:
/// ---
/// char* s = clone("abc").get;
/// scope(exit) free(s);
/// assert(slice(s) == "abc");
/// assert(slice("literal") == "literal");
/// assert(slice("plain C".ptr) == "plain C");
/// assert(slice(null) is null);
/// ---
auto slice(S)(S text) @trusted if (isStringLike!S) {
	// A literal converts equally well to a pointer and to a slice, so separate overloads would be ambiguous for it.
	static if (is(S == typeof(null))) return (char[]).init;
	else static if (is(S : const(char)[])) return text[];
	else {
		if (text is null) return text[0 .. 0];
		if (fp.pointer.valid(text)) return text[0 .. fp.pointer.length(text)];
		return text[0 .. core.stdc.string.strlen(text)];
	}
}


unittest {
	char[5] hello = "hello";
	assert(slice(hello[]) == "hello");
	assert(slice(null) is null);
	// A literal converts to both a pointer and a slice, which made separate overloads ambiguous.
	assert(slice("hello") == "hello");
	static assert(is(typeof(slice("hello")) == string));
	static assert(is(typeof(slice(hello[])) == char[]));
	assert(slice(cast(const(char)*) null) is null && slice("C string".ptr) == "C string");
}


// === queries ===================================================================

// wrapper: container vocabulary every reader knows
/// The number of characters (bytes) in `text`, excluding the terminator.
///
/// Examples:
/// ---
/// char* s = clone("four").get;
/// scope(exit) free(s);
/// assert(length(s) == 4 && length("abc") == 3);
/// assert(length(null) == 0);
/// ---
size_t length(S)(S text) if (isStringLike!S) {
	return slice(text).length;
}

/// Orders two strings lexicographically by their bytes, a shorter string before any it is a prefix of: negative if `a` sorts first, zero if equal, positive otherwise.
///
/// Examples:
/// ---
/// assert(compare("abc", "abc".ptr) == 0);
/// assert(compare("aa", "b") < 0 && compare("ab", "aa") > 0);
/// assert(compare("ab", "abc") < 0 && compare(null, "") == 0);
/// ---
int compare(A, B)(A a, B b) @trusted if (isStringLike!A && isStringLike!B) {
	const(char)[] x = slice(a), y = slice(b);
	immutable common = x.length < y.length ? x.length : y.length;
	immutable order = common == 0 ? 0 : core.stdc.string.memcmp(x.ptr, y.ptr, common);
	if (order != 0) return order;
	return x.length < y.length ? -1 : x.length > y.length ? 1 : 0;
}

/// Whether `a` and `b` hold the same characters.
///
/// Examples:
/// ---
/// char* s = clone("same").get;
/// scope(exit) free(s);
/// assert(equal(s, "same"));
/// assert(!equal(s, "different"));
/// ---
bool equal(A, B)(A a, B b) @trusted if (isStringLike!A && isStringLike!B) {
	const(char)[] x = slice(a), y = slice(b);
	return x.length == y.length && (x.length == 0 || core.stdc.string.memcmp(x.ptr, y.ptr, x.length) == 0);
}


unittest {
	// Every form `isStringLike` admits reads as the same text.
	char[3] buffer = "abc";
	char* dynamic = clone(buffer[]).get;
	scope(exit) free(dynamic);
	const(char)* constant = dynamic;
	immutable(char)* literal = "abc".ptr;
	const(char)[] view = buffer[];
	assert(equal(dynamic, constant) && equal(constant, literal) && equal(literal, view) && equal(view, "abc"));
	assert(equal(null, "") && equal(cast(char*) null, null) && compare(null, "a") < 0);
	assert(length(dynamic) == 3 && length(constant) == 3 && length(view) == 3);

	assert(compare("Hello World", "Hello World") == 0);
	assert(compare("Hello World", "Hello World!") < 0 && compare("Hello World!", "Hello World") > 0);
	assert(compare("b", "aa") > 0 && compare("\xFF", "\x01") > 0); // bytes compare unsigned
	assert(!equal("ab", "abc") && !equal("abc", "abd"));
}


// === search ====================================================================

// A needle is a string or a single character.
private enum bool isNeedle(N) = isStringLike!N || is(immutable N == immutable char);

private const(char)[] needleText(N)(return ref N needle) @trusted {
	static if (isStringLike!N) return slice(needle);
	else return (&needle)[0 .. 1];
}

/// The index of the first `needle`, a string or a character, in `haystack` at or after `start` (0 by default), or `fp.pointer.notFound`, including when `start` is past the end.
///
/// Examples:
/// ---
/// assert(find("abcabc", "bc", 2) == 4 && find("abcabc", 'c') == 2);
/// assert(find("abc", "x") == fp.pointer.notFound);
/// assert(find("abc", "abc", 4) == fp.pointer.notFound);
/// ---
size_t find(H, N)(H haystack, N needle, size_t start = 0) @trusted if (isStringLike!H && isNeedle!N) {
	const(char)[] text = slice(haystack), pattern = needleText(needle);
	if (start > text.length || pattern.length > text.length - start) return fp.pointer.notFound;
	if (pattern.length == 0) return start;

	immutable last = text.length - pattern.length;
	for (size_t at = start; at <= last; ++at) {
		auto hit = cast(const(char)*) core.stdc.string.memchr(text.ptr + at, pattern[0], last - at + 1);
		if (hit is null) break;
		at = hit - text.ptr;
		if (core.stdc.string.memcmp(hit + 1, pattern.ptr + 1, pattern.length - 1) == 0) return at;
	}
	return fp.pointer.notFound;
}

/// The index of the last `needle`, a string or a character, in `haystack`, or `fp.pointer.notFound`. An empty `needle` is found at the end.
///
/// Examples:
/// ---
/// assert(findLast("a/b/c", '/') == 3 && findLast("abcabc", "abc") == 3);
/// assert(findLast("abc", "x") == fp.pointer.notFound && findLast("abc", "") == 3);
/// ---
size_t findLast(H, N)(H haystack, N needle) @trusted if (isStringLike!H && isNeedle!N) {
	const(char)[] text = slice(haystack), pattern = needleText(needle);
	if (pattern.length > text.length) return fp.pointer.notFound;
	for (size_t at = text.length - pattern.length + 1; at-- > 0;)
		if (text[at .. at + pattern.length] == pattern) return at;
	return fp.pointer.notFound;
}

// wrapper: container vocabulary every reader knows
/// Whether `needle`, a string or a character, occurs in `haystack` at or after `start` (0 by default).
///
/// Examples:
/// ---
/// assert(contains("haystack", "st") && contains("haystack", 'k'));
/// assert(!contains("haystack", "hay", 1));
/// ---
bool contains(H, N)(H haystack, N needle, size_t start = 0) if (isStringLike!H && isNeedle!N) {
	return find(haystack, needle, start) != fp.pointer.notFound;
}

/// Whether `needle`, a string or a character, occurs in `haystack` starting exactly at `start` (0 by default); false for a `start` past the end.
///
/// Examples:
/// ---
/// assert(startsWith("prefix", "pre") && startsWith("prefix", 'p'));
/// assert(startsWith("prefix", "fix", 3));
/// ---
bool startsWith(H, N)(H haystack, N needle, size_t start = 0) @trusted if (isStringLike!H && isNeedle!N) {
	const(char)[] text = slice(haystack), pattern = needleText(needle);
	if (start > text.length || pattern.length > text.length - start) return false;
	return text[start .. start + pattern.length] == pattern;
}

/// Whether `haystack` ends with `needle`, a string or a character. To ask whether `needle` ends at index `end`, pass `slice(haystack)[0 .. end]`.
///
/// Examples:
/// ---
/// assert(endsWith("suffix", "fix") && endsWith("suffix", 'x') && endsWith("suffix", ""));
/// assert(!endsWith("suffix", "suf") && endsWith(slice("suffix")[0 .. 3], "suf"));
/// ---
bool endsWith(H, N)(H haystack, N needle) @trusted if (isStringLike!H && isNeedle!N) {
	const(char)[] text = slice(haystack), pattern = needleText(needle);
	return pattern.length <= text.length && text[$ - pattern.length .. $] == pattern;
}


unittest { // searches at the ends, past them, and through every argument form
	char* bang = clone("Hello World!").get;
	scope(exit) free(bang);
	assert(find(bang, "World!") == 6 && contains(bang, "World!"));
	assert(find(bang, "zzz") == fp.pointer.notFound && !contains(bang, "zzz"));
	assert(find(bang, "", length(bang)) == length(bang) && find(bang, "", 100) == fp.pointer.notFound);
	assert(find(bang, '!') == 11 && find(bang, 'o', 5) == 7 && find(bang, 'o', 8) == fp.pointer.notFound);
	assert(find("aab", "ab") == 1 && find("ababac", "abac") == 2 && find("abc", "c", 2) == 2 && find("abc", "bc", 2) == fp.pointer.notFound);
	assert(startsWith(bang, "Hello") && endsWith(bang, "World!") && !endsWith(bang, "World"));
	assert(startsWith(bang, "", length(bang)) && !startsWith(bang, "", 100) && !startsWith(bang, "", size_t.max));
	assert(!startsWith("", 'a') && !endsWith("", 'a') && !endsWith("ab", "abc"));
	assert(findLast("", "") == 0 && findLast("", 'a') == fp.pointer.notFound && findLast("aaa", "aa") == 1);
	assert(findLast("abcab", "abd") == fp.pointer.notFound);

	char* s = clone("one two one").get;
	scope(exit) free(s);
	const(char)[] one = slice(s)[0 .. 3];
	assert(find(s, one, 1) == 8 && contains(slice(s), "two".ptr) && findLast(s, one) == 8);
	assert(startsWith(slice(s), one) && endsWith(s, one));
}


// === views =====================================================================

private bool among(const(char)[] characters, char c) {
	foreach (candidate; characters)
		if (candidate == c) return true;
	return false;
}

/// `text` without its leading run of the bytes in `characters` (ASCII whitespace by default), as a slice of it keeping its qualifier.
///
/// Examples:
/// ---
/// assert(trimStart("  \tvalue ") == "value " && trimStart("--x", "-") == "x");
/// ---
auto trimStart(S)(S text, const(char)[] characters = fp.string.ascii.whitespace) if (isStringLike!S) {
	auto view = slice(text);
	size_t start = 0;
	while (start < view.length && among(characters, view[start])) ++start;
	return view[start .. $];
}

/// `text` without its trailing run of the bytes in `characters` (ASCII whitespace by default), as a slice of it keeping its qualifier.
///
/// Examples:
/// ---
/// assert(trimEnd("value \t\r\n") == "value" && trimEnd("x--", "-") == "x");
/// assert(trimEnd("  ", " ") == "");
/// ---
auto trimEnd(S)(S text, const(char)[] characters = fp.string.ascii.whitespace) if (isStringLike!S) {
	auto view = slice(text);
	size_t end = view.length;
	while (end > 0 && among(characters, view[end - 1])) --end;
	return view[0 .. end];
}

/// `text` without its leading and trailing runs of the bytes in `characters` (ASCII whitespace by default), as a slice of it keeping its qualifier.
///
/// Examples:
/// ---
/// assert(trim("  value \t") == "value" && trim("--x-", "-") == "x" && trim(" \n ") == "");
/// ---
auto trim(S)(S text, const(char)[] characters = fp.string.ascii.whitespace) if (isStringLike!S) {
	auto view = slice(text);
	size_t start = 0, end = view.length;
	while (start < end && among(characters, view[start])) ++start;
	while (end > start && among(characters, view[end - 1])) --end;
	return view[start .. end];
}

/// Splits `text` on every occurrence of `delimiter`, which must not be empty. Returns a new `fp.dynarray` of slices into `text`, so `text` must outlive them; free the dynarray itself with `fp.dynarray.free`. Returns null if an allocation was refused; on success it holds at least one slice, so it is never null.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// const(char)[]* parts = split("a,b,,c", ",");
/// scope(exit) fp.dynarray.free(parts);
/// assert(fp.dynarray.length(parts) == 4);
/// assert(parts[0] == "a" && parts[2] == "" && parts[3] == "c");
/// ---
const(char)[]* split(S, D)(S text, D delimiter) @trusted if (isStringLike!S && isNeedle!D) {
	const(char)[] view = slice(text), pattern = needleText(delimiter);
	assert(pattern.length > 0);
	const(char)[]* result = null;

	size_t start = 0;
	while (true) {
		immutable position = find(view, pattern, start);
		immutable end = position == fp.pointer.notFound ? view.length : position;
		if (!fp.dynarray.pushBack(result, view[start .. end])) {
			fp.dynarray.free(result);
			return null;
		}
		if (position == fp.pointer.notFound) break;
		start = position + pattern.length;
	}
	return result;
}


unittest { // trims keep qualifiers and stop at the other end; splits on characters and strings
	static assert(is(typeof(trim("x")) == string) && is(typeof(trimStart(cast(char[]) null)) == char[]));
	assert(trim("") == "" && trim(null) == "" && trimStart("   ") == "" && trimEnd("a b") == "a b");
	assert(trimEnd("ab\t \t", " \t") == "ab" && trim("ab", "") == "ab" && trim("\v\fa\f\v") == "a");
	char* padded = clone(" x ").get;
	scope(exit) free(padded);
	assert(trim(padded) == "x" && trim(padded).ptr is padded + 1);

	const(char)[]* parts = split("a,bb,,ccc", ',');
	scope(exit) fp.dynarray.free(parts);
	assert(fp.dynarray.length(parts) == 4);
	assert(parts[0] == "a" && parts[1] == "bb" && parts[2] == "" && parts[3] == "ccc");

	char* colons = clone("a::bb::ccc").get;
	scope(exit) free(colons);
	char* delimiter = clone("::").get;
	scope(exit) free(delimiter);
	const(char)[]* byString = split(colons, delimiter);
	scope(exit) fp.dynarray.free(byString);
	assert(fp.dynarray.length(byString) == 3);
	assert(byString[0] == "a" && byString[1] == "bb" && byString[2] == "ccc");

	const(char)[]* whole = split("no-delimiter-here", ",");
	scope(exit) fp.dynarray.free(whole);
	assert(fp.dynarray.length(whole) == 1 && whole[0] == "no-delimiter-here");

	// The first allocation holds one slice, or two where slices are 8 bytes, so a later push is refused, leaving a partial result.
	auto rationed = fp.testing.limitAllocations(1);
	assert(split("a,b,c", ",") is null);
	fp.testing.restoreAllocator(rationed);
}


// === lines =====================================================================

/// Whether a line break ends at byte `at` of `text`, which must be within it: true at a `\n`, and at a `\r` not followed by `\n`, so `\n`, `\r\n` and a lone `\r` each count once, at their last byte. Every line function here, and `fp.rope`, breaks lines by this rule.
///
/// Examples:
/// ---
/// assert(breaksLine("a\nb", 1) && breaksLine("a\rb", 1) && breaksLine("a\r", 1));
/// assert(!breaksLine("a\r\nb", 1) && breaksLine("a\r\nb", 2) && !breaksLine("ab", 0));
/// ---
bool breaksLine(const(char)[] text, size_t at) {
	assert(at < text.length, "fp.string.breaksLine: offset out of bounds");
	return text[at] == '\n' || (text[at] == '\r' && (at + 1 == text.length || text[at + 1] != '\n'));
}

/// The number of line breaks in `text`, as `breaksLine` counts them: one less than its number of lines.
///
/// Examples:
/// ---
/// assert(lineBreakCount("a\nb\r\nc\rd") == 3 && lineBreakCount("") == 0 && lineBreakCount("a\n") == 1);
/// ---
size_t lineBreakCount(S)(S text) if (isStringLike!S) {
	const(char)[] view = slice(text);
	size_t count = 0;
	foreach (at; 0 .. view.length)
		if (breaksLine(view, at)) ++count;
	return count;
}

/// The 0-based line byte `at` of `text` lies on: the number of line breaks before it. `at` may be `length(text)`.
///
/// Examples:
/// ---
/// assert(lineOf("a\nbc\n", 0) == 0 && lineOf("a\nbc\n", 2) == 1 && lineOf("a\nbc\n", 5) == 2);
/// assert(lineOf("a\r\nb", 1) == 0 && lineOf("a\r\nb", 3) == 1);
/// ---
size_t lineOf(S)(S text, size_t at) if (isStringLike!S) {
	const(char)[] view = slice(text);
	assert(at <= view.length, "fp.string.lineOf: offset out of bounds");
	size_t line = 0;
	foreach (i; 0 .. at)
		if (breaksLine(view, i)) ++line;
	return line;
}

/// The byte offset where 0-based line `line` of `text` starts, or `fp.pointer.notFound` if `text` has fewer lines.
///
/// Examples:
/// ---
/// assert(lineStart("a\nbc\n", 0) == 0 && lineStart("a\nbc\n", 1) == 2 && lineStart("a\nbc\n", 2) == 5);
/// assert(lineStart("a\nbc\n", 3) == fp.pointer.notFound);
/// ---
size_t lineStart(S)(S text, size_t line) if (isStringLike!S) {
	if (line == 0) return 0;
	const(char)[] view = slice(text);
	foreach (at; 0 .. view.length)
		if (breaksLine(view, at) && --line == 0) return at + 1;
	return fp.pointer.notFound;
}

/// Where the line holding byte `start` of `text` ends: the offset of the line break after `start`, or `length(text)` if none follows. `start` may be `length(text)`.
///
/// Examples:
/// ---
/// assert(lineEnd("ab\r\ncd", 0) == 2 && lineEnd("ab\r\ncd", 4) == 6 && lineEnd("a\nb", 1) == 1);
/// ---
size_t lineEnd(S)(S text, size_t start) if (isStringLike!S) {
	const(char)[] view = slice(text);
	assert(start <= view.length, "fp.string.lineEnd: offset out of bounds");
	foreach (at; start .. view.length)
		if (view[at] == '\n' || view[at] == '\r') return at;
	return view.length;
}


unittest { // every line function agrees with the others on text mixing all three breaks
	static immutable string text = "one\r\ntwo\n\rthree\r\r\nfour\n";
	assert(lineBreakCount(text) == 6);
	size_t line = 0;
	foreach (at; 0 .. text.length + 1) {
		assert(lineOf(text, at) == line);
		if (at < text.length && breaksLine(text, at)) {
			++line;
			assert(lineStart(text, line) == at + 1);
		}
	}
	assert(lineStart(text, line + 1) == fp.pointer.notFound && line == lineBreakCount(text));
	foreach (i; 0 .. line + 1) {
		immutable start = lineStart(text, i), end = lineEnd(text, start);
		immutable next = i == line ? text.length : lineStart(text, i + 1);
		assert(start <= end && end <= next && trimEnd(text[start .. next], "\r\n") == text[start .. end]);
	}
	assert(lineEnd("", 0) == 0 && lineOf("", 0) == 0 && lineStart("", 0) == 0 && lineStart("", 1) == fp.pointer.notFound);
}


// === creation and freeing ======================================================

/// A new fp string holding a copy of `text`, null if `text` is empty, since null is the empty string. Returns null, rather than a null string, if the copy could not be allocated.
///
/// Examples:
/// ---
/// char* a = clone("text").get;
/// scope(exit) free(a);
/// char* b = clone(a).get;
/// scope(exit) free(b);
/// assert(b !is a && equal(a, b));
/// assert(clone("").get is null);
/// ---
std.typecons.Nullable!(char*) clone(S)(S text) @trusted if (isStringLike!S) {
	const(char)[] view = slice(text);
	if (view.length == 0) return typeof(return)(null);
	char* out_ = null;
	if (fp.dynarray.growToSize(out_, view.length) is null) return typeof(return).init;
	core.stdc.string.memcpy(out_, view.ptr, view.length);
	return typeof(return)(out_);
}

/// Frees `text`, which may be an fp string, a plain heap fat pointer, or memory straight from `fp.pointer.allocator`; each is released by its own layer. A stack fat pointer (from `fp.pointer.Array` or `fp.pointer.allocateOnStack`) belongs to its frame and is left alone. A hash table is rejected and left untouched, since only `fp.hashtable.free` can release it. Anything else is passed to `fp.pointer.allocator` as though it came from it, so a string literal or a stack buffer must not be freed here. The `ref` overload also sets `text` to null, unless it was rejected.
///
/// Examples:
/// ---
/// char* s = clone("bye").get;
/// free(s);
/// assert(s is null);
/// ---
void free(ref char* text) @trusted {
	// Nulling a rejected table would lose the caller's only handle to it.
	if (fp.pointer.pointerType(text) == fp.pointer.PointerType.hashTable) return;
	free(cast(const char*) text);
	text = null;
}
/// Ditto
void free(const char* text) @trusted {
	immutable type = fp.pointer.pointerType(text);
	if (type == fp.pointer.PointerType.stack || type == fp.pointer.PointerType.hashTable) return;
	if (fp.dynarray.valid(text)) fp.dynarray.free(text);
	else if (fp.pointer.valid(text) && fp.pointer.onHeap(text)) fp.pointer.free(text);
	else cast(void)fp.pointer.allocator(cast(void*) text, 0);
}


unittest {
	char* dynamic = clone("abc").get;
	scope(exit) free(dynamic);
	assert(fp.pointer.valid(dynamic) && fp.dynarray.valid(dynamic));
	assert(!fp.pointer.onStack(dynamic) && fp.pointer.onHeap(dynamic));
	assert(length(dynamic) == 3 && dynamic[3] == 0); // fp strings are null terminated!
	assert(clone(null).get is null && clone(cast(char*) null).get is null);
	auto rationed = fp.testing.limitAllocations(0);
	assert(clone("x").isNull && clone("").get is null);
	fp.testing.restoreAllocator(rationed);

	// Null takes every branch of the by-value overload harmlessly.
	free(null);
	char* heapText = fp.pointer.allocate!char(4);
	assert(heapText !is null);
	free(heapText);
	char* nullText = null;
	free(nullText);
	assert(nullText is null);
	fp.pointer.Array!(char, 4) onStack;
	onStack[0] = 'h';
	char* stackText = onStack;
	free(stackText);
	assert(stackText is null && onStack[0] == 'h');
	static import fp.hashtable;
	char* table = fp.hashtable.create!char();
	assert(table !is null && fp.hashtable.insert(table, 'h') !is null);
	free(table);
	free(cast(const char*) table);
	assert(table !is null && fp.hashtable.contains(table, 'h'));
	fp.hashtable.free(table);
}


// === growth ====================================================================

// Only a dynarray can grow in place, so a plain heap or stack pointer is refused instead of asserted away.
private bool growable(const char* text) @trusted {
	return text is null || fp.dynarray.valid(cast(void*) text);
}

/// Appends `b` to `a`, which may be null. Returns false if `a` could not grow or is a pointer that is not an fp string and so cannot grow, leaving it unchanged; appending nothing to a string that could grow succeeds.
///
/// Examples:
/// ---
/// static import fp.pointer;
/// char* s = null;
/// scope(exit) free(s);
/// assert(concatenate(s, "ab"));
/// assert(concatenate(s, "cd".ptr));
/// assert(concatenate(s, ""));
/// assert(equal(s, "abcd"));
///
/// char* heap = fp.pointer.allocate!char(4);
/// assert(!concatenate(heap, "!"));
/// free(heap);
/// ---
bool concatenate(S)(ref char* a, S b) @trusted if (isStringLike!S) {
	if (!growable(a)) return false;
	const(char)[] view = slice(b);
	if (view.length == 0) return true;
	if (!fp.dynarray.concatenate(a, view)) return false;
	// The NUL written at allocation sits at the end of the capacity, which may run past the string.
	a[length(a)] = 0;
	return true;
}

// Characters and numbers go through a stack buffer, not `format`, which would heap-allocate for every one appended. Returns false only if an allocation was refused.
private bool appendPiece(T)(ref char* text, T piece) @trusted {
	// `is(T : const(char)*)` covers every qualifier `slice` accepts; naming them individually once missed `immutable(char)*`, a literal's `.ptr`.
	static if (is(T : const(char)[]) || is(T : const(char)*)) {
		return concatenate(text, slice(piece));
	} else static if (is(immutable T == immutable char)) {
		return concatenate(text, (&piece)[0 .. 1]);
	} else static if (is(immutable T == immutable wchar) || is(immutable T == immutable dchar)) {
		char[4] buffer;
		size_t n = fp.string.utf.encode(piece, buffer);
		if (n == 0) n = fp.string.utf.encode(0xFFFD, buffer);
		return concatenate(text, buffer[0 .. n]);
	} else static if (is(T : real) && !is(T : long) && !is(T : ulong)) {
		return fp.string.numbers.appendFloat(text, cast(double) piece);
	} else static if (__traits(isUnsigned, T)) {
		return fp.string.numbers.appendUnsigned(text, piece);
	} else static if (is(T : long)) {
		return fp.string.numbers.appendSigned(text, piece);
	} else static assert(0, "fp.string: cannot append a " ~ T.stringof);
}

/// Appends every piece to `text`, which may be null: slices, fp strings, characters, and numbers (integers in decimal, floating point in the shortest form that reads back as the same `double`). A `wchar` or `dchar` is encoded as UTF-8, and one that cannot be, such as a lone surrogate, as U+FFFD. A piece may view `text` itself. Returns false if an allocation was refused, leaving `text` as it was.
///
/// Examples:
/// ---
/// char* s = null;
/// scope(exit) free(s);
/// assert(append(s, "line ", 42, ": ", 1.5, '!', '€'));
/// assert(equal(s, "line 42: 1.5!€"));
/// assert(append(s, 'x') && append(s, 0.1));
/// assert(equal(s, "line 42: 1.5!€x0.1"));
/// ---
bool append(Args...)(ref char* text, Args pieces) @trusted {
	// An earlier piece may move `text`, so pieces viewing it are copied before any is appended.
	const(char)[][Args.length] views;
	char*[Args.length] copies;
	scope(exit) foreach (ref copy; copies) free(copy);
	static foreach (i, A; Args) static if (isStringLike!A) {
		views[i] = slice(pieces[i]);
		if (fp.dynarray.overlaps(text, views[i])) {
			auto cloned = clone(views[i]);
			if (cloned.isNull) return false;
			copies[i] = cloned.get;
			views[i] = slice(copies[i]);
		}
	}

	immutable wasNull = text is null;
	immutable before = length(text);
	static foreach (i, A; Args) {{
		static if (isStringLike!A) immutable appended = appendPiece(text, views[i]);
		else immutable appended = appendPiece(text, pieces[i]);
		if (!appended) {
			if (wasNull) free(text);
			else {
				cast(void)fp.dynarray.removeLast(text, length(text) - before);
				text[before] = 0;
			}
			return false;
		}
	}}
	return true;
}

/// A new fp string of every piece, as `append` writes them; it is null, the empty string, when every piece is empty. Returns null, rather than a null string, if an allocation was refused.
///
/// Examples:
/// ---
/// char* s = joined("n=", -7, "!").get;
/// scope(exit) free(s);
/// assert(equal(s, "n=-7!"));
/// assert(joined("").get is null);
/// ---
std.typecons.Nullable!(char*) joined(Args...)(Args pieces) {
	char* out_ = null;
	if (!append(out_, pieces)) return typeof(return).init;
	return typeof(return)(out_);
}

private enum bool isSliceArg(T) = isStringLike!T && !is(T : const(char)*);

private alias aliasSeq(T...) = T;

// `Args` with each slice replaced by the C string `format` passes in its place, and top-level qualifiers dropped so the copies can be assigned.
private template cArgTypes(Args...) {
	static if (Args.length == 0) alias cArgTypes = Args;
	else static if (isSliceArg!(Args[0])) alias cArgTypes = aliasSeq!(const(char)*, cArgTypes!(Args[1 .. $]));
	else alias cArgTypes = aliasSeq!(typeof(cast() Args[0].init), cArgTypes!(Args[1 .. $]));
}

// Null if `vsnprintf` rejected the format or the result could not be allocated; a null string if the result is empty.
private extern (C) std.typecons.Nullable!(char*) formatC(const char* pattern, ...) @trusted {
	core.stdc.stdarg.va_list sizing;
	core.stdc.stdarg.va_start(sizing, pattern);
	immutable size = core.stdc.stdio.vsnprintf(null, 0, pattern, sizing);
	core.stdc.stdarg.va_end(sizing);
	if (size < 0) return typeof(return).init;
	if (size == 0) return typeof(return)(null);

	char* out_ = null;
	if (fp.dynarray.growToSize(out_, size) is null) return typeof(return).init;
	core.stdc.stdarg.va_list args;
	core.stdc.stdarg.va_start(args, pattern);
	cast(void)core.stdc.stdio.vsnprintf(out_, size + 1, pattern, args);
	core.stdc.stdarg.va_end(args);
	return typeof(return)(out_);
}

/// A new fp string formatted by `vsnprintf`, null if the result is empty. A slice argument may stand where `%s` expects a string: it is passed as a null-terminated copy, since C varargs cannot carry a D slice. Returns null, rather than a null string, if `vsnprintf` rejected the format or an allocation, of a copy or of the result, was refused.
///
/// Examples:
/// ---
/// char* s = format("%d-%s-%s", 7, "slice", "C string".ptr).get;
/// scope(exit) free(s);
/// assert(equal(s, "7-slice-C string"));
/// assert(format("").get is null);
/// ---
std.typecons.Nullable!(char*) format(Args...)(const char* pattern, Args args) @trusted {
	cArgTypes!Args cArgs;
	scope(exit) static foreach (i, A; Args) static if (isSliceArg!A) if (args[i].length != 0) free(cArgs[i]);
	static foreach (i, A; Args) {
		static if (isSliceArg!A) {
			if (args[i].length == 0) cArgs[i] = "".ptr;
			else {
				auto cloned = clone(args[i]);
				if (cloned.isNull) return typeof(return).init;
				cArgs[i] = cloned.get;
			}
		} else cArgs[i] = args[i];
	}
	return formatC(pattern, cArgs);
}


unittest {
	char* text = null;
	scope(exit) free(text);
	foreach (c; "abc") assert(append(text, c));
	assert(slice(text) == "abc");
	assert(text[3] == '\0');
	assert(concatenate(text, "!"));
	assert(concatenate(text, " bob"));
	assert(equal(text, "abc! bob"));
	assert(append(text, "") && concatenate(text, "") && equal(text, "abc! bob")); // an empty piece is not a failure

	// A pointer that is not an fp string cannot grow in place, so appending to it is refused rather than asserted away.
	char* heap = fp.pointer.allocate!char(4);
	assert(heap !is null);
	assert(!concatenate(heap, "x") && !append(heap, 'y'));
	assert(!repeat(heap, 2) && !replaceRange(heap, 0, 1, "z") && !replaceAll(heap, "a", "b"));
	free(heap);
	assert(heap is null);

	fp.pointer.Array!(char, 4) onStack;
	onStack[0] = 'a';
	char* stackText = onStack;
	assert(fp.pointer.pointerType(stackText) == fp.pointer.PointerType.stack);
	assert(!concatenate(stackText, "b") && !append(stackText, 'c'));

	// Characters are appended as text, not as their numeric values.
	char* chars = joined('a', cast(const char) 'b', wchar('é'), dchar(0x1F600), cast(wchar) 0xD800, cast(dchar) 0x110000).get;
	scope(exit) free(chars);
	assert(slice(chars) == "abé\U0001F600��");

	char* name = clone("verify.d").get;
	scope(exit) free(name);
	char* out_ = null;
	scope(exit) free(out_);
	assert(append(out_, "at ", name, ":", 42, " of ", 100UL));
	assert(slice(out_) == "at verify.d:42 of 100");

	char* made = joined("n=", -7, " x=", 1.5, " y=", 0.1, " z=", 1e300, " w=", double.nan).get;
	scope(exit) free(made);
	assert(slice(made) == "n=-7 x=1.5 y=0.1 z=1e+300 w=nan");

	// A refused allocation in joined is null, distinct from the empty string.
	auto rationed = fp.testing.limitAllocations(0);
	assert(joined("x").isNull);
	fp.testing.restoreAllocator(rationed);
	assert(!joined("").isNull && joined("").get is null);

	char* extremes = joined(ulong.max, " ", long.min, " ", ubyte(200), " ", true).get;
	scope(exit) free(extremes);
	assert(slice(extremes) == "18446744073709551615 -9223372036854775808 200 1");

	char* nothing = null;
	char* withNull = joined("a", nothing, "b").get;
	scope(exit) free(withNull);
	assert(slice(withNull) == "ab");

	char* world = clone("World").get;
	scope(exit) free(world);
	char* mixed = joined("Hello, ".ptr, world, "!".ptr).get;
	scope(exit) free(mixed);
	assert(equal(mixed, "Hello, World!"));

	char* formatted = format("%s %s%c\n", "Hello".ptr, "World".ptr, '!').get;
	scope(exit) free(formatted);
	assert(equal(formatted, "Hello World!\n"));
	char[5] worldBuffer = "World";
	char* formattedSlices = format("%s %s%c%s", "Hello", worldBuffer[], '!', "").get;
	scope(exit) free(formattedSlices);
	assert(equal(formattedSlices, "Hello World!"));
	assert(format("%s", "").get is null && format("").get is null);
	const size_t constNumber = 7;
	immutable(char)* immutablePointer = "imm".ptr;
	const char* constPointer = "c".ptr;
	char* formattedQualified = format("%03zu %s %s", constNumber, immutablePointer, constPointer).get;
	scope(exit) free(formattedQualified);
	assert(equal(formattedQualified, "007 imm c"));
}

unittest { // refusals leave the string as it was
	fp.pointer.Allocator previous;

	// Refused at the copy of the slice argument, then at the result.
	foreach (allowed; 0 .. 2) {
		previous = fp.testing.limitAllocations(allowed);
		assert(format("%s", "text").isNull);
		fp.testing.restoreAllocator(previous);
	}

	// A refused push must leave the string untouched, not write a terminator through the null it leaves.
	char* text = null;
	previous = fp.testing.limitAllocations();
	assert(!append(text, 'a'));
	fp.testing.restoreAllocator(previous);
	assert(text is null);

	assert(append(text, 'a'));
	scope(exit) free(text);
	while (fp.dynarray.length(text) < fp.dynarray.capacity(text))
		assert(append(text, 'a'));
	immutable filled = length(text);
	previous = fp.testing.limitAllocations();
	assert(!append(text, 'b'));
	fp.testing.restoreAllocator(previous);
	assert(length(text) == filled && text[filled] == '\0');

	char* s = clone("x").get;
	scope(exit) free(s);
	previous = fp.testing.limitAllocations();
	assert(!append(s, "more", 1));
	fp.testing.restoreAllocator(previous);
	assert(equal(s, "x"));

	// The first piece is appended and the second refused: the first must be taken back off.
	previous = fp.testing.limitAllocations(1);
	assert(!append(s, "abc", "a piece longer than the first allocation"));
	fp.testing.restoreAllocator(previous);
	assert(equal(s, "x") && s[1] == '\0');

	// The first piece fits the first allocation; the second needs another.
	previous = fp.testing.limitAllocations(1);
	assert(joined("abc", "a piece longer than the first allocation").isNull);
	fp.testing.restoreAllocator(previous);
}


// === edit ======================================================================

/// Repeats fp string `text` so it holds `times` copies of itself. A `times` of 0 frees it, leaving null, and an empty `text` stays as it is. Returns false if an allocation was refused, the length would overflow, or `text` is a pointer that is not an fp string and so cannot grow, leaving `text` unchanged.
///
/// Examples:
/// ---
/// char* s = clone("ab").get;
/// scope(exit) free(s);
/// assert(repeat(s, 3));
/// assert(equal(s, "ababab"));
/// ---
bool repeat(ref char* text, size_t times) @trusted {
	if (!growable(text)) return false;
	if (times == 0) {
		free(text);
		return true;
	}
	immutable once = length(text);
	if (once == 0 || times == 1) return true;
	bool overflow = false;
	immutable total = core.checkedint.mulu(once, times, overflow);
	if (overflow || fp.dynarray.growToSize(text, total) is null) return false;
	foreach (copy; 1 .. times)
		core.stdc.string.memcpy(text + copy * once, text, once);
	text[total] = 0;
	return true;
}

/// Replaces the `count` characters of fp string `text` starting at `start`, which must fit within it, with `replacement`, which may view `text` itself. Returns false if an allocation was refused or `text` is a pointer that is not an fp string and so cannot grow, leaving it unchanged.
///
/// Examples:
/// ---
/// char* s = clone("Hello World").get;
/// scope(exit) free(s);
/// assert(replaceRange(s, 6, 5, "Bob"));
/// assert(equal(s, "Hello Bob"));
/// ---
bool replaceRange(S)(ref char* text, size_t start, size_t count, S replacement) @trusted if (isStringLike!S) {
	if (!growable(text)) return false;
	const(char)[] with_ = slice(replacement);
	immutable before = length(text);
	assert(count <= before && start <= before - count, "fp.string.replaceRange: range out of bounds");
	immutable end = start + count;

	// `memmove`, not `memcpy`: `replacement` may view `text` itself.
	if (count > with_.length) {
		core.stdc.string.memmove(text + start, with_.ptr, with_.length);
		cast(void)fp.dynarray.removeRange(text, start + with_.length, count - with_.length);
	} else if (with_.length > count) {
		// Growing may free a `replacement` that views `text`, and the shift moves its bytes, so it is copied first.
		char* copy = null;
		scope(exit) free(copy);
		if (fp.dynarray.overlaps(text, with_)) {
			auto cloned = clone(with_);
			if (cloned.isNull) return false;
			copy = cloned.get;
			with_ = slice(copy);
		}
		if (fp.dynarray.grow(text, with_.length - count) is null) return false;
		core.stdc.string.memmove(text + start + with_.length, text + end, before - end);
		core.stdc.string.memcpy(text + start, with_.ptr, with_.length);
	} else if (with_.length != 0) {
		core.stdc.string.memmove(text + start, with_.ptr, with_.length);
	}
	if (text !is null) text[length(text)] = 0;
	return true;
}

/// Replaces the first `needle` at or after `start` (0 by default) in fp string `text` with `replacement`. Returns where it was found, `fp.pointer.notFound`, or `fp.pointer.allocationRefused` if `text` could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// static import fp.pointer;
/// char* s = clone("a-b-c").get;
/// scope(exit) free(s);
/// assert(replaceFirst(s, "-", "+") == 1);
/// assert(equal(s, "a+b-c"));
/// assert(replaceFirst(s, "x", "+") == fp.pointer.notFound);
/// ---
size_t replaceFirst(N, R)(ref char* text, N needle, R replacement, size_t start = 0) if (isNeedle!N && isStringLike!R) {
	const(char)[] pattern = needleText(needle);
	immutable at = find(text, pattern, start);
	if (at == fp.pointer.notFound) return at;
	if (!replaceRange(text, at, pattern.length, replacement)) return fp.pointer.allocationRefused;
	return at;
}

/// Replaces every `needle`, which must not be empty, at or after `start` (0 by default) in fp string `text` with `replacement`, never rescanning replaced text. Either argument may view `text` itself. Returns false if an allocation was refused or `text` is a pointer that is not an fp string and so cannot grow, leaving `text` unchanged.
///
/// Examples:
/// ---
/// char* s = clone("a-b-c").get;
/// scope(exit) free(s);
/// assert(replaceAll(s, '-', "--"));
/// assert(equal(s, "a--b--c"));
/// ---
bool replaceAll(N, R)(ref char* text, N needle, R replacement, size_t start = 0) @trusted if (isNeedle!N && isStringLike!R) {
	if (!growable(text)) return false;
	// The result is built apart and swapped in, so `text`, and any argument viewing it, is read unchanged throughout.
	const(char)[] source = slice(text), pattern = needleText(needle), with_ = slice(replacement);
	assert(pattern.length > 0, "fp.string.replaceAll: empty needle");
	size_t at = find(source, pattern, start);
	if (at == fp.pointer.notFound) return true;

	char* out_ = null;
	size_t copied = 0;
	for (; at != fp.pointer.notFound; at = find(source, pattern, copied)) {
		if (!concatenate(out_, source[copied .. at]) || !concatenate(out_, with_)) {
			free(out_);
			return false;
		}
		copied = at + pattern.length;
	}
	if (!concatenate(out_, source[copied .. $])) {
		free(out_);
		return false;
	}
	free(text);
	text = out_;
	return true;
}


unittest {
	char* nothing = null;
	assert(repeat(nothing, 0) && nothing is null);
	assert(repeat(nothing, 3) && nothing is null);

	char* replaced = clone("Hello World").get;
	scope(exit) free(replaced);
	assert(repeat(replaced, 5));
	assert(equal(replaced, "Hello WorldHello WorldHello WorldHello WorldHello World") && replaced[55] == '\0');
	assert(!repeat(replaced, size_t.max / 5 + 1));
	assert(length(replaced) == 55);
	char* emptied = clone("ab").get;
	scope(exit) free(emptied);
	fp.dynarray.clear(emptied);
	assert(repeat(emptied, 3) && length(emptied) == 0);
	assert(replaceAll(replaced, "World", "Bob"));
	assert(equal(replaced, "Hello BobHello BobHello BobHello BobHello Bob"));
	assert(replaceAll(replaced, "Bob", "World!"));
	assert(equal(replaced, "Hello World!Hello World!Hello World!Hello World!Hello World!"));
	assert(replaceAll(replaced, "World!", "Earth!", 12));
	assert(equal(replaced, "Hello World!Hello Earth!Hello Earth!Hello Earth!Hello Earth!"));
	assert(replaceAll(replaced, "absent", "x") && length(replaced) == 60);

	char* gone = clone("aaa").get;
	assert(replaceAll(gone, 'a', "") && gone is null); // replacing everything with nothing leaves the empty string

	char* replacedRange = clone("Hello World").get;
	scope(exit) free(replacedRange);
	assert(replaceRange(replacedRange, 6, 5, "Bob"));
	assert(equal(replacedRange, "Hello Bob"));
	assert(replaceRange(replacedRange, 0, 0, ">") && replaceRange(replacedRange, length(replacedRange), 0, "<"));
	assert(equal(replacedRange, ">Hello Bob<"));

	char* replacedFirst = clone("Hello World World").get;
	scope(exit) free(replacedFirst);
	assert(replaceFirst(replacedFirst, "World", "Bob") == 6);
	assert(equal(replacedFirst, "Hello Bob World"));
	assert(replaceFirst(replacedFirst, "World", "Bob", 7) == 10);
	assert(equal(replacedFirst, "Hello Bob Bob"));

	char* s = clone("one two one").get;
	scope(exit) free(s);
	assert(replaceFirst(s, "two".ptr, slice(s)[4 .. 7]) == 4);
	assert(equal(s, "one two one"));
}

unittest {
	// Arguments viewing the string being changed keep the text they had when passed, through reallocation, shifting and earlier replacements.
	auto previous = fp.dynarray.beginPoisoningAllocator();
	scope(exit) fp.dynarray.endPoisoningAllocator(previous);

	char* s = clone("abcd").get;
	scope(exit) free(s);
	assert(fp.dynarray.length(s) == fp.dynarray.capacity(s)); // full, so the appends below reallocate
	char* twice = joined(s, s).get;
	scope(exit) free(twice);
	assert(concatenate(s, s));
	assert(equal(s, twice));
	assert(append(s, slice(s)[0 .. 2], 1));
	assert(startsWith(s, twice) && endsWith(s, "ab1"));

	char* r = clone("abcdef").get;
	scope(exit) free(r);
	assert(replaceRange(r, 2, 2, slice(r)[1 .. 5]));
	assert(equal(r, "abbcdeef"));
	assert(replaceRange(r, 0, 4, slice(r)[5 .. 6]));
	assert(equal(r, "edeef"));
	assert(replaceRange(r, 0, 2, slice(r)[2 .. 4]));
	assert(equal(r, "eeeef"));

	char* t = clone("a-b-c").get;
	scope(exit) free(t);
	assert(replaceAll(t, slice(t)[1 .. 2], "+"));
	assert(equal(t, "a+b+c"));
	assert(replaceAll(t, "+", t));
	assert(equal(t, "aa+b+cba+b+cc"));

	// A later piece viewing `u` must not read the block an earlier piece's growth freed.
	char* u = clone("abcd").get;
	scope(exit) free(u);
	assert(append(u, "x", u, slice(u)[1 .. 2]));
	assert(equal(u, "abcdxabcdb"));
}

unittest { // edits refused anywhere leave the string as it was
	char* ab = clone("ab").get;
	scope(exit) free(ab);
	auto previous = fp.testing.limitAllocations(0);
	assert(!repeat(ab, 3));
	fp.testing.restoreAllocator(previous);
	assert(equal(ab, "ab") && ab[2] == '\0');

	char* dash = clone("a-b").get;
	scope(exit) free(dash);
	previous = fp.testing.limitAllocations();
	assert(replaceFirst(dash, "-", "--") == fp.pointer.allocationRefused);
	assert(!replaceAll(dash, "-", "--"));
	// Refused at the copy taken of a replacement that views `dash`.
	assert(!replaceRange(dash, 0, 0, dash));
	fp.testing.restoreAllocator(previous);
	assert(equal(dash, "a-b"));

	// Refused at each allocation building the result in turn; the string never changes.
	foreach (allowed; 0 .. 6) {
		char* many = clone("x-").get;
		scope(exit) free(many);
		assert(repeat(many, 32) && concatenate(many, "x"));
		char* original = clone(many).get;
		scope(exit) free(original);
		previous = fp.testing.limitAllocations(allowed);
		immutable done = replaceAll(many, "-", "<->");
		fp.testing.restoreAllocator(previous);
		if (done) assert(length(many) == 65 + 2 * 32 && startsWith(many, "x<->x<->") && endsWith(many, "x<->x"));
		else assert(equal(many, original));
	}
}

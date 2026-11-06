/// Null-terminated dynamic strings on top of `fp.dynarray`. An fp string is a `char*` dynarray that always ends in a zero byte, so it passes straight to C. A null `char*` is the empty string.
///
/// Every string argument is `isStringLike`: an fp string, a C string, a D slice or literal, or null.
///
/// Examples:
/// ---
/// char* s = clone("Hello");
/// scope(exit) free(s);
/// assert(concatenate(s, ", World"));
/// assert(equal(s, "Hello, World"));
/// assert(s[length(s)] == '\0');
/// ---
module fp.string;

import core.stdc.string;
import core.stdc.stdio : snprintf, vsnprintf;
import core.stdc.stdarg : va_list, va_start, va_end;
static import core.checkedint;
static import core.stdc.errno;
static import core.stdc.stdlib;
static import std.typecons;

static import fp.pointer;
static import fp.dynarray;
version(unittest) static import fp.testing;


@nogc nothrow:


/// Whether the functions here accept an `S` as a string: a `char*` of any qualifier (an fp string or C string), a D slice or literal, or `typeof(null)`. Static arrays are excluded, since they would be copied and sliced on the stack; pass `buffer[]` instead.
///
/// Examples:
/// ---
/// static assert(isStringLike!(char*) && isStringLike!string && isStringLike!(typeof(null)));
/// static assert(!isStringLike!(char[4]) && !isStringLike!(int*));
/// ---
enum bool isStringLike(S) = !__traits(isStaticArray, S) && (is(S : const(char)[]) || is(S : const(char)*));

/// A D slice over the characters of `text`, keeping its qualifier: a D slice as is, an fp string's recorded length, or a C string's `strlen`. Null gives null.
///
/// Examples:
/// ---
/// char* s = clone("abc");
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


// wrapper: container vocabulary every reader knows
/// The number of characters (bytes) in `text`, excluding the terminator.
///
/// Examples:
/// ---
/// char* s = clone("four");
/// scope(exit) free(s);
/// assert(length(s) == 4);
/// assert(length(null) == 0);
/// ---
size_t length(inout char* text) @trusted {
	return slice(text).length;
}




/// A new fp string holding a copy of `text`; null if the copy is empty (null is the empty string) or could not be allocated.
///
/// Examples:
/// ---
/// char* a = clone("text");
/// scope(exit) free(a);
/// char* b = clone(a);
/// scope(exit) free(b);
/// assert(b !is a && equal(a, b));
/// assert(clone("") is null);
/// ---
char* clone(S)(S text) @trusted if (isStringLike!S) {
	const(char)[] view = slice(text);
	if (view.length == 0) return null;
	char* out_ = null;
	if (fp.dynarray.growToSize(out_, view.length) is null) return null;
	core.stdc.string.memcpy(out_, view.ptr, view.length);
	return out_;
}


/// Frees `text`, which may be an fp string, a plain heap fat pointer, or memory straight from `fp.pointer.allocator`; each is released by its own layer. A stack fat pointer (from `fp.pointer.Array` or `fp.pointer.allocateOnStack`) belongs to its frame and is left alone. A hash table is rejected and left untouched, since only `fp.hashtable.free` can release it. Anything else is passed to `fp.pointer.allocator` as though it came from it, so a string literal or a stack buffer must not be freed here. The `ref` overload also sets `text` to null, unless it was rejected.
///
/// Examples:
/// ---
/// char* s = clone("bye");
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

// Only a dynarray can grow in place, so a plain heap or stack pointer is refused instead of asserted away.
private bool growable(const char* text) @trusted {
	return text is null || fp.dynarray.valid(cast(void*) text);
}

private enum bool isSliceArg(T) = isStringLike!T && !is(T : const(char)*);

private alias aliasSeq(T...) = T;

// `Args` with each slice replaced by the C string `format` passes in its place, and top-level qualifiers dropped so the copies can be assigned.
private template cArgTypes(Args...) {
	static if (Args.length == 0) alias cArgTypes = Args;
	else static if (isSliceArg!(Args[0])) alias cArgTypes = aliasSeq!(const(char)*, cArgTypes!(Args[1 .. $]));
	else alias cArgTypes = aliasSeq!(typeof(cast() Args[0].init), cArgTypes!(Args[1 .. $]));
}

private extern (C) char* formatC(const char* pattern, ...) @trusted {
	va_list argsSize;
	va_start(argsSize, pattern);
	immutable size = vsnprintf(null, 0, pattern, argsSize);
	va_end(argsSize);
	if (size <= 0) return null;

	char* out_ = null;
	if (fp.dynarray.growToSize(out_, size) is null) return null;

	va_list args;
	va_start(args, pattern);
	cast(void)vsnprintf(out_, length(out_) + 1, pattern, args);
	va_end(args);
	return out_;
}

/// A new fp string formatted by `vsnprintf`. A slice argument may stand where `%s` expects a string: it is passed as a null-terminated copy, since C varargs cannot carry a D slice. Returns null if the result is empty (null is the empty string), `vsnprintf` rejected the format, or an allocation, of a copy or of the result, was refused.
///
/// Examples:
/// ---
/// char* s = format("%d-%s-%s", 7, "slice", "C string".ptr);
/// scope(exit) free(s);
/// assert(equal(s, "7-slice-C string"));
/// ---
char* format(Args...)(const char* pattern, Args args) @trusted {
	cArgTypes!Args cArgs;
	scope(exit) static foreach (i, A; Args) static if (isSliceArg!A) if (args[i].length != 0) free(cArgs[i]);
	static foreach (i, A; Args) {
		static if (isSliceArg!A) {
			cArgs[i] = args[i].length == 0 ? "".ptr : clone(args[i]);
			if (cArgs[i] is null) return null;
		} else cArgs[i] = args[i];
	}
	return formatC(pattern, cArgs);
}


/// Orders two strings by length, then by bytes: negative if `a` sorts first, zero if equal, positive otherwise. Not lexicographic: `"b"` sorts before `"aa"`.
///
/// Examples:
/// ---
/// assert(compare("abc", "abc".ptr) == 0);
/// assert(compare("b", "aa") < 0);
/// assert(compare("ab", "aa") > 0);
/// ---
int compare(A, B)(A a, B b) @trusted if (isStringLike!A && isStringLike!B) {
	const(char)[] x = slice(a);
	const(char)[] y = slice(b);
	if (x.length != y.length) return x.length < y.length ? -1 : 1;
	return core.stdc.string.memcmp(x.ptr, y.ptr, x.length);
}

/// Whether `a` and `b` hold the same characters.
///
/// Examples:
/// ---
/// char* s = clone("same");
/// scope(exit) free(s);
/// assert(equal(s, "same"));
/// assert(!equal(s, "different"));
/// ---
bool equal(A, B)(A a, B b) @trusted if (isStringLike!A && isStringLike!B) {
	return compare(a, b) == 0;
}


/// The index of the first `needle` in `haystack` at or after `start` (0 by default), or `fp.pointer.notFound`, including when `start` is past the end.
///
/// Examples:
/// ---
/// assert(find("abcabc", "bc", 2) == 4);
/// assert(find("abc", "x") == fp.pointer.notFound);
/// assert(find("abc", "abc", 4) == fp.pointer.notFound);
/// ---
size_t find(H, N)(H haystack, N needle, size_t start = 0) @trusted if (isStringLike!H && isStringLike!N) {
	const(char)[] haystackText = slice(haystack);
	const(char)[] needleText = slice(needle);
	if (start > haystackText.length || needleText.length > haystackText.length - start) return fp.pointer.notFound;

	immutable bound = haystackText.length - needleText.length;
	outer: for (size_t i = start; i <= bound; ++i) {
		foreach (j; 0 .. needleText.length)
			if (haystackText[i + j] != needleText[j])
				continue outer;
		return i;
	}
	return fp.pointer.notFound;
}

// wrapper: container vocabulary every reader knows
/// Whether `needle` occurs in `haystack` at or after `start` (0 by default).
///
/// Examples:
/// ---
/// assert(contains("haystack", "st"));
/// assert(!contains("haystack", "hay", 1));
/// ---
bool contains(H, N)(H haystack, N needle, size_t start = 0) @trusted if (isStringLike!H && isStringLike!N) {
	return find(haystack, needle, start) != fp.pointer.notFound;
}

/// Whether `needle` occurs in `haystack` starting exactly at `start` (0 by default); false for a `start` past the end.
///
/// Examples:
/// ---
/// assert(startsWith("prefix", "pre"));
/// assert(startsWith("prefix", "fix", 3));
/// ---
bool startsWith(H, N)(H haystack, N needle, size_t start = 0) @trusted if (isStringLike!H && isStringLike!N) {
	const(char)[] haystackText = slice(haystack);
	const(char)[] needleText = slice(needle);
	if (start > haystackText.length || needleText.length > haystackText.length - start) return false;
	return haystackText[start .. start + needleText.length] == needleText;
}

/// Whether `needle` occurs in `haystack` ending exactly at index `end`; false for an `end` past the end. An `end` of 0 or less counts back from the end of `haystack`, so by default `needle` ends it.
///
/// Examples:
/// ---
/// assert(endsWith("suffix", "fix") && endsWith("suffix", "fix", 0));
/// assert(endsWith("suffix", "suf", 3));
/// assert(endsWith("suffix", "uff", -2));
/// ---
bool endsWith(H, N)(H haystack, N needle, ptrdiff_t end = 0) @trusted if (isStringLike!H && isStringLike!N) {
	const(char)[] haystackText = slice(haystack);
	const(char)[] needleText = slice(needle);
	if (end <= 0) end += cast(ptrdiff_t) haystackText.length;
	if (end > cast(ptrdiff_t) haystackText.length || cast(ptrdiff_t) needleText.length > end) return false;
	immutable start = cast(size_t)(end - cast(ptrdiff_t) needleText.length);
	return haystackText[start .. cast(size_t) end] == needleText;
}

/// Whether `a` and `b` hold the same characters once ASCII letters are folded to one case; other bytes must match exactly.
///
/// Examples:
/// ---
/// assert(equalIgnoringAsciiCase("Content-Length", "content-length"));
/// assert(!equalIgnoringAsciiCase("abc", "abd") && !equalIgnoringAsciiCase("a", "ab"));
/// ---
bool equalIgnoringAsciiCase(A, B)(A a, B b) @trusted if (isStringLike!A && isStringLike!B) {
	const(char)[] x = slice(a), y = slice(b);
	if (x.length != y.length) return false;
	foreach (i; 0 .. x.length) {
		char p = x[i], q = y[i];
		if (p >= 'A' && p <= 'Z') p |= 0x20;
		if (q >= 'A' && q <= 'Z') q |= 0x20;
		if (p != q) return false;
	}
	return true;
}

/// `text` without its trailing run of the bytes in `characters`, as a slice of it.
///
/// Examples:
/// ---
/// assert(trimEnd("value \t\t", " \t") == "value");
/// assert(trimEnd("  ", " ") == "");
/// ---
inout(char)[] trimEnd(inout(char)[] text, const(char)[] characters) {
	size_t end = text.length;
	outer: while (end > 0) {
		foreach (c; characters)
			if (text[end - 1] == c) {
				--end;
				continue outer;
			}
		break;
	}
	return text[0 .. end];
}

/// Splits `text` on every occurrence of `delimiter`, which must not be empty. Returns a new `fp.dynarray` of slices into `text`, so `text` must outlive them; free the dynarray itself with `fp.dynarray.free`. Returns null if an allocation was refused.
///
/// Examples:
/// ---
/// const(char)[]* parts = split("a,b,,c", ",");
/// scope(exit) fp.dynarray.free(parts);
/// assert(fp.dynarray.length(parts) == 4);
/// assert(parts[0] == "a" && parts[2] == "" && parts[3] == "c");
/// ---
const(char)[]* split(S, D)(S text, D delimiter) @trusted if (isStringLike!S && isStringLike!D) {
	const(char)[] s = slice(text);
	const(char)[] d = slice(delimiter);
	assert(d.length > 0);
	const(char)[]* result = null;

	size_t start = 0;
	while (true) {
		immutable position = find(s, d, start);
		immutable end = position == fp.pointer.notFound ? s.length : position;
		if (!fp.dynarray.pushBack(result, s[start .. end])) {
			fp.dynarray.free(result);
			return null;
		}
		if (position == fp.pointer.notFound) break;
		start = position + d.length;
	}

	return result;
}


/// Appends `b` to `a`, which may be null. Returns false if `a` could not grow or is a pointer that is not an fp string and so cannot grow, leaving it unchanged; appending nothing succeeds.
///
/// Examples:
/// ---
/// char* s = null;
/// scope(exit) free(s);
/// assert(concatenate(s, "ab"));
/// assert(concatenate(s, "cd".ptr));
/// assert(concatenate(s, ""));
/// assert(equal(s, "abcd"));
///
/// char* heap = fp.pointer.allocate!char(4);
/// assert(!concatenate(heap, "!"));
/// fp.string.free(heap);
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


/// Why a codepoint could not be encoded as UTF-8, or appended once encoded.
enum Utf8Error : ubyte {
	none, /// It was encoded (and appended).
	outOfRange, /// Above U+10FFFF.
	surrogate, /// U+D800-U+DFFF: UTF-16 machinery, never valid in UTF-8.
	allocationRefused, /// Encodable, but the string could not grow to hold it.
}

/// Encodes `codepoint` into `out_`, which must have room for four bytes. Returns the number of bytes written, or 0 with `error` saying why.
///
/// Examples:
/// ---
/// char[4] buffer;
/// Utf8Error error;
/// assert(encodeUtf8(0x20AC, buffer.ptr, error) == 3);
/// assert(buffer[0 .. 3] == "€");
/// assert(encodeUtf8(0xD800, buffer.ptr, error) == 0 && error == Utf8Error.surrogate);
/// assert(encodeUtf8('A', buffer.ptr) == 1);
/// ---
size_t encodeUtf8(uint codepoint, char* out_, out Utf8Error error) @trusted {
	if (codepoint > 0x10FFFF) {
		error = Utf8Error.outOfRange;
		return 0;
	}
	if (codepoint >= 0xD800 && codepoint <= 0xDFFF) {
		error = Utf8Error.surrogate;
		return 0;
	}

	if (codepoint <= 0x7F) {
		out_[0] = cast(char) codepoint;
		return 1;
	} else if (codepoint <= 0x7FF) {
		out_[0] = cast(char)(0xC0 | (codepoint >> 6));
		out_[1] = cast(char)(0x80 | (codepoint & 0x3F));
		return 2;
	} else if (codepoint <= 0xFFFF) {
		out_[0] = cast(char)(0xE0 | (codepoint >> 12));
		out_[1] = cast(char)(0x80 | ((codepoint >> 6) & 0x3F));
		out_[2] = cast(char)(0x80 | (codepoint & 0x3F));
		return 3;
	}
	out_[0] = cast(char)(0xF0 | (codepoint >> 18));
	out_[1] = cast(char)(0x80 | ((codepoint >> 12) & 0x3F));
	out_[2] = cast(char)(0x80 | ((codepoint >> 6) & 0x3F));
	out_[3] = cast(char)(0x80 | (codepoint & 0x3F));
	return 4;
}
/// Ditto
size_t encodeUtf8(uint codepoint, char* out_) @trusted {
	Utf8Error ignored;
	return encodeUtf8(codepoint, out_, ignored);
}


// --- numbers -------------------------------------------------------------------

/// The most characters `formatUnsigned` or `formatSigned` writes: twenty digits and a sign.
enum size_t maxDecimalLength = 21;

/// `value` written in decimal into the end of `buffer`, returned as the slice of `buffer` holding it, for callers that want the digits without an fp string. It cannot fail.
///
/// Examples:
/// ---
/// char[maxDecimalLength] buffer;
/// assert(formatUnsigned(0, buffer) == "0" && formatUnsigned(ulong.max, buffer) == "18446744073709551615");
/// ---
const(char)[] formatUnsigned(ulong value, return ref char[maxDecimalLength] buffer) {
	size_t at = buffer.length;
	do {
		buffer[--at] = cast(char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	return buffer[at .. $];
}

/// `value` written in decimal, with a leading `-` when negative, into the end of `buffer`, returned as the slice of `buffer` holding it. It cannot fail.
///
/// Examples:
/// ---
/// char[maxDecimalLength] buffer;
/// assert(formatSigned(-7, buffer) == "-7" && formatSigned(long.min, buffer) == "-9223372036854775808");
/// ---
const(char)[] formatSigned(long value, return ref char[maxDecimalLength] buffer) {
	// Negated as unsigned, so `long.min`, whose magnitude no `long` holds, works too.
	immutable magnitude = value < 0 ? 0UL - cast(ulong) value : cast(ulong) value;
	immutable length = formatUnsigned(magnitude, buffer).length;
	if (value >= 0) return buffer[$ - length .. $];
	buffer[$ - length - 1] = '-';
	return buffer[$ - length - 1 .. $];
}

/// Appends `value` in decimal to `text`, which may be null. Returns false if `text` could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// char* s = null;
/// scope(exit) free(s);
/// assert(appendUnsigned(s, 0) && appendUnsigned(s, 18446744073709551615UL));
/// assert(equal(s, "018446744073709551615"));
/// ---
bool appendUnsigned(ref char* text, ulong value) {
	char[maxDecimalLength] buffer;
	return concatenate(text, formatUnsigned(value, buffer));
}

/// Appends `value` in decimal, with a leading `-` when negative, to `text`, which may be null. Returns false if `text` could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// char* s = null;
/// scope(exit) free(s);
/// assert(appendSigned(s, -9223372036854775807L - 1) && appendSigned(s, 7));
/// assert(equal(s, "-92233720368547758087"));
/// ---
bool appendSigned(ref char* text, long value) {
	char[maxDecimalLength] buffer;
	return concatenate(text, formatSigned(value, buffer));
}

/// Appends `value` in lowercase hexadecimal to `text`, which may be null, padded with zeros to at least `width` digits. Returns false if `text` could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// char* s = null;
/// scope(exit) free(s);
/// assert(appendHex(s, 0xAB, 4) && appendHex(s, 0, 0));
/// assert(equal(s, "00ab0"));
/// ---
bool appendHex(ref char* text, ulong value, size_t width = 0) @trusted {
	static immutable char[16] digitsOf = "0123456789abcdef";
	char[16] digits;
	assert(width <= digits.length);
	size_t at = digits.length;
	do {
		digits[--at] = digitsOf[value & 0xF];
		value >>= 4;
	} while (value != 0);
	while (digits.length - at < width) digits[--at] = '0';
	return concatenate(text, digits[at .. $]);
}

/// Appends `value` to `text`, which may be null, in the shortest decimal form that reads back (through `parseFloat`) as the same `double`: `0.1`, `1e+300`, `inf`, `-inf` or `nan`. Returns false if `text` could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// char* s = null;
/// scope(exit) free(s);
/// assert(appendFloat(s, 0.1) && appendFloat(s, 1e300) && appendFloat(s, -double.infinity));
/// assert(equal(s, "0.11e+300-inf"));
/// ---
bool appendFloat(ref char* text, double value) @trusted {
	char[32] buffer;
	int n = 0;
	// 17 significant digits always round-trip a double; fewer usually do, and read better.
	foreach (precision; 1 .. 18) {
		n = snprintf(buffer.ptr, buffer.length, "%.*g", precision, value);
		if (n <= 0 || n >= buffer.length) return false;
		if (value != value || core.stdc.stdlib.strtod(buffer.ptr, null) == value) break;
	}
	return concatenate(text, buffer[0 .. n]);
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
		size_t n = encodeUtf8(piece, buffer.ptr);
		if (n == 0) n = encodeUtf8(0xFFFD, buffer.ptr);
		return concatenate(text, buffer[0 .. n]);
	} else static if (is(T : real) && !is(T : long) && !is(T : ulong)) {
		return appendFloat(text, cast(double) piece);
	} else static if (__traits(isUnsigned, T)) {
		return appendUnsigned(text, piece);
	} else static if (is(T : long)) {
		return appendSigned(text, piece);
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
			if ((copies[i] = clone(views[i])) is null) return false;
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

/// A new fp string of every piece, as `append` writes them; it is null, the empty string, when every piece is empty. Returns null, rather than a null string, if an allocation was refused. Free the result with `fp.string.free`.
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


/// Repeats fp string `text` so it holds `times` copies of itself. A `times` of 0 frees it, leaving null, and an empty `text` stays as it is. Returns `text`, or null if an allocation was refused, the length would overflow, or `text` is a pointer that is not an fp string and so cannot grow, leaving `text` unchanged.
///
/// Examples:
/// ---
/// char* s = clone("ab");
/// scope(exit) free(s);
/// assert(repeat(s, 3) !is null);
/// assert(equal(s, "ababab"));
/// ---
char* repeat(ref char* text, size_t times) @trusted {
	if (times == 0) {
		free(text);
		return text;
	}
	if (length(text) == 0) return text;

	if (!growable(text)) return null;
	char* one = clone(text);
	scope(exit) free(one);
	bool overflow = false;
	immutable newLength = core.checkedint.mulu(length(text), times, overflow);
	if (one is null || overflow || fp.dynarray.reserve(text, newLength) is null) return null;
	// The capacity is reserved, so these appends cannot fail.
	foreach (i; 0 .. times - 1)
		cast(void)concatenate(text, one);
	return text;
}


/// Replaces the `rangeLen` characters of fp string `in_` starting at `start`, which must fit within the string, with `with_`. Returns `in_`, or null if an allocation was refused or `in_` is a pointer that is not an fp string and so cannot grow, leaving it unchanged.
///
/// Examples:
/// ---
/// char* s = clone("Hello World");
/// scope(exit) free(s);
/// assert(replaceRange(s, "Bob", 6, 5) !is null);
/// assert(equal(s, "Hello Bob"));
/// ---
char* replaceRange(S)(ref char* in_, S with_, size_t start, size_t rangeLen) @trusted if (isStringLike!S) {
	if (!growable(in_)) return null;
	const(char)[] w = slice(with_);
	immutable inLen = length(in_);
	assert(rangeLen <= inLen && start <= inLen - rangeLen);
	immutable end = start + rangeLen;

	immutable withLen = w.length;
	// `memmove`, not `memcpy`: `with_` may view `in_` itself.
	if (rangeLen > withLen) {
		immutable diff = rangeLen - withLen;
		core.stdc.string.memmove(in_ + start, w.ptr, withLen);
		cast(void)fp.dynarray.removeRange(in_, start + withLen, diff);
	} else if (withLen > rangeLen) {
		// Growing may free a `with_` that views `in_`, and the shift moves its text, so it is copied first.
		char* copy = null;
		scope(exit) free(copy);
		if (fp.dynarray.overlaps(in_, w)) {
			if ((copy = clone(w)) is null) return null;
			w = slice(copy);
		}
		immutable diff = withLen - rangeLen;
		if (fp.dynarray.grow(in_, diff) is null) return null;
		core.stdc.string.memmove(in_ + end + diff, in_ + end, inLen - end);
		core.stdc.string.memcpy(in_ + start, w.ptr, withLen);
	} else {
		core.stdc.string.memmove(in_ + start, w.ptr, withLen);
	}
	in_[length(in_)] = 0;
	return in_;
}

/// Replaces the first `needle` at or after `start` in fp string `in_` with `replacement`. Returns where it was found, `fp.pointer.notFound`, or `fp.pointer.allocationRefused` if `in_` could not grow (leaving it unchanged).
///
/// Examples:
/// ---
/// char* s = clone("a-b-c");
/// scope(exit) free(s);
/// assert(replaceFirst(s, "-", "+", 0) == 1);
/// assert(equal(s, "a+b-c"));
/// ---
size_t replaceFirst(N, R)(ref char* in_, N needle, R replacement, size_t start) @trusted if (isStringLike!N && isStringLike!R) {
	const(char)[] n = slice(needle);
	start = find(in_, n, start);
	if (start == fp.pointer.notFound) return start;
	if (replaceRange(in_, replacement, start, n.length) is null) return fp.pointer.allocationRefused;
	return start;
}

/// Replaces every `needle`, which must not be empty, at or after `start` in fp string `in_` with `replacement`, never rescanning replaced text. Returns `in_`, or null if an allocation was refused, in which case the replacements before that stay made.
///
/// Examples:
/// ---
/// char* s = clone("a-b-c");
/// scope(exit) free(s);
/// assert(replace(s, "-", "--", 0) !is null);
/// assert(equal(s, "a--b--c"));
/// ---
char* replace(N, R)(ref char* in_, N needle, R replacement, size_t start) @trusted if (isStringLike!N && isStringLike!R) {
	const(char)[] n = slice(needle);
	const(char)[] r = slice(replacement);
	assert(n.length > 0);
	// Every replacement changes `in_`, so arguments viewing it are copied first to keep the text they had.
	char* needleCopy = null;
	char* replacementCopy = null;
	scope(exit) {
		free(needleCopy);
		free(replacementCopy);
	}
	if (fp.dynarray.overlaps(in_, n)) {
		if ((needleCopy = clone(n)) is null) return null;
		n = slice(needleCopy);
	}
	if (fp.dynarray.overlaps(in_, r)) {
		if ((replacementCopy = clone(r)) is null) return null;
		r = slice(replacementCopy);
	}
	while ((start = replaceFirst(in_, n, r, start)) != fp.pointer.notFound) {
		if (start == fp.pointer.allocationRefused) return null;
		start += r.length;
	}
	return in_;
}


/// Whether `c` is an ASCII decimal digit.
///
/// Examples:
/// ---
/// assert(isDigit('7') && !isDigit('a'));
/// ---
bool isDigit(char c) { return c >= '0' && c <= '9'; }

/// Whether `c` is an ASCII octal digit.
///
/// Examples:
/// ---
/// assert(isOctalDigit('7') && !isOctalDigit('8'));
/// ---
bool isOctalDigit(char c) { return c >= '0' && c <= '7'; }

/// Whether `c` is an ASCII hexadecimal digit, in either case.
///
/// Examples:
/// ---
/// assert(isHexDigit('f') && isHexDigit('F') && !isHexDigit('g'));
/// ---
bool isHexDigit(char c) { return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }

/// Whether `c` is an ASCII letter.
///
/// Examples:
/// ---
/// assert(isAsciiAlpha('q') && isAsciiAlpha('Q') && !isAsciiAlpha('1'));
/// ---
bool isAsciiAlpha(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }


/// The value of ASCII hexadecimal digit `c`, which must satisfy `isHexDigit`: 0 to 15.
///
/// Examples:
/// ---
/// assert(hexDigitValue('7') == 7 && hexDigitValue('b') == 11 && hexDigitValue('F') == 15);
/// ---
uint hexDigitValue(char c) {
	assert(isHexDigit(c), "fp.string: hexDigitValue of a character that is not a hexadecimal digit");
	if (isDigit(c)) return c - '0';
	return (c | 0x20) - 'a' + 10;
}

/// A parsed unsigned integer, as `parseUnsigned` returns it.
struct Unsigned {
	ulong value; /// The number.
}

/// Reads `digits`, every one a digit of `base` (2 to 16, in either case), as an unsigned number. Returns null if `digits` is empty, holds a character that is not a digit of `base`, or its value does not fit in a `ulong`.
///
/// Examples:
/// ---
/// assert(parseUnsigned("ff", 16).get.value == 255);
/// assert(parseUnsigned("18446744073709551615", 10).get.value == ulong.max);
/// assert(parseUnsigned("18446744073709551616", 10).isNull);
/// assert(parseUnsigned("12", 2).isNull && parseUnsigned("", 10).isNull);
/// ---
std.typecons.Nullable!Unsigned parseUnsigned(const(char)[] digits, uint base) {
	assert(base >= 2 && base <= 16);
	if (digits.length == 0) return typeof(return).init;
	ulong value = 0;
	foreach (c; digits) {
		if (!isHexDigit(c)) return typeof(return).init;
		immutable digit = hexDigitValue(c);
		if (digit >= base) return typeof(return).init;
		bool overflow = false;
		value = core.checkedint.addu(core.checkedint.mulu(value, base, overflow), digit, overflow);
		if (overflow) return typeof(return).init;
	}
	return typeof(return)(Unsigned(value));
}

/// A parsed floating-point number, as `parseFloat` returns it.
struct Float {
	double value; /// The number.
}

/// Reads all of `text` as a decimal or hexadecimal floating-point number, as C's `strtod` does in the "C" locale. Returns null if `text` is not entirely a number, or its magnitude is too large for a `double`; a value too small rounds toward zero. The spellings `inf` and `nan` read as themselves.
///
/// Examples:
/// ---
/// assert(parseFloat("1.5e3").get.value == 1500);
/// assert(parseFloat("1e999").isNull && parseFloat("1x").isNull && parseFloat("").isNull);
/// ---
std.typecons.Nullable!Float parseFloat(const(char)[] text) @trusted {
	// strtod skips leading white space, which is not part of a number.
	if (text.length == 0 || text[0] == ' ' || (text[0] >= '\t' && text[0] <= '\r')) return typeof(return).init;
	char[64] small;
	char* copy = null;
	scope(exit) free(copy);
	char* terminated = small.ptr;
	if (text.length < small.length) {
		fp.pointer.copy(small[0 .. text.length], text);
		small[text.length] = 0;
	} else {
		if ((copy = clone(text)) is null) return typeof(return).init;
		terminated = copy;
	}
	char* end;
	core.stdc.errno.errno = 0;
	immutable value = core.stdc.stdlib.strtod(terminated, &end);
	if (end != terminated + text.length) return typeof(return).init;
	immutable huge = value == double.infinity || value == -double.infinity;
	if (core.stdc.errno.errno == core.stdc.errno.ERANGE && huge) return typeof(return).init;
	return typeof(return)(Float(value));
}


/// Encodes `codepoint` as UTF-8 and appends it to `text`, which may be null. Returns `Utf8Error.none`, or why nothing was appended: `Utf8Error.outOfRange` or `Utf8Error.surrogate` for an unencodable value, `Utf8Error.allocationRefused` when `text` cannot grow, which includes a pointer that is not an fp string.
///
/// Examples:
/// ---
/// char* s = null;
/// scope(exit) free(s);
/// assert(appendCodepoint(s, 0xE9) == Utf8Error.none);
/// assert(equal(s, "é"));
/// assert(appendCodepoint(s, 0x110000) == Utf8Error.outOfRange);
/// ---
Utf8Error appendCodepoint(ref char* text, uint codepoint) @trusted {
	char[4] encoded;
	Utf8Error error;
	immutable n = encodeUtf8(codepoint, encoded.ptr, error);
	if (n > 0 && !concatenate(text, encoded[0 .. n])) return Utf8Error.allocationRefused;
	return error;
}

/// Whether `codepoint` lies in one of the inclusive ranges of `table`, which must be sorted and must not overlap, as the Unicode property tables a lexer or renderer generates are. A binary search: O(log n).
///
/// Examples:
/// ---
/// static immutable uint[2][3] letters = [[0x41, 0x5A], [0x61, 0x7A], [0xC0, 0xD6]];
/// assert(inCodepointRanges(letters[], 'q') && inCodepointRanges(letters[], 0xC5));
/// assert(!inCodepointRanges(letters[], '1') && !inCodepointRanges(letters[], 0xD7));
/// ---
bool inCodepointRanges(const(uint[2])[] table, uint codepoint) {
	size_t low = 0, high = table.length;
	while (low < high) {
		immutable middle = low + (high - low) / 2;
		if (codepoint < table[middle][0]) high = middle;
		else if (codepoint > table[middle][1]) low = middle + 1;
		else return true;
	}
	return false;
}

/// Decodes the codepoint starting at `s[i]`, advancing `i` past it.
///
/// Safe on arbitrary bytes: continuation bytes are bounds-checked before they are read. A sequence that is truncated, lacks a continuation byte, is overlong, or encodes a surrogate or a value above U+10FFFF clears `valid`, decodes as its lead byte and consumes one byte, so a caller ignoring `valid` still makes progress.
///
/// Examples:
/// ---
/// size_t i = 0;
/// bool valid;
/// assert(decodeUtf8("€x", i, valid) == 0x20AC && valid && i == 3);
/// assert(decodeUtf8("€x", i) == 'x' && i == 4);
///
/// size_t j = 0;
/// assert(decodeUtf8("\xE2", j, valid) == 0xE2 && !valid && j == 1);
/// ---
uint decodeUtf8(const(char)[] s, ref size_t i, out bool valid) @trusted {
	immutable c = cast(ubyte) s[i];
	if (c < 0x80) {
		valid = true;
		return s[i++];
	}

	// `least` is the smallest codepoint needing `n` bytes; anything below it is an overlong encoding.
	size_t n = 0;
	uint codepoint = 0, least = 0;
	if ((c >> 5) == 0x6) { n = 2; codepoint = c & 0x1F; least = 0x80; }
	else if ((c >> 4) == 0xE) { n = 3; codepoint = c & 0x0F; least = 0x800; }
	else if ((c >> 3) == 0x1E) { n = 4; codepoint = c & 0x07; least = 0x10000; }

	valid = n != 0 && n <= s.length - i;
	foreach (k; 1 .. valid ? n : 1) {
		immutable b = cast(ubyte) s[i + k];
		if ((b & 0xC0) != 0x80) {
			valid = false;
			break;
		}
		codepoint = (codepoint << 6) | (b & 0x3F);
	}
	if (valid && (codepoint < least || codepoint > 0x10FFFF || (codepoint >= 0xD800 && codepoint <= 0xDFFF)))
		valid = false;

	if (!valid) {
		++i;
		return c;
	}
	i += n;
	return codepoint;
}
/// Ditto
uint decodeUtf8(const(char)[] s, ref size_t i) @trusted {
	bool ignored;
	return decodeUtf8(s, i, ignored);
}

/// The length in bytes of the UTF-8 sequence lead byte `lead` starts: 1 for ASCII, and for a continuation byte or a byte no sequence starts, so a scan stepping by it always advances. It does not check the bytes that follow.
///
/// Examples:
/// ---
/// assert(utf8SequenceLength('a') == 1 && utf8SequenceLength("é"[0]) == 2 && utf8SequenceLength("€"[0]) == 3);
/// assert(utf8SequenceLength("😀"[0]) == 4 && utf8SequenceLength("é"[1]) == 1);
/// ---
size_t utf8SequenceLength(char lead) {
	immutable c = cast(ubyte) lead;
	if (c >= 0xF8) return 1;
	if (c >= 0xF0) return 4;
	if (c >= 0xE0) return 3;
	if (c >= 0xC0) return 2;
	return 1;
}

/// The UTF-16 code units byte `c` of UTF-8 text adds: 2 where it starts a four-byte sequence, which UTF-16 writes as a surrogate pair, 0 for a continuation byte, and 1 otherwise. Summed over well-formed text, it gives the text's UTF-16 length, as editors that count in UTF-16 need.
///
/// Examples:
/// ---
/// size_t units = 0;
/// foreach (c; "aé😀") units += utf16Length(c);
/// assert(units == 4);
/// ---
size_t utf16Length(char c) {
	if ((c & 0xC0) == 0x80) return 0;
	return utf8SequenceLength(c) == 4 ? 2 : 1;
}

/// Decodes UTF-8 into a new `fp.dynarray` of codepoints, which the caller frees with `fp.dynarray.free`. Returns null if the input is empty or not valid UTF-8, or an allocation was refused.
///
/// Examples:
/// ---
/// uint* cps = codepoints("hé");
/// scope(exit) fp.dynarray.free(cps);
/// assert(fp.dynarray.length(cps) == 2 && cps[1] == 0xE9);
/// assert(codepoints("\xFF") is null);
/// ---
uint* codepoints(S)(S text) @trusted if (isStringLike!S) {
	const(char)[] view = slice(text);
	uint* out_ = null;
	size_t i = 0;

	while (i < view.length) {
		bool valid;
		immutable codepoint = decodeUtf8(view, i, valid);
		if (!valid || !fp.dynarray.pushBack(out_, codepoint)) {
			fp.dynarray.free(out_);
			return null;
		}
	}
	return out_;
}

/// Converts UTF-8 into a new `fp.dynarray` of UTF-16 code units, which the caller frees with `fp.dynarray.free`. A 0 unit follows the last, outside the length, so the result is also a null-terminated wide string, as Windows' wide APIs take. Returns null if the input is empty or not valid UTF-8, or an allocation was refused.
///
/// Examples:
/// ---
/// wchar* units = utf16("é😀");
/// scope(exit) fp.dynarray.free(units);
/// assert(fp.dynarray.length(units) == 3 && units[0] == 0xE9 && units[1] == 0xD83D && units[2] == 0xDE00 && units[3] == 0);
/// assert(utf16("\xFF") is null);
/// ---
wchar* utf16(S)(S text) @trusted if (isStringLike!S) {
	const(char)[] view = slice(text);
	if (view.length == 0) return null;
	// One more unit than the text needs holds the terminator.
	size_t units = 1;
	foreach (c; view) units += utf16Length(c);
	wchar* out_ = null;
	if (fp.dynarray.reserve(out_, units) is null) return null;

	size_t i = 0;
	while (i < view.length) {
		bool valid;
		immutable codepoint = decodeUtf8(view, i, valid);
		bool pushed;
		if (codepoint < 0x10000) pushed = fp.dynarray.pushBack(out_, cast(wchar) codepoint);
		else pushed = fp.dynarray.pushBack(out_, cast(wchar) (0xD800 + ((codepoint - 0x10000) >> 10))) && fp.dynarray.pushBack(out_, cast(wchar) (0xDC00 + (codepoint & 0x3FF)));
		if (!valid || !pushed) {
			fp.dynarray.free(out_);
			return null;
		}
	}
	// Valid text needs exactly the units counted, so the terminator's slot is still reserved.
	assert(fp.dynarray.capacity(out_) > fp.dynarray.length(out_));
	out_[fp.dynarray.length(out_)] = 0;
	return out_;
}

/// Encodes `codepoints` as a new fp string, or returns null if there are none (null is the empty string), one is not encodable, or the string could not be allocated. `codepoints` is a `uint` slice, or a `uint*` fat pointer such as the dynarray `codepoints` returns; like `isStringLike`, a static array must be passed as `array[]`.
///
/// Examples:
/// ---
/// uint[2] cps = ['o', 0x4E16];
/// char* s = fromCodepoints(cps[]);
/// scope(exit) free(s);
/// assert(equal(s, "o世"));
/// ---
char* fromCodepoints(C)(C codepoints) @trusted if (!__traits(isStaticArray, C) && (is(C : const(uint)[]) || is(C : const(uint)*))) {
	static if (is(C : const(uint)[])) const(uint)[] view = codepoints;
	else const(uint)[] view = codepoints[0 .. fp.pointer.length(codepoints)];
	// An empty reservation would leave a string whose first byte, unwritten, is not its terminator.
	if (view.length == 0) return null;

	char* out_ = null;
	if (fp.dynarray.reserve(out_, view.length) is null) return null;

	foreach (codepoint; view) {
		char[4] encoded;
		immutable encodedLength = encodeUtf8(codepoint, encoded.ptr);
		if (encodedLength == 0 || !concatenate(out_, encoded[0 .. encodedLength])) {
			fp.dynarray.free(out_);
			return null;
		}
	}
	return out_;
}

/// Converts UTF-16 code units into a new fp string, or returns null if there are none (null is the empty string), they are not valid UTF-16, such as a lone surrogate, or the string could not be allocated. `units` is a `wchar` slice, or a `wchar*` fat pointer such as the dynarray `utf16` returns; like `isStringLike`, a static array must be passed as `array[]`.
///
/// Examples:
/// ---
/// char* s = fromUtf16("é😀"w);
/// scope(exit) free(s);
/// assert(equal(s, "é😀"));
/// wchar[1] lone = [0xD800];
/// assert(fromUtf16(lone[]) is null);
/// ---
char* fromUtf16(U)(U units) @trusted if (!__traits(isStaticArray, U) && (is(U : const(wchar)[]) || is(U : const(wchar)*))) {
	static if (is(U : const(wchar)[])) const(wchar)[] view = units;
	else const(wchar)[] view = units[0 .. fp.pointer.length(units)];
	if (view.length == 0) return null;

	char* out_ = null;
	if (fp.dynarray.reserve(out_, view.length) is null) return null;

	for (size_t i = 0; i < view.length; ++i) {
		uint codepoint = view[i];
		if (codepoint >= 0xD800 && codepoint < 0xDC00 && i + 1 < view.length && view[i + 1] >= 0xDC00 && view[i + 1] < 0xE000)
			codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (view[++i] - 0xDC00);
		char[4] encoded;
		// A surrogate left unpaired does not encode.
		immutable encodedLength = encodeUtf8(codepoint, encoded.ptr);
		if (encodedLength == 0 || !concatenate(out_, encoded[0 .. encodedLength])) {
			fp.dynarray.free(out_);
			return null;
		}
	}
	return out_;
}


unittest {
	char[5] hello = "hello";
	assert(slice(hello[]) == "hello");
	assert(slice(null) is null);
	// A literal converts to both a pointer and a slice, which made separate overloads ambiguous.
	assert(slice("hello") == "hello");
	static assert(is(typeof(slice("hello")) == string));

	// Every form `isStringLike` admits reads as the same text.
	char[3] buffer = "abc";
	char* dynamic = clone(buffer[]);
	scope(exit) free(dynamic);
	const(char)* constant = dynamic;
	immutable(char)* literal = "abc".ptr;
	const(char)[] view = buffer[];
	assert(equal(dynamic, constant) && equal(constant, literal) && equal(literal, view) && equal(view, "abc"));
	assert(equal(null, "") && equal(cast(char*) null, null) && compare(null, "a") < 0);
	assert(clone(null) is null && length(null) == 0);

	assert(fp.pointer.valid(dynamic) && fp.dynarray.valid(dynamic));
	assert(!fp.pointer.onStack(dynamic) && fp.pointer.onHeap(dynamic));
	assert(length(dynamic) == 3);
	assert(dynamic[3] == 0); // fp strings are null terminated!

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

	char* formatted = format("%s %s%c\n", "Hello".ptr, "World".ptr, '!');
	scope(exit) free(formatted);
	assert(equal(formatted, "Hello World!\n"));
	char[5] world = "World";
	char* formattedSlices = format("%s %s%c%s", "Hello", world[], '!', "");
	scope(exit) free(formattedSlices);
	assert(equal(formattedSlices, "Hello World!"));
	assert(format("%s", "") is null && format("") is null);
	const size_t constNumber = 7;
	immutable(char)* immutablePointer = "imm".ptr;
	const char* constPointer = "c".ptr;
	char* formattedQualified = format("%03zu %s %s", constNumber, immutablePointer, constPointer);
	scope(exit) free(formattedQualified);
	assert(equal(formattedQualified, "007 imm c"));
}

unittest {
	char* text = clone("Hello World");
	scope(exit) free(text);
	char* bang = clone("Hello World!");
	scope(exit) free(bang);
	assert(compare(text, text) == 0);
	assert(compare(text, bang) < 0);
	assert(compare(bang, text) > 0);
	assert(compare(bang, "Hello World!") == 0);

	// Lengths 2^32 apart must not compare equal through `int` truncation. Only lengths are read, so the slices need no backing memory.
	static if (size_t.sizeof > int.sizeof) {
		char c;
		auto huge = (&c)[0 .. (size_t(1) << 32) + 1];
		auto single = (&c)[0 .. 1];
		assert(compare(huge, single) > 0);
		assert(compare(single, huge) < 0);
	}

	assert(find(bang, "World!", 0) == 6 && contains(bang, "World!", 0));
	assert(find(bang, "zzz", 0) == fp.pointer.notFound && !contains(bang, "zzz", 0));
	assert(find(bang, "", length(bang)) == length(bang) && find(bang, "", 100) == fp.pointer.notFound);
	assert(startsWith(bang, "Hello", 0));
	assert(endsWith(bang, "World!", 0) && !endsWith(bang, "World", 0));
	assert(startsWith(bang, "", length(bang)) && !startsWith(bang, "", 100) && !startsWith(bang, "", size_t.max));
	assert(endsWith(bang, "", length(bang)) && !endsWith(bang, "", 100));

	char* s = clone("one two one");
	scope(exit) free(s);
	const(char)[] one = slice(s)[0 .. 3];
	assert(find(s, one, 1) == 8 && contains(slice(s), "two".ptr, 0));
	assert(startsWith(slice(s), one, 0) && endsWith(s, one, 0));

	const(char)[]* parts = split("a,bb,,ccc", ",");
	scope(exit) fp.dynarray.free(parts);
	assert(fp.dynarray.length(parts) == 4);
	assert(parts[0] == "a" && parts[1] == "bb" && parts[2] == "" && parts[3] == "ccc");

	char* colons = clone("a::bb::ccc");
	scope(exit) free(colons);
	char* delimiter = clone("::");
	scope(exit) free(delimiter);
	const(char)[]* byString = split(colons, delimiter);
	scope(exit) fp.dynarray.free(byString);
	assert(fp.dynarray.length(byString) == 3);
	assert(byString[0] == "a" && byString[1] == "bb" && byString[2] == "ccc");

	const(char)[]* whole = split("no-delimiter-here", ",");
	scope(exit) fp.dynarray.free(whole);
	assert(fp.dynarray.length(whole) == 1);
	assert(whole[0] == "no-delimiter-here");
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
	assert(repeat(heap, 2) is null && replaceRange(heap, "z", 0, 1) is null);
	free(heap);
	assert(heap is null);

	fp.pointer.Array!(char, 4) onStack;
	onStack[0] = 'a';
	char* stackText = onStack;
	assert(fp.pointer.pointerType(stackText) == fp.pointer.PointerType.stack);
	assert(!concatenate(stackText, "b") && !append(stackText, 'c'));

	char[4] buffer;
	Utf8Error error;
	assert(encodeUtf8(0x110000, buffer.ptr, error) == 0 && error == Utf8Error.outOfRange);
	assert(encodeUtf8(0xDC00, buffer.ptr, error) == 0 && error == Utf8Error.surrogate);
	assert(encodeUtf8(0x1F600, buffer.ptr, error) == 4 && error == Utf8Error.none);

	// Characters are appended as text, not as their numeric values.
	char* chars = joined('a', cast(const char) 'b', wchar('é'), dchar(0x1F600), cast(wchar) 0xD800, cast(dchar) 0x110000).get;
	scope(exit) free(chars);
	assert(slice(chars) == "abé\U0001F600\uFFFD\uFFFD");

	char* name = clone("verify.d");
	scope(exit) free(name);
	char* out_ = null;
	scope(exit) free(out_);
	assert(append(out_, "at ", name, ":", 42, " of ", 100UL));
	assert(slice(out_) == "at verify.d:42 of 100");

	char* made = joined("n=", -7, " x=", 1.5, " y=", 0.1, " z=", 1e300, " w=", double.nan).get;
	scope(exit) free(made);
	assert(slice(made) == "n=-7 x=1.5 y=0.1 z=1e+300 w=nan");

	// Every double reads back as itself from the shortest form append writes.
	foreach (value; [1.0 / 3, 2.0 / 3, 123456789.123456789, double.min_normal, double.max, -0.0, 0.30000000000000004]) {
		char* written = null;
		scope(exit) free(written);
		assert(appendFloat(written, value));
		assert(parseFloat(slice(written)).get.value == value);
	}

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

	char* world = clone("World");
	scope(exit) free(world);
	char* mixed = joined("Hello, ".ptr, world, "!".ptr).get;
	scope(exit) free(mixed);
	assert(equal(mixed, "Hello, World!"));
}

unittest {
	char* zeroRepl = null;
	assert(repeat(zeroRepl, 0) is null);
	assert(zeroRepl is null);

	char* replaced = clone("Hello World");
	scope(exit) free(replaced);
	assert(repeat(replaced, 5) !is null);
	assert(equal(replaced, "Hello WorldHello WorldHello WorldHello WorldHello World"));
	assert(repeat(replaced, size_t.max / 5 + 1) is null);
	assert(length(replaced) == 55);
	char* emptied = clone("ab");
	scope(exit) free(emptied);
	fp.dynarray.clear(emptied);
	assert(repeat(emptied, 3) is emptied && length(emptied) == 0);
	assert(replace(replaced, "World", "Bob", 0) !is null);
	assert(equal(replaced, "Hello BobHello BobHello BobHello BobHello Bob"));
	assert(replace(replaced, "Bob", "World!", 0) !is null);
	assert(equal(replaced, "Hello World!Hello World!Hello World!Hello World!Hello World!"));
	assert(replace(replaced, "World!", "Earth!", 0) !is null);
	assert(equal(replaced, "Hello Earth!Hello Earth!Hello Earth!Hello Earth!Hello Earth!"));

	char* replacedRange = clone("Hello World");
	scope(exit) free(replacedRange);
	assert(replaceRange(replacedRange, "Bob", 6, 5) !is null);
	assert(equal(replacedRange, "Hello Bob"));

	char* replacedFirst = clone("Hello World World");
	scope(exit) free(replacedFirst);
	assert(replaceFirst(replacedFirst, "World", "Bob", 0) == 6);
	assert(equal(replacedFirst, "Hello Bob World"));

	char* s = clone("one two one");
	scope(exit) free(s);
	assert(replaceFirst(s, "two".ptr, slice(s)[4 .. 7], 0) == 4);
	assert(equal(s, "one two one"));
}

unittest {
	// Arguments viewing the string being changed keep the text they had when passed, through reallocation, shifting and earlier replacements.
	auto previous = fp.dynarray.beginPoisoningAllocator();
	scope(exit) fp.dynarray.endPoisoningAllocator(previous);

	char* s = clone("abcd");
	scope(exit) free(s);
	assert(fp.dynarray.length(s) == fp.dynarray.capacity(s)); // full, so the appends below reallocate
	char* twice = joined(s, s).get;
	scope(exit) free(twice);
	assert(concatenate(s, s));
	assert(equal(s, twice));
	assert(append(s, slice(s)[0 .. 2], 1));
	assert(startsWith(s, twice, 0) && endsWith(s, "ab1", 0));

	char* r = clone("abcdef");
	scope(exit) free(r);
	assert(replaceRange(r, slice(r)[1 .. 5], 2, 2) !is null);
	assert(equal(r, "abbcdeef"));
	assert(replaceRange(r, slice(r)[5 .. 6], 0, 4) !is null);
	assert(equal(r, "edeef"));
	assert(replaceRange(r, slice(r)[2 .. 4], 0, 2) !is null);
	assert(equal(r, "eeeef"));

	char* t = clone("a-b-c");
	scope(exit) free(t);
	assert(replace(t, slice(t)[1 .. 2], "+", 0) !is null);
	assert(equal(t, "a+b+c"));
	assert(replace(t, "+", t, 0) !is null);
	assert(equal(t, "aa+b+cba+b+cc"));

	// A later piece viewing `u` must not read the block an earlier piece's growth freed.
	char* u = clone("abcd");
	scope(exit) free(u);
	assert(append(u, "x", u, slice(u)[1 .. 2]));
	assert(equal(u, "abcdxabcdb"));
}

unittest {
	assert(isDigit('0') && isDigit('9') && !isDigit('a') && !isDigit('/'));
	assert(isOctalDigit('7') && !isOctalDigit('8'));
	assert(isHexDigit('0') && isHexDigit('f') && isHexDigit('F') && !isHexDigit('g'));
	assert(isAsciiAlpha('a') && isAsciiAlpha('Z') && !isAsciiAlpha('0'));

	char* out_ = null;
	scope(exit) free(out_);
	assert(appendCodepoint(out_, 'A') == Utf8Error.none);
	assert(appendCodepoint(out_, 0x20AC) == Utf8Error.none);
	assert(slice(out_) == "A\xe2\x82\xac");
	assert(appendCodepoint(out_, 0x110000) == Utf8Error.outOfRange);
	assert(appendCodepoint(out_, 0xD800) == Utf8Error.surrogate);
	assert(slice(out_) == "A\xe2\x82\xac");

	static immutable string[4] whole = ["A", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80"];
	static immutable uint[4] expected = [0x41, 0xE9, 0x20AC, 0x1F600];
	foreach (n, s; whole) {
		size_t i = 0;
		bool valid;
		assert(decodeUtf8(s, i, valid) == expected[n]);
		assert(valid && i == s.length);
	}
	foreach (s; whole[1 .. $]) {
		auto truncated = s[0 .. $ - 1];
		size_t i = 0;
		bool valid;
		immutable codepoint = decodeUtf8(truncated, i, valid);
		assert(i > 0);
		assert(codepoint == cast(ubyte) truncated[0] || i == truncated.length);
	}
	size_t j = 0;
	assert(decodeUtf8("\xc3\xa9", j) == 0xE9 && j == 2);

	// A non-continuation byte, overlong forms, a surrogate and a value past U+10FFFF are all malformed.
	static immutable string[5] malformed = ["\xc3A", "\xc0\x80", "\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80"];
	foreach (s; malformed) {
		size_t i = 0;
		bool valid;
		assert(decodeUtf8(s, i, valid) == cast(ubyte) s[0] && !valid && i == 1);
		assert(codepoints(s) is null);
	}
	j = 0;
	assert(decodeUtf8("\xf4\x8f\xbf\xbf", j) == 0x10FFFF && j == 4);

	// Sequence lengths agree with what decoding consumes, and UTF-16 units sum to each code point's units.
	foreach (n, s; whole) {
		size_t i = 0, units = 0;
		cast(void) decodeUtf8(s, i);
		assert(utf8SequenceLength(s[0]) == i);
		foreach (c; s) units += utf16Length(c);
		assert(units == (expected[n] >= 0x10000 ? 2 : 1));
	}
	assert(utf8SequenceLength('\x80') == 1 && utf8SequenceLength('\xFF') == 1 && utf16Length('\xFF') == 1);

	uint* codepoint = codepoints("Hello, 世界 café \U0001F600");
	scope(exit) fp.dynarray.free(codepoint);
	uint[15] cps = ['H', 'e', 'l', 'l', 'o', ',', ' ', 0x4E16, 0x754C, ' ', 'c', 'a', 'f', 0xE9, ' '];
	assert(fp.dynarray.length(codepoint) == cps.length + 1);
	foreach (i, c; cps)
		assert(codepoint[i] == c);
	assert(codepoint[cps.length] == 0x1F600);

	char* utf8 = fromCodepoints(codepoint);
	scope(exit) free(utf8);
	assert(equal(utf8, "Hello, 世界 café \U0001F600"));

	wchar* units = utf16("Hello, 世界 café \U0001F600");
	scope(exit) fp.dynarray.free(units);
	assert(units[0 .. fp.dynarray.length(units)] =="Hello, 世界 café \U0001F600"w && units[fp.dynarray.length(units)] == 0);
	assert(utf16("") is null && utf16("\xe2\x82") is null && utf16("a\xf0\x9f\x98") is null && utf16("\xed\xa0\x80") is null);
	char* roundTrip = fromUtf16(units);
	scope(exit) free(roundTrip);
	assert(equal(roundTrip, "Hello, 世界 café \U0001F600"));
	wchar[2] reversed = [0xDE00, 0xD83D];
	wchar[2] unpaired = ['a', 0xDC00];
	assert(fromUtf16(reversed[]) is null && fromUtf16(unpaired[]) is null && fromUtf16("a￿"w[0 .. 1]) !is null);
	assert(fromUtf16((wchar[]).init) is null && fromUtf16(cast(wchar*) null) is null);

	assert(codepoints("\xe2\x82") is null);
	assert(codepoints("\xf0\x9f\x98") is null);
	ubyte[1] invalidByte = [0x80];
	assert(codepoints(cast(char[]) invalidByte[]) is null);
	uint[1] outOfRange = [0x110000];
	assert(fromCodepoints(outOfRange[]) is null);
	uint[1] surrogate = [0xD800];
	assert(fromCodepoints(surrogate[]) is null);
	assert(fromCodepoints((uint[]).init) is null && fromCodepoints(cast(uint*) null) is null);
}

unittest {
	fp.pointer.Allocator previous;

	// Refused at the copy of the slice argument, then at the result.
	foreach (allowed; 0 .. 2) {
		previous = fp.testing.limitAllocations(allowed);
		assert(format("%s", "text") is null);
		fp.testing.restoreAllocator(previous);
	}

	// The first allocation holds one slice, or two where slices are 8 bytes, so a later push is refused, leaving a partial result.
	previous = fp.testing.limitAllocations(1);
	assert(split("a,b,c", ",") is null);
	fp.testing.restoreAllocator(previous);

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

	char* s = clone("x");
	scope(exit) free(s);
	previous = fp.testing.limitAllocations();
	assert(!append(s, "more", 1));
	assert(appendCodepoint(s, 0xE9) == Utf8Error.allocationRefused);
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

	// Refused at the copy of `ab`, then at the reservation.
	char* ab = clone("ab");
	scope(exit) free(ab);
	foreach (allowed; 0 .. 2) {
		previous = fp.testing.limitAllocations(allowed);
		assert(repeat(ab, 3) is null);
		fp.testing.restoreAllocator(previous);
		assert(equal(ab, "ab"));
	}

	char* dash = clone("a-b");
	scope(exit) free(dash);
	previous = fp.testing.limitAllocations();
	assert(replaceFirst(dash, "-", "--", 0) == fp.pointer.allocationRefused);
	assert(replace(dash, "-", "--", 0) is null);
	// Refused at the copies taken of arguments that view `dash`.
	assert(replaceRange(dash, dash, 0, 0) is null);
	assert(replace(dash, slice(dash)[1 .. 2], "+", 0) is null);
	assert(replace(dash, "-", dash, 0) is null);
	fp.testing.restoreAllocator(previous);
	assert(equal(dash, "a-b"));

	// Each first allocation succeeds and a later one is refused, leaving a partial result to free.
	previous = fp.testing.limitAllocations(1);
	assert(codepoints("more than four codepoints") is null);
	fp.testing.restoreAllocator(previous);
	previous = fp.testing.limitAllocations(0);
	assert(utf16("x") is null);
	fp.testing.restoreAllocator(previous);
	previous = fp.testing.limitAllocations(1);
	assert(fromUtf16("世界"w) is null);
	fp.testing.restoreAllocator(previous);
	uint[2] wide = [0x4E16, 0x754C];
	previous = fp.testing.limitAllocations(1);
	assert(fromCodepoints(wide[]) is null);
	fp.testing.restoreAllocator(previous);
}

unittest { // number formatting and parsing, case folding, trimming and range lookup
	foreach (c; "0123456789abcdefABCDEF") assert(hexDigitValue(c) == (isDigit(c) ? c - '0' : (c | 0x20) - 'a' + 10));

	assert(parseUnsigned("777", 8).get.value == 511 && parseUnsigned("101", 2).get.value == 5);
	assert(parseUnsigned("FFFFFFFFFFFFFFFF", 16).get.value == ulong.max);
	assert(parseUnsigned("10000000000000000", 16).isNull); // one digit too many
	assert(parseUnsigned("8", 8).isNull && parseUnsigned("1_0", 10).isNull && parseUnsigned("-1", 10).isNull);

	assert(parseFloat("0x1p-2").get.value == 0.25 && parseFloat("-0").get.value == 0);
	assert(parseFloat("inf").get.value == double.infinity);
	assert(parseFloat("-1e400").isNull && parseFloat(" 1").isNull && parseFloat("1 ").isNull);
	assert(parseFloat("1e-400").get.value == 0); // underflow rounds toward zero
	char[100] longDigits = '1';
	assert(parseFloat(longDigits[]).get.value > 1e98); // past the stack buffer, so read from a heap copy

	char* s = null;
	scope(exit) free(s);
	assert(appendSigned(s, 0) && appendSigned(s, -5) && appendHex(s, 0xDEADBEEF) && appendHex(s, 1, 16));
	assert(equal(s, "0-5deadbeef0000000000000001"));

	assert(equalIgnoringAsciiCase("", "") && equalIgnoringAsciiCase("ÄbC", "Äbc") && !equalIgnoringAsciiCase("[", "{"));
	assert(trimEnd("", " ") == "" && trimEnd("a b", " ") == "a b" && trimEnd("ab\t \t", " \t") == "ab");

	static immutable uint[2][1] single = [[5, 5]];
	assert(inCodepointRanges(single[], 5) && !inCodepointRanges(single[], 4) && !inCodepointRanges(single[], 6));
	assert(!inCodepointRanges((const(uint[2])[]).init, 0));
}

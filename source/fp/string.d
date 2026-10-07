/// Null-terminated dynamic strings on top of `fp.dynarray`. An fp string is a `char*` dynarray that always ends in a zero byte, so it passes straight to C. A null `char*` is the empty string.
///
/// Every string argument is `isStringLike`: an fp string, a C string, a D slice or literal, or null.
///
/// Examples:
/// ---
/// char* s = makeDynamic("Hello");
/// scope(exit) free(s);
/// assert(concatenate(s, ", World") !is null);
/// assert(equal(s, "Hello, World"));
/// assert(s[length(s)] == '\0');
/// ---
module fp.string;

import core.stdc.string;
import core.stdc.stdio : snprintf, vsnprintf;
import core.stdc.stdarg : va_list, va_start, va_end;
static import core.checkedint;

static import fp.pointer;
static import fp.dynarray;


@nogc nothrow:


/// Whether the functions here accept an `S` as a string: a `char*` of any qualifier (an fp string or C string), a D slice or literal, or `typeof(null)`. Static arrays are excluded, since they would be copied and sliced on the stack; pass `buffer[]` instead.
///
/// Examples:
/// ---
/// static assert(isStringLike!(char*) && isStringLike!string && isStringLike!(typeof(null)));
/// static assert(!isStringLike!(char[4]) && !isStringLike!(int*));
/// ---
enum bool isStringLike(S) = !__traits(isStaticArray, S) && (is(S : const(char)[]) || is(S : const(char)*));

/// A D slice over the characters of `str`, keeping its qualifier: a D slice as is, an fp string's recorded length, or a C string's `strlen`. Null gives null.
///
/// Examples:
/// ---
/// char* s = makeDynamic("abc");
/// scope(exit) free(s);
/// assert(slice(s) == "abc");
/// assert(slice("literal") == "literal");
/// assert(slice("plain C".ptr) == "plain C");
/// assert(slice(null) is null);
/// ---
auto slice(S)(S str) @trusted if (isStringLike!S) {
	// A literal converts equally well to a pointer and to a slice, so separate overloads would be ambiguous for it.
	static if (is(S == typeof(null))) return (char[]).init;
	else static if (is(S : const(char)[])) return str[];
	else {
		if (str is null) return str[0 .. 0];
		if (fp.pointer.valid(str)) return str[0 .. fp.pointer.length(str)];
		return str[0 .. core.stdc.string.strlen(str)];
	}
}


/// The number of characters (bytes) in `str`, excluding the terminator.
///
/// Examples:
/// ---
/// char* s = makeDynamic("four");
/// scope(exit) free(s);
/// assert(length(s) == 4);
/// assert(length(null) == 0);
/// ---
size_t length(inout char* str) @trusted {
	return slice(str).length;
}

/// Ditto
alias size = length;



/// A new fp string holding a copy of `str`; null if the copy is empty (null is the empty string) or could not be allocated.
///
/// Examples:
/// ---
/// char* a = makeDynamic("text");
/// scope(exit) free(a);
/// char* b = makeDynamic(a);
/// scope(exit) free(b);
/// assert(b !is a && equal(a, b));
/// assert(makeDynamic("") is null);
/// ---
char* makeDynamic(S)(S str) @trusted if (isStringLike!S) {
	const(char)[] view = slice(str);
	if (view.length == 0) return null;
	char* out_ = null;
	if (fp.dynarray.growToSize(out_, view.length) is null) return null;
	core.stdc.string.memcpy(out_, view.ptr, view.length);
	return out_;
}

/// Ditto
alias clone = makeDynamic;

/// Frees `str`, which may be an fp string, a plain heap fat pointer, or memory straight from `allocFunction`; each is released by its own layer. A stack fat pointer (from `fp.pointer.Array` or `fp.pointer.alloca`) belongs to its frame and is left alone. A hash table is rejected and left untouched, since only `fp.hashtable.free` can release it. The `ref` overload also sets `str` to null, unless it was rejected.
///
/// Examples:
/// ---
/// char* s = makeDynamic("bye");
/// free(s);
/// assert(s is null);
/// ---
void free(ref char* str) @trusted {
	// Nulling a rejected table would lose the caller's only handle to it.
	if (fp.pointer.pointerType(str) == fp.pointer.PointerType.hashTable) return;
	free(cast(const char*) str);
	str = null;
}
/// Ditto
void free(const char* str) @trusted {
	immutable type = fp.pointer.pointerType(str);
	if (type == fp.pointer.PointerType.stack || type == fp.pointer.PointerType.hashTable) return;
	if (fp.dynarray.valid(str)) fp.dynarray.free(str);
	else if (fp.pointer.valid(str) && fp.pointer.heapAllocated(str)) fp.pointer.free(str);
	else cast(void)fp.pointer.allocFunction(cast(void*) str, 0);
}

private enum bool isSliceArg(T) = isStringLike!T && !is(T : const(char)*);

private alias aliasSeq(T...) = T;

// `Args` with each slice replaced by the C string `format` passes in its place.
private template cArgTypes(Args...) {
	static if (Args.length == 0) alias cArgTypes = Args;
	else static if (isSliceArg!(Args[0])) alias cArgTypes = aliasSeq!(const(char)*, cArgTypes!(Args[1 .. $]));
	else alias cArgTypes = aliasSeq!(Args[0], cArgTypes!(Args[1 .. $]));
}

private extern (C) char* formatC(const char* fmt, ...) @trusted {
	va_list argsSize;
	va_start(argsSize, fmt);
	immutable size = vsnprintf(null, 0, fmt, argsSize);
	va_end(argsSize);
	if (size <= 0) return null;

	char* out_ = null;
	if (fp.dynarray.growToSize(out_, size) is null) return null;

	va_list args;
	va_start(args, fmt);
	cast(void)vsnprintf(out_, length(out_) + 1, fmt, args);
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
char* format(Args...)(const char* fmt, Args args) @trusted {
	cArgTypes!Args cArgs;
	scope(exit) static foreach (i, A; Args) static if (isSliceArg!A) if (args[i].length != 0) free(cArgs[i]);
	static foreach (i, A; Args) {
		static if (isSliceArg!A) {
			cArgs[i] = args[i].length == 0 ? "".ptr : makeDynamic(args[i]);
			if (cArgs[i] is null) return null;
		} else cArgs[i] = args[i];
	}
	return formatC(fmt, cArgs);
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
/// char* s = makeDynamic("same");
/// scope(exit) free(s);
/// assert(equal(s, "same"));
/// assert(!equal(s, "different"));
/// ---
bool equal(A, B)(A a, B b) @trusted if (isStringLike!A && isStringLike!B) {
	return compare(a, b) == 0;
}


/// The index of the first `needle` in `haystack` at or after `start`, or `fp.pointer.notFound`.
///
/// Examples:
/// ---
/// assert(find("abcabc", "bc", 2) == 4);
/// assert(find("abc", "x", 0) == fp.pointer.notFound);
/// ---
size_t find(H, N)(H haystack, N needle, size_t start) @trusted if (isStringLike!H && isStringLike!N) {
	const(char)[] h = slice(haystack);
	const(char)[] n = slice(needle);
	assert(start <= h.length);
	if (n.length > h.length - start) return fp.pointer.notFound;

	immutable bound = h.length - n.length;
	outer: for (size_t i = start; i <= bound; ++i) {
		foreach (j; 0 .. n.length)
			if (h[i + j] != n[j])
				continue outer;
		return i;
	}
	return fp.pointer.notFound;
}

/// Whether `needle` occurs in `haystack` at or after `start`.
///
/// Examples:
/// ---
/// assert(contains("haystack", "st", 0));
/// assert(!contains("haystack", "hay", 1));
/// ---
bool contains(H, N)(H haystack, N needle, size_t start) @trusted if (isStringLike!H && isStringLike!N) {
	return find(haystack, needle, start) != fp.pointer.notFound;
}

/// Whether `needle` occurs in `haystack` starting exactly at `start`; false for a `start` past the end.
///
/// Examples:
/// ---
/// assert(startsWith("prefix", "pre", 0));
/// assert(startsWith("prefix", "fix", 3));
/// ---
bool startsWith(H, N)(H haystack, N needle, size_t start) @trusted if (isStringLike!H && isStringLike!N) {
	const(char)[] h = slice(haystack);
	const(char)[] n = slice(needle);
	if (start > h.length || n.length > h.length - start) return false;
	return h[start .. start + n.length] == n;
}

/// Whether `needle` occurs in `haystack` ending exactly at index `end`; false for an `end` past the end. An `end` of 0 or less counts back from the end of `haystack`.
///
/// Examples:
/// ---
/// assert(endsWith("suffix", "fix", 0));
/// assert(endsWith("suffix", "suf", 3));
/// assert(endsWith("suffix", "uff", -2));
/// ---
bool endsWith(H, N)(H haystack, N needle, ptrdiff_t end) @trusted if (isStringLike!H && isStringLike!N) {
	const(char)[] h = slice(haystack);
	const(char)[] n = slice(needle);
	if (end <= 0) end += cast(ptrdiff_t) h.length;
	if (end > cast(ptrdiff_t) h.length || cast(ptrdiff_t) n.length > end) return false;
	immutable start = cast(size_t)(end - cast(ptrdiff_t) n.length);
	return h[start .. cast(size_t) end] == n;
}

/// Splits `str` on every occurrence of `delimiter`, which must not be empty. Returns a new `fp.dynarray` of slices into `str`, so `str` must outlive them; free the dynarray itself with `fp.dynarray.free`. Returns null if an allocation was refused.
///
/// Examples:
/// ---
/// const(char)[]* parts = split("a,b,,c", ",");
/// scope(exit) fp.dynarray.free(parts);
/// assert(fp.dynarray.length(parts) == 4);
/// assert(parts[0] == "a" && parts[2] == "" && parts[3] == "c");
/// ---
const(char)[]* split(S, D)(S str, D delimiter) @trusted if (isStringLike!S && isStringLike!D) {
	const(char)[] s = slice(str);
	const(char)[] d = slice(delimiter);
	assert(d.length > 0);
	const(char)[]* result = null;

	size_t start = 0;
	while (true) {
		immutable pos = find(s, d, start);
		immutable end = pos == fp.pointer.notFound ? s.length : pos;
		if (!fp.dynarray.pushBack(result, s[start .. end])) {
			fp.dynarray.free(result);
			return null;
		}
		if (pos == fp.pointer.notFound) break;
		start = pos + d.length;
	}

	return result;
}


/// Appends character `c` to `str`, which may be null. Returns `str`, or null if it could not grow (leaving it unchanged).
///
/// Examples:
/// ---
/// char* s = null;
/// scope(exit) free(s);
/// assert(append(s, 'h') !is null);
/// assert(append(s, 'i') !is null);
/// assert(equal(s, "hi"));
/// ---
char* append(ref char* str, char c) @trusted {
	return concatenate(str, (&c)[0 .. 1]);
}

/// Appends `b` to `a`, which may be null. Returns `a`, or null if it could not grow (leaving it unchanged) or both are empty.
///
/// Examples:
/// ---
/// char* s = null;
/// scope(exit) free(s);
/// assert(concatenate(s, "ab") !is null);
/// assert(concatenate(s, "cd".ptr) !is null);
/// assert(equal(s, "abcd"));
/// ---
char* concatenate(S)(ref char* a, S b) @trusted if (isStringLike!S) {
	assert(fp.pointer.valid(a) || a is null);
	const(char)[] view = slice(b);
	if (length(a) + view.length == 0) return null;
	if (!fp.dynarray.concatenate(a, view)) return null;
	// The NUL written at allocation sits at the end of the capacity, which may run past the string.
	a[length(a)] = 0;
	return a;
}


/// Why a codepoint could not be encoded as UTF-8, or appended once encoded.
enum Utf8Error : ubyte {
	none, /// It was encoded (and appended).
	outOfRange, /// Above U+10FFFF.
	surrogate, /// U+D800-U+DFFF: UTF-16 machinery, never valid in UTF-8.
	allocationRefused, /// Encodable, but the string could not grow to hold it.
}

/// Encodes `codepoint` into `out_`, which must have room for four bytes. Returns the number of bytes written, or 0 with `err` saying why.
///
/// Examples:
/// ---
/// char[4] buffer;
/// Utf8Error err;
/// assert(encodeUtf8(0x20AC, buffer.ptr, err) == 3);
/// assert(buffer[0 .. 3] == "€");
/// assert(encodeUtf8(0xD800, buffer.ptr, err) == 0 && err == Utf8Error.surrogate);
/// assert(encodeUtf8('A', buffer.ptr) == 1);
/// ---
size_t encodeUtf8(uint codepoint, char* out_, out Utf8Error err) @trusted {
	if (codepoint > 0x10FFFF) {
		err = Utf8Error.outOfRange;
		return 0;
	}
	if (codepoint >= 0xD800 && codepoint <= 0xDFFF) {
		err = Utf8Error.surrogate;
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


// Characters and numbers go through a stack buffer, not `format`, which would heap-allocate for every one appended. Returns false only if an allocation was refused.
private bool appendPiece(T)(ref char* str, T piece) @trusted {
	// `is(T : const(char)*)` covers every qualifier `slice` accepts; naming them individually once missed `immutable(char)*`, a literal's `.ptr`.
	static if (is(T : const(char)[]) || is(T : const(char)*)) {
		const(char)[] text = slice(piece);
	} else static if (is(immutable T == immutable char)) {
		const(char)[] text = (&piece)[0 .. 1];
	} else static if (is(immutable T == immutable wchar) || is(immutable T == immutable dchar)) {
		char[4] buffer;
		size_t n = encodeUtf8(piece, buffer.ptr);
		if (n == 0) n = encodeUtf8(0xFFFD, buffer.ptr);
		const(char)[] text = buffer[0 .. n];
	} else static if (is(T : real) && !is(T : long) && !is(T : ulong)) {
		char[64] buffer;
		immutable n = snprintf(buffer.ptr, buffer.length, "%Lg", cast(real) piece);
		const(char)[] text = n > 0 ? buffer[0 .. n] : null;
	} else static if (__traits(isUnsigned, T)) {
		char[32] buffer;
		immutable n = snprintf(buffer.ptr, buffer.length, "%llu", cast(ulong) piece);
		const(char)[] text = n > 0 ? buffer[0 .. n] : null;
	} else static if (is(T : long)) {
		char[32] buffer;
		immutable n = snprintf(buffer.ptr, buffer.length, "%lld", cast(long) piece);
		const(char)[] text = n > 0 ? buffer[0 .. n] : null;
	} else static assert(0, "fp.string: cannot concatenate a " ~ T.stringof);
	// `concatenate` also returns null for an empty result, which is not a failure.
	return text.length == 0 || concatenate(str, text) !is null;
}

/// Appends every piece to `str`, which may be null: slices, fp strings, characters, and numbers (written in decimal). A `wchar` or `dchar` is encoded as UTF-8, and one that cannot be, such as a lone surrogate, as U+FFFD. A piece may view `str` itself. Returns `str`, or null if an allocation was refused, leaving `str` as it was.
///
/// Examples:
/// ---
/// char* s = null;
/// scope(exit) free(s);
/// assert(concatenateMultiple(s, "line ", 42, ": ", 1.5, '!', '€') !is null);
/// assert(equal(s, "line 42: 1.5!€"));
/// ---
char* concatenateMultiple(Args...)(ref char* str, Args pieces) @trusted {
	// An earlier piece may move `str`, so pieces viewing it are copied before any is appended.
	const(char)[][Args.length] views;
	char*[Args.length] copies;
	scope(exit) foreach (ref copy; copies) free(copy);
	static foreach (i, A; Args) static if (isStringLike!A) {
		views[i] = slice(pieces[i]);
		if (fp.dynarray.overlaps(str, views[i])) {
			if ((copies[i] = makeDynamic(views[i])) is null) return null;
			views[i] = slice(copies[i]);
		}
	}

	immutable wasNull = str is null;
	immutable before = length(str);
	static foreach (i, A; Args) {{
		static if (isStringLike!A) immutable appended = appendPiece(str, views[i]);
		else immutable appended = appendPiece(str, pieces[i]);
		if (!appended) {
			if (wasNull) free(str);
			else {
				cast(void)fp.dynarray.popBackCount(str, length(str) - before);
				str[before] = 0;
			}
			return null;
		}
	}}
	return str;
}

/// A new fp string concatenating every piece, as `concatenateMultiple` does, or null if the result is empty or an allocation was refused. Free the result with `fp.string.free`.
///
/// Examples:
/// ---
/// char* s = createFromConcatenation("n=", -7, "!");
/// scope(exit) free(s);
/// assert(equal(s, "n=-7!"));
/// ---
char* createFromConcatenation(Args...)(Args pieces) {
	char* out_ = null;
	return concatenateMultiple(out_, pieces);
}


/// Repeats fp string `str` so it holds `times` copies of itself. A `times` of 0 frees it, leaving null, and an empty `str` stays as it is. Returns `str`, or null if an allocation was refused or the length would overflow, leaving `str` unchanged.
///
/// Examples:
/// ---
/// char* s = makeDynamic("ab");
/// scope(exit) free(s);
/// assert(replicate(s, 3) !is null);
/// assert(equal(s, "ababab"));
/// ---
char* replicate(ref char* str, size_t times) @trusted {
	if (times == 0) {
		free(str);
		return str;
	}
	if (length(str) == 0) return str;

	assert(fp.pointer.valid(str));
	char* one = makeDynamic(str);
	scope(exit) free(one);
	bool overflow = false;
	immutable newLength = core.checkedint.mulu(length(str), times, overflow);
	if (one is null || overflow || fp.dynarray.reserve(str, newLength) is null) return null;
	// The capacity is reserved, so these appends cannot fail.
	foreach (i; 0 .. times - 1)
		cast(void)concatenate(str, one);
	return str;
}


/// Replaces the `rangeLen` characters of fp string `in_` starting at `start` with `with_`. Returns `in_`, or null if an allocation was refused (leaving it unchanged).
///
/// Examples:
/// ---
/// char* s = makeDynamic("Hello World");
/// scope(exit) free(s);
/// assert(replaceRange(s, "Bob", 6, 5) !is null);
/// assert(equal(s, "Hello Bob"));
/// ---
char* replaceRange(S)(ref char* in_, S with_, size_t start, size_t rangeLen) @trusted if (isStringLike!S) {
	assert(fp.pointer.valid(in_));
	const(char)[] w = slice(with_);
	immutable inLen = length(in_);
	assert(rangeLen <= inLen && start <= inLen - rangeLen);
	immutable end = start + rangeLen;

	immutable withLen = w.length;
	// `memmove`, not `memcpy`: `with_` may view `in_` itself.
	if (rangeLen > withLen) {
		immutable diff = rangeLen - withLen;
		core.stdc.string.memmove(in_ + start, w.ptr, withLen);
		cast(void)fp.dynarray.deleteRange(in_, start + withLen, diff, false);
	} else if (withLen > rangeLen) {
		// Growing may free a `with_` that views `in_`, and the shift moves its text, so it is copied first.
		char* copy = null;
		scope(exit) free(copy);
		if (fp.dynarray.overlaps(in_, w)) {
			if ((copy = makeDynamic(w)) is null) return null;
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
/// char* s = makeDynamic("a-b-c");
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
/// char* s = makeDynamic("a-b-c");
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
		if ((needleCopy = makeDynamic(n)) is null) return null;
		n = slice(needleCopy);
	}
	if (fp.dynarray.overlaps(in_, r)) {
		if ((replacementCopy = makeDynamic(r)) is null) return null;
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


/// Encodes `codepoint` as UTF-8 and appends it to `str`, which may be null. Returns `Utf8Error.none`, or why nothing was appended.
///
/// Examples:
/// ---
/// char* s = null;
/// scope(exit) free(s);
/// assert(appendCodepoint(s, 0xE9) == Utf8Error.none);
/// assert(equal(s, "é"));
/// assert(appendCodepoint(s, 0x110000) == Utf8Error.outOfRange);
/// ---
Utf8Error appendCodepoint(ref char* str, uint codepoint) @trusted {
	char[4] encoded;
	Utf8Error err;
	immutable n = encodeUtf8(codepoint, encoded.ptr, err);
	if (n > 0 && concatenate(str, encoded[0 .. n]) is null) return Utf8Error.allocationRefused;
	return err;
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
	uint cp = 0, least = 0;
	if ((c >> 5) == 0x6) { n = 2; cp = c & 0x1F; least = 0x80; }
	else if ((c >> 4) == 0xE) { n = 3; cp = c & 0x0F; least = 0x800; }
	else if ((c >> 3) == 0x1E) { n = 4; cp = c & 0x07; least = 0x10000; }

	valid = n != 0 && n <= s.length - i;
	foreach (k; 1 .. valid ? n : 1) {
		immutable b = cast(ubyte) s[i + k];
		if ((b & 0xC0) != 0x80) {
			valid = false;
			break;
		}
		cp = (cp << 6) | (b & 0x3F);
	}
	if (valid && (cp < least || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)))
		valid = false;

	if (!valid) {
		++i;
		return c;
	}
	i += n;
	return cp;
}
/// Ditto
uint decodeUtf8(const(char)[] s, ref size_t i) @trusted {
	bool ignored;
	return decodeUtf8(s, i, ignored);
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
uint* codepoints(S)(S str) @trusted if (isStringLike!S) {
	const(char)[] view = slice(str);
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

	foreach (cp; view) {
		char[4] temp;
		immutable len = encodeUtf8(cp, temp.ptr);
		if (len == 0 || concatenate(out_, temp[0 .. len]) is null) {
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
	char* dynamic = makeDynamic(buffer[]);
	scope(exit) free(dynamic);
	const(char)* constant = dynamic;
	immutable(char)* literal = "abc".ptr;
	const(char)[] view = buffer[];
	assert(equal(dynamic, constant) && equal(constant, literal) && equal(literal, view) && equal(view, "abc"));
	assert(equal(null, "") && equal(cast(char*) null, null) && compare(null, "a") < 0);
	assert(makeDynamic(null) is null && length(null) == 0);

	assert(fp.pointer.valid(dynamic) && fp.dynarray.valid(dynamic));
	assert(!fp.pointer.stackAllocated(dynamic) && fp.pointer.heapAllocated(dynamic));
	assert(length(dynamic) == 3);
	assert(dynamic[3] == 0); // fp strings are null terminated!

	// Null takes every branch of the by-value overload harmlessly.
	free(null);
	char* heapStr = fp.pointer.malloc!char(4);
	assert(heapStr !is null);
	free(heapStr);
	char* nullStr = null;
	free(nullStr);
	assert(nullStr is null);
	fp.pointer.Array!(char, 4) onStack;
	onStack[0] = 'h';
	char* stackStr = onStack;
	free(stackStr);
	assert(stackStr is null && onStack[0] == 'h');
	static import fp.hashtable;
	char* table = fp.hashtable.create!char();
	assert(table !is null && fp.hashtable.insert(table, 'h') !is null);
	free(table);
	free(cast(const char*) table);
	assert(table !is null && fp.hashtable.contains(table, 'h'));
	fp.hashtable.free(table);

	char* fmt = format("%s %s%c\n", "Hello".ptr, "World".ptr, '!');
	scope(exit) free(fmt);
	assert(equal(fmt, "Hello World!\n"));
	char[5] world = "World";
	char* fmtSlices = format("%s %s%c%s", "Hello", world[], '!', "");
	scope(exit) free(fmtSlices);
	assert(equal(fmtSlices, "Hello World!"));
	assert(format("%s", "") is null && format("") is null);
}

unittest {
	char* str = makeDynamic("Hello World");
	scope(exit) free(str);
	char* bang = makeDynamic("Hello World!");
	scope(exit) free(bang);
	assert(compare(str, str) == 0);
	assert(compare(str, bang) < 0);
	assert(compare(bang, str) > 0);
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
	assert(startsWith(bang, "Hello", 0));
	assert(endsWith(bang, "World!", 0) && !endsWith(bang, "World", 0));
	assert(startsWith(bang, "", length(bang)) && !startsWith(bang, "", 100) && !startsWith(bang, "", size_t.max));
	assert(endsWith(bang, "", length(bang)) && !endsWith(bang, "", 100));

	char* s = makeDynamic("one two one");
	scope(exit) free(s);
	const(char)[] one = slice(s)[0 .. 3];
	assert(find(s, one, 1) == 8 && contains(slice(s), "two".ptr, 0));
	assert(startsWith(slice(s), one, 0) && endsWith(s, one, 0));

	const(char)[]* parts = split("a,bb,,ccc", ",");
	scope(exit) fp.dynarray.free(parts);
	assert(fp.dynarray.length(parts) == 4);
	assert(parts[0] == "a" && parts[1] == "bb" && parts[2] == "" && parts[3] == "ccc");

	char* colons = makeDynamic("a::bb::ccc");
	scope(exit) free(colons);
	char* delim = makeDynamic("::");
	scope(exit) free(delim);
	const(char)[]* byString = split(colons, delim);
	scope(exit) fp.dynarray.free(byString);
	assert(fp.dynarray.length(byString) == 3);
	assert(byString[0] == "a" && byString[1] == "bb" && byString[2] == "ccc");

	const(char)[]* whole = split("no-delimiter-here", ",");
	scope(exit) fp.dynarray.free(whole);
	assert(fp.dynarray.length(whole) == 1);
	assert(whole[0] == "no-delimiter-here");
}

unittest {
	char* str = null;
	scope(exit) free(str);
	foreach (c; "abc") assert(append(str, c) !is null);
	assert(slice(str) == "abc");
	assert(str[3] == '\0');
	assert(concatenate(str, "!") !is null);
	assert(concatenate(str, " bob") !is null);
	assert(equal(str, "abc! bob"));
	assert(concatenateMultiple(str, "") is str); // an empty piece is not a failure

	char[4] buffer;
	Utf8Error err;
	assert(encodeUtf8(0x110000, buffer.ptr, err) == 0 && err == Utf8Error.outOfRange);
	assert(encodeUtf8(0xDC00, buffer.ptr, err) == 0 && err == Utf8Error.surrogate);
	assert(encodeUtf8(0x1F600, buffer.ptr, err) == 4 && err == Utf8Error.none);

	// Characters are appended as text, not as their numeric values.
	char* chars = createFromConcatenation('a', cast(const char) 'b', wchar('é'), dchar(0x1F600), cast(wchar) 0xD800, cast(dchar) 0x110000);
	scope(exit) free(chars);
	assert(slice(chars) == "abé\U0001F600\uFFFD\uFFFD");

	char* name = makeDynamic("verify.d");
	scope(exit) free(name);
	char* out_ = null;
	scope(exit) free(out_);
	assert(concatenateMultiple(out_, "at ", name, ":", 42, " of ", 100UL) !is null);
	assert(slice(out_) == "at verify.d:42 of 100");

	char* made = createFromConcatenation("n=", -7, " x=", 1.5);
	scope(exit) free(made);
	assert(slice(made) == "n=-7 x=1.5");

	char* extremes = createFromConcatenation(ulong.max, " ", long.min, " ", ubyte(200), " ", true);
	scope(exit) free(extremes);
	assert(slice(extremes) == "18446744073709551615 -9223372036854775808 200 1");

	char* nothing = null;
	char* withNull = createFromConcatenation("a", nothing, "b");
	scope(exit) free(withNull);
	assert(slice(withNull) == "ab");

	char* world = makeDynamic("World");
	scope(exit) free(world);
	char* mixed = createFromConcatenation("Hello, ".ptr, world, "!".ptr);
	scope(exit) free(mixed);
	assert(equal(mixed, "Hello, World!"));
}

unittest {
	char* zeroRepl = null;
	assert(replicate(zeroRepl, 0) is null);
	assert(zeroRepl is null);

	char* replaced = makeDynamic("Hello World");
	scope(exit) free(replaced);
	assert(replicate(replaced, 5) !is null);
	assert(equal(replaced, "Hello WorldHello WorldHello WorldHello WorldHello World"));
	assert(replicate(replaced, size_t.max / 5 + 1) is null);
	assert(length(replaced) == 55);
	char* emptied = makeDynamic("ab");
	scope(exit) free(emptied);
	fp.dynarray.clear(emptied);
	assert(replicate(emptied, 3) is emptied && length(emptied) == 0);
	assert(replace(replaced, "World", "Bob", 0) !is null);
	assert(equal(replaced, "Hello BobHello BobHello BobHello BobHello Bob"));
	assert(replace(replaced, "Bob", "World!", 0) !is null);
	assert(equal(replaced, "Hello World!Hello World!Hello World!Hello World!Hello World!"));
	assert(replace(replaced, "World!", "Earth!", 0) !is null);
	assert(equal(replaced, "Hello Earth!Hello Earth!Hello Earth!Hello Earth!Hello Earth!"));

	char* rr = makeDynamic("Hello World");
	scope(exit) free(rr);
	assert(replaceRange(rr, "Bob", 6, 5) !is null);
	assert(equal(rr, "Hello Bob"));

	char* rf = makeDynamic("Hello World World");
	scope(exit) free(rf);
	assert(replaceFirst(rf, "World", "Bob", 0) == 6);
	assert(equal(rf, "Hello Bob World"));

	char* s = makeDynamic("one two one");
	scope(exit) free(s);
	assert(replaceFirst(s, "two".ptr, slice(s)[4 .. 7], 0) == 4);
	assert(equal(s, "one two one"));
}

unittest {
	// Arguments viewing the string being changed keep the text they had when passed, through reallocation, shifting and earlier replacements.
	auto previous = fp.dynarray.beginPoisoningAllocator();
	scope(exit) fp.dynarray.endPoisoningAllocator(previous);

	char* s = makeDynamic("abcd");
	scope(exit) free(s);
	assert(fp.dynarray.length(s) == fp.dynarray.capacity(s)); // full, so the appends below reallocate
	char* twice = createFromConcatenation(s, s);
	scope(exit) free(twice);
	assert(concatenate(s, s) !is null);
	assert(equal(s, twice));
	assert(concatenateMultiple(s, slice(s)[0 .. 2], 1) !is null);
	assert(startsWith(s, twice, 0) && endsWith(s, "ab1", 0));

	char* r = makeDynamic("abcdef");
	scope(exit) free(r);
	assert(replaceRange(r, slice(r)[1 .. 5], 2, 2) !is null);
	assert(equal(r, "abbcdeef"));
	assert(replaceRange(r, slice(r)[5 .. 6], 0, 4) !is null);
	assert(equal(r, "edeef"));
	assert(replaceRange(r, slice(r)[2 .. 4], 0, 2) !is null);
	assert(equal(r, "eeeef"));

	char* t = makeDynamic("a-b-c");
	scope(exit) free(t);
	assert(replace(t, slice(t)[1 .. 2], "+", 0) !is null);
	assert(equal(t, "a+b+c"));
	assert(replace(t, "+", t, 0) !is null);
	assert(equal(t, "aa+b+cba+b+cc"));

	// A later piece viewing `u` must not read the block an earlier piece's growth freed.
	char* u = makeDynamic("abcd");
	scope(exit) free(u);
	assert(concatenateMultiple(u, "x", u, slice(u)[1 .. 2]) !is null);
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
		immutable cp = decodeUtf8(truncated, i, valid);
		assert(i > 0);
		assert(cp == cast(ubyte) truncated[0] || i == truncated.length);
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

	uint* cp = codepoints("Hello, 世界 café \U0001F600");
	scope(exit) fp.dynarray.free(cp);
	uint[15] cps = ['H', 'e', 'l', 'l', 'o', ',', ' ', 0x4E16, 0x754C, ' ', 'c', 'a', 'f', 0xE9, ' '];
	assert(fp.dynarray.length(cp) == cps.length + 1);
	foreach (i, c; cps)
		assert(cp[i] == c);
	assert(cp[cps.length] == 0x1F600);

	char* utf8 = fromCodepoints(cp);
	scope(exit) free(utf8);
	assert(equal(utf8, "Hello, 世界 café \U0001F600"));

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
	fp.pointer.AllocFunction previous;

	// Refused at the copy of the slice argument, then at the result.
	foreach (allowed; 0 .. 2) {
		previous = fp.dynarray.beginRationedAllocator(allowed);
		assert(format("%s", "text") is null);
		fp.dynarray.endRationedAllocator(previous);
	}

	// The first allocation holds one slice, or two where slices are 8 bytes, so a later push is refused, leaving a partial result.
	previous = fp.dynarray.beginRationedAllocator(1);
	assert(split("a,b,c", ",") is null);
	fp.dynarray.endRationedAllocator(previous);

	// A refused push must leave the string untouched, not write a terminator through the null it leaves.
	char* str = null;
	previous = fp.dynarray.beginRationedAllocator();
	assert(append(str, 'a') is null);
	fp.dynarray.endRationedAllocator(previous);
	assert(str is null);

	assert(append(str, 'a') !is null);
	scope(exit) free(str);
	while (fp.dynarray.length(str) < fp.dynarray.capacity(str))
		assert(append(str, 'a') !is null);
	immutable filled = length(str);
	previous = fp.dynarray.beginRationedAllocator();
	assert(append(str, 'b') is null);
	fp.dynarray.endRationedAllocator(previous);
	assert(length(str) == filled && str[filled] == '\0');

	char* s = makeDynamic("x");
	scope(exit) free(s);
	previous = fp.dynarray.beginRationedAllocator();
	assert(concatenateMultiple(s, "more", 1) is null);
	assert(appendCodepoint(s, 0xE9) == Utf8Error.allocationRefused);
	fp.dynarray.endRationedAllocator(previous);
	assert(equal(s, "x"));

	// The first piece is appended and the second refused: the first must be taken back off.
	previous = fp.dynarray.beginRationedAllocator(1);
	assert(concatenateMultiple(s, "abc", "a piece longer than the first allocation") is null);
	fp.dynarray.endRationedAllocator(previous);
	assert(equal(s, "x") && s[1] == '\0');

	// The first piece fits the first allocation; the second needs another.
	previous = fp.dynarray.beginRationedAllocator(1);
	assert(createFromConcatenation("abc", "a piece longer than the first allocation") is null);
	fp.dynarray.endRationedAllocator(previous);

	// Refused at the copy of `ab`, then at the reservation.
	char* ab = makeDynamic("ab");
	scope(exit) free(ab);
	foreach (allowed; 0 .. 2) {
		previous = fp.dynarray.beginRationedAllocator(allowed);
		assert(replicate(ab, 3) is null);
		fp.dynarray.endRationedAllocator(previous);
		assert(equal(ab, "ab"));
	}

	char* dash = makeDynamic("a-b");
	scope(exit) free(dash);
	previous = fp.dynarray.beginRationedAllocator();
	assert(replaceFirst(dash, "-", "--", 0) == fp.pointer.allocationRefused);
	assert(replace(dash, "-", "--", 0) is null);
	// Refused at the copies taken of arguments that view `dash`.
	assert(replaceRange(dash, dash, 0, 0) is null);
	assert(replace(dash, slice(dash)[1 .. 2], "+", 0) is null);
	assert(replace(dash, "-", dash, 0) is null);
	fp.dynarray.endRationedAllocator(previous);
	assert(equal(dash, "a-b"));

	// Each first allocation succeeds and a later one is refused, leaving a partial result to free.
	previous = fp.dynarray.beginRationedAllocator(1);
	assert(codepoints("more than four codepoints") is null);
	fp.dynarray.endRationedAllocator(previous);
	uint[2] wide = [0x4E16, 0x754C];
	previous = fp.dynarray.beginRationedAllocator(1);
	assert(fromCodepoints(wide[]) is null);
	fp.dynarray.endRationedAllocator(previous);
}

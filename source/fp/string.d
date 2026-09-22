module fp.string;

import core.stdc.string : cStrlen = strlen, cMemcpy = memcpy, cMemcmp = memcmp, cMemmove = memmove;
import core.stdc.stdio : vsnprintf;
import core.stdc.stdarg : va_list, va_start, va_end;

import fp.pointer : allocFunction, valid, heapAllocated, stackAllocated, notFound, ptrLength = length, ptrFree = free;
import fp.dynarray : valid_dynarray, growToSize, grow, pushBack, reserve, deleteRange, daFree = free;



@nogc nothrow: // every declaration below is @nogc nothrow unless stated otherwise



inout(char)[] slice(inout char* str) @trusted {
	if (str is null) return null;
	if (valid(str)) return str[0 .. ptrLength(str)];
	return str[0 .. cStrlen(str)];
}
private inout(char)[] slice(inout(char)[] s) { return s; }

alias string_slice = slice;

size_t length(inout char* str) @trusted {
	return slice(str).length;
}
alias size = length;

void free(const char* str) @trusted {
	if (valid_dynarray(str)) daFree(str);
	else if (valid(str) && heapAllocated(str)) ptrFree(str);
	else allocFunction(cast(void*) str, 0);
}
void free(ref char* str) @trusted {
	if (valid_dynarray(str)) daFree(str);
	else if (valid(str) && heapAllocated(str)) ptrFree(str);
	else {
		allocFunction(cast(void*) str, 0);
		str = null;
	}
}

/// Returns a newly allocated copy of `view`, or null if it could not be allocated.
char* makeDynamicSlice(inout(char)[] view) @trusted {
	if (view.length == 0) return null;
	char* out_ = null;
	if (growToSize(out_, view.length) is null) return null;
	cMemcpy(out_, view.ptr, view.length);
	return out_;
}
char* makeDynamic(inout char* str) @trusted {
	return makeDynamicSlice(slice(str));
}

alias promoteLiteral = makeDynamic;
alias clone = makeDynamic;

int compareSlices(inout(char)[] a, inout(char)[] b) @trusted {
	if (a.length != b.length) return cast(int)(a.length - b.length);
	return cMemcmp(a.ptr, b.ptr, a.length);
}
int compare(inout char* a, inout char* b) @trusted {
	return compareSlices(slice(a), slice(b));
}

bool equal(inout char* a, inout char* b) @trusted {
	return compare(a, b) == 0;
}

char* concatenateSlice(ref char* a, inout(char)[] b) @trusted {
	assert(valid(a) || a is null);
	immutable sizeA = length(a);
	immutable sizeB = b.length;
	if (sizeA + sizeB == 0) return null;
	// `a` is left holding exactly what it did before if this fails, so a
	// caller that ignores the result still has a usable string.
	if (growToSize(a, sizeA + sizeB) is null) return null;
	cMemcpy(a + sizeA, b.ptr, sizeB);
	return a;
}
char* concatenate(ref char* a, inout char* b) @trusted {
	return concatenateSlice(a, slice(b));
}

char* concatenateMultipleSlices(Args...)(ref char* str, Args pieces) @trusted {
	static foreach (p; pieces)
		cast(void)concatenateSlice(str, p);
	return str;
}
char* concatenateMultiple(Args...)(ref char* str, Args pieces) @trusted {
	static foreach (p; pieces)
		cast(void)concatenateSlice(str, slice(p));
	return str;
}

/// Concatenates every piece into a newly heap-allocated fp string (empty
/// pieces are fine). The caller frees the result with `fp.string.free`.
char* createFromConcatenationSlices(Args...)(Args pieces) @trusted {
	char* out_ = null;
	return concatenateMultipleSlices(out_, pieces);
}
char* createFromConcatenation(Args...)(Args pieces) @trusted {
	char* out_ = null;
	return concatenateMultiple(out_, pieces);
}

char* append(ref char* str, char c) @trusted {
	assert(valid(str));
	immutable size = ptrLength(str);
	pushBack(str, c);
	str[size + 1] = 0;
	return str;
}

// ASCII character classes.
bool isDigit(char c) { return c >= '0' && c <= '9'; }
bool isOctalDigit(char c) { return c >= '0' && c <= '7'; }
bool isHexDigit(char c) { return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
bool isAsciiAlpha(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }

unittest {
	assert(isDigit('0') && isDigit('9') && !isDigit('a') && !isDigit('/'));
	assert(isOctalDigit('7') && !isOctalDigit('8'));
	assert(isHexDigit('0') && isHexDigit('f') && isHexDigit('F') && !isHexDigit('g'));
	assert(isAsciiAlpha('a') && isAsciiAlpha('Z') && !isAsciiAlpha('0'));
}

/// Why a codepoint is not encodable as UTF-8.
enum Utf8Error : ubyte {
	none,
	outOfRange,  /// above U+10FFFF
	surrogate,   /// U+D800-U+DFFF: UTF-16 machinery, never valid in UTF-8
}

/// Encodes `codepoint` into `out_` (which must have room for four bytes),
/// returning the number of bytes written, or 0 with `err` set.
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

size_t encodeUtf8(uint codepoint, char* out_) @trusted {
	Utf8Error ignored;
	return encodeUtf8(codepoint, out_, ignored);
}

/// Decodes the codepoint starting at `s[i]`, advancing `i` past it.
///
/// The continuation bytes a lead byte promises are checked against the end of
/// `s` before they are read, so this is safe to run over arbitrary bytes - a
/// string literal can hold a truncated sequence (`"\xE2"` is a lead byte with
/// nothing behind it). A truncated or otherwise malformed sequence clears
/// `valid`, decodes as the lead byte itself and consumes one byte, so a caller
/// that ignores `valid` still makes progress and never reads past the slice.
uint decodeUtf8(const(char)[] s, ref size_t i, out bool valid) @trusted {
	valid = true;
	immutable c = cast(ubyte) s[i];

	if (c < 0x80) {
		return cast(uint) s[i++];
	} else if ((c >> 5) == 0x6 && i + 1 < s.length) {
		immutable cp = ((c & 0x1F) << 6) | (cast(ubyte) s[i + 1] & 0x3F);
		i += 2;
		return cp;
	} else if ((c >> 4) == 0xE && i + 2 < s.length) {
		immutable cp = ((c & 0x0F) << 12)
			| ((cast(ubyte) s[i + 1] & 0x3F) << 6)
			| (cast(ubyte) s[i + 2] & 0x3F);
		i += 3;
		return cp;
	} else if ((c >> 3) == 0x1E && i + 3 < s.length) {
		immutable cp = ((c & 0x07) << 18)
			| ((cast(ubyte) s[i + 1] & 0x3F) << 12)
			| ((cast(ubyte) s[i + 2] & 0x3F) << 6)
			| (cast(ubyte) s[i + 3] & 0x3F);
		i += 4;
		return cp;
	}
	valid = false;
	++i;
	return c;
}

uint decodeUtf8(const(char)[] s, ref size_t i) @trusted {
	bool ignored;
	return decodeUtf8(s, i, ignored);
}

// Returns a newly allocated string that must be freed by the caller. Returns null on error.
uint* codepointsSlice(inout(char)[] view) @trusted {
	uint* out_ = null;
	size_t i = 0;

	while (i < view.length) {
		bool valid;
		immutable codepoint = decodeUtf8(cast(const(char)[]) view, i, valid);
		if (!valid) {
			if (out_ !is null) daFree(out_);
			return null;
		}
		pushBack(out_, codepoint);
	}
	return out_;
}
uint* codepoints(inout char* str) @trusted {
	return codepointsSlice(slice(str));
}

// Returns a newly allocated string that must be freed by the caller. Returns null on error.
char* fromCodepointsSlice(inout(uint)[] codepoints) @trusted {
	char* out_ = null;
	if (reserve(out_, codepoints.length) is null) return null;

	foreach (cp; codepoints) {
		char[4] temp;
		immutable len = encodeUtf8(cp, temp.ptr);
		if (len == 0) {
			if (out_ !is null) daFree(out_);
			return null;
		}
		foreach (j; 0 .. len)
			cast(void)append(out_, temp[j]);
	}
	return out_;
}
char* fromCodepoints(inout uint* codepoints) @trusted {
	return fromCodepointsSlice(codepoints[0 .. ptrLength(codepoints)]);
}

char* replicate(ref char* str, size_t times) @trusted {
	if (times == 0) {
		free(str);
		return str;
	}

	assert(valid(str));
	char* one = makeDynamic(str);
	scope(exit) free(one);
	foreach (i; 0 .. times - 1)
		cast(void)concatenate(str, one);
	return str;
}

size_t findSlices(inout(char)[] haystack, inout(char)[] needle, size_t start) @trusted {
	assert(start <= haystack.length);
	if (needle.length > haystack.length - start) return notFound;

	immutable bound = haystack.length - needle.length;
	outer: for (size_t i = start; i <= bound; ++i) {
		foreach (j; 0 .. needle.length)
			if (haystack[i + j] != needle[j])
				continue outer;
		return i;
	}
	return notFound;
}
size_t find(inout char* haystack, inout char* needle, size_t start) @trusted {
	return findSlices(slice(haystack), slice(needle), start);
}

bool contains(inout char* haystack, inout char* needle, size_t start) @trusted {
	return find(haystack, needle, start) != notFound;
}

/// Splits `str` on every occurrence of `delimiter`, returning a newly
/// allocated fp dynarray of non-owning slices into `str`. The slices alias
/// `str`, so it must outlive them; the caller frees the returned dynarray
/// itself with `fp.dynarray.free`.
const(char)[]* splitSlices(const(char)[] str, const(char)[] delimiter) @trusted {
	assert(delimiter.length > 0);
	const(char)[]* result = null;

	size_t start = 0;
	while (true) {
		immutable pos = findSlices(str, delimiter, start);
		if (pos == notFound) {
			pushBack(result, str[start .. $]);
			break;
		}
		pushBack(result, str[start .. pos]);
		start = pos + delimiter.length;
	}

	return result;
}
const(char)[]* split(inout char* str, inout char* delimiter) @trusted {
	return splitSlices(slice(str), slice(delimiter));
}

bool startsWithSlices(inout(char)[] haystack, inout(char)[] needle, size_t start) @trusted {
	if (needle.length > haystack.length - start) return false;
	return haystack[start .. start + needle.length] == needle;
}
bool startsWith(inout char* haystack, inout char* needle, size_t start) @trusted {
	return startsWithSlices(slice(haystack), slice(needle), start);
}

bool endsWithSlices(inout(char)[] haystack, inout(char)[] needle, ptrdiff_t end) @trusted {
	if (end <= 0) end += cast(ptrdiff_t) haystack.length;
	if (cast(ptrdiff_t) needle.length > end) return false;
	immutable start = cast(size_t)(end - cast(ptrdiff_t) needle.length);
	return haystack[start .. cast(size_t) end] == needle;
}
bool endsWith(inout char* haystack, inout char* needle, ptrdiff_t end) @trusted {
	return endsWithSlices(slice(haystack), slice(needle), end);
}

char* replaceRangeSlice(ref char* in_, inout(char)[] with_, size_t start, size_t rangeLen) @trusted {
	assert(valid(in_));
	immutable end = start + rangeLen;
	immutable inLen = length(in_);
	assert(end <= inLen);

	immutable withLen = with_.length;
	if (rangeLen > withLen) {
		immutable diff = rangeLen - withLen;
		cMemcpy(in_ + start, with_.ptr, withLen);
		deleteRange(in_, start + withLen, diff, false);
	} else if (withLen > rangeLen) {
		immutable diff = withLen - rangeLen;
		if (grow(in_, diff) is null) return null;
		cMemmove(in_ + end + diff, in_ + end, inLen - end);
		cMemcpy(in_ + start, with_.ptr, withLen);
	} else {
		cMemcpy(in_ + start, with_.ptr, withLen);
	}
	in_[length(in_)] = 0;
	return in_;
}

char* replaceRange(ref char* in_, inout char* with_, size_t start, size_t rangeLen) @trusted {
	return replaceRangeSlice(in_, slice(with_), start, rangeLen);
}

size_t replaceFirstSlices(ref char* in_, inout(char)[] find_, inout(char)[] replace_, size_t start) @trusted {
	start = findSlices(slice(in_), find_, start);
	if (start == notFound) return start;
	cast(void)replaceRangeSlice(in_, replace_, start, find_.length);
	return start;
}

size_t replaceFirst(ref char* in_, inout char* find_, inout char* replace_, size_t start) @trusted {
	return replaceFirstSlices(in_, slice(find_), slice(replace_), start);
}

char* replaceSlices(ref char* in_, inout(char)[] find_, inout(char)[] replace_, size_t start) @trusted {
	while ((start = replaceFirstSlices(in_, find_, replace_, start)) != notFound)
		start += replace_.length;
	return in_;
}

char* replace(ref char* in_, inout char* find_, inout char* replace_, size_t start) @trusted {
	return replaceSlices(in_, slice(find_), slice(replace_), start);
}

// Returns a newly allocated string that must be freed by the caller. Returns null on error.
extern (C) char* format(inout char* fmt, ...) @trusted {
	va_list argsSize;
	va_start(argsSize, fmt);
	immutable size = vsnprintf(null, 0, fmt, argsSize);
	va_end(argsSize);

	char* out_ = null;
	if (growToSize(out_, size) is null) return null;

	va_list args;
	va_start(args, fmt);
	vsnprintf(out_, length(out_) + 1, fmt, args);
	va_end(args);
	return out_;
}

unittest {
	// The `inout(char)[]` overload of `slice` (identity passthrough for
	// inputs that are already slices, as opposed to the `char*` overload
	// above it).
	char[5] buf = "hello";
	assert(slice(buf[]) == "hello");
}

unittest {
	// free()'s `const char*` overload (as opposed to the `ref char*` one,
	// which lvalue arguments prefer): a null argument exercises all three
	// of its branches (not a dynarray, not valid/heap-allocated, falls
	// through to the raw-allocator branch) safely, since freeing null is a
	// no-op at every level.
	free(null);

	// The `ref char*` overload's heap-allocated (but non-dynarray) branch.
	import fp.pointer : ptrMalloc = malloc;
	char* heapStr = ptrMalloc!char(4);
	free(heapStr);

	// The `ref char*` overload's final fallback branch, which also nulls
	// the argument out.
	char* nullStr = null;
	free(nullStr);
	assert(nullStr is null);
}

unittest {
	char* str = promoteLiteral("Hello World");
	scope(exit) free(str);

	assert(valid(str));
	assert(valid_dynarray(str));
	assert(!stackAllocated(str));
	assert(heapAllocated(str));
	assert(length(str) == 11);
	assert(compare(str, str) == 0);
	assert(str[length(str)] == 0); // fp strings are null terminated!

	char* concat = makeDynamic(str);
	scope(exit) free(concat);
	cast(void)concatenate(concat, "!");
	assert(compare(str, concat) < 0);
	assert(compare(concat, str) > 0);
	assert(compare(concat, "Hello World!") == 0);
	cast(void)concatenate(concat, " bob");
	assert(compare(concat, "Hello World! bob") == 0);
	assert(contains(concat, "World!", 0));
	assert(find(concat, "World!", 0) == 6);
	assert(find(concat, "zzz", 0) == notFound);
	assert(!contains(concat, "zzz", 0));

	char* appended = makeDynamic(str);
	scope(exit) free(appended);
	cast(void)append(appended, '!');
	assert(compare(appended, "Hello World!") == 0);

	char* fmt = format("%s %s%c\n", "Hello".ptr, "World".ptr, '!');
	scope(exit) free(fmt);
	assert(compare(fmt, "Hello World!\n") == 0);

	char* repl = makeDynamicSlice("Hello World");
	scope(exit) free(repl);
	cast(void)replicate(repl, 5);
	assert(compare(repl, "Hello WorldHello WorldHello WorldHello WorldHello World") == 0);

	char* zeroRepl = null;
	cast(void)replicate(zeroRepl, 0);
	assert(zeroRepl is null);

	char* replaced = makeDynamic(repl);
	scope(exit) free(replaced);
	cast(void)replace(replaced, "World", "Bob", 0);
	assert(compare(replaced, "Hello BobHello BobHello BobHello BobHello Bob") == 0);
	assert(startsWith(replaced, "Hello", 0));
	assert(endsWith(replaced, "Bob", 0));
	cast(void)replace(replaced, "Bob", "World!", 0);
	assert(compare(replaced, "Hello World!Hello World!Hello World!Hello World!Hello World!") == 0);
	assert(startsWith(replaced, "Hello", 0));
	assert(endsWith(replaced, "World!", 0));
	assert(!endsWith(replaced, "World", 0));
	// Equal-length find/replace: the third (in-place, no grow/shrink) branch
	// of replaceRangeSlice.
	cast(void)replace(replaced, "World!", "Earth!", 0);
	assert(compare(replaced, "Hello Earth!Hello Earth!Hello Earth!Hello Earth!Hello Earth!") == 0);

	// The char*-based `replaceRange`/`replaceFirst` wrappers: every prior
	// call above went through their `*Slices` counterparts directly.
	char* rr = makeDynamicSlice("Hello World");
	scope(exit) free(rr);
	cast(void)replaceRange(rr, "Bob", 6, 5);
	assert(compare(rr, "Hello Bob") == 0);

	char* rf = makeDynamicSlice("Hello World World");
	scope(exit) free(rf);
	size_t firstPos = replaceFirst(rf, "World", "Bob", 0);
	assert(firstPos == 6);
	assert(compare(rf, "Hello Bob World") == 0);
}

unittest {
	import fp.dynarray : daLength = length;

	uint* cp = codepoints("Hello, 世界");
	scope(exit) daFree(cp);
	uint[9] expected = ['H', 'e', 'l', 'l', 'o', ',', ' ', 0x4E16, 0x754C];
	assert(daLength(cp) == expected.length);
	foreach (i, c; expected)
		assert(cp[i] == c);

	char* utf8 = fromCodepoints(cp);
	scope(exit) free(utf8);
	assert(equal(utf8, "Hello, 世界"));
}

unittest {
	// 2-byte and 4-byte UTF-8 encode/decode round trips: the test above only
	// exercises 1-byte (ASCII) and 3-byte (CJK) codepoints.
	import fp.dynarray : daLength = length;

	uint* cp = codepoints("café \U0001F600");
	scope(exit) daFree(cp);
	uint[6] expected = ['c', 'a', 'f', 0xE9, ' ', 0x1F600];
	assert(daLength(cp) == expected.length);
	foreach (i, c; expected)
		assert(cp[i] == c);

	char* utf8 = fromCodepoints(cp);
	scope(exit) free(utf8);
	assert(equal(utf8, "café \U0001F600"));
}

unittest {
	// encodeUtf8 rejecting an out-of-range codepoint, and fromCodepointsSlice
	// propagating that failure.
	uint[1] outOfRange = [0x110000];
	assert(fromCodepointsSlice(outOfRange[]) is null);

	// codepointsSlice rejecting an invalid UTF-8 lead byte.
	ubyte[1] invalidByte = [0x80];
	assert(codepointsSlice(cast(char[]) invalidByte[]) is null);

	// A surrogate half is UTF-16 machinery, never encodable as UTF-8.
	uint[1] surrogate = [0xD800];
	assert(fromCodepointsSlice(surrogate[]) is null);

	char[4] buffer;
	Utf8Error err;
	assert(encodeUtf8(0x110000, buffer.ptr, err) == 0 && err == Utf8Error.outOfRange);
	assert(encodeUtf8(0xDC00, buffer.ptr, err) == 0 && err == Utf8Error.surrogate);
	assert(encodeUtf8(0x1F600, buffer.ptr, err) == 4 && err == Utf8Error.none);
}

unittest { // decodeUtf8 handles each sequence length, and truncation at each
	static immutable string[4] whole = ["A", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80"];
	static immutable uint[4] expected = [0x41, 0xE9, 0x20AC, 0x1F600];
	foreach (n, s; whole) {
		size_t i = 0;
		bool valid;
		assert(decodeUtf8(s, i, valid) == expected[n]);
		assert(valid && i == s.length);
	}

	// A lead byte with its continuation bytes cut off decodes as itself and
	// still advances, so the caller cannot loop forever or read past the end.
	foreach (s; whole[1 .. $]) {
		auto truncated = s[0 .. $ - 1];
		size_t i = 0;
		bool valid;
		immutable cp = decodeUtf8(truncated, i, valid);
		assert(i > 0);
		assert(cp == cast(ubyte) truncated[0] || i == truncated.length);
	}

	// The truncated three- and four-byte sequences are what used to read past
	// the end of the slice inside codepointsSlice.
	assert(codepointsSlice("\xe2\x82") is null);
	assert(codepointsSlice("\xf0\x9f\x98") is null);
}

unittest {
	import fp.dynarray : daLength = length;

	const(char)[]* parts = splitSlices("a,bb,,ccc", ",");
	scope (exit) daFree(parts);

	assert(daLength(parts) == 4);
	assert(parts[0] == "a");
	assert(parts[1] == "bb");
	assert(parts[2] == "");
	assert(parts[3] == "ccc");
}

unittest {
	// Multi-character delimiter, and the char*-based `split` wrapper.
	import fp.dynarray : daLength = length;

	char* str = promoteLiteral("a::bb::ccc");
	scope (exit) free(str);
	char* delim = promoteLiteral("::");
	scope (exit) free(delim);

	const(char)[]* parts = split(str, delim);
	scope (exit) daFree(parts);

	assert(daLength(parts) == 3);
	assert(parts[0] == "a");
	assert(parts[1] == "bb");
	assert(parts[2] == "ccc");
}

unittest {
	import fp.dynarray : daLength = length;

	const(char)[]* parts = splitSlices("no-delimiter-here", ",");
	scope (exit) daFree(parts);

	assert(daLength(parts) == 1);
	assert(parts[0] == "no-delimiter-here");
}

unittest {
	char* result = createFromConcatenationSlices("Hello, ", "World", "!");
	scope (exit) free(result);
	assert(equal(result, "Hello, World!"));

	char* world = promoteLiteral("World");
	scope (exit) free(world);
	char* mixed = createFromConcatenation("Hello, ".ptr, world, "!".ptr);
	scope (exit) free(mixed);
	assert(equal(mixed, "Hello, World!"));
}

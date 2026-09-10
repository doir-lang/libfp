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

private char* makeDynamicSlice(inout(char)[] view) @trusted {
	if (view.length == 0) return null;
	char* out_ = null;
	growToSize(out_, view.length);
	cMemcpy(out_, view.ptr, view.length);
	return out_;
}
char* makeDynamic(inout char* str) @trusted {
	return makeDynamicSlice(slice(str));
}

alias promoteLiteral = makeDynamic;
alias clone = makeDynamic;

private int compareSlices(inout(char)[] a, inout(char)[] b) @trusted {
	if (a.length != b.length) return cast(int)(a.length - b.length);
	return cMemcmp(a.ptr, b.ptr, a.length);
}
int compare(inout char* a, inout char* b) @trusted {
	return compareSlices(slice(a), slice(b));
}

bool equal(inout char* a, inout char* b) @trusted {
	return compare(a, b) == 0;
}

private char* concatenateSlice(ref char* a, inout(char)[] b) @trusted {
	assert(valid(a) || a is null);
	immutable sizeA = length(a);
	immutable sizeB = b.length;
	if (sizeA + sizeB == 0) return null;
	growToSize(a, sizeA + sizeB);
	cMemcpy(a + sizeA, b.ptr, sizeB);
	return a;
}
char* concatenate(ref char* a, inout char* b) @trusted {
	return concatenateSlice(a, slice(b));
}

char* append(ref char* str, char c) @trusted {
	assert(valid(str));
	immutable size = ptrLength(str);
	pushBack(str, c);
	str[size + 1] = 0;
	return str;
}

private size_t encodeUtf8(uint codepoint, char* out_) @trusted {
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
	} else if (codepoint <= 0x10FFFF) {
		out_[0] = cast(char)(0xF0 | (codepoint >> 18));
		out_[1] = cast(char)(0x80 | ((codepoint >> 12) & 0x3F));
		out_[2] = cast(char)(0x80 | ((codepoint >> 6) & 0x3F));
		out_[3] = cast(char)(0x80 | (codepoint & 0x3F));
		return 4;
	}
	return 0;
}

// Returns a newly allocated string that must be freed by the caller. Returns null on error.
uint* codepointsSlice(inout(char)[] view) @trusted {
	const(ubyte)* s = cast(const(ubyte)*) view.ptr;
	uint* out_ = null;
	size_t i = 0;

	while (i < view.length) {
		uint codepoint = 0;
		if (s[i] < 0x80) {
			codepoint = s[i];
			i += 1;
		} else if ((s[i] >> 5) == 0x6) {
			codepoint = (s[i] & 0x1F) << 6;
			codepoint |= (s[i + 1] & 0x3F);
			i += 2;
		} else if ((s[i] >> 4) == 0xE) {
			codepoint = (s[i] & 0x0F) << 12;
			codepoint |= (s[i + 1] & 0x3F) << 6;
			codepoint |= (s[i + 2] & 0x3F);
			i += 3;
		} else if ((s[i] >> 3) == 0x1E) {
			codepoint = (s[i] & 0x07) << 18;
			codepoint |= (s[i + 1] & 0x3F) << 12;
			codepoint |= (s[i + 2] & 0x3F) << 6;
			codepoint |= (s[i + 3] & 0x3F);
			i += 4;
		} else {
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
	reserve(out_, codepoints.length);

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
		str = null;
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
		grow(in_, diff);
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
	growToSize(out_, size);

	va_list args;
	va_start(args, fmt);
	vsnprintf(out_, length(out_) + 1, fmt, args);
	va_end(args);
	return out_;
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

/// ASCII character classes and case: digits, letters, whitespace, and comparison that folds ASCII letters to one case.
/// A byte outside ASCII belongs to no class and is never changed, so all of these are safe on UTF-8 text.
///
/// Examples:
/// ---
/// assert(isDigit('7') && isLetter('q') && isWhitespace('\t'));
/// assert(toUpper('a') == 'A' && toUpper('1') == '1');
/// assert(equalIgnoringCase("Content-Length", "content-length"));
/// ---
module fp.string.ascii;

static import fp.pointer;
static import fp.string;


@nogc nothrow:


// === classes ===================================================================

/// The ASCII whitespace characters `isWhitespace` accepts, as the default set `fp.string.trim` and its kin remove.
enum string whitespace = " \t\n\v\f\r";

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

/// Whether `c` is an ASCII uppercase letter.
///
/// Examples:
/// ---
/// assert(isUpper('Q') && !isUpper('q') && !isUpper('1'));
/// ---
bool isUpper(char c) { return c >= 'A' && c <= 'Z'; }

/// Whether `c` is an ASCII lowercase letter.
///
/// Examples:
/// ---
/// assert(isLower('q') && !isLower('Q') && !isLower('1'));
/// ---
bool isLower(char c) { return c >= 'a' && c <= 'z'; }

/// Whether `c` is an ASCII letter, in either case.
///
/// Examples:
/// ---
/// assert(isLetter('q') && isLetter('Q') && !isLetter('1'));
/// ---
bool isLetter(char c) { return isUpper(c) || isLower(c); }

/// Whether `c` is an ASCII letter or decimal digit.
///
/// Examples:
/// ---
/// assert(isAlphanumeric('q') && isAlphanumeric('7') && !isAlphanumeric('_'));
/// ---
bool isAlphanumeric(char c) { return isLetter(c) || isDigit(c); }

/// Whether `c` is ASCII whitespace: a space, tab, line feed, vertical tab, form feed or carriage return.
///
/// Examples:
/// ---
/// assert(isWhitespace(' ') && isWhitespace('\r') && !isWhitespace('x') && !isWhitespace('\0'));
/// ---
bool isWhitespace(char c) { return c == ' ' || (c >= '\t' && c <= '\r'); }


unittest {
	assert(isDigit('0') && isDigit('9') && !isDigit('a') && !isDigit('/'));
	assert(isOctalDigit('0') && isOctalDigit('7') && !isOctalDigit('8'));
	assert(isHexDigit('0') && isHexDigit('f') && isHexDigit('F') && !isHexDigit('g') && !isHexDigit('G'));
	assert(isLetter('a') && isLetter('Z') && !isLetter('0') && !isLetter('@') && !isLetter('['));
	foreach (c; whitespace) assert(isWhitespace(c));
	foreach (i; 0 .. 256) {
		immutable c = cast(char) i;
		if (i >= 0x80) assert(!isDigit(c) && !isHexDigit(c) && !isLetter(c) && !isWhitespace(c) && !isAlphanumeric(c));
		assert(isAlphanumeric(c) == (isLetter(c) || isDigit(c)));
	}
}


// === case ======================================================================

/// `c` with an ASCII uppercase letter lowered; any other byte as it is.
///
/// Examples:
/// ---
/// assert(toLower('Q') == 'q' && toLower('q') == 'q' && toLower('[') == '[');
/// ---
char toLower(char c) { return isUpper(c) ? cast(char)(c | 0x20) : c; }

/// `c` with an ASCII lowercase letter raised; any other byte as it is.
///
/// Examples:
/// ---
/// assert(toUpper('q') == 'Q' && toUpper('Q') == 'Q' && toUpper('{') == '{');
/// ---
char toUpper(char c) { return isLower(c) ? cast(char)(c & ~0x20) : c; }

/// Lowers every ASCII uppercase letter of `text` in place.
/// It cannot fail.
///
/// Examples:
/// ---
/// char[5] text = "MiXeD";
/// lowerInPlace(text[]);
/// assert(text == "mixed");
/// ---
void lowerInPlace(char[] text) {
	foreach (ref c; text) c = toLower(c);
	foreach (c; text) assert(!isUpper(c), "fp.string.ascii.lowerInPlace: left an upper-case letter");
}

/// Raises every ASCII lowercase letter of `text` in place.
/// It cannot fail.
///
/// Examples:
/// ---
/// char[5] text = "MiXeD";
/// upperInPlace(text[]);
/// assert(text == "MIXED");
/// ---
void upperInPlace(char[] text) {
	foreach (ref c; text) c = toUpper(c);
	foreach (c; text) assert(!isLower(c), "fp.string.ascii.upperInPlace: left a lower-case letter");
}


// === comparison ================================================================

// Whether `a` and `b`, of equal length, match once ASCII letters are folded to one case.
private bool sameIgnoringCase(const(char)[] a, const(char)[] b) {
	assert(a.length == b.length, "fp.string.ascii: comparing texts of different lengths");
	assert((a.ptr !is null || a.length == 0) && (b.ptr !is null || b.length == 0), "fp.string.ascii: text with a length but no bytes");
	foreach (i; 0 .. a.length)
		if (toLower(a[i]) != toLower(b[i])) return false;
	return true;
}

/// Whether `a` and `b` hold the same characters once ASCII letters are folded to one case; other bytes must match exactly.
///
/// Examples:
/// ---
/// assert(equalIgnoringCase("Content-Length", "content-length"));
/// assert(!equalIgnoringCase("abc", "abd") && !equalIgnoringCase("a", "ab"));
/// ---
bool equalIgnoringCase(A, B)(A a, B b) if (fp.string.isStringLike!A && fp.string.isStringLike!B) {
	const(char)[] x = fp.string.slice(a), y = fp.string.slice(b);
	return x.length == y.length && sameIgnoringCase(x, y);
}

/// Whether `needle` occurs in `haystack` starting exactly at `start` (0 by default), ASCII letters folded to one case; false for a `start` past the end.
///
/// Examples:
/// ---
/// assert(startsWithIgnoringCase("Content-Type: text", "content-type"));
/// assert(startsWithIgnoringCase("x-API-Key", "api", 2) && !startsWithIgnoringCase("ab", "abc"));
/// ---
bool startsWithIgnoringCase(H, N)(H haystack, N needle, size_t start = 0) if (fp.string.isStringLike!H && fp.string.isStringLike!N) {
	const(char)[] text = fp.string.slice(haystack), pattern = fp.string.slice(needle);
	if (start > text.length || pattern.length > text.length - start) return false;
	return sameIgnoringCase(text[start .. start + pattern.length], pattern);
}

/// The index of the first `needle` in `haystack` at or after `start` (0 by default), ASCII letters folded to one case, or `fp.pointer.notFound`, including when `start` is past the end.
///
/// Examples:
/// ---
/// static import fp.pointer;
/// assert(findIgnoringCase("Transfer-Encoding: Chunked", "CHUNKED") == 19);
/// assert(findIgnoringCase("abc", "x") == fp.pointer.notFound);
/// ---
size_t findIgnoringCase(H, N)(H haystack, N needle, size_t start = 0) if (fp.string.isStringLike!H && fp.string.isStringLike!N) {
	const(char)[] text = fp.string.slice(haystack), pattern = fp.string.slice(needle);
	if (start > text.length || pattern.length > text.length - start) return fp.pointer.notFound;
	assert(text.length < fp.pointer.allocationRefused, "fp.string.ascii.findIgnoringCase: an offset could be read as a sentinel");
	foreach (at; start .. text.length - pattern.length + 1)
		if (sameIgnoringCase(text[at .. at + pattern.length], pattern)) return at;
	return fp.pointer.notFound;
}


unittest { // case folding leaves non-letters alone; comparisons at the ends and past them
	foreach (i; 0 .. 256) {
		immutable c = cast(char) i;
		if (!isLetter(c)) assert(toLower(c) == c && toUpper(c) == c);
		else assert(toLower(c) == (c | 0x20) && toUpper(c) == (c & ~0x20));
	}
	char[6] mixed = "a\xC3\x84Z[@";
	lowerInPlace(mixed[]);
	assert(mixed == "a\xC3\x84z[@");
	upperInPlace(mixed[]);
	assert(mixed == "A\xC3\x84Z[@");

	assert(equalIgnoringCase("", "") && equalIgnoringCase("ÄbC", "Äbc") && !equalIgnoringCase("[", "{") && !equalIgnoringCase("@", "`"));
	assert(equalIgnoringCase(null, "") && equalIgnoringCase("ABC".ptr, "abc"));
	assert(startsWithIgnoringCase("abc", "", 3) && !startsWithIgnoringCase("abc", "", 4) && !startsWithIgnoringCase("abc", "", size_t.max));
	assert(findIgnoringCase("aBcAbC", "abc", 1) == 3 && findIgnoringCase("abc", "", 3) == 3);
	assert(findIgnoringCase("abc", "", 4) == fp.pointer.notFound && findIgnoringCase("ab", "abc") == fp.pointer.notFound);
	assert(findIgnoringCase("abcab", "ABD") == fp.pointer.notFound);
}

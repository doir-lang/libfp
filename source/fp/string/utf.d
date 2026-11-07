/// UTF-8 and UTF-16: encoding and decoding codepoints, validating and counting UTF-8 text, converting it to and from UTF-16 code units or codepoint arrays, and looking codepoints up in Unicode property tables.
///
/// Decoding is safe on arbitrary bytes: an ill-formed sequence decodes as its lead byte and consumes one byte, so a scan that ignores validity still advances.
///
/// Examples:
/// ---
/// static import fp.string;
/// char* s = null;
/// scope(exit) fp.string.free(s);
/// assert(append(s, 0x20AC) == EncodeError.none);
/// size_t at = 0;
/// assert(decode(fp.string.slice(s), at) == 0x20AC && at == 3);
/// assert(firstInvalid(s) == fp.pointer.notFound && utf16Length(s) == 1);
/// ---
module fp.string.utf;

static import std.typecons;

static import fp.algorithms;
static import fp.dynarray;
static import fp.pointer;
static import fp.string;
version(unittest) static import fp.testing;


@nogc nothrow:


// === encoding ==================================================================

/// Why a codepoint could not be encoded as UTF-8, or appended once encoded.
enum EncodeError : ubyte {
	none, /// It was encoded (and appended).
	outOfRange, /// Above U+10FFFF.
	surrogate, /// U+D800-U+DFFF: UTF-16 machinery, never valid in UTF-8.
	allocationRefused, /// Encodable, but the string could not grow to hold it.
}

/// Encodes `codepoint` into the start of `out_`. Returns the number of bytes written, or 0 with `error` saying why.
///
/// Examples:
/// ---
/// char[4] buffer;
/// EncodeError error;
/// assert(encode(0x20AC, buffer, error) == 3);
/// assert(buffer[0 .. 3] == "€");
/// assert(encode(0xD800, buffer, error) == 0 && error == EncodeError.surrogate);
/// assert(encode('A', buffer) == 1);
/// ---
size_t encode(uint codepoint, ref char[4] out_, out EncodeError error) {
	if (codepoint > 0x10FFFF) {
		error = EncodeError.outOfRange;
		return 0;
	}
	if (codepoint >= 0xD800 && codepoint <= 0xDFFF) {
		error = EncodeError.surrogate;
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
size_t encode(uint codepoint, ref char[4] out_) {
	EncodeError ignored;
	return encode(codepoint, out_, ignored);
}

/// Encodes `codepoint` as UTF-8 and appends it to `text`, which may be null. Returns `EncodeError.none`, or why nothing was appended: `EncodeError.outOfRange` or `EncodeError.surrogate` for an unencodable value, `EncodeError.allocationRefused` when `text` cannot grow, which includes a pointer that is not an fp string.
///
/// Examples:
/// ---
/// static import fp.string;
/// char* s = null;
/// scope(exit) fp.string.free(s);
/// assert(append(s, 0xE9) == EncodeError.none);
/// assert(fp.string.equal(s, "é"));
/// assert(append(s, 0x110000) == EncodeError.outOfRange);
/// ---
EncodeError append(ref char* text, uint codepoint) {
	char[4] encoded;
	EncodeError error;
	immutable n = encode(codepoint, encoded, error);
	if (n > 0 && !fp.string.concatenate(text, encoded[0 .. n])) return EncodeError.allocationRefused;
	return error;
}


unittest {
	char[4] buffer;
	EncodeError error;
	assert(encode(0x110000, buffer, error) == 0 && error == EncodeError.outOfRange);
	assert(encode(0xDC00, buffer, error) == 0 && error == EncodeError.surrogate);
	assert(encode(0x1F600, buffer, error) == 4 && error == EncodeError.none && buffer == "\U0001F600");
	assert(encode(0x7FF, buffer) == 2 && encode(0x800, buffer) == 3 && encode(0xFFFF, buffer) == 3 && encode(0x10000, buffer) == 4);

	char* out_ = null;
	scope(exit) fp.string.free(out_);
	assert(append(out_, 'A') == EncodeError.none);
	assert(append(out_, 0x20AC) == EncodeError.none);
	assert(fp.string.slice(out_) == "A\xe2\x82\xac");
	assert(append(out_, 0x110000) == EncodeError.outOfRange);
	assert(append(out_, 0xD800) == EncodeError.surrogate);
	assert(fp.string.slice(out_) == "A\xe2\x82\xac");

	while (fp.string.length(out_) < fp.dynarray.capacity(out_)) assert(append(out_, 'x') == EncodeError.none);
	immutable filled = fp.string.length(out_);
	auto rationed = fp.testing.limitAllocations(0);
	assert(append(out_, 0xE9) == EncodeError.allocationRefused);
	fp.testing.restoreAllocator(rationed);
	assert(fp.string.length(out_) == filled);
	char* heap = fp.pointer.allocate!char(4);
	assert(append(heap, 'x') == EncodeError.allocationRefused);
	fp.string.free(heap);
}


// === decoding ==================================================================

/// Decodes the codepoint starting at `text[at]`, advancing `at` past it.
///
/// Safe on arbitrary bytes: continuation bytes are bounds-checked before they are read. A sequence that is truncated, lacks a continuation byte, is overlong, or encodes a surrogate or a value above U+10FFFF clears `valid`, decodes as its lead byte and consumes one byte, so a caller ignoring `valid` still makes progress.
///
/// Examples:
/// ---
/// size_t at = 0;
/// bool valid;
/// assert(decode("€x", at, valid) == 0x20AC && valid && at == 3);
/// assert(decode("€x", at) == 'x' && at == 4);
///
/// size_t other = 0;
/// assert(decode("\xE2", other, valid) == 0xE2 && !valid && other == 1);
/// ---
uint decode(const(char)[] text, ref size_t at, out bool valid) {
	immutable c = cast(ubyte) text[at];
	if (c < 0x80) {
		valid = true;
		return text[at++];
	}

	// `least` is the smallest codepoint needing `n` bytes; anything below it is an overlong encoding.
	size_t n = 0;
	uint codepoint = 0, least = 0;
	if ((c >> 5) == 0x6) { n = 2; codepoint = c & 0x1F; least = 0x80; }
	else if ((c >> 4) == 0xE) { n = 3; codepoint = c & 0x0F; least = 0x800; }
	else if ((c >> 3) == 0x1E) { n = 4; codepoint = c & 0x07; least = 0x10000; }

	valid = n != 0 && n <= text.length - at;
	foreach (k; 1 .. valid ? n : 1) {
		immutable b = cast(ubyte) text[at + k];
		if ((b & 0xC0) != 0x80) {
			valid = false;
			break;
		}
		codepoint = (codepoint << 6) | (b & 0x3F);
	}
	if (valid && (codepoint < least || codepoint > 0x10FFFF || (codepoint >= 0xD800 && codepoint <= 0xDFFF)))
		valid = false;

	if (!valid) {
		++at;
		return c;
	}
	at += n;
	return codepoint;
}
/// Ditto
uint decode(const(char)[] text, ref size_t at) {
	bool ignored;
	return decode(text, at, ignored);
}

/// The length in bytes of the UTF-8 sequence lead byte `lead` starts: 1 for ASCII, and for a continuation byte or a byte no sequence starts, so a scan stepping by it always advances. It does not check the bytes that follow.
///
/// Examples:
/// ---
/// assert(sequenceLength('a') == 1 && sequenceLength("é"[0]) == 2 && sequenceLength("€"[0]) == 3);
/// assert(sequenceLength("😀"[0]) == 4 && sequenceLength("é"[1]) == 1);
/// ---
size_t sequenceLength(char lead) {
	immutable c = cast(ubyte) lead;
	if (c >= 0xF8) return 1;
	if (c >= 0xF0) return 4;
	if (c >= 0xE0) return 3;
	if (c >= 0xC0) return 2;
	return 1;
}

/// The index of the first byte of `text` that does not start a well-formed UTF-8 sequence, as `decode` judges it, or `fp.pointer.notFound` if `text` is valid UTF-8.
///
/// Examples:
/// ---
/// static import fp.pointer;
/// assert(firstInvalid("héllo") == fp.pointer.notFound && firstInvalid(null) == fp.pointer.notFound);
/// assert(firstInvalid("ab\xFFc") == 2 && firstInvalid("\xE2\x82") == 0);
/// ---
size_t firstInvalid(S)(S text) if (fp.string.isStringLike!S) {
	const(char)[] view = fp.string.slice(text);
	size_t at = 0;
	while (at < view.length) {
		immutable start = at;
		bool valid;
		cast(void) decode(view, at, valid);
		if (!valid) return start;
	}
	return fp.pointer.notFound;
}

/// The number of codepoints in `text`, counting each byte `decode` finds ill-formed as one.
///
/// Examples:
/// ---
/// assert(codepointCount("aé😀") == 3 && codepointCount("\xFF\xFF") == 2 && codepointCount(null) == 0);
/// ---
size_t codepointCount(S)(S text) if (fp.string.isStringLike!S) {
	const(char)[] view = fp.string.slice(text);
	size_t count = 0;
	for (size_t at = 0; at < view.length; ++count) cast(void) decode(view, at);
	return count;
}

// The UTF-16 units byte `c` adds: 2 where it starts a four-byte sequence, 0 for a continuation byte, and 1 otherwise.
private size_t utf16Units(char c) {
	if ((c & 0xC0) == 0x80) return 0;
	return sequenceLength(c) == 4 ? 2 : 1;
}

/// The number of UTF-16 code units well-formed UTF-8 `text` takes, as editors that count in UTF-16 need: two for a codepoint above U+FFFF, which UTF-16 writes as a surrogate pair, one for any other. It counts by lead bytes, so it is defined on any text but meaningful only on valid UTF-8.
///
/// Examples:
/// ---
/// assert(utf16Length("aé😀") == 4 && utf16Length(null) == 0);
/// ---
size_t utf16Length(S)(S text) if (fp.string.isStringLike!S) {
	size_t units = 0;
	foreach (c; fp.string.slice(text)) units += utf16Units(c);
	return units;
}

/// Whether `codepoint` lies in one of the inclusive ranges of `table`, which must be sorted and must not overlap, as the Unicode property tables a lexer or renderer generates are. A binary search: O(log n).
///
/// Examples:
/// ---
/// static immutable uint[2][3] letters = [[0x41, 0x5A], [0x61, 0x7A], [0xC0, 0xD6]];
/// assert(inRanges(letters[], 'q') && inRanges(letters[], 0xC5));
/// assert(!inRanges(letters[], '1') && !inRanges(letters[], 0xD7));
/// ---
bool inRanges(const(uint[2])[] table, uint codepoint) {
	immutable at = fp.algorithms.lowerBound!((range, c) => range[1] < c)(table, codepoint);
	return at < table.length && table[at][0] <= codepoint;
}


unittest { // well-formed and ill-formed sequences, validation, counting and range lookup
	static immutable string[4] whole = ["A", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80"];
	static immutable uint[4] expected = [0x41, 0xE9, 0x20AC, 0x1F600];
	foreach (n, s; whole) {
		size_t at = 0;
		bool valid;
		assert(decode(s, at, valid) == expected[n]);
		assert(valid && at == s.length);
		assert(sequenceLength(s[0]) == s.length && utf16Length(s) == (expected[n] >= 0x10000 ? 2 : 1));
	}
	foreach (s; whole[1 .. $]) {
		auto truncated = s[0 .. $ - 1];
		size_t at = 0;
		bool valid;
		immutable codepoint = decode(truncated, at, valid);
		assert(!valid && at == 1 && codepoint == cast(ubyte) truncated[0]);
		assert(firstInvalid(truncated) == 0);
	}

	// A non-continuation byte, overlong forms, a surrogate and a value past U+10FFFF are all malformed.
	static immutable string[5] malformed = ["\xc3A", "\xc0\x80", "\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80"];
	foreach (s; malformed) {
		size_t at = 0;
		bool valid;
		assert(decode(s, at, valid) == cast(ubyte) s[0] && !valid && at == 1);
		assert(firstInvalid(s) == 0 && codepoints(s).isNull);
	}
	size_t at = 0;
	assert(decode("\xf4\x8f\xbf\xbf", at) == 0x10FFFF && at == 4);
	assert(sequenceLength('\x80') == 1 && sequenceLength('\xFF') == 1 && utf16Length("\xFF") == 1);
	assert(firstInvalid("ok\xc3A") == 2 && codepointCount("ok\xc3A") == 4);
	assert(firstInvalid("héllo") == fp.pointer.notFound);

	static immutable uint[2][1] single = [[5, 5]];
	assert(inRanges(single[], 5) && !inRanges(single[], 4) && !inRanges(single[], 6));
	assert(!inRanges((const(uint[2])[]).init, 0));
	static immutable uint[2][3] several = [[1, 3], [10, 10], [20, 30]];
	foreach (codepoint; 0 .. 40)
		assert(inRanges(several[], codepoint) == ((codepoint >= 1 && codepoint <= 3) || codepoint == 10 || (codepoint >= 20 && codepoint <= 30)));
}


// === conversion ================================================================

/// Decodes UTF-8 into a new `fp.dynarray` of codepoints, which the caller frees with `fp.dynarray.free`; the dynarray is null when `text` is empty. Returns null, rather than a null dynarray, if `text` is not valid UTF-8 or an allocation was refused.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// uint* decoded = codepoints("hé").get;
/// scope(exit) fp.dynarray.free(decoded);
/// assert(fp.dynarray.length(decoded) == 2 && decoded[1] == 0xE9);
/// assert(codepoints("\xFF").isNull && codepoints("").get is null);
/// ---
std.typecons.Nullable!(uint*) codepoints(S)(S text) @trusted if (fp.string.isStringLike!S) {
	const(char)[] view = fp.string.slice(text);
	uint* out_ = null;
	size_t at = 0;
	while (at < view.length) {
		bool valid;
		immutable codepoint = decode(view, at, valid);
		if (!valid || !fp.dynarray.pushBack(out_, codepoint)) {
			fp.dynarray.free(out_);
			return typeof(return).init;
		}
	}
	return typeof(return)(out_);
}

/// Converts UTF-8 into a new `fp.dynarray` of UTF-16 code units, which the caller frees with `fp.dynarray.free`; the dynarray is null when `text` is empty. A 0 unit follows the last, outside the length, so the result is also a null-terminated wide string, as Windows' wide APIs take. Returns null, rather than a null dynarray, if `text` is not valid UTF-8 or an allocation was refused.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// wchar* units = toUtf16("é😀").get;
/// scope(exit) fp.dynarray.free(units);
/// assert(fp.dynarray.length(units) == 3 && units[0] == 0xE9 && units[1] == 0xD83D && units[2] == 0xDE00 && units[3] == 0);
/// assert(toUtf16("\xFF").isNull && toUtf16("").get is null);
/// ---
std.typecons.Nullable!(wchar*) toUtf16(S)(S text) @trusted if (fp.string.isStringLike!S) {
	const(char)[] view = fp.string.slice(text);
	if (view.length == 0) return typeof(return)(null);
	// One more unit than the text needs holds the terminator.
	wchar* out_ = null;
	if (fp.dynarray.reserve(out_, utf16Length(view) + 1) is null) return typeof(return).init;

	size_t at = 0;
	while (at < view.length) {
		bool valid;
		immutable codepoint = decode(view, at, valid);
		bool pushed;
		if (codepoint < 0x10000) pushed = fp.dynarray.pushBack(out_, cast(wchar) codepoint);
		else pushed = fp.dynarray.pushBack(out_, cast(wchar) (0xD800 + ((codepoint - 0x10000) >> 10))) && fp.dynarray.pushBack(out_, cast(wchar) (0xDC00 + (codepoint & 0x3FF)));
		if (!valid || !pushed) {
			fp.dynarray.free(out_);
			return typeof(return).init;
		}
	}
	// Valid text needs exactly the units counted, so the terminator's slot is still reserved.
	assert(fp.dynarray.capacity(out_) > fp.dynarray.length(out_));
	out_[fp.dynarray.length(out_)] = 0;
	return typeof(return)(out_);
}

/// Encodes `codepoints` as a new fp string, which is null when there are none. Returns null, rather than a null string, if one is not encodable or the string could not be allocated. `codepoints` is a `uint` slice, or a `uint*` fat pointer such as the dynarray `codepoints` returns; like `fp.string.isStringLike`, a static array must be passed as `array[]`.
///
/// Examples:
/// ---
/// static import fp.string;
/// uint[2] decoded = ['o', 0x4E16];
/// char* s = fromCodepoints(decoded[]).get;
/// scope(exit) fp.string.free(s);
/// assert(fp.string.equal(s, "o世"));
/// ---
std.typecons.Nullable!(char*) fromCodepoints(C)(C codepoints) @trusted if (!__traits(isStaticArray, C) && (is(C : const(uint)[]) || is(C : const(uint)*))) {
	static if (is(C : const(uint)[])) const(uint)[] view = codepoints;
	else const(uint)[] view = codepoints[0 .. fp.pointer.length(codepoints)];
	// An empty reservation would leave a string whose first byte, unwritten, is not its terminator.
	if (view.length == 0) return typeof(return)(null);

	char* out_ = null;
	if (fp.dynarray.reserve(out_, view.length) is null) return typeof(return).init;
	foreach (codepoint; view) {
		if (append(out_, codepoint) != EncodeError.none) {
			fp.dynarray.free(out_);
			return typeof(return).init;
		}
	}
	return typeof(return)(out_);
}

/// Converts UTF-16 code units into a new fp string, which is null when there are none. Returns null, rather than a null string, if they are not valid UTF-16, such as a lone surrogate, or the string could not be allocated. `units` is a `wchar` slice, or a `wchar*` fat pointer such as the dynarray `toUtf16` returns; like `fp.string.isStringLike`, a static array must be passed as `array[]`.
///
/// Examples:
/// ---
/// static import fp.string;
/// char* s = fromUtf16("é😀"w).get;
/// scope(exit) fp.string.free(s);
/// assert(fp.string.equal(s, "é😀"));
/// wchar[1] lone = [0xD800];
/// assert(fromUtf16(lone[]).isNull);
/// ---
std.typecons.Nullable!(char*) fromUtf16(U)(U units) @trusted if (!__traits(isStaticArray, U) && (is(U : const(wchar)[]) || is(U : const(wchar)*))) {
	static if (is(U : const(wchar)[])) const(wchar)[] view = units;
	else const(wchar)[] view = units[0 .. fp.pointer.length(units)];
	if (view.length == 0) return typeof(return)(null);

	char* out_ = null;
	if (fp.dynarray.reserve(out_, view.length) is null) return typeof(return).init;
	for (size_t i = 0; i < view.length; ++i) {
		uint codepoint = view[i];
		if (codepoint >= 0xD800 && codepoint < 0xDC00 && i + 1 < view.length && view[i + 1] >= 0xDC00 && view[i + 1] < 0xE000)
			codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (view[++i] - 0xDC00);
		// A surrogate left unpaired does not encode.
		if (append(out_, codepoint) != EncodeError.none) {
			fp.dynarray.free(out_);
			return typeof(return).init;
		}
	}
	return typeof(return)(out_);
}


unittest { // round trips; invalid input; refusals partway through
	uint* decoded = codepoints("Hello, 世界 café \U0001F600").get;
	scope(exit) fp.dynarray.free(decoded);
	uint[15] expected = ['H', 'e', 'l', 'l', 'o', ',', ' ', 0x4E16, 0x754C, ' ', 'c', 'a', 'f', 0xE9, ' '];
	assert(fp.dynarray.length(decoded) == expected.length + 1);
	foreach (i, c; expected) assert(decoded[i] == c);
	assert(decoded[expected.length] == 0x1F600);

	char* utf8 = fromCodepoints(decoded).get;
	scope(exit) fp.string.free(utf8);
	assert(fp.string.equal(utf8, "Hello, 世界 café \U0001F600"));

	wchar* units = toUtf16("Hello, 世界 café \U0001F600").get;
	scope(exit) fp.dynarray.free(units);
	assert(units[0 .. fp.dynarray.length(units)] == "Hello, 世界 café \U0001F600"w && units[fp.dynarray.length(units)] == 0);
	assert(toUtf16("\xe2\x82").isNull && toUtf16("a\xf0\x9f\x98").isNull && toUtf16("\xed\xa0\x80").isNull);
	char* roundTrip = fromUtf16(units).get;
	scope(exit) fp.string.free(roundTrip);
	assert(fp.string.equal(roundTrip, "Hello, 世界 café \U0001F600"));
	wchar[2] reversed = [0xDE00, 0xD83D];
	wchar[2] unpaired = ['a', 0xDC00];
	assert(fromUtf16(reversed[]).isNull && fromUtf16(unpaired[]).isNull && !fromUtf16("a￿"w[0 .. 1]).isNull);
	assert(fromUtf16((wchar[]).init).get is null && fromUtf16(cast(wchar*) null).get is null);

	assert(codepoints("\xe2\x82").isNull && codepoints("\xf0\x9f\x98").isNull);
	ubyte[1] invalidByte = [0x80];
	assert(codepoints(cast(char[]) invalidByte[]).isNull);
	uint[1] outOfRange = [0x110000];
	assert(fromCodepoints(outOfRange[]).isNull);
	uint[1] surrogate = [0xD800];
	assert(fromCodepoints(surrogate[]).isNull);
	assert(fromCodepoints((uint[]).init).get is null && fromCodepoints(cast(uint*) null).get is null);

	// Each first allocation succeeds and a later one is refused, leaving a partial result to free.
	auto previous = fp.testing.limitAllocations(1);
	assert(codepoints("more than four codepoints").isNull);
	fp.testing.restoreAllocator(previous);
	previous = fp.testing.limitAllocations(0);
	assert(toUtf16("x").isNull);
	fp.testing.restoreAllocator(previous);
	previous = fp.testing.limitAllocations(1);
	assert(fromUtf16("世界"w).isNull);
	fp.testing.restoreAllocator(previous);
	uint[2] wide = [0x4E16, 0x754C];
	previous = fp.testing.limitAllocations(1);
	assert(fromCodepoints(wide[]).isNull);
	fp.testing.restoreAllocator(previous);
}

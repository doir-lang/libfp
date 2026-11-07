/// Numbers as text: writing integers in decimal or hexadecimal into a stack buffer or onto an fp string, writing a `double` in the shortest form that reads back as itself, and parsing integers and floating-point numbers. Nothing here depends on the C locale.
///
/// Examples:
/// ---
/// static import fp.string;
/// char* s = null;
/// scope(exit) fp.string.free(s);
/// assert(appendSigned(s, -42) && appendHex(s, 255, 4));
/// assert(fp.string.equal(s, "-4200ff"));
/// assert(parseSigned("-42").get.value == -42 && parseUnsigned("ff", 16).get.value == 255);
/// ---
module fp.string.numbers;

static import core.checkedint;
static import core.stdc.stdio;
static import core.stdc.stdlib;
static import std.typecons;

static import fp.pointer;
static import fp.string;
static import fp.string.ascii;
version(unittest) {
	static import fp.dynarray;
	static import fp.testing;
}


@nogc nothrow:


// === formatting into a buffer ==================================================

/// The most characters `formatUnsigned` or `formatSigned` writes: twenty digits and a sign.
enum size_t maxDecimalLength = 21;

/// The most digits `formatHex` writes: sixteen, one for each four bits of a `ulong`.
enum size_t maxHexLength = ulong.sizeof * 2;

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

/// `value` written in lowercase hexadecimal, padded with zeros to at least `width` digits (at most `maxHexLength`), into the end of `buffer`, returned as the slice of `buffer` holding it. It cannot fail.
///
/// Examples:
/// ---
/// char[maxHexLength] buffer;
/// assert(formatHex(0xAB, buffer) == "ab" && formatHex(0xAB, buffer, 4) == "00ab" && formatHex(0, buffer) == "0");
/// ---
const(char)[] formatHex(ulong value, return ref char[maxHexLength] buffer, size_t width = 0) {
	static immutable char[16] digitsOf = "0123456789abcdef";
	assert(width <= maxHexLength, "fp.string.numbers.formatHex: width past maxHexLength");
	size_t at = buffer.length;
	do {
		buffer[--at] = digitsOf[value & 0xF];
		value >>= 4;
	} while (value != 0);
	while (buffer.length - at < width) buffer[--at] = '0';
	return buffer[at .. $];
}


unittest {
	char[maxDecimalLength] decimal;
	assert(formatUnsigned(10, decimal) == "10" && formatSigned(0, decimal) == "0" && formatSigned(long.max, decimal) == "9223372036854775807");
	char[maxHexLength] hex;
	assert(formatHex(ulong.max, hex) == "ffffffffffffffff" && formatHex(1, hex, maxHexLength) == "0000000000000001");
	assert(formatHex(0xDEADBEEF, hex, 2) == "deadbeef");
}


// === appending to an fp string =================================================

/// Appends `value` in decimal to `text`, which may be null. Returns false if `text` could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// static import fp.string;
/// char* s = null;
/// scope(exit) fp.string.free(s);
/// assert(appendUnsigned(s, 0) && appendUnsigned(s, 18446744073709551615UL));
/// assert(fp.string.equal(s, "018446744073709551615"));
/// ---
bool appendUnsigned(ref char* text, ulong value) {
	char[maxDecimalLength] buffer;
	return fp.string.concatenate(text, formatUnsigned(value, buffer));
}

/// Appends `value` in decimal, with a leading `-` when negative, to `text`, which may be null. Returns false if `text` could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// static import fp.string;
/// char* s = null;
/// scope(exit) fp.string.free(s);
/// assert(appendSigned(s, -9223372036854775807L - 1) && appendSigned(s, 7));
/// assert(fp.string.equal(s, "-92233720368547758087"));
/// ---
bool appendSigned(ref char* text, long value) {
	char[maxDecimalLength] buffer;
	return fp.string.concatenate(text, formatSigned(value, buffer));
}

/// Appends `value` in lowercase hexadecimal to `text`, which may be null, padded with zeros to at least `width` digits (at most `maxHexLength`). Returns false if `text` could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// static import fp.string;
/// char* s = null;
/// scope(exit) fp.string.free(s);
/// assert(appendHex(s, 0xAB, 4) && appendHex(s, 0));
/// assert(fp.string.equal(s, "00ab0"));
/// ---
bool appendHex(ref char* text, ulong value, size_t width = 0) {
	char[maxHexLength] buffer;
	return fp.string.concatenate(text, formatHex(value, buffer, width));
}

/// Appends `value` to `text`, which may be null, in the shortest decimal form that reads back (through `parseFloat`) as the same `double`: `0.1`, `1e+300`, `inf`, `-inf` or `nan`. Returns false if `text` could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// static import fp.string;
/// char* s = null;
/// scope(exit) fp.string.free(s);
/// assert(appendFloat(s, 0.1) && appendFloat(s, 1e300) && appendFloat(s, -double.infinity));
/// assert(fp.string.equal(s, "0.11e+300-inf"));
/// ---
bool appendFloat(ref char* text, double value) @trusted {
	char[32] buffer;
	int n = 0;
	// 17 significant digits always round-trip a double; fewer usually do, and read better.
	foreach (precision; 1 .. 18) {
		n = core.stdc.stdio.snprintf(buffer.ptr, buffer.length, "%.*g", precision, value);
		if (n <= 0 || n >= buffer.length) return false;
		if (value != value || core.stdc.stdlib.strtod(buffer.ptr, null) == value) break;
	}
	return fp.string.concatenate(text, buffer[0 .. n]);
}


unittest { // every double reads back as itself; a refused growth leaves the text alone
	char* s = null;
	scope(exit) fp.string.free(s);
	assert(appendSigned(s, 0) && appendSigned(s, -5) && appendHex(s, 0xDEADBEEF) && appendHex(s, 1, 16));
	assert(fp.string.equal(s, "0-5deadbeef0000000000000001"));

	foreach (value; [1.0 / 3, 2.0 / 3, 123456789.123456789, double.min_normal, double.max, -0.0, 0.30000000000000004]) {
		char* written = null;
		scope(exit) fp.string.free(written);
		assert(appendFloat(written, value));
		assert(parseFloat(fp.string.slice(written)).get.value == value);
	}

	char* full = fp.string.clone("x").get;
	scope(exit) fp.string.free(full);
	while (fp.string.length(full) < fp.dynarray.capacity(full)) assert(fp.string.concatenate(full, "x"));
	immutable before = fp.string.length(full);
	auto rationed = fp.testing.limitAllocations(0);
	assert(!appendUnsigned(full, 1) && !appendSigned(full, -1) && !appendHex(full, 1) && !appendFloat(full, 1.5));
	fp.testing.restoreAllocator(rationed);
	assert(fp.string.length(full) == before && full[before] == '\0');
}


// === parsing ===================================================================

/// The value of ASCII hexadecimal digit `c`, which must satisfy `fp.string.ascii.isHexDigit`: 0 to 15.
///
/// Examples:
/// ---
/// assert(hexDigitValue('7') == 7 && hexDigitValue('b') == 11 && hexDigitValue('F') == 15);
/// ---
uint hexDigitValue(char c) {
	assert(fp.string.ascii.isHexDigit(c), "fp.string.numbers: hexDigitValue of a character that is not a hexadecimal digit");
	if (fp.string.ascii.isDigit(c)) return c - '0';
	return (c | 0x20) - 'a' + 10;
}

/// A parsed unsigned integer, as `parseUnsigned` returns it.
struct Unsigned {
	ulong value; /// The number.
}

/// Reads all of `digits`, every one a digit of `base` (2 to 16, in either case; 10 by default), as an unsigned number. Returns null if `digits` is empty, holds a character that is not a digit of `base`, such as a sign, or its value does not fit in a `ulong`.
///
/// Examples:
/// ---
/// assert(parseUnsigned("ff", 16).get.value == 255);
/// assert(parseUnsigned("18446744073709551615").get.value == ulong.max);
/// assert(parseUnsigned("18446744073709551616").isNull);
/// assert(parseUnsigned("12", 2).isNull && parseUnsigned("").isNull);
/// ---
std.typecons.Nullable!Unsigned parseUnsigned(const(char)[] digits, uint base = 10) {
	assert(base >= 2 && base <= 16);
	if (digits.length == 0) return typeof(return).init;
	ulong value = 0;
	foreach (c; digits) {
		if (!fp.string.ascii.isHexDigit(c)) return typeof(return).init;
		immutable digit = hexDigitValue(c);
		if (digit >= base) return typeof(return).init;
		bool overflow = false;
		value = core.checkedint.addu(core.checkedint.mulu(value, base, overflow), digit, overflow);
		if (overflow) return typeof(return).init;
	}
	return typeof(return)(Unsigned(value));
}

/// A parsed signed integer, as `parseSigned` returns it.
struct Signed {
	long value; /// The number.
}

/// Reads all of `text` as a signed number: an optional `+` or `-`, then digits of `base` as `parseUnsigned` reads them. Returns null if `text` is not entirely such a number or its value does not fit in a `long`.
///
/// Examples:
/// ---
/// assert(parseSigned("-42").get.value == -42 && parseSigned("+7").get.value == 7 && parseSigned("-ff", 16).get.value == -255);
/// assert(parseSigned("-9223372036854775808").get.value == long.min);
/// assert(parseSigned("9223372036854775808").isNull && parseSigned("-").isNull && parseSigned("--1").isNull);
/// ---
std.typecons.Nullable!Signed parseSigned(const(char)[] text, uint base = 10) {
	immutable negative = text.length != 0 && text[0] == '-';
	const digits = text.length != 0 && (text[0] == '-' || text[0] == '+') ? text[1 .. $] : text;
	immutable magnitude = parseUnsigned(digits, base);
	if (magnitude.isNull) return typeof(return).init;
	immutable limit = negative ? 0UL - cast(ulong) long.min : cast(ulong) long.max;
	if (magnitude.get.value > limit) return typeof(return).init;
	return typeof(return)(Signed(negative ? cast(long)(0UL - magnitude.get.value) : cast(long) magnitude.get.value));
}

/// A parsed floating-point number, as `parseFloat` returns it.
struct Float {
	double value; /// The number.
}

/// Reads all of `text` as a decimal or hexadecimal floating-point number, as C's `strtod` does in the "C" locale. Returns null if `text` is not entirely a number or a copy of a long `text` could not be allocated; a value too large rounds to an infinity, and one too small toward zero, as IEEE round-to-nearest does. The spellings `inf` and `nan` read as themselves.
///
/// Examples:
/// ---
/// assert(parseFloat("1.5e3").get.value == 1500);
/// assert(parseFloat("1e999").get.value == double.infinity);
/// assert(parseFloat("1x").isNull && parseFloat("").isNull);
/// ---
std.typecons.Nullable!Float parseFloat(const(char)[] text) @trusted {
	// strtod skips leading white space, which is not part of a number.
	if (text.length == 0 || fp.string.ascii.isWhitespace(text[0])) return typeof(return).init;
	char[64] small;
	char* copy = null;
	scope(exit) fp.string.free(copy);
	char* terminated = small.ptr;
	if (text.length < small.length) {
		fp.pointer.copy(small[0 .. text.length], text);
		small[text.length] = 0;
	} else {
		auto cloned = fp.string.clone(text);
		if (cloned.isNull) return typeof(return).init;
		terminated = copy = cloned.get;
	}
	char* end;
	immutable value = core.stdc.stdlib.strtod(terminated, &end);
	if (end != terminated + text.length) return typeof(return).init;
	return typeof(return)(Float(value));
}


unittest { // every digit's value; bases, overflow and signs; floats at the edges
	foreach (c; "0123456789abcdefABCDEF") assert(hexDigitValue(c) == (fp.string.ascii.isDigit(c) ? c - '0' : (c | 0x20) - 'a' + 10));

	assert(parseUnsigned("777", 8).get.value == 511 && parseUnsigned("101", 2).get.value == 5);
	assert(parseUnsigned("FFFFFFFFFFFFFFFF", 16).get.value == ulong.max);
	assert(parseUnsigned("10000000000000000", 16).isNull); // one digit too many
	assert(parseUnsigned("8", 8).isNull && parseUnsigned("1_0").isNull && parseUnsigned("-1").isNull && parseUnsigned("+1").isNull);

	assert(parseSigned("0").get.value == 0 && parseSigned("-0").get.value == 0);
	assert(parseSigned("9223372036854775807").get.value == long.max && parseSigned("-9223372036854775809").isNull);
	assert(parseSigned("+").isNull && parseSigned("").isNull && parseSigned(" 1").isNull && parseSigned("1-").isNull);
	assert(parseSigned("-777", 8).get.value == -511);

	assert(parseFloat("0x1p-2").get.value == 0.25 && parseFloat("-0").get.value == 0);
	assert(parseFloat("inf").get.value == double.infinity);
	assert(parseFloat("-1e400").get.value == -double.infinity && parseFloat(" 1").isNull && parseFloat("1 ").isNull && parseFloat("\t1").isNull);
	assert(parseFloat("1e-400").get.value == 0); // underflow rounds toward zero
	char[100] longDigits = '1';
	assert(parseFloat(longDigits[]).get.value > 1e98); // past the stack buffer, so read from a heap copy
	auto rationed = fp.testing.limitAllocations(0);
	assert(parseFloat(longDigits[]).isNull);
	fp.testing.restoreAllocator(rationed);
}

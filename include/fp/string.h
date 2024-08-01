#ifndef __LIB_FAT_POINTER_STRING_H__
#define __LIB_FAT_POINTER_STRING_H__

#include "dynarray.h"
#include "fp/pointer.h"
#include <stdio.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

#define fp_string char*
typedef fp_view(char) fp_string_view;

#define fp_string_npos ((size_t)-1)

#ifndef __cplusplus
#define fp_string_view_literal(data, size) ((fp_string_view) {(data), (size)})
#else
#define fp_string_view_literal(data, size) (fp_string_view{(data), (size)})
#endif
#define fp_string_view_null fp_string_view_literal(NULL, 0)

#define fp_string_capacity fpda_capacity

void fp_string_free(fp_string str) FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	if(is_fpda(str)) fpda_free(str);
	else if(is_fp(str) && fp_is_heap_allocated(str)) fp_free(str);
	else FP_ALLOCATION_FUNCTION(str, 0);
}
#else
;
#endif

#define fp_string_free_and_null(str) (fp_string_free(str), str = NULL)

#if defined __cplusplus && (defined _MSC_VER || defined __APPLE__)
}
#endif // __cplusplus && _MSC_VER

FP_CONSTEXPR inline static fp_string_view fp_string_to_view(fp_string str) FP_NOEXCEPT {
	if(!str) return fp_string_view_null;
	if(is_fp(str)) return fp_view_make_full(char, (fp_string)str);
	return fp_string_view_literal((fp_string)str, strlen(str));
}
FP_CONSTEXPR inline static const fp_string_view fp_string_to_view_const(const fp_string str) FP_NOEXCEPT {
	if(!str) return fp_string_view_null;
	if(is_fp(str)) return fp_view_make_full(char, (fp_string)str);
	return fp_string_view_literal((fp_string)str, strlen(str));
}

#if defined __cplusplus && (defined _MSC_VER || defined __APPLE__)
extern "C" {
#endif // __cplusplus && _MSC_VER

#define fp_string_view_length(view) fp_view_length(view)
FP_CONSTEXPR inline static size_t fp_string_length(const fp_string str) FP_NOEXCEPT {
	auto view = fp_string_to_view_const(str);
	return fp_string_view_length(view);
}

inline static fp_string fp_string_view_make_dynamic(const fp_string_view view) FP_NOEXCEPT {
	fp_string out = NULL;
	size_t size = fp_view_size(view);
	if(size == 0) return nullptr;
	fpda_resize(out, size);
	memcpy(out, fp_view_data(char, view), size);
	return out;
}
inline static fp_string fp_string_make_dynamic(const fp_string str) FP_NOEXCEPT { return fp_string_view_make_dynamic(fp_string_to_view_const(str)); }

#define fp_string_promote_literal fp_string_make_dynamic
#define fp_string_clone fp_string_make_dynamic

FP_CONSTEXPR inline static int fp_string_view_compare(const fp_string_view a, const fp_string_view b) FP_NOEXCEPT {
	size_t sizeA = fp_view_length(a);
	size_t sizeB = fp_view_length(b);
	if(sizeA != sizeB) return sizeA - sizeB;
	return memcmp(fp_view_data(char, a), fp_view_data(char, b), sizeA);
}
FP_CONSTEXPR inline static int fp_string_compare(const fp_string a, const fp_string b) FP_NOEXCEPT { return fp_string_view_compare(fp_string_to_view_const(a), fp_string_to_view_const(b)); }

#define fp_string_view_equal(a, b) (fp_string_view_compare((a), (b)) == 0)
#define fp_string_equal(a, b) (fp_string_compare((a), (b)) == 0)

inline static fp_string __fp_string_view_concatenate_inplace(fp_string* a, const fp_string_view b) FP_NOEXCEPT {
	assert(is_fpda(*a) || !*a);
	size_t sizeA = fp_string_length(*a);
	size_t sizeB = fp_view_length(b);
	if(sizeA + sizeB == 0) return nullptr;
	fpda_resize(*a, sizeA + sizeB);

	memcpy(*a + sizeA, fp_view_data(char, b), sizeB);
	return *a;
}
inline static fp_string __fp_string_concatenate_inplace(fp_string* a, const fp_string b) FP_NOEXCEPT { return __fp_string_view_concatenate_inplace(a, fp_string_to_view_const(b)); }

#define fp_string_view_concatenate_inplace(a, b) __fp_string_view_concatenate_inplace(&a, (b))
#define fp_string_concatenate_inplace(a, b) __fp_string_concatenate_inplace(&a, (b))

inline static fp_string fp_string_view_concatenate(const fp_string_view a, const fp_string_view b) FP_NOEXCEPT {
	fp_dynarray(char) out = NULL;
	size_t sizeA = fp_view_length(a);
	size_t sizeB = fp_view_length(b);
	if(sizeA + sizeB == 0) return nullptr;
	fpda_resize(out, sizeA + sizeB);

	memcpy(out, fp_view_data(char, a), sizeA);
	memcpy(out + sizeA, fp_view_data(char, b), sizeB);
	return out;
}
inline static fp_string fp_string_concatenate(const fp_string a, const fp_string b) FP_NOEXCEPT { return fp_string_view_concatenate(fp_string_to_view_const(a), fp_string_to_view_const(b)); }

inline static fp_string fp_string_view_concatenate_n(size_t count, ...) FP_NOEXCEPT {
	fp_dynarray(char) out = NULL;
	va_list args;
	va_start(args, count);

	for(size_t i = count, sum = 0; --i; ) {
		fp_string_view view = va_arg(args, fp_string_view);
		size_t size = fp_view_size(view);
		fpda_grow(out, size);
		memcpy(out + sum, fp_view_data(char, view), size);
		sum += size;
	}

	va_end(args);
	return out;
}
fp_string fp_string_concatenate_n(size_t count, ...) FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	fp_dynarray(char) out = NULL;
	va_list args;
	va_start(args, count);

	for(size_t i = count, sum = 0; --i; ) {
		fp_string str = va_arg(args, fp_string);
		size_t size = fp_string_length(str);
		fpda_grow(out, size);
		memcpy(out + sum, str, size);
		sum += size;
	}

	va_end(args);
	return out;
}
#else
;
#endif

inline static fp_string fp_string_append_impl(fp_string* str, char c) FP_NOEXCEPT {
	assert(is_fpda(*str));
	size_t size = fpda_length(*str);

	fpda_push_back(*str, c);
	(*str)[size + 1] = 0;
	return *str;
}
#define fp_string_append(str, c) fp_string_append_impl(&str, (c))



inline static fp_dynarray(uint32_t) fp_string_view_to_codepoints(const fp_string_view view) {
	const unsigned char *s = (const unsigned char *)fp_view_data(char, view);
	fp_dynarray(uint32_t) out = nullptr;

	for(size_t i = 0; i < fp_view_size(view); ) {
		uint32_t codepoint = 0;
		if (*s < 0x80) {
			// 1-byte (ASCII)
			codepoint = *s++;
			++i;
		} else if ((*s >> 5) == 0x6) {
			// 2-byte sequence
			codepoint = (*s++ & 0x1F) << 6;
			codepoint |= (*s++ & 0x3F);
			i += 2;
		} else if ((*s >> 4) == 0xE) {
			// 3-byte sequence
			codepoint = (*s++ & 0x0F) << 12;
			codepoint |= (*s++ & 0x3F) << 6;
			codepoint |= (*s++ & 0x3F);
			i += 3;
		} else if ((*s >> 3) == 0x1E) {
			// 4-byte sequence
			codepoint = (*s++ & 0x07) << 18;
			codepoint |= (*s++ & 0x3F) << 12;
			codepoint |= (*s++ & 0x3F) << 6;
			codepoint |= (*s++ & 0x3F);
			i += 4;
		} else {
			if(out) fpda_free_and_null(out);
			return nullptr;
		}

		fpda_push_back(out, codepoint);
	}

	return out;
}
inline static fp_dynarray(uint32_t) fp_string_to_codepoints(const fp_string str) {
	return fp_string_view_to_codepoints(fp_string_to_view_const(str));
}

// Encodes a single UTF-32 code point into UTF-8
// Returns the number of bytes written
inline static size_t fp_encode_utf8(uint32_t codepoint, char out[4]) {
	if (codepoint <= 0x7F) {
		out[0] = codepoint;
		return 1;
	} else if (codepoint <= 0x7FF) {
		out[0] = 0xC0 | (codepoint >> 6);
		out[1] = 0x80 | (codepoint & 0x3F);
		return 2;
	} else if (codepoint <= 0xFFFF) {
		out[0] = 0xE0 | (codepoint >> 12);
		out[1] = 0x80 | ((codepoint >> 6) & 0x3F);
		out[2] = 0x80 | (codepoint & 0x3F);
		return 3;
	} else if (codepoint <= 0x10FFFF) {
		out[0] = 0xF0 | (codepoint >> 18);
		out[1] = 0x80 | ((codepoint >> 12) & 0x3F);
		out[2] = 0x80 | ((codepoint >> 6) & 0x3F);
		out[3] = 0x80 | (codepoint & 0x3F);
		return 4;
	}
	return 0;  // Invalid code point
}

inline static fp_string fp_codepoints_view_to_string(fp_view(uint32_t) codepoints) {
	fp_string out = nullptr;
	fpda_reserve(out, fp_view_size(codepoints));

	for (size_t i = 0; i < fp_view_size(codepoints); ++i) {
		char temp[4];
		size_t len = fp_encode_utf8(*fp_view_access(uint32_t, codepoints, i), temp);
		if(len == 0) {
			if(out) fpda_free_and_null(out);
			return nullptr;
		}

		for (size_t j = 0; j < len; ++j)
			fp_string_append(out, temp[j]);
	}

	return out;
}
inline static fp_string fp_codepoints_to_string(const fp_dynarray(uint32_t) codepoints) {
	return fp_codepoints_view_to_string(fp_view_make_full(uint32_t, (uint32_t*)codepoints));
}



inline static fp_string fp_string_replicate_inplace(fp_string* str, size_t times) FP_NOEXCEPT {
	if(times == 0) return *str = nullptr;

	assert(is_fpda(*str));
	auto one = fp_string_make_dynamic(*str);
	for(size_t i = 0; i < times - 1; ++i) // NOTE: -1 since we already have 1 copy
		fp_string_concatenate_inplace(*str, one);
	fp_string_free(one);
	return *str;
}

inline static fp_string fp_string_view_replicate(const fp_string_view view, size_t times) FP_NOEXCEPT {
	auto out = fp_string_view_make_dynamic(view);
	return fp_string_replicate_inplace(&out, times);
}
inline static fp_string fp_string_replicate(const fp_string str, size_t times) FP_NOEXCEPT { return fp_string_view_replicate(fp_string_to_view_const(str), times); }

inline static size_t fp_string_view_find(const fp_string_view haystack, const fp_string_view needle, size_t start) {
	size_t haystack_size = fp_view_size(haystack);
	size_t needle_size = fp_view_size(needle);
	assert(start <= haystack_size);
	if(needle_size > haystack_size - start) return fp_string_npos; // Can't find a needle thats bigger than the haystack

	for(size_t i = start, bound = haystack_size - needle_size; i <= bound; ++i) {
		bool continue_outer = false;
		for(size_t j = 0; j < needle_size; ++j)
			if(*fp_view_access(char, haystack, i + j) != *fp_view_access(char, needle, j)) {
				continue_outer = true;
				break;
			}
		if(continue_outer) continue;
		return i;
	}
	return fp_string_npos;
}
inline static size_t fp_string_find(const fp_string haystack, const fp_string needle, size_t start) {
	return fp_string_view_find(fp_string_to_view_const(haystack), fp_string_to_view_const(needle), start);
}

inline static bool fp_string_view_contains(const fp_string_view haystack, const fp_string_view needle, size_t start) {
	return fp_string_view_find(haystack, needle, start) != fp_string_npos;
}
inline static bool fp_string_contains(const fp_string haystack, const fp_string needle, size_t start) {
	return fp_string_find(haystack, needle, start) != fp_string_npos;
}

inline static bool fp_string_view_starts_with(const fp_string_view haystack, const fp_string_view needle, size_t start) {
	size_t view_size = fp_view_size(haystack);
	size_t needle_size = fp_view_size(needle);
	if(needle_size > view_size - start) return false;

	auto sub = (fp_void_view)fp_view_subview(char, haystack, start, needle_size);
	return fp_view_equal(sub, (fp_void_view)needle);
}
inline static size_t fp_string_starts_with(const fp_string haystack, const fp_string needle, size_t start) {
	return fp_string_view_starts_with(fp_string_to_view_const(haystack), fp_string_to_view_const(needle), start);
}

inline static bool fp_string_view_ends_with(const fp_string_view haystack, const fp_string_view needle, ptrdiff_t end) {
	size_t view_size = fp_view_size(haystack);
	if(end <= 0) end = view_size + end;
	size_t needle_size = fp_view_size(needle);
	if(needle_size > end) return false;

	auto sub = (fp_void_view)fp_view_subview(char, haystack, end - needle_size, needle_size);
	return fp_view_equal(sub, (fp_void_view)needle);
}
inline static size_t fp_string_ends_with(const fp_string haystack, const fp_string needle, ptrdiff_t end) {
	return fp_string_view_ends_with(fp_string_to_view_const(haystack), fp_string_to_view_const(needle), end);
}

inline static fp_dynarray(fp_string_view) fp_string_view_split(const fp_string_view view, const fp_string_view delimiters) {
	fp_dynarray(fp_string_view) out = nullptr;
	size_t found, last_found = 0, MAX = -1;
	auto view_data = fp_view_data(char, view);
	do {
		found = -1;
		for(size_t i = 0, size = fp_view_size(delimiters); i < size; ++i) {
			auto delim = fp_view_subview(char, (fp_string_view)delimiters, i, 1);
			found = FP_MIN(found, fp_string_view_find(view, delim, last_found));
		}
		if(found == MAX) break;

		fpda_push_back(out, fp_string_view_literal(view_data + last_found, found - last_found));
		last_found = found;
	} while(found != MAX);

	// Once there are no more delimiters to be found push the final string
	fpda_push_back(out, fp_string_view_literal(view_data + last_found, fp_view_size(view) - last_found));
	return out;
}
inline static fp_dynarray(fp_string_view) fp_string_split(const fp_string view, const fp_string delimiters) {
	return fp_string_view_split(fp_string_to_view_const(view), fp_string_to_view_const(delimiters));
}

inline static fp_string fp_string_replace_range_inplace(fp_string* in, const fp_string_view with, size_t start, size_t range_len) {
	assert(is_fpda(*in));
	auto end = start + range_len;
	auto in_len = fp_string_length(*in);
	assert(end <= in_len);

	ptrdiff_t with_len = fp_view_size(with);
	auto diff = (ptrdiff_t)range_len - with_len;
	if(diff > 0 /*range longer*/) {
		memcpy(*in + start, fp_view_data(char, with), with_len);
		fpda_delete_range(*in, start + with_len, diff);
	} else if(diff < 0 /*with longer*/) {
		diff = -diff;
		fpda_grow(*in, diff);
		memmove(*in + end + diff, *in + end, in_len - start - diff);
		memcpy(*in + start, fp_view_data(char, with), with_len);
	} else /*with_len == range_len*/ {
		memcpy(*in + start, fp_view_data(char, with), with_len);
	}
	(*in)[fpda_size(*in)] = 0; // Make sure the string is null terminated
	return *in;
}

inline static fp_string fp_string_view_replace_range(const fp_string_view view, const fp_string_view with, size_t start, size_t len) {
	auto out = fp_string_view_make_dynamic(view);
	return fp_string_replace_range_inplace(&out, with, start, len);
}
inline static fp_string fp_string_replace_range(const fp_string str, const fp_string with, size_t start, size_t len) {
	return fp_string_view_replace_range(fp_string_to_view_const(str), fp_string_to_view_const(with), start, len);
}

// NOTE: Returns position of replacement (or npos if there was nothing to replace)
inline static size_t fp_string_replace_first_inplace(fp_string* in, const fp_string_view find, const fp_string_view replace, size_t start) {
	start = fp_string_view_find(fp_string_to_view_const(*in), find, start);
	if(start == fp_string_npos) return start;

	fp_string_replace_range_inplace(in, replace, start, fp_view_size(find));
	return start;
}

inline static size_t fp_string_view_replace_first(const fp_string_view view, const fp_string_view find, const fp_string_view replace, size_t start) {
	auto out = fp_string_view_make_dynamic(view);
	return fp_string_replace_first_inplace(&out, find, replace, start);
}
inline static size_t fp_string_replace_first(const fp_string str, const fp_string find, const fp_string replace, size_t start) {
	return fp_string_view_replace_first(fp_string_to_view_const(str), fp_string_to_view_const(find), fp_string_to_view_const(replace), start);
}

inline static fp_string fp_string_replace_inplace(fp_string* in, const fp_string_view find, const fp_string_view replace, size_t start) {
	while((start = fp_string_replace_first_inplace(in, find, replace, start)) != fp_string_npos)
		start += fp_view_size(replace);
	return *in;
}

inline static fp_string fp_string_view_replace(const fp_string_view view, const fp_string_view find, const fp_string_view replace, size_t start) {
	auto out = fp_string_view_make_dynamic(view);
	return fp_string_replace_inplace(&out, find, replace, start);
}
inline static fp_string fp_string_replace(const fp_string str, const fp_string find, const fp_string replace, size_t start) {
	return fp_string_view_replace(fp_string_to_view_const(str), fp_string_to_view_const(find), fp_string_to_view_const(replace), start);
}

inline static fp_string fp_string_vformat(const fp_string format, va_list args) FP_NOEXCEPT {
	va_list argsSize;
	va_copy(argsSize, args);
	size_t size = vsnprintf(NULL, 0, format, argsSize);
	va_end(argsSize);

	fp_dynarray(char) out = NULL;
	fpda_resize(out, size);

	vsnprintf(out, fpda_size(out) + 1, format, args);
	return out;
}
inline static fp_string fp_string_view_vformat(const fp_string_view format, va_list args) FP_NOEXCEPT {
	return fp_string_vformat(fp_string_view_make_dynamic(format), args);
}

inline static fp_string fp_string_format(const fp_string format, ...) FP_NOEXCEPT {
	va_list args;
	va_start(args, format);
	auto out = fp_string_vformat(format, args);
	va_end(args);
	return out;
}
inline static fp_string fp_string_view_format(const fp_string_view format, ...) FP_NOEXCEPT {
	va_list args;
	va_start(args, format);
	auto out = fp_string_view_vformat(format, args);
	va_end(args);
	return out;
}

#ifdef __cplusplus
}
#endif

#if defined __cplusplus && __cpp_lib_string_view >= 201606L
#include <string_view>

FP_CONSTEXPR inline static std::string_view fp_string_view_to_std(fp_string_view view) {
	return std::string_view{fp_view_data(char, view), fp_view_size(view)};
}
FP_CONSTEXPR inline static std::string_view fp_string_to_std(fp_string str) {
	return fp_string_view_to_std(fp_string_to_view(str));
}

FP_CONSTEXPR inline static fp_string_view fp_std_to_string_view(std::string_view view) {
	return fp_string_view_literal((char*)view.data(), view.size());
}
#endif

#endif // __LIB_FAT_POINTER_STRING_H__
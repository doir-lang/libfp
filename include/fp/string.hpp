#pragma once

#include "dynarray.hpp"
#include "fp/pointer.hpp"
#include "string.h"
#include <compare>

#ifdef FP_OSTREAM_SUPPORT
	#include <ostream>
	#include <string_view>
#endif

#ifndef FP_FORMAT_SUPPORT
	#if __cpp_lib_format >= 201907L
		#define FP_FORMAT_SUPPORT
	#endif
	#ifdef _LIBCPP_FORMAT
		#define FP_FORMAT_SUPPORT
	#endif
#endif

#ifdef FP_FORMAT_SUPPORT
	#include <format>
	#include <string_view>
#endif

namespace fp {

	inline static size_t encode_utf8(uint32_t codepoint, char out[4]) { return fp_encode_utf8(codepoint, out); }

	struct string_view: public view<char> {
		using super = view<char>;
		using super::super;
		string_view(char* str) : string_view(from_cstr(str)) {}
		string_view(const char* str) : string_view(from_cstr(str)) {}
		string_view(const char* str, size_t size) : string_view(from_ptr_size(str, size)) {}
		string_view(fp_string_view view) : super(fp_view_data(char, view), fp_view_size(view)) { }
		string_view(const string_view&) = default;
		string_view(string_view&&) = default;
		string_view& operator=(const string_view&) = default;
		string_view& operator=(string_view&&) = default;

		static string_view from_cstr(const char* str) { return from_ptr_size(str, fp_string_length(str)); }
		static string_view from_ptr_size(const char* str, size_t size) { return {fp_string_view_literal((char*)str, size)}; }

		struct string make_dynamic() const;
		int compare(const string_view o) const;
		dynarray<uint32_t> to_codepoints() const;
		struct string replicate(size_t times) const;
		struct string format(...) const;

		struct string replace_range(const string_view with, size_t start, size_t len) const;
		size_t replace_first(const string_view find, const string_view replace, size_t start = 0) const;
		struct string replace(const string_view find, const string_view replace, size_t start = 0) const;

		inline string_view subview(size_t start, size_t length) { return {super::subview(start, length)}; }
		inline string_view subview_max_size(size_t start, size_t length) { return {super::subview_max_size(start, length)}; }
		inline string_view subview(size_t start) { return {super::subview(start)}; }
		inline string_view subview_start_end(size_t start, size_t end) { return {super::subview_start_end(start, end)}; }

		std::strong_ordering operator<=>(const string_view o) const {
			auto res = compare(o);
			if(res < 0) return std::strong_ordering::less;
			if(res > 0) return std::strong_ordering::greater;
			return std::strong_ordering::equal;
		}
		std::strong_ordering operator<=>(const char* o) const {
			auto res = compare({fp_string_to_view_const(o)});
			if(res < 0) return std::strong_ordering::less;
			if(res > 0) return std::strong_ordering::greater;
			return std::strong_ordering::equal;
		}
		bool operator==(const string_view o) const { return this->operator<=>(o) == std::strong_ordering::equal; }
		bool operator==(const char* o) const { return this->operator<=>(o) == std::strong_ordering::equal; }

		inline size_t find(const string_view needle, size_t start = 0) const { return fp_string_view_find(view_(), needle, start); }
		bool contains(const string_view needle, size_t start = 0) const { return fp_string_view_contains(view_(), needle, start); }

		bool starts_with(const string_view needle, size_t start = 0) const { return fp_string_view_starts_with(view_(), needle, start); }
		bool ends_with(const string_view needle, size_t end = 0) const { return fp_string_view_ends_with(view_(), needle, end); }

		inline fp::dynarray<string_view> split(const string_view delimiters) const { return {(string_view*)fp_string_view_split(view_(), delimiters)}; }

#ifdef FP_OSTREAM_SUPPORT
		string_view(std::string_view v) : super((char*)v.data(), v.size()) {}

		std::string_view to_std() { return {data(), size()}; }
		const std::string_view to_std() const { return {data(), size()}; }
		friend std::ostream& operator<<(std::ostream& s, const string_view& view) {
			return s << const_cast<string_view&>(view).to_std();
		}
#endif
#ifdef FP_FORMAT_SUPPORT
		friend std::formatter<string_view, char>;
#endif
	};

	template<typename Derived, typename Dynamic>
	struct string_crtp_common {
		using view = string_view;

		static Dynamic from_codepoints(const fp::view<const uint32_t> codepoints) { return Dynamic{fp_codepoints_view_to_string((fp::view<uint32_t>&)codepoints)}; }
		static Dynamic from_codepoints(const dynarray<const uint32_t> codepoints) { return Dynamic{fp_codepoints_to_string(codepoints.raw)}; }

		static Dynamic make_dynamic(const char* string) { return Dynamic{fp_string_make_dynamic(string)}; }
		Dynamic make_dynamic() const { return make_dynamic(ptr()); }
		inline void free(bool nullify = true) {
			fp_string_free(ptr());
			if(nullify) ptr() = nullptr;
		}
		inline void free() const {
			fp_string_free(ptr());
		}

		string_view full_view() { return {fp_string_to_view(ptr())}; }
		const string_view full_view() const { return {fp_string_to_view_const(ptr())}; }

		size_t length() const { return fp_string_length(ptr()); }
		size_t size() const { return length(); }
		int compare(const char* o) const { return fp_string_compare(ptr(), o); }
		int compare(const string_view o) const { return fp_string_view_compare(full_view(), o); }
		std::strong_ordering operator<=>(const string_view o) const {
			auto res = compare(o);
			if(res < 0) return std::strong_ordering::less;
			if(res > 0) return std::strong_ordering::greater;
			return std::strong_ordering::equal;
		}
		std::strong_ordering operator<=>(const char* o) const {
			auto res = compare(o);
			if(res < 0) return std::strong_ordering::less;
			if(res > 0) return std::strong_ordering::greater;
			return std::strong_ordering::equal;
		}
		std::strong_ordering operator<=>(const Derived& o) const { return *this <=> o.data(); }
		bool operator==(const string_view o) const { return this->operator<=>(o) == std::strong_ordering::equal; }
		// bool operator==(const char* o) const { return this->operator<=>(o) == std::strong_ordering::equal; }
		friend bool operator==(const Derived& a, const Derived& b) { return a.operator<=>(b) == std::strong_ordering::equal; }

		dynarray<uint32_t> to_codepoints() const { return fp_string_to_codepoints(ptr()); }

		size_t find(const string_view needle, size_t start = 0) const { return fp_string_view_find(full_view(), needle, start); }
		size_t find(const char* needle, size_t start = 0) const { return fp_string_find(ptr(), needle, start); }
		bool contains(const string_view needle, size_t start = 0) const { return fp_string_view_contains(full_view(), needle, start); }
		bool contains(const char* needle, size_t start = 0) const { return fp_string_contains(ptr(), needle, start); }

		bool starts_with(const string_view needle, size_t start = 0) const { return fp_string_view_starts_with(full_view(), needle, start); }
		bool starts_with(const char* needle, size_t start = 0) const { return fp_string_starts_with(ptr(), needle, start); }
		bool ends_with(const string_view needle, size_t end = 0) const { return fp_string_view_ends_with(full_view(), needle, end); }
		bool ends_with(const char* needle, size_t end = 0) const { return fp_string_ends_with(ptr(), needle, end); }

		fp::dynarray<string_view> split(const string_view delimiters) { return {(string_view*)fp_string_view_split(full_view(), delimiters)}; }
		fp::dynarray<const string_view> split(const string_view delimiters) const { return {(const string_view*)fp_string_view_split(full_view(), delimiters)}; }
		fp::dynarray<string_view> split(const char* delimiters) { return {(string_view*)fp_string_split(ptr(), delimiters)}; }
		fp::dynarray<const string_view> split(const char* delimiters) const { return {(const string_view*)fp_string_split(ptr(), delimiters)}; }

		Dynamic replace_range(const string_view with, size_t start, size_t len) const {
			return Dynamic{fp_string_view_replace_range(full_view(), with, start, len)};
		}
		Dynamic replace_range(const char* with, size_t start, size_t len) const {
			return Dynamic{fp_string_replace_range(ptr(), with, start, len)};
		}
		size_t replace_first(const string_view find, const string_view replace, size_t start = 0) const {
			return fp_string_view_replace_first(full_view(), find, replace, start);
		}
		size_t replace_first(const char* find, const char* replace, size_t start = 0) const {
			return fp_string_replace_first(ptr(), find, replace, start);
		}
		Dynamic replace(const string_view find, const string_view replace, size_t start = 0) const {
			return Dynamic{fp_string_view_replace(full_view(), find, replace, start)};
		}
		Dynamic replace(const char* find, const char* replace, size_t start = 0) const {
			return Dynamic{fp_string_replace(ptr(), find, replace, start)};
		}

	protected:
		inline Derived* derived() { return (Derived*)this; }
		inline const Derived* derived() const { return (Derived*)this; }
		inline char*& ptr() { return derived()->ptr(); }
		inline const char* const & ptr() const { return derived()->ptr(); }
	};

	template<typename Derived>
	struct string_crtp : public string_crtp_common<Derived, Derived> {
		// Derived& concatenate_inplace(const Derived& o) { fp_string_concatenate_inplace(ptr(), o.data()); return *derived(); }
		// Derived& operator+=(const Derived& o) { concatenate_inplace(o); return *derived(); }
		Derived& concatenate_inplace(const string_view o) { fp_string_view_concatenate_inplace(ptr(), o); return *derived(); }
		Derived& operator+=(const string_view o) { concatenate_inplace(o); return *derived(); }

		// Derived concatenate(const Derived& o) const { return Derived{fp_string_concatenate(ptr(), o.data())}; }
		// Derived operator+(const Derived& o) const { return concatenate(o); }
		Derived concatenate(const string_view o) const { return Derived{fp_string_view_concatenate(this->full_view(), o)}; }
		Derived operator+(const string_view o) const { return concatenate(o); }

		Derived& append(const char c) { fp_string_append(ptr(), c); return *derived(); }
		Derived& operator+=(const char c) { return append(c); }
		Derived operator+(const char c) { return std::move(this->make_dynamic().append(c)); }

		Derived replicate(size_t times) { return Derived{fp_string_replicate(ptr(), times)}; }

		Derived& replace_range_inplace(const string_view with, size_t start, size_t range_len) {
			fp_string_replace_range_inplace(&ptr(), with, start, range_len);
			return *derived();
		}
		// Derived& replace_range_inplace(const Derived& with, size_t start, size_t range_len) {
		// 	return replace_range_inplace(with.full_view(), start, range_len);
		// }

		Derived& replace_first_inplace(const string_view find, const string_view replace, size_t start = 0) {
			fp_string_replace_first_inplace(&ptr(), find, replace, start);
			return *derived();
		}
		// Derived& replace_first_inplace(const Derived& find, const Derived& replace, size_t start = 0) {
		// 	return replace_first_inplace(find.full_view(), replace.full_view(), start);
		// }

		Derived& replace_inplace(const string_view find, const string_view replace, size_t start = 0) {
			fp_string_replace_inplace(&ptr(), find, replace, start);
			return *derived();
		}
		// Derived& replace_inplace(const Derived& find, const Derived& replace, size_t start = 0) {
		// 	return replace_inplace(find.full_view(), replace.full_view(), start);
		// }

#ifdef FP_FORMAT_SUPPORT
	#ifndef _MSC_VER
		Derived c_format(...) const {
			va_list args;
			va_start(args, ptr());
			auto out = fp_string_vformat(ptr(), args);
			va_end(args);
			return Derived{out};
		}
	#endif

		template<class... Args>
		static Derived format(std::format_string<Args...> fmt, Args&&... args) {
			auto standard = std::format(fmt, std::forward<Args>(args)...);
			if(standard.empty()) return nullptr;
			return Derived{fp_string_make_dynamic(standard.c_str())};
		}
#elif !defined(_MSC_VER)
		Derived format(...) const {
			va_list args;
			va_start(args, ptr());
			auto out = fp_string_vformat(ptr(), args);
			va_end(args);
			return Derived{out};
		}
#endif

	protected:
		using super = string_crtp_common<Derived, Derived>;
		using super::derived;
		using super::ptr;
	};

	struct string: public dynarray<char>, public string_crtp<string> {
		using view = string_view;
		using super = dynarray<char>;
		using super::super;
		using super::operator=;
		using super::ptr;
		// string(std::nullptr_t): super(nullptr) {}
		explicit string(char* str): super(str) {}
		explicit string(const char* str): super(str == nullptr || is_fpda(str) ? (char*)str : fp_string_make_dynamic(str)) {}
		FP_HPP_DEFAULT_CONSTRUCTOR_BLOCK(string, super);

		using crtp = string_crtp<string>;
		using crtp::free;
		// using crtp::clone;
		using crtp::size;
		using crtp::concatenate;
		using crtp::full_view;

		operator view() { return full_view(); }
		operator const view() const { return full_view(); }

		fp::auto_free<string> auto_free();

		static fp::dynarray<string> make_dynamic(fp::dynarray<string_view> views) {
			auto out = fp::dynarray<string>{nullptr}.reserve(views.size());
			for(auto view: views)
				out.push_back(view.make_dynamic());
			return out;
		}
	};

	template<>
	struct auto_free<string> : public string {
		constexpr auto_free(): string(nullptr) {}
		constexpr auto_free(std::nullptr_t): string(nullptr) {}
		auto_free(char* ptr): string(ptr) {}
		auto_free(const char* ptr): string(ptr) {}
		auto_free(const string& o): string(o.clone()) {}
		auto_free(string&& o): string(std::exchange(o.raw, nullptr)) {}
		auto_free(const auto_free& o): string(o.clone()) {}
		auto_free(auto_free&& o): string(std::exchange(o.raw, nullptr)) {}
		auto_free& operator=(const string& o) { (void)~auto_free(); string::raw = o.clone().raw; return *this;}
		auto_free& operator=(string&& o) { (void)~auto_free(); string::raw = std::exchange(o.raw, nullptr); return *this; }
		auto_free& operator=(const auto_free& o) { (void)~auto_free(); string::raw = o.clone().raw; return *this;}
		auto_free& operator=(auto_free&& o) { (void)~auto_free(); string::raw = std::exchange(o.raw, nullptr); return *this; }
		~auto_free() { if(string::raw) string::free(true); }

		using string::string;
	};

	inline fp::auto_free<string> string::auto_free() { return std::move(*this); }

	namespace raii {
		using string = auto_free<fp::string>;
	}

	namespace wrapped {
		struct string : public wrapped::pointer<char>, public string_crtp_common<wrapped::string, fp::string> {
			using view = string_view;
			using super = wrapped::pointer<char>;
			using super::super;
			using super::operator=;
			using super::ptr;
			string(std::nullptr_t): super(nullptr) {}
			explicit string(char* str): super(str) {}
			explicit string(const char* str): super((char*)str) {}

			using crtp = string_crtp_common<wrapped::string, fp::string>;
			using crtp::free;
			using crtp::size;
		};
	}


	inline string string_view::make_dynamic() const { return string{fp_string_view_make_dynamic(view_())}; }
	inline int string_view::compare(const string_view o) const { return fp_string_view_compare(view_(), o); }
	inline dynarray<uint32_t> string_view::to_codepoints() const { return fp_string_view_to_codepoints(view_()); }
	inline string string_view::replicate(size_t times) const { return string{fp_string_view_replicate(view_(), times)}; }
	inline string string_view::format(...) const {
		va_list args;
		va_start(args, view_());
		auto out = fp_string_view_vformat(view_(), args);
		va_end(args);
		return string{out};
	}

	inline string string_view::replace_range(const string_view with, size_t start, size_t len) const {
		return string{fp_string_view_replace_range(view_(), with, start, len)};
	}
	inline size_t string_view::replace_first(const string_view find, const string_view replace, size_t start /* = 0 */) const {
		return fp_string_view_replace_first(view_(), find, replace, start);
	}
	inline string string_view::replace(const string_view find, const string_view replace, size_t start /* = 0 */) const {
		return string{fp_string_view_replace(view_(), find, replace, start)};
	}

	inline string operator+(const string_view a, const string& b) {
		return a.make_dynamic().concatenate_inplace(b.full_view());
	}
	inline string operator+(const char* a, const string& b) {
		return fp::string_view(a) + b;
	}
	inline string operator+(const string& a, const char* b) {
		return a + fp::string_view(b);
	}

	inline raii::string operator+(const string_view a, const raii::string& b) {
		return a.make_dynamic().concatenate_inplace(b.full_view());
	}
	inline raii::string operator+(const char* a, const raii::string& b) {
		return fp::string_view(a) + b;
	}
	inline raii::string operator+(const raii::string& a, const char* b) {
		return a + fp::string_view(b);
	}

#ifdef FP_FORMAT_SUPPORT
	namespace builder {
		struct string: public fp::raii::string {
			FP_HPP_DEFAULT_CONSTRUCTOR_BLOCK(string, fp::raii::string);

			template<typename T>
			requires(requires{std::formatter<T, char>{};})
			inline string& operator<<(T value) {
				fp::auto_free str = format("{}", value);
				concatenate_inplace(str);
				return *this;
			}

			inline string& operator<<(const char c) {
				append(c);
				return *this;
			}

			inline string& operator<<(const char* str) {
				concatenate_inplace(str);
				return *this;
			}

			inline string& operator<<(const fp::string& str) {
				concatenate_inplace(str);
				return *this;
			}

			inline string& operator<<(const fp::string_view& view) {
				*this += view;
				return *this;
			}

			inline string& operator<<(const fp_string_view& view) {
				return *this << fp::string_view{view};
			}
		};
	}

	template<>
	struct auto_free<builder::string> : public builder::string {
		using builder::string::string;
	};
#endif
}

#ifdef FP_OSTREAM_SUPPORT
#ifndef _MSC_VER
inline std::ostream& operator<<(std::ostream& s, const fp::string& str) {
	if (str.raw) return s << str.raw;
	return s;
}

inline std::ostream& operator<<(std::ostream& s, const fp::raii::string& str) {
	if (str.raw) return s << str.raw;
	return s;
}

inline std::ostream& operator<<(std::ostream& s, const fp::wrapped::string& str) {
	if (str.raw) return s << str.raw;
	return s;
}
#endif
#endif

#ifdef FP_FORMAT_SUPPORT
namespace std {
	// template<typename Derived, typename Dynamic>
	// struct formatter<fp::string_view, char> : public formatter<fp::raii::string_view, char> {
	// 	using super = formatter<fp::raii::string_view, char>;

	// 	template<class FmtContext>
	// 	FmtContext::iterator format(const fp::string_view str, FmtContext& ctx) const {
	// 		fp::raii::string_view view{str.data(), str.size()};
	// 		return super::format(view, ctx);
	// 	}
	// };

	template<>
	struct formatter<fp::wrapped::string, char> : public formatter<std::string_view, char> {
		using super = formatter<std::string_view, char>;

		template<class FmtContext>
		FmtContext::iterator format(const fp::wrapped::string str, FmtContext& ctx) const {
			std::string_view view{str.raw, str.size()};
			return super::format(view, ctx);
		}
	};

	template<>
	struct formatter<fp::string, char> : public formatter<fp::wrapped::string, char> {};
	template<>
	struct formatter<fp::raii::string, char> : public formatter<fp::wrapped::string, char> {};
}
#endif

#ifndef FP_NO_STRING_LITERAL
inline static fp::string_view operator ""_fpv(const char* p, size_t size) {
	return fp_string_view_literal((char*)p, size);
}

inline static fp::string operator ""_fp(const char* p, size_t size) {
	auto out = fp::string_view{fp_string_view_literal((char*)p, size)}.make_dynamic();
	return out;
}

inline static fp::raii::string operator ""_fpr(const char* p, size_t size) {
	auto out = fp::string_view{fp_string_view_literal((char*)p, size)}.make_dynamic();
	return out.auto_free();
}
#endif

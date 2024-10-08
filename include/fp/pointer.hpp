#pragma once

#include <algorithm>
#include <cstddef>
#include <utility>
#include <cstring>
#include <array>

#include "fp/string.h"
#include "pointer.h"

#ifdef FP_ENABLE_STD_RANGES
	#include <ranges>
#endif
#if defined(__cpp_lib_span) && __cpp_lib_span >= 202002L
	#include <span>
#endif

namespace fp {

	namespace wrapped {
		template<typename T>
		struct pointer {
			T* raw;

			pointer(): raw(nullptr) {}
			pointer(std::nullptr_t): raw(nullptr) {}
			pointer(T* ptr_): raw(ptr_) {}
			pointer(const pointer& o) = default;
			pointer(pointer&& o): raw(std::exchange(o.raw, nullptr)) {}
			pointer& operator=(const pointer& o) = default;
			pointer& operator=(pointer&& o) { raw = std::exchange(o.raw, nullptr); return *this; }

			inline operator pointer<std::add_const_t<T>>() const { return *(pointer<std::add_const_t<T>>*)this; }

			T* data() { return raw; }
			const T* data() const { return raw; }
			inline T& operator*() {
				assert(raw);
				return *raw;
			}
			inline const T& operator*() const {
				assert(raw);
				return *raw;
			}
			inline T* operator->() {
				assert(raw);
				return raw;
			}
			inline const T* operator->() const {
				assert(raw);
				return raw;
			}

		protected:
			inline T*& ptr() { return raw; }
			inline const T* const & ptr() const { return raw; }
		};
	}



	template<typename T>
	struct view: public fp_view(T) {
		view(T* data = nullptr, size_t size = 0): fp_view(T)(fp_view_literal(T, data, size)) {}
		view(fp_view(T) o) : fp_view(T)(o) {}
		view(const view&) = default;
		view(view&&) = default;
		view& operator=(const view&) = default;
		view& operator=(view&&) = default;

		inline operator view<std::add_const_t<T>>() const { return *(view<std::add_const_t<T>>*)this; }
		fp_view(T)& raw() { return *this; }

		static view make(T* p, size_t start, size_t length) {
			assert(fp_size(p) >= start + length);
			return {fp_view_make(T, p, start, length)};
		}
		static view make_full(T* p) {
			assert(is_fp(p));
			return {fp_view_make_full(T, p)};
		}
		static view make_start_end(T* p, size_t start, size_t end) {
			assert(start < end);
			assert(fp_size(p) >= end);
			return {fp_view_make_start_end(T, p, start, end)};
		}

		static view from_variable(T& var) { return {&var, 1}; }

		inline T* data() { return fp_view_data(T, view_()); }
		inline const T* data() const { return fp_view_data(T, view_()); }

		inline size_t length() const { return fp_view_length(view_()); }
		inline size_t size() const { return fp_view_size(view_()); }
		inline bool empty() const { return size() == 0; }

		inline view subview(size_t start, size_t length) {
			assert(start + length <= size());
			return {fp_view_subview(T, view_(), start, length)};
		}
		inline view subview_max_size(size_t start, size_t length) { return subview(start, std::min(size() - start, length)); }
		inline view subview(size_t start) { return subview(start, size() - start); }
		inline view subview_start_end(size_t start, size_t end) {
			assert(start <= end);
			assert(end <= size());
			return {fp_view_subview_start_end(T, view_(), start, end)};
		}

		inline view<T> subview(size_t start, size_t length) const {
			assert(start + length <= size());
			return {fp_view_subview(T, view_(), start, length)};
		}
		inline view<T> subview_max_size(size_t start, size_t length) const { return subview(start, std::min(size() - start, length)); }
		inline view<T> subview(size_t start) const { return subview(start, size() - start); }
		inline view<T> subview_start_end(size_t start, size_t end) const {
			assert(start <= end);
			assert(end <= size());
			return {fp_view_subview_start_end(T, view_(), start, end)};
		}

		inline view<std::byte> byte_view() { return {(std::byte*)data(), size() * sizeof(T)}; }
		inline view<const std::byte> byte_view() const { return {(const std::byte*)data(), size() * sizeof(T)}; }

		inline T* begin() { return fp_view_begin(T, view_()); }
		inline T* end() { return fp_view_end(T, view_()); } // TODO: Fails on MSVC?

		size_t compare(const view other) const { return fp_view_compare(view_(), other); }
		std::strong_ordering operator<=>(const view o) const {
			auto res = compare(o);
			if(res < 0) return std::strong_ordering::less;
			if(res > 0) return std::strong_ordering::greater;
			return std::strong_ordering::equal;
		}
		bool operator==(const view o) const { return this->operator<=>(o) == std::strong_ordering::equal; }

#ifdef FP_ENABLE_STD_RANGES
		inline auto range() { return std::ranges::subrange(begin(), end()); }
#endif
#if defined(__cpp_lib_span) && __cpp_lib_span >= 202002L
		view(const std::span<T> span) : fp_view(T)(span.data(), span.size()) {}

		inline std::span<T> span() { return {data(), size()}; }
		inline operator std::span<T>() { return span(); }
#endif

		inline T& operator*() {
			assert(!empty());
			return *data();
		}
		inline const T& operator*() const {
			assert(!empty());
			return *data();
		}
		inline T* operator->() {
			assert(!empty());
			return data();
		}
		inline const T* operator->() const {
			assert(!empty());
			return data();
		}

		inline T& operator[](size_t i) {
			assert(!empty());
			assert(i < size());
			return data()[i];
		}
		inline const T& operator[](size_t i) const {
			assert(!empty());
			assert(i < size());
			return data()[i];
		}

	protected:
		inline fp_view(T) view_() { return *this; }
		inline const fp_view(T) view_() const { return *this; }
		inline fp_void_view void_view() { return *(fp_void_view*)this; }
		inline const fp_void_view void_view() const { return *(fp_void_view*)this; }
	};




	template<typename T, typename Derived>
	struct pointer_crtp {
		using view_t = fp::view<T>;

		inline T* data() { return ptr(); }
		inline const T* data() const { return ptr(); }
		explicit inline operator T*() { return ptr(); }
		explicit inline operator const T*() const { return ptr(); }
		T* release() { return std::exchange(ptr(), nullptr); }

		inline bool is_fp() const { return ::is_fp(ptr()); }
		inline bool stack_allocated() const { return fp_is_stack_allocated(ptr()); }
		inline bool heap_allocated() const { return fp_is_heap_allocated(ptr()); }
		inline operator bool() const { return data() != nullptr; }

		inline size_t length() const { return fp_length(ptr()); }
		inline size_t size() const { return fp_size(ptr()); }
		inline bool empty() const { return fp_empty(ptr()); }

		inline view_t view(size_t start, size_t length) { return view_t::make(ptr(), start, length); }
		inline view_t view_full() { return view_t::make_full(ptr()); }
		inline view_t full_view() { return view_t::make_full(ptr()); }
		inline view_t view_start_end(size_t start, size_t end) { return view_t::make_start_end(ptr(), start, end); }

		inline T& front() { return *fp_front(ptr()); }
		inline T& back() { return *fp_back(ptr()); }

		inline T* begin() { return fp_begin(ptr()); }
		inline const T* begin() const { return fp_begin(ptr()); }
		inline T* end() { return fp_end(ptr()); }
		inline const T* end() const { return fp_end((T*)ptr()); }

#ifdef FP_ENABLE_STD_RANGES
		inline auto range() { return std::ranges::subrange(begin(), end()); }
#endif
#if defined(__cpp_lib_span) && __cpp_lib_span >= 202002L
		inline std::span<T> span() { return {data(), size()}; }
#endif

		inline Derived& fill(const T& value = {}) {
			std::fill(begin(), end(), value);
			return *(Derived*)this;
		}

		inline T& operator*() {
			assert(!empty());
			return *data();
		}
		inline const T& operator*() const {
			assert(!empty());
			return *data();
		}
		inline T* operator->() {
			assert(!empty());
			return data();
		}
		inline const T* operator->() const {
			assert(!empty());
			return data();
		}

		inline T& operator[](size_t i) {
			assert(!empty());
			assert(i < size());
			return data()[i];
		}
		inline const T& operator[](size_t i) const {
			assert(!empty());
			assert(i < size());
			return data()[i];
		}

	protected:
		inline T*& ptr() { return ((Derived*)this)->ptr(); }
		inline const T* const & ptr() const { return (((const Derived*)this)->ptr()); }
	};


	template<typename T>
	struct pointer: public wrapped::pointer<T>, public pointer_crtp<T, pointer<T>> {
		using wrapped::pointer<T>::pointer;
		using wrapped::pointer<T>::raw;
		using pointer_crtp<T, pointer<T>>::data;

		pointer(T* ptr_): wrapped::pointer<T>(ptr_) { assert(ptr_ == nullptr || this->is_fp()); }
		inline operator pointer<std::add_const_t<T>>() const { return *(pointer<std::add_const_t<T>>*)this; }

		inline void free() { fp_free(raw); }
		inline void free_and_null() { fp_free_and_null(raw); }
		inline pointer& realloc(size_t new_count) { raw = fp_realloc(T, raw, new_count); return *this; }

		inline pointer clone() const { return fp_clone(raw); }

	protected:
		friend pointer_crtp<T, pointer<T>>;
		inline T*& ptr() { return raw; }
		inline const T* const & ptr() const { return raw; }
	};

	namespace raii {
		template<typename T>
		struct pointer: public fp::pointer<T> {
			using super = fp::pointer<T>;
			// using super::super;
			pointer(): super(nullptr) {}
			pointer(std::nullptr_t): super(nullptr) {}
			pointer(T* ptr): super(ptr) {}
			pointer(const super& o): super(o.clone()) {}
			pointer(super&& o): super(std::exchange(o.raw, nullptr)) {}
			pointer(const pointer& o): super(o.clone()) {}
			pointer(pointer&& o): super(std::exchange(o.raw, nullptr)) {}
			pointer& operator=(const pointer& o) { if(super::raw) super::free(); super::raw = o.clone(); return *this;}
			pointer& operator=(pointer&& o) { if(super::raw) super::free(); super::raw = std::exchange(o.raw, nullptr); return *this; }
			~pointer() { if(super::raw) super::free_and_null(); }

			inline operator pointer<std::add_const_t<T>>() const { return *(pointer<std::add_const_t<T>>*)this; }
		};
	}

	template<typename T>
	inline pointer<T> malloc(size_t count = 1) {
		return fp_malloc(T, count);
	}
	template<typename T>
	inline pointer<T> realloc(pointer<T> ptr, size_t new_count) {
		return ptr.realloc(new_count);
	}
	template<typename T>
	inline void free(pointer<T> ptr) {
		ptr.free();
	}


	template<typename T, size_t N>
	struct array: public pointer_crtp<T, array<T, N>> {
		__FatPointerHeaderTruncated __header = {
			.magic = FP_STACK_MAGIC_NUMBER,
			.size = N,
		};
		T raw[N];

		inline operator array<std::add_const_t<T>, N>() const { return *(array<std::add_const_t<T>, N>*)this; }

	protected:
		friend pointer_crtp<T, array<T, N>>;
		inline T*& ptr() {
			thread_local static auto tmp = &raw[0];
			tmp = &raw[0];
			return tmp;
		}
		inline const T* const & ptr() const { return const_cast<array*>(this)->ptr(); }
	};

}
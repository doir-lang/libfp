#pragma once

#include "pointer.hpp"
#include "dynarray.h"

namespace fp {

	template<typename T, typename Derived>
	struct dynarray_crtp {
		inline bool is_dynarray() const { return is_fpda(ptr()); }
		inline size_t capacity() const { return fpda_capacity(ptr()); }

		inline void free() { fpda_free(ptr()); }
		inline void free_and_null() { fpda_free_and_null(ptr()); }

		inline Derived& reserve(size_t size) {
			fpda_reserve(ptr(), size);
			return *derived();
		}
		inline Derived& grow(size_t to_add, const T& value = {}) {
			fpda_grow_and_initialize(ptr(), to_add, value);
			return *derived();
		}
		inline Derived& grow_to_size(size_t size, const T& value = {}) {
			fpda_grow_to_size_and_initialize(ptr(), size, value);
			return *derived();
		}

		inline T& push_back(const T& value) {
			return fpda_push_back(ptr(), value);
		}

		inline T& pop_back_n(size_t count) {
			return *fpda_pop_back_n(ptr(), count);
		}
		inline T& pop_back() {
			return *fpda_pop_back(ptr());
		}
		inline T& pop_back_to_size(size_t size) {
			assert(size < fpda_size(ptr()));
			return *fpda_pop_back_to_size(ptr(), size);
		}

		inline T& insert(size_t pos, const T& value = {}) {
			return fpda_insert(ptr(), pos, value);
		}
		inline T& push_front(const T& value = {}) {
			return fpda_push_front(ptr(), value);
		}
		inline view<T> insert_uninitialized(size_t pos, size_t count = 1) {
			fpda_insert_uninitialized(ptr(), pos, count);
			return derived()->view(pos, count);
		}

		inline Derived& delete_range(size_t pos, size_t count) {
			fpda_delete_range(ptr(), pos, count);
			return *derived();
		}
		inline Derived& delete_(size_t pos) {
			fpda_delete(ptr(), pos);
			return *derived();
		}
		inline Derived& remove(size_t pos) { return delete_(pos); }
		inline Derived& delete_start_end(size_t start, size_t end) {
			fpda_delete_start_end(ptr(), start, end);
			return *derived();
		}

		inline Derived& shrink_delete_range(size_t pos, size_t count) {
			fpda_shrink_delete_range(ptr(), pos, count);
			return *derived();
		}
		inline Derived& shrink_delete(size_t pos) {
			fpda_shrink_delete(ptr(), pos);
			return *derived();
		}
		inline Derived& shrink_delete_start_end(size_t start, size_t end) {
			fpda_shrink_delete_start_end(ptr(), start, end);
			return *derived();
		}

		inline Derived& resize(size_t size) {
			fpda_resize(ptr(), size);
			return *derived();
		}
		inline Derived& shrink_to_fit() {
			fpda_shrink_to_fit(ptr());
			return *derived();
		}

		inline Derived& swap_range(size_t start1, size_t start2, size_t count) {
			fpda_swap_range(ptr(), start1, start2, count);
			return *derived();
		}
		inline Derived& swap(size_t pos1, size_t pos2) {
			fpda_swap(ptr(), pos1, pos2);
			return *derived();
		}

		inline Derived& swap_delete_range(size_t pos, size_t count) {
			fpda_swap_delete_range(ptr(), pos, count);
			return *derived();
		}
		inline Derived& swap_delete(size_t pos) {
			fpda_swap_delete(ptr(), pos);
			return *derived();
		}
		inline Derived& swap_delete_start_end(size_t start, size_t end) {
			fpda_swap_delete_start_end(ptr(), start, end);
			return *derived();
		}

		inline T& pop_front() {
			return *fpda_pop_front(ptr());
		}

		inline Derived clone() const {
			return (T*)fpda_clone(ptr());
		}

		inline Derived& clear() {
			fpda_clear(ptr());
			return *derived();
		}

	protected:
		inline Derived* derived() { return (Derived*)this; }
		inline const Derived* derived() const { return (Derived*)this; }
		inline T*& ptr() { return derived()->ptr(); }
		inline const T* const & ptr() const { return derived()->ptr(); }
	};

	template<typename T>
	struct dynarray: public pointer<T>, public dynarray_crtp<T, dynarray<T>> {
		using super = pointer<T>;
		using super::super;
		// using super::operator=;
		using super::ptr;

		using crtp = dynarray_crtp<T, dynarray<T>>;
		using crtp::free;
		using crtp::free_and_null;
		using crtp::clone;

		inline operator dynarray<std::add_const_t<T>>() const { return *(dynarray<std::add_const_t<T>>*)this; }
	};

	namespace raii {
		template<typename T>
		struct dynarray: public raii::pointer<T>, public dynarray_crtp<T, raii::dynarray<T>> {
			using super = raii::pointer<T>;
			using super::ptr;

			using crtp = dynarray_crtp<T, raii::dynarray<T>>;
			using crtp::free;
			using crtp::free_and_null;
			using crtp::clone;

			dynarray(): super(nullptr) {}
			dynarray(T* ptr): super(ptr) {}
			dynarray(const fp::dynarray<T>& o): super(std::move(o.clone())) {}
			dynarray(fp::dynarray<T>&& o): super(std::exchange(o.raw, nullptr)) {}
			dynarray(const dynarray& o): super(std::move(o.clone())) {}
			dynarray(dynarray&& o): super(std::exchange(o.raw, nullptr)) {}
			dynarray& operator=(const dynarray& o) { if(super::raw) crtp::free(); super::raw = o.clone(); return *this;}
			dynarray& operator=(dynarray&& o) { if(super::raw) crtp::free(); super::raw = std::exchange(o.raw, nullptr); return *this; }
			~dynarray() { if(super::raw) crtp::free_and_null(); }

			inline operator dynarray<std::add_const_t<T>>() const { return *(dynarray<std::add_const_t<T>>*)this; }
		};
	}
}
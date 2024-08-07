#pragma once

#include "pointer.hpp"
#include "dynarray.h"
#include <type_traits>

namespace fp {

	template<typename T, typename Derived>
	struct dynarray_crtp {
		inline bool is_dynarray() const { return is_fpda(ptr()); }
		inline size_t capacity() const { return fpda_capacity(ptr()); }

		inline void free(bool nullify = true) { 
			if constexpr (!std::is_trivially_destructible_v<T>) {
				for(auto& e: *derived())
					e.~T();
			}
			fpda_free(ptr()); 
			if(nullify) ptr() = nullptr;
		}
		inline void free() const { 
			if constexpr (!std::is_trivially_destructible_v<T>) {
				for(auto& e: *derived())
					e.~T();
			}
			fpda_free((void*)ptr()); 
		}

		inline Derived& reserve(size_t size) {
			fpda_reserve(ptr(), size);
			return *derived();
		}
		inline Derived& grow(size_t to_add, const T& value = {}) {
			fpda_grow_and_initialize(ptr(), to_add, value);
			return *derived();
		}
		inline Derived& grow_uninitialized(size_t to_add) {
			fpda_grow(ptr(), to_add);
			return *derived();
		}
		inline Derived& grow_to_size(size_t size, const T& value = {}) {
			fpda_grow_to_size_and_initialize(ptr(), size, value);
			return *derived();
		}
		inline Derived& grow_to_size_uninitialized(size_t size) {
			fpda_grow_to_size(ptr(), size);
			return *derived();
		}

		inline T& push_back(const T& value) {
			return fpda_push_back(ptr(), value);
		}
		template<typename... Targs>
		inline T& emplace_back(Targs... args) {
			auto out = fpda_grow(ptr(), 1);
			return *(new(out) T(std::forward<Targs>(args)...));
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
		template<typename... Targs>
		inline T& emplace(size_t pos, Targs... args) {
			auto out = fpda_insert_uninitialized(ptr(), pos, 1);
			return *(new(out) T(std::forward<Targs>(args)...));
		}

		inline T& push_front(const T& value = {}) {
			return fpda_push_front(ptr(), value);
		}
		template<typename... Targs>
		inline T& emplace_front(Targs... args) {
			return emplace(0, std::forward<Targs>(args)...);
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
			if constexpr (!std::is_trivially_destructible_v<T>) {
				for(auto& e: *derived())
					e.~T();
			}
			fpda_clear(ptr());
			return *derived();
		}

		inline Derived& concatenate_view_in_place(const view<const T> view) {
			fpda_concatenate_view_in_place(ptr(), view);
			return *derived();
		}

		inline Derived& concatenate_view(const view<const T> view) const {
			return (T*)fpda_concatenate_view(ptr(), view);
		}

		inline Derived& concatenate_in_place(const Derived& other) {
			fpda_concatenate_in_place(ptr(), other.ptr());
			return *derived();
		}

		inline Derived& concatenate(const Derived& other) const {
			return (T*)fpda_concatenate(ptr(), other.ptr());
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

		dynarray(std::initializer_list<T> init) {
			crtp::reserve(init.size());
			for(auto& i: init)
				crtp::push_back(std::move(i));
		}

		FP_HPP_DEFAULT_CONSTRUCTOR_BLOCK(dynarray, super);

		using crtp = dynarray_crtp<T, dynarray<T>>;
		using crtp::free;
		using crtp::clone;

		inline operator dynarray<std::add_const_t<T>>() const { return *(dynarray<std::add_const_t<T>>*)this; }
	};

	namespace raii {
		template<typename T>
		using dynarray = auto_free<fp::dynarray<T>>;
	}
}
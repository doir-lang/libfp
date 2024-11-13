#pragma once

#include "../dynarray.hpp"
#include "map.h"

#include <functional>

namespace fp {

	namespace detail {
		template<typename T>
		T& get_key(T& key) {
			return key;
		}
		template<typename T>
		const T& get_key(const T& key) {
			return key;
		}

		template<typename Tkey, typename Tvalue>
		Tkey& get_key(std::pair<Tkey, Tvalue>& pair) {
			return pair.first;
		}
		template<typename Tkey, typename Tvalue>
		const Tkey& get_key(const std::pair<Tkey, Tvalue>& pair) {
			return pair.first;
		}

		template<typename Tkey, typename Tvalue>
		using pair_type = std::conditional_t<!std::is_same_v<Tvalue, void>, std::pair<Tkey, Tvalue>, Tkey>;
	}

	template<typename T>
	struct should_store_hashes_while_initializing: public std::false_type {};

	// typedef uint64_t(*fp_hash_map_function_t)(const fp_void_view) FP_NOEXCEPT;
	// typedef bool(*fp_hash_map_equal_function_t)(const fp_void_view, const fp_void_view) FP_NOEXCEPT;
	// typedef void*(*fp_hash_map_copy_function_t)(void*, const void*, size_t) FP_NOEXCEPT;
	// typedef void*(*fp_hash_map_swap_function_t)(void*, void*, size_t) FP_NOEXCEPT;
	// typedef void(*fp_hash_map_finalize_function_t)(fp_void_view) FP_NOEXCEPT;

	template<typename Tkey, typename Tvalue, typename Hash = void, typename Equal = void>
	struct hash_map: public fp::dynarray<detail::pair_type<Tkey, Tvalue>> {
	protected:
		using pair_type = detail::pair_type<Tkey, Tvalue>;
		constexpr static auto hash_function = std::conditional_t<std::is_same_v<Hash, void>, std::hash<Tkey>, Hash>{};
		constexpr static auto equal_function = std::conditional_t<std::is_same_v<Equal, void>, std::equal_to<Tkey>, Hash>{};

		static uint64_t _fp_hash(const fp_void_view view) FP_NOEXCEPT {
			assert(fp_view_size(view) == sizeof(pair_type));
			auto pair = (pair_type*)fp_view_data_void(view);
			return hash_function(detail::get_key(*pair));
		}

		static bool _fp_equal(const fp_void_view a, const fp_void_view b) FP_NOEXCEPT {
			assert(fp_view_size(a) == sizeof(pair_type));
			auto& keyA = detail::get_key(*(pair_type*)fp_view_data_void(a));
			assert(fp_view_size(b) == sizeof(pair_type));
			auto& keyB = detail::get_key(*(pair_type*)fp_view_data_void(b));
			return equal_function(keyA, keyB);
		}

		static void* _fp_copy(void* dest, const void* src, size_t size) FP_NOEXCEPT {
			assert(size == sizeof(pair_type));
			if constexpr(std::is_trivially_copyable_v<pair_type>)
				return std::memcpy(dest, src, size);
			else return *(pair_type*)dest = *(pair_type*)src, dest;
		}

		static void* _fp_swap(void* dest, void* src, size_t size) FP_NOEXCEPT {
			assert(size == sizeof(pair_type));
			if constexpr(std::is_trivially_copyable_v<pair_type>)
				return memswap(dest, src, size);
			else return std::swap(*(pair_type*)dest, *(pair_type*)src), dest;
		}

		static void _fp_finalize(fp_void_view view) FP_NOEXCEPT {
			assert(fp_view_size(view) == sizeof(pair_type));
			auto pair = (pair_type*)fp_view_data_void(view);
			pair->~pair_type();
		}
	public:
		static void initialize_empty_hash_map(hash_map& map, bool store_hashes = should_store_hashes_while_initializing<pair_type>::value){
			if(map.raw) fp_hash_map_free_and_finalize(pair_type, map.raw);
			map.raw = nullptr;

			fp_hash_map_create_empty_table(pair_type, map.raw, store_hashes);
			fp_hash_map_set_hash_function(map.raw,_fp_hash);
			fp_hash_map_set_equal_function(map.raw, _fp_equal);
			fp_hash_map_set_copy_function(map.raw, _fp_copy);
			fp_hash_map_set_swap_function(map.raw, _fp_swap);
			fp_hash_map_set_finalize_function(map.raw, _fp_finalize);
		}

		hash_map(bool store_hashes = should_store_hashes_while_initializing<pair_type>::value) {
			initialize_empty_hash_map(*this, store_hashes);
		}
		hash_map(const hash_map&) = default;
		hash_map(hash_map&&) = default;
		hash_map& operator=(const hash_map&) = default;
		hash_map& operator=(hash_map&&) = default;

		hash_map& rehash(bool store_hashes = should_store_hashes_while_initializing<pair_type>::value) {
			fp_hash_map_rehash(pair_type, this->raw, store_hashes);
			return *this;
		}
		hash_map& double_size_and_rehash(bool store_hashes = should_store_hashes_while_initializing<pair_type>::value) {
			fp_hash_map_double_size_and_rehash(pair_type, this->raw, store_hashes);
			return *this;
		}

		pair_type* insert(const pair_type& pair, bool store_hashes = false) {
			return fp_hash_map_insert_store_hashes(pair_type, this->raw, pair, store_hashes);
		}
		pair_type* insert_or_replace(const pair_type& pair) {
			return fp_hash_map_insert_or_replace(pair_type, this->raw, const_cast<pair_type&>(pair));
		}

		pair_type* insert(const Tkey& key) requires(!std::same_as<Tvalue, void>) {
			return insert_or_replace(pair_type{key, {}});
		}

		template<typename Tbegin, typename Tend>
		bool insert_range(Tbegin first, Tend last) {
			bool good = true;
			std::for_each(first, last, [this, &good](const pair_type& pair){
				good &= insert_or_replace(pair);
			});
			return good;
		}

#ifdef FP_ENABLE_STD_RANGES
		template<std::range Trange>
		bool insert_range(Trange range) {
			bool good = true;
			std::ranges::for_each(range, [this, &good](const pair_type& pair){
				good &= insert_or_replace(pair);
			});
			return good;
		}
#endif

		pair_type* find(const pair_type& pair, bool rehash = false) { // TODO: Do we want to introduce an optional type that can take references?
			if(rehash) this->rehash();
			return fp_hash_map_find(pair_type, this->raw, pair);
		}
		pair_type* find(const Tkey& key, bool rehash = false) requires(!std::same_as<Tvalue, void>) {
			return find(pair_type{key, {}}, rehash);
		}

		size_t find_index(const pair_type& pair, bool rehash = false) {
			if(rehash) this->rehash();
			return fp_hash_map_find_index(pair_type, this->raw, pair);
		}
		size_t find_index(const Tkey& key, bool rehash = false) requires(!std::same_as<Tvalue, void>) {
			return find_index(pair_type{key, {}}, rehash);
		}

		bool contains(const pair_type& pair, bool rehash = false) {
			if(rehash) this->rehash();
			return fp_hash_map_contains(pair_type, this->raw, pair);
		}
		bool contains(const Tkey& key, bool rehash = false) requires(!std::same_as<Tvalue, void>) {
			return contains(pair_type{key, {}}, rehash);
		}

		void free() {
			fp_hash_map_free_and_finalize(pair_type, this->raw);
		}
		void free_and_null() {
			fp_hash_map_free_finalize_and_null(pair_type, this->raw);
		}
	};

	template<typename Tkey, typename Hash = void, typename Equal = void>
	struct hash_set : public hash_map<Tkey, void, Hash, Equal> {

	};

	namespace raii {
		template<typename Tkey, typename Tvalue, typename Hash = void, typename Equal = void>
		struct hash_map: public fp::hash_map<Tkey, Tvalue, Hash, Equal> {
			using super = fp::hash_map<Tkey, Tvalue, Hash, Equal>;
			using super::super;
			hash_map& operator=(const hash_map& o) { if(super::raw) super::free(); super::raw = o.clone(); return *this;}
			hash_map& operator=(hash_map&& o) { if(super::raw) super::free(); super::raw = std::exchange(o.raw, nullptr); return *this; }
			~hash_map() { if(super::raw) super::free_and_null(); }
		};

		template<typename Tkey, typename Hash = void, typename Equal = void>
		struct hash_set : public hash_map<Tkey, void, Hash, Equal> {

		};
	}
}

#pragma once

#include "hash.h"
#include "dynarray.hpp"
#include "fnv1a.hpp"
#include <cstddef>
#include <functional>
#include <initializer_list>

namespace fp {
	template<typename T>
	struct hash_table: public dynarray<T> {
		using super = dynarray<T>;
		using super::super;
		using super::ptr;
		FP_HPP_DEFAULT_CONSTRUCTOR_BLOCK(hash_table, super);

	protected:
		static uint64_t hash_function(const fp_void_view view) noexcept {
			const T& v = *(T*)fp_view_data_void(view);
			return fnv1a<T>{}(v);
		}
		static bool equal_function(const fp_void_view a_, const fp_void_view b_) noexcept {
			const T& a = *(T*)fp_view_data_void(a_);
			const T& b = *(T*)fp_view_data_void(b_);
			return std::equal_to{}(a, b);
		}
		static void* copy_function(void* dest, const void* src, size_t size) noexcept {
			if constexpr(std::is_trivially_copyable_v<T>) {
				return std::memcpy(dest, src, size);
			} else {
				assert(size == sizeof(T));
				*(T*)dest = *(T*)src;
				return dest;
			}
		}
		static void* swap_function(void* a, void* b, size_t size) noexcept {
			if constexpr(std::is_trivially_copyable_v<T>) {
				return memswap(a, b, size);
			} else {
				assert(size == sizeof(T));
				std::swap(*(T*)a, *(T*)b);
				return a;
			}
		}
		static void finalize_function(fp_void_view view) noexcept {
			T& v = *(T*)fp_view_data_void(view);
			if constexpr(!std::is_trivially_destructible_v<T>) {
				v.~T();
			}
		}
	public:
		struct config {
			fp_hash_function_t hash_function = hash_table::hash_function;
			fpht_equal_function_t compare_function = hash_table::equal_function;
			fpht_copy_function_t copy_function = hash_table::copy_function;
			// fpht_swap_function_t swap_function = hash_table::swap_function;
			fpht_finalize_function_t finalize_function = hash_table::finalize_function;
			size_t base_size = FP_DEFAULT_HASH_TABLE_BASE_SIZE;
			size_t neighborhood_size = FP_DEFAULT_HASH_TABLE_NEIGHBORHOOD_SIZE;
			size_t max_fail_retries = FP_DEFAULT_HASH_TABLE_MAX_FAIL_RETRIES;
		};
		struct config_input: public config {
			using config::config;
			config_input(const config& c): config(c) {}
			config_input(const fp_hash_table_config& c) { memcpy(this, &c, sizeof(c)); }
			config_input(const config_input&) = default;
			config_input(config_input&&) = default;
			config_input& operator=(const config_input&) = default;
			config_input& operator=(config_input&&) = default;
			fp_hash_table_config c() const { return *(fp_hash_table_config*)this; }
		};

		hash_table(std::initializer_list<T> init) : hash_table(hash_table::create()) {
			for(auto& item: init)
				insert(item);
		}

		static hash_table create(const config_input config = {}) {
			return fp_create_hash_table(T, config.c());
		}

		static hash_table from_view(const view<T> view, const config_input config = {}) {
			return fp_create_hash_table_from_view(T, view, config.c());
		}

		static hash_table from_array(const pointer<T> array, const config_input config = {}) {
			return fp_create_hash_table_from_array(array, config.c());
		}

		bool is_hash_table() const {
			return is_fpht(ptr());
		}

		size_t rehash() {
			return fpht_rehash(ptr());
		}

		size_t double_size_and_rehash() {
			return fpht_double_size_and_rehash(ptr());
		}

		T& insert(const T& key, bool assume_unique = false) {
			if(assume_unique) return *fpht_insert_assume_unique(ptr(), key);
			else return *fpht_insert(ptr(), key);
		}

		size_t find_position(const T& key) const {
			return fpht_find_position(ptr(), key);
		}

		bool contains(const T& key) const {
			return fpht_contains(ptr(), key);
		}

		T* find(const T& key) {
			return fpht_find(ptr(), key);
		}
		const T* find(const T& key) const {
			return fpht_find(ptr(), key);
		}

		hash_table& remove_at_position(size_t position) {
			fpht_remove_at_position(ptr(), position);
			return *this;
		}

		hash_table& remove(const T& key) {
			fpht_remove(ptr(), key);
			return *this;
		}

		size_t find_first_occupied_position(){
			return fpht_find_first_occupied_position(ptr());
		}

		T* find_first_occupied(){
			return fpht_find_first_occupied(ptr());
		}

		size_t find_last_occupied_position(){
			return fpht_find_last_occupied_position(ptr());
		}

		T* find_last_occupied (){
			return fpht_find_last_occupied(ptr());
		}

		size_t occupied_size() {
			return fpht_occupied_size(ptr());
		}

		hash_table& finalize() {
			fpht_finalize(ptr());
			return *this;
		}

		hash_table& clear() {
			fpht_clear(ptr());
			return *this;
		}

		inline void free(bool nullify = true) {
			fpht_free(ptr());
			if(nullify) ptr() = nullptr;
		}
		inline void free() const {
			fpht_free(ptr());
		}

		fp::auto_free<hash_table> auto_free() { return std::move(*this); }
	};

	template<typename Key, typename Value, typename Hash = void, typename Equals = void>
	struct hash_map: public hash_table<std::pair<Key, Value>> {
		using super = hash_table<std::pair<Key, Value>>;
		using pair = std::pair<Key, Value>;
		FP_HPP_DEFAULT_CONSTRUCTOR_BLOCK(hash_map, super);
	protected:
		static uint64_t hash_function(const fp_void_view view) noexcept {
			const pair& p = *(pair*)fp_view_data_void(view);
			if constexpr(std::is_same_v<Hash, void>) {
				return fnv1a<Key>{}(p.first);
			} else {
				return Hash{}(p.first);
			}
		}
		static bool equal_function(const fp_void_view a_, const fp_void_view b_) noexcept {
			const pair& a = *(pair*)fp_view_data_void(a_);
			const pair& b = *(pair*)fp_view_data_void(b_);
			if constexpr(std::is_same_v<Hash, void>) {
				return std::equal_to{}(a.first, b.first);
			} else {
				return Equals{}(a.first, b.first);
			}
		}
		static void* copy_function(void* dest, const void* src, size_t size) noexcept {
			if constexpr(std::is_trivially_copyable_v<pair>) {
				return std::memcpy(dest, src, size);
			} else {
				assert(size == sizeof(pair));
				*(pair*)dest = *(pair*)src;
				return dest;
			}
		}
		static void* swap_function(void* a, void* b, size_t size) noexcept {
			if constexpr(std::is_trivially_copyable_v<pair>) {
				return memswap(a, b, size);
			} else {
				assert(size == sizeof(pair));
				std::swap(*(pair*)a, *(pair*)b);
				return a;
			}
		}
		static void finalize_function(fp_void_view view) noexcept {
			pair& p = *(pair*)fp_view_data_void(view);
			if constexpr(!std::is_trivially_destructible_v<Key>) {
				p.first.~Key();
			}
			if constexpr(!std::is_trivially_destructible_v<Value>) {
				p.second.~Value();
			}
		}

		constexpr static fp_hash_table_config default_config {
			.hash_function = hash_function,
			.compare_function = equal_function,
			.copy_function = copy_function,
			// .swap_function = swap_function,
			.finalize_function = finalize_function
		};

	public:
		hash_map(
			size_t base_size = FP_DEFAULT_HASH_TABLE_BASE_SIZE,
			size_t neighborhood_size = FP_DEFAULT_HASH_TABLE_NEIGHBORHOOD_SIZE,
			size_t max_fail_retries = FP_DEFAULT_HASH_TABLE_MAX_FAIL_RETRIES
		): super(super::create([=]{
			auto config = default_config;
			config.base_size = base_size;
			config.neighborhood_size = neighborhood_size;
			config.max_fail_retries = max_fail_retries;
			return config;
		}())) {}
		hash_map(std::nullptr_t): hash_map() {}

		Value& insert(const Key& key, bool assume_unique = false) {
			auto& p = super::insert({key, {}}, assume_unique); // TODO: Leaks
			return p.second;
		}

		size_t find_position(const Key& key) const {
			return super::find_position({key, {}});
		}

		bool contains(const Key& key) const {
			return super::contains({key, {}});
		}

		Value* find(const Key& key) {
			auto p = super::find({key, {}});
			if(!p) return nullptr;
			return &p->second;
		}
		const Value* find(const Key& key) const {
			auto p = super::find({key, {}});
			if(!p) return nullptr;
			return &p->second;
		}

		Value& get_or_default(const Key& key, const Value& default_) {
			auto v = find(key);
			if(!v) return insert(key, true) = default_;
			return *v;
		}

		Value& operator[](const Key& key) {
			return insert(key, false);
		}
		const Value& operator[](const Key& key) const {
			auto v = find(key);
			assert(v);
			return *v;
		}

		fp::auto_free<hash_map> auto_free() { return std::move(*this); }
	};

	namespace raii {
		template<typename T>
		using hash_table = auto_free<hash_table<T>>;
		template<typename Key, typename Value, typename Hash = void, typename Equals = void>
		using hash_map = auto_free<hash_map<Key, Value, Hash, Equals>>;
	}
}

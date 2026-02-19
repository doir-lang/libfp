#ifndef __LIB_FAT_POINTER_HASH_TABLE_H__
#define __LIB_FAT_POINTER_HASH_TABLE_H__

#include "dynarray.h"

#ifdef __cplusplus
extern "C" {
#endif

#define fp_hashtable(type) fp_dynarray(type)

#ifndef FP_DEFAULT_HASH_FUNCTION
	#include "fnv1a.h"
	#define FP_DEFAULT_HASH_FUNCTION fp_fnv1a_hash_void
#endif
typedef uint64_t(*fp_hash_function_t)(const fp_void_view) FP_NOEXCEPT;

#ifndef FP_DEFAULT_HASH_TABLE_COMPARE_EQUAL_FUNCTION
#define FP_DEFAULT_HASH_TABLE_COMPARE_EQUAL_FUNCTION fp_view_equal
#endif
typedef bool(*fpht_equal_function_t)(const fp_void_view, const fp_void_view) FP_NOEXCEPT;

#ifndef FP_DEFAULT_HASH_TABLE_COPY_FUNCTION
inline static void* __fp_memcpy(void* dest, const void* src, size_t size) FP_NOEXCEPT {
	return memcpy(dest, src, size); // NOTE: This wrapper function is needed due to a mismatched noexcept specifier on clang
}
#define FP_DEFAULT_HASH_TABLE_COPY_FUNCTION __fp_memcpy
#endif
typedef void*(*fpht_copy_function_t)(void*, const void*, size_t) FP_NOEXCEPT;

// #ifndef FP_DEFAULT_HASH_TABLE_SWAP_FUNCTION
// #define FP_DEFAULT_HASH_TABLE_SWAP_FUNCTION memswap
// #endif
// typedef void*(*fpht_swap_function_t)(void*, void*, size_t) FP_NOEXCEPT;

#ifndef FP_DEFAULT_HASH_TABLE_FINALIZE_FUNCTION
#define FP_DEFAULT_HASH_TABLE_FINALIZE_FUNCTION NULL
#endif
typedef void(*fpht_finalize_function_t)(fp_void_view) FP_NOEXCEPT;

// #ifndef FP_DEFAULT_HASH_TABLE_MAX_LOAD_FACTOR
// #define FP_DEFAULT_HASH_TABLE_MAX_LOAD_FACTOR .95
// #endif

#ifndef FP_DEFAULT_HASH_TABLE_NEIGHBORHOOD_SIZE
#define FP_DEFAULT_HASH_TABLE_NEIGHBORHOOD_SIZE 8
#endif

#ifndef FP_DEFAULT_HASH_TABLE_BASE_SIZE
#define FP_DEFAULT_HASH_TABLE_BASE_SIZE FP_DEFAULT_HASH_TABLE_NEIGHBORHOOD_SIZE
#endif

#ifndef FP_DEFAULT_HASH_TABLE_MAX_FAIL_RETRIES
#define FP_DEFAULT_HASH_TABLE_MAX_FAIL_RETRIES FP_DEFAULT_HASH_TABLE_NEIGHBORHOOD_SIZE
#endif

struct fp_hash_table_config {
	fp_hash_function_t hash_function
#ifdef __cplusplus
		= FP_DEFAULT_HASH_FUNCTION
#endif
	;
	fpht_equal_function_t compare_function
#ifdef __cplusplus
		= FP_DEFAULT_HASH_TABLE_COMPARE_EQUAL_FUNCTION
#endif
	;
	fpht_copy_function_t copy_function
#ifdef __cplusplus
		= FP_DEFAULT_HASH_TABLE_COPY_FUNCTION
#endif
	;
// 		fpht_swap_function_t swap_function
// #ifdef __cplusplus
// 		= FP_DEFAULT_HASH_TABLE_SWAP_FUNCTION
// #endif
// 	;
	fpht_finalize_function_t finalize_function
#ifdef __cplusplus
		= FP_DEFAULT_HASH_TABLE_FINALIZE_FUNCTION
#endif
	;
	size_t base_size
#ifdef __cplusplus
		= FP_DEFAULT_HASH_TABLE_BASE_SIZE
#endif
	;
	size_t neighborhood_size
#ifdef __cplusplus
		= FP_DEFAULT_HASH_TABLE_NEIGHBORHOOD_SIZE
#endif
	;
	size_t max_fail_retries
#ifdef __cplusplus
		= FP_DEFAULT_HASH_TABLE_MAX_FAIL_RETRIES
#endif
	;
// 	float max_load_factor
// #ifdef __cplusplus
// 		= FP_DEFAULT_HASH_TABLE_MAX_LOAD_FACTOR
// #endif
// 	;
};

inline static struct fp_hash_table_config fpht_default_config() {
#ifdef __cplusplus
	return {};
#else
	return (struct fp_hash_table_config){
		FP_DEFAULT_HASH_FUNCTION,
		FP_DEFAULT_HASH_TABLE_COMPARE_EQUAL_FUNCTION,
		FP_DEFAULT_HASH_TABLE_COPY_FUNCTION,
		// FP_DEFAULT_HASH_TABLE_SWAP_FUNCTION,
		FP_DEFAULT_HASH_TABLE_FINALIZE_FUNCTION,
		FP_DEFAULT_HASH_TABLE_BASE_SIZE,
		FP_DEFAULT_HASH_TABLE_NEIGHBORHOOD_SIZE,
		FP_DEFAULT_HASH_TABLE_MAX_FAIL_RETRIES,
		// FP_DEFAULT_HASH_TABLE_MAX_LOAD_FACTOR,
	};
#endif
}

struct __FatHashTableHeader {
	size_t* entry_infos;
	const struct fp_hash_table_config config;
	struct __FatDynamicArrayHeader h;
};

#ifndef __cplusplus
	/// @brief Size of dynamic array header in bytes
	#define FP_HASH_TABLE_HEADER_SIZE sizeof(struct __FatHashTableHeader)
#else
	/// @brief Size of dynamic array header in bytes (C++ version)
	static constexpr size_t FP_HASH_TABLE_HEADER_SIZE = sizeof(__FatHashTableHeader) - detail::completed_sizeof_v<decltype(__FatPointerHeader{}.data)>;
#endif

inline static bool is_fpht(const void* table) FP_NOEXCEPT {
	return __fpda_header(table)->h.magic == FP_HASH_TABLE_MAGIC_NUMBER;
}

inline static struct __FatHashTableHeader* __fpht_header(const void* table) FP_NOEXCEPT {
	assert(is_fpht(table));

	uint8_t* p = (uint8_t*)table;
	p -= FP_HASH_TABLE_HEADER_SIZE;
	return (struct __FatHashTableHeader*)p;
}
inline static const struct fp_hash_table_config* __fp_hash_table_config(const void* table) FP_NOEXCEPT {
	return &__fpht_header(table)->config;
}

inline static size_t* __fpht_entry_info(const void* table, size_t index) FP_NOEXCEPT {
	assert(index < fpda_size(__fpht_header(table)->entry_infos));
	return __fpht_header(table)->entry_infos + index;
}

inline static bool __fpht_entry_occupied(const void* table, size_t index) FP_NOEXCEPT {
	return *__fpht_entry_info(table, index) & (1 << 31);
}

inline static void __fpht_entry_set_occupied(const void* table, size_t index, bool state) FP_NOEXCEPT {
	assert(index < fpda_size(table));
	if(state) *__fpht_entry_info(table, index) |= (1 << 31);
	else *__fpht_entry_info(table, index) &= ~(1 << 31);
}

inline static size_t __fpht_hash(const void* table, const fp_void_view key) {
#ifndef FP_HASH_TABLE_STATIC_HASH_FUNCTION
	auto config = __fp_hash_table_config(table);
	return config->hash_function(key) % fpda_size(table);
#else
	return FP_DEFAULT_HASH_FUNCTION(key) % fpda_size(table);
#endif
}

inline static bool __fpht_compare_equal(const void* table, const fp_void_view a, const fp_void_view b) {
#ifndef FP_HASH_TABLE_STATIC_COMPARE_EQUAL_FUNCTION
	auto config = __fp_hash_table_config(table);
	return config->compare_function(a, b);
#else
	return FP_DEFAULT_HASH_TABLE_COMPARE_EQUAL_FUNCTION(a, b);
#endif
}

inline static void* __fpht_copy(const void* table, void* dest, const void* src, size_t size) {
#ifndef FP_HASH_TABLE_STATIC_COPY_FUNCTION
	auto config = __fp_hash_table_config(table);
	return config->copy_function(dest, src, size);
#else
	return FP_DEFAULT_HASH_TABLE_COPY_FUNCTION(dest, src, size);
#endif
}

// inline static void* __fpht_swap(const void* table, void* a, void* b, size_t size) {
// #ifndef FP_HASH_TABLE_STATIC_SWAP_FUNCTION
// 	auto config = __fp_hash_table_config(table);
// 	return config->swap_function(a, b, size);
// #else
// 	return FP_DEFAULT_HASH_TABLE_SWAP_FUNCTION(a, b, size);
// #endif
// }

inline static void __fpht_finalize(const void* table, fp_void_view what) {
#ifndef FP_HASH_TABLE_STATIC_FINALIZE_FUNCTION
	auto config = __fp_hash_table_config(table);
	if(config->finalize_function != NULL)
		config->finalize_function(what);
#else
	const fpht_finalize_function_t finalize = FP_DEFAULT_HASH_TABLE_FINALIZE_FUNCTION;
	if(finalize != NULL)
		finalize(what);
#endif
}

// Accessor macros for hash table
#define __FPHT_GET_CAPACITY(H) ((H)->h.capacity)
#define __FPHT_SET_CAPACITY(H, v) ((H)->h.capacity = (v))
#define __FPHT_GET_SIZE(H) ((H)->h.h.size)
#define __FPHT_SET_SIZE(H, v) ((H)->h.h.size = (v))
#define __FPHT_GET_DATA(H) ((H)->h.h.data)
#define __FPHT_COPY_EXTRA(newH, oldH) do {                                 \
	(newH)->entry_infos = (oldH)->entry_infos;                             \
	memcpy((void*)&(newH)->config, &(oldH)->config, sizeof(struct fp_hash_table_config)); \
} while(0)

inline static void* __fpht_maybe_grow(void** da, size_t type_size, size_t new_size, bool update_utilized, bool exact_sizing) FP_NOEXCEPT {
	void* tmp;
#define __fpht_malloc_impl(size) (tmp = __fpda_malloc(size, FP_HASH_TABLE_HEADER_SIZE - FPDA_HEADER_SIZE), __fpda_header(tmp)->h.magic = FP_HASH_TABLE_MAGIC_NUMBER, tmp)
#define __fpht_free_impl(da) __fp_alloc(__fpht_header(da), 0)
	__FP_MAYBE_GROW_IMPL(da, type_size, new_size, update_utilized, exact_sizing,
						__fpht_malloc_impl, __fpht_free_impl, __fpht_header, is_fpht,
						__FPHT_GET_CAPACITY, __FPHT_SET_CAPACITY,
						__FPHT_GET_SIZE, __FPHT_SET_SIZE,
						__FPHT_GET_DATA, __FPHT_COPY_EXTRA);
#undef __fpht_free_impl
#undef __fpht_malloc_impl
}

void* __fp_create_hash_table(size_t type_size, const struct fp_hash_table_config config)
#ifdef FP_IMPLEMENTATION
{
	void* out = __fpda_malloc(type_size * config.base_size, FP_HASH_TABLE_HEADER_SIZE - FPDA_HEADER_SIZE);
	__fpda_header(out)->h.magic = FP_HASH_TABLE_MAGIC_NUMBER;

	auto h = __fpht_header(out);
	h->h.capacity = config.base_size;
	h->h.h.size = config.base_size;
	memcpy((void*)&h->config, &config, sizeof(struct fp_hash_table_config));

	h->entry_infos = nullptr;
	fpda_grow_to_size_and_initialize(h->entry_infos, config.base_size, 0);

	return out;
}
#else
;
#endif

#define fp_create_hash_table(type, config) (type*)__fp_create_hash_table(sizeof(type), config)
#define fp_create_default_hash_table(type) fp_create_hash_table(type, fpht_default_config())

inline static size_t __fpht_double_size_and_rehash(void** table, size_t type_size, size_t failures);

inline static size_t __fpht_find_empty_hash_position(const void* table, size_t hash) {
	auto config = __fp_hash_table_config(table);
	for(size_t i = 0; i < config->neighborhood_size; ++i) {
		size_t probe = (hash + i) % fpda_size(table);
		if(!__fpht_entry_occupied(table, probe))
			return probe;
	}
	return fp_not_found;
}

inline static size_t __fpht_hash_distance(const void* table, size_t hash, size_t position) {
	size_t size = fpda_size(table);
	if(position < hash)
		return size - hash + position;
	else return position - hash;
}

inline static void* __fpht_insert(void** table, const fp_void_view key, size_t failures) {
	auto config = __fp_hash_table_config(*table);
	size_t hash = __fpht_hash(*table, key);
	size_t position = __fpht_find_empty_hash_position(*table, hash);
	if(position == fp_not_found && failures < config->max_fail_retries) {
		if(!__fpht_double_size_and_rehash(table, fp_view_size(key), failures + 1))
			return NULL;
		return __fpht_insert(table, key, failures + 1);
	} else if(position == fp_not_found)
		return NULL;

	auto tableP = (uint8_t*)*table;
	__fpht_copy(*table, tableP + fp_view_size(key) * position, fp_view_data_void(key), fp_view_size(key));
	// Mark position as belonging to hash and as being occupied
	*__fpht_entry_info(*table, hash) |= (1 << __fpht_hash_distance(table, hash, position));
	__fpht_entry_set_occupied(*table, position, true);

	return tableP + fp_view_size(key) * position;
}

#define __fpht_validate_table_and_key(table, key) assert(sizeof(*table) == sizeof(key))
#define fpht_insert_assume_unique(table, key) (__fpht_validate_table_and_key(table, key), (FP_TYPE_OF_REMOVE_POINTER(table)*)__fpht_insert((void**)&table, fp_void_view_literal(&(key), sizeof(key)), 0))

inline static size_t __fpht_rehash(void** table, size_t type_size, size_t failures) {
	size_t size = fpda_size(*table);
	{ // Confirm that if we have manually added or removed entries that there are enough entry infos to store their metadata
		size_t entries_size = fpda_size(__fpht_header(*table)->entry_infos);
		if(entries_size < size)
			fpda_grow_and_initialize(__fpht_header(*table)->entry_infos, size - entries_size, 0);
	}
	uint8_t* scratch = fp_alloca(uint8_t, type_size);
	auto tableP = (uint8_t*)*table;

	for(size_t i = 0; i < size; ++i) {
		bool occupied = __fpht_entry_occupied(*table, i);
		*__fpht_entry_info(*table, i) = 0; // Clear hash metadata and mark unoccupied
		if(!occupied) continue;

		__fpht_copy(*table, scratch, tableP + i * type_size, type_size);
		if(!__fpht_insert(table, fp_void_view_literal(scratch, type_size), failures))
			return i;
		tableP = (uint8_t*)*table;  // re-read in case of realloc
	}
	return fp_not_found;
}

#define fpht_rehash(table) __fpht_rehash((void**)&table, sizeof(*table), 0)

inline static size_t __fpht_double_size_and_rehash(void** table, size_t type_size, size_t failures) {
	size_t size = fpda_size(*table), new_size = size * 2;
	// TODO: Will this function work... since the header allocation sizes are off?
	__fpht_maybe_grow(table, type_size, new_size, true, true);
	fpda_grow_and_initialize(__fpht_header(*table)->entry_infos, size, 0);

	auto tableP = (uint8_t*)*table;
	for(size_t i = 0; i < size; ++i)
		if(i % 2 == 1) {
			// Copy every other cell to the blank half of the table and null their original memory
			__fpht_copy(*table, tableP + (new_size - i) * type_size, tableP + i * type_size, type_size);
			memset(tableP + i * type_size, 0, type_size);
			// Swap the entry info of the cells
			fpda_swap(__fpht_header(*table)->entry_infos, i, new_size - i);
		}

	return __fpht_rehash(table, type_size, failures);
}

#define fpht_double_size_and_rehash(table) __fpht_double_size_and_rehash((void**)&table, sizeof(*table), 0)

inline static size_t __fpht_find_position(const void* table, const fp_void_view key) FP_NOEXCEPT {
	auto config = __fp_hash_table_config(table);
	auto hash = __fpht_hash(table, key);
	auto hash_info = *__fpht_entry_info(table, hash);
	auto tableP = (uint8_t*)table;
	size_t type_size = fp_view_size(key);
	for(size_t i = 0; i < config->neighborhood_size; ++i) {
		if((hash_info & (1 << i)) == 0) continue;
		size_t probe = (hash + i) % fpda_size(table);
		if(!__fpht_entry_occupied(table, probe)) continue;
		if(__fpht_compare_equal(table, key, fp_void_view_literal(tableP + probe * type_size, type_size)))
			return probe;
	}
	return fp_not_found;
}

#define fpht_find_position(table, key) (__fpht_validate_table_and_key(table, key), __fpht_find_position(table, fp_void_view_literal(&(key), sizeof(key))))
#define fpht_find(table, key) (__fpda_global_concatenate_pointer = (void*)fpht_find_position(table, key), (size_t)__fpda_global_concatenate_pointer != fp_not_found ? table + (size_t)__fpda_global_concatenate_pointer : NULL)
#define fpht_contains(table, key) (fpht_find_position(table, key) != fp_not_found)

#define fpht_insert(table, key) (__fpda_global_concatenate_pointer = fpht_find(table, key),\
	__fpda_global_concatenate_pointer == NULL ? fpht_insert_assume_unique(table, key) : (FP_TYPE_OF_REMOVE_POINTER(table)*)__fpda_global_concatenate_pointer)

#define fpht_remove_at_position(table, position) __fpht_entry_set_occupied(table, position, false)
#define fpht_remove(table, key) (__fpda_global_concatenate_pointer = (void*)fpht_find_position(table, key),\
	(size_t)__fpda_global_concatenate_pointer == fp_not_found ? (void)0 : fpht_remove_at_position(table, (size_t)__fpda_global_concatenate_pointer))

inline static size_t fpht_find_first_occupied_position(const void* table) {
	for(size_t i = 0; i < fpda_size(table); ++i)
		if(__fpht_entry_occupied(table, i))
			return i;
	return fp_not_found;
}
#define fpht_find_first_occupied(table) (__fpda_global_concatenate_pointer = (void*)fpht_find_first_occupied_position(table), (size_t)__fpda_global_concatenate_pointer != fp_not_found ? table + (size_t)__fpda_global_concatenate_pointer : NULL)

inline static size_t fpht_find_last_occupied_position(const void* table) {
	for(size_t i = fpda_size(table); --i; )
		if(__fpht_entry_occupied(table, i))
			return i;
	return fp_not_found;
}
#define fpht_find_last_occupied(table) (__fpda_global_concatenate_pointer = (void*)fpht_find_last_occupied_position(table), (size_t)__fpda_global_concatenate_pointer != fp_not_found ? table + (size_t)__fpda_global_concatenate_pointer : NULL)

inline static size_t fpht_occupied_size(const void* table) {
	if(!table) return 0;

	size_t count = 0;
	for(size_t i = fpda_size(table); --i; )
		if(__fpht_entry_occupied(table, i))
			++count;
	return count;
}

void* __fp_create_hash_table_from_view(size_t type_size, fp_void_view view, const struct fp_hash_table_config config)
#ifdef FP_IMPLEMENTATION
{
	auto out = __fp_create_hash_table(type_size, config);
	auto p = (uint8_t*)fp_view_data_void(view);
	for(size_t i = 0; i < fp_view_size(view); ++i)
		__fpht_insert(&out, fp_void_view_literal(p + i * type_size, type_size), 0);
	return out;
}
#else
;
#endif

#define fp_create_hash_table_from_view(type, view, config) ((type*)__fp_create_hash_table_from_view(sizeof(type), (fp_void_view)view, config))
#define fp_create_default_hash_table_from_view(type, view) fp_create_hash_table_from_view(type, view, fpht_default_config())
#define fp_create_hash_table_from_array(a, config) fp_create_hash_table_from_view(FP_TYPE_OF_REMOVE_POINTER(a), fp_view_make_full(FP_TYPE_OF_REMOVE_POINTER(a), a), config)
#define fp_create_default_hash_table_from_array(a) fp_create_hash_table_from_array(a, fpht_default_config())

inline static void __fpht_finalize_all(void** table, size_t type_size) {
	auto tableP = (uint8_t*)*table;
	for(size_t i = 0; i < fp_size(*table); ++i)
		if(__fpht_entry_occupied(*table, i))
			__fpht_finalize(*table, fp_void_view_literal(tableP + i * type_size, type_size));
}

#define fpht_finalize(table) __fpht_finalize_all((void**)&table, sizeof(*table))
#define fpht_clear(table) (fpht_finalize(table), fpda_clear(table))

inline static void __fpht_free(void** table, size_t type_size) {
	__fpht_finalize_all(table, type_size);
	fpda_free_and_null(__fpht_header(*table)->entry_infos);
	__fp_alloc(__fpht_header(*table), 0);
}
#define fpht_free(table) __fpht_free((void**)&table, sizeof(*table))
#define fpht_free_and_null(table) (fpht_free(table), table = NULL)

#ifdef __cplusplus
} // extern "C"
#endif

#endif // __LIB_FAT_POINTER_HASH_TABLE_H__

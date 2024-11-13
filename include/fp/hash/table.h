#ifndef __LIB_FAT_POINTER_HASH_TABLE_H__
#define __LIB_FAT_POINTER_HASH_TABLE_H__

#include "../dynarray.h"

#ifdef __cplusplus
extern "C" {
#endif

#define fp_hashtable(type) fp_dynarray(type)

#ifndef FP_HASH_FUNCTION // Defaults to FNV-1a
	inline static uint64_t __fp_hash_default(const fp_void_view view) FP_NOEXCEPT {
		constexpr uint64_t FNV_OFFSET_BASIS = 14695981039346656037u;
		constexpr uint64_t FNV_PRIME = 1099511628211u;

		uint64_t hash = FNV_OFFSET_BASIS;
		for(size_t i = fp_view_size(view); i--; ) {
			hash ^= (uint64_t)fp_view_data(char, view)[i];
			hash *= FNV_PRIME;
		}
		return hash;
	}
	#define FP_HASH_FUNCTION __fp_hash_default
#endif

#ifndef FP_HASH_COMPARE_EQUAL_FUNCTION
#define FP_HASH_COMPARE_EQUAL_FUNCTION fp_view_equal
#endif

#ifndef FP_HASH_COPY_FUNCTION
#define FP_HASH_COPY_FUNCTION memcpy
#endif

#ifndef FP_HASH_SWAP_FUNCTION
#define FP_HASH_SWAP_FUNCTION memswap
#endif

#ifndef FP_HASH_FINALIZE_FUNCTION
#define FP_HASH_FINALIZE_FUNCTION NULL
#endif

#ifndef FP_HASH_MAX_LOAD_FACTOR
#define FP_HASH_MAX_LOAD_FACTOR .95
#endif

#ifndef FP_HASH_NEIGHBORHOOD_SIZE
#define FP_HASH_NEIGHBORHOOD_SIZE 8
#endif

#ifndef FP_HASH_MAX_FAIL_RETRIES
#define FP_HASH_MAX_FAIL_RETRIES 5
#endif



struct __FatHashTableHeader { // The header itself is a fpda of u32s storing hop_info, the first 1 or 2 ptrsizes of which store hashes and hashers
	fp_dynarray(size_t) hashes;
#ifndef __cplusplus
	uint32_t hop_infos[];
#else
	uint32_t hop_infos[1];
#endif
};

inline static struct __FatHashTableHeader* __fp_hash_header(void* table) FP_NOEXCEPT {
	return (struct __FatHashTableHeader*)*(void**)table; // The first ptrsize bytes of the table is a pointer to the hash header
}

inline static bool is_fp_hash(void* table) FP_NOEXCEPT { return fp_magic_number(table) == FP_HASH_MAGIC_NUMBER; }
#define is_fp_hashtable is_fp_hash



inline static int16_t __fp_hash_elements_to_skip(size_t type_size) FP_NOEXCEPT {
	size_t pointersInType = sizeof(void*) / type_size;
	if(pointersInType < 1) pointersInType = 1;
	return pointersInType;
}
/**
* @brief How many bytes from the front of the table to skip when iterating over the table
* @param type Type of the table in question
*/
#define fp_hash_elements_to_skip(type) __fp_hash_elements_to_skip(sizeof(type))

/**
* @brief How many bytes from the front of the table to skip when iterating over the table's hop infos
*/
inline static int16_t fp_hash_infos_to_skip() FP_NOEXCEPT {
	size_t pointersInU32 = sizeof(void*) / sizeof(uint32_t);
	if(pointersInU32 < 1) pointersInU32 = 1;
	return pointersInU32;
}

// Offset from indecies into the elements array to indecies into the infos array // TODO: Is this always zero?
#define FP_HASH_ELEM2INFO_OFFSET(type_size) (-__fp_hash_elements_to_skip(type_size) + fp_hash_infos_to_skip())
#define FP_HASH_ELEM2HASH_OFFSET(type_size) (-__fp_hash_elements_to_skip(type_size))

// TODO: Are there any invariants we have that allow us to assume that we can just shift? instead of modulo?
inline static size_t __fp_hash_element_modulo(void* table, size_t n, size_t type_size) FP_NOEXCEPT {
	return __fp_hash_elements_to_skip(type_size) + n % (fpda_size(table) - __fp_hash_elements_to_skip(type_size));
}



inline static uint32_t* __fp_hash_entry_hop_info(void* table, size_t index) FP_NOEXCEPT {
	assert(is_fp_hash(table));
	assert(__fp_hash_header(table)->hop_infos != NULL);
	assert(fpda_size(__fp_hash_header(table)) > index);
	return ((uint32_t*)__fp_hash_header(table)) + index;
}

inline static bool __fp_hash_entry_is_occupied(void* table, size_t index) FP_NOEXCEPT {
	return *__fp_hash_entry_hop_info(table, index) & (1 << 31);
}

inline static void __fp_hash_entry_set_occupied(void* table, size_t index, bool value) FP_NOEXCEPT {
	if(value) *__fp_hash_entry_hop_info(table, index) |= (1 << 31);
	else *__fp_hash_entry_hop_info(table, index) &= ~(1 << 31);
}

inline static size_t* __fp_hash_entry_hash(void* table, size_t index) FP_NOEXCEPT {
	assert(is_fp_hash(table));
	assert(__fp_hash_header(table)->hashes != NULL);
	assert(fpda_size(__fp_hash_header(table)->hashes) > index);
	return __fp_hash_header(table)->hashes + index;
}

inline static void __fp_hash_free(void* table, size_t type_size) FP_NOEXCEPT {
	auto h = __fp_hash_header(table);

	// We need to be sure to free all of the allocated side structures!
	if(h->hashes) fpda_free(h->hashes);
	fpda_free(h);
	fpda_free(table);
}
#define fp_hash_free(table) __fp_hash_free(table, 0)
#define fp_hash_free_and_null(table) (fp_hash_free(table), table = NULL)
#define fp_hash_free_and_finalize(type, table) __fp_hash_free(table, sizeof(type))
#define fp_hash_free_finalize_and_null(type, table) (fp_hash_free_and_finalize(type, table), table = NULL)



size_t __fp_hash(void* table, fp_void_view key, size_t type_size) FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	assert(fp_view_size(key) == type_size);
	return __fp_hash_element_modulo(table, FP_HASH_FUNCTION(key), type_size);
}
#else
;
#endif
/**
* @brief Function which hashes a variable
* @note By default uses FNV-1a hash algorithm
* @param type type of both the values stored in the hash table, and this specific key
* @param table the table to produce a hash for (the returned hash will be modulo the size of this table)
* @param key variable to hash
*/
#define fp_hash(type, table, key) __fp_hash(table, fp_variable_to_void_view(type, key), sizeof(type))

inline static bool __fp_hash_compare_equal(void* table, fp_void_view a, fp_void_view b) FP_NOEXCEPT {
	assert(fp_view_size(a) == fp_view_size(b));
	return FP_HASH_COMPARE_EQUAL_FUNCTION(a, b);
}

inline static bool __fp_hash_copy(void* table, void* a, void* b, size_t n) FP_NOEXCEPT {
	return FP_HASH_COPY_FUNCTION(a, b, n);
}

inline static bool __fp_hash_swap(void* table, void* a, void* b, size_t n) FP_NOEXCEPT {
	return FP_HASH_SWAP_FUNCTION(a, b, n);
}

inline static size_t __fp_hash_invalid_position() FP_NOEXCEPT { return -1; }

inline static size_t __fp_hash_find_position(void* table, const void* _key, size_t type_size) FP_NOEXCEPT {
	int16_t infoOffset = FP_HASH_ELEM2INFO_OFFSET(type_size);
	int16_t hashOffset = FP_HASH_ELEM2HASH_OFFSET(type_size);
	assert(table); assert(!fp_empty(table));

	auto key = fp_void_view_literal(_key, type_size);
	size_t* hashes = __fp_hash_header(table)->hashes;
	size_t hash = __fp_hash(table, key, type_size);
	for(size_t i = 0; i <= FP_HASH_NEIGHBORHOOD_SIZE; ++i) {
		size_t probe = __fp_hash_element_modulo(table, hash + i, type_size);
		char* probeP = ((char*)table) + probe * type_size;
		bool occupied = __fp_hash_entry_is_occupied(table, probe + infoOffset);
		if(hashes) if(!occupied || *__fp_hash_entry_hash(table, probe + hashOffset) != hash) continue;
		if(occupied && __fp_hash_compare_equal(table, key, fp_void_view_literal(probeP, type_size)))
			return probe;
	}
	return __fp_hash_invalid_position();
}

inline static size_t __fp_hash_find_empty_spot(void* table, size_t start, size_t type_size) FP_NOEXCEPT {
	int16_t infoOffset = FP_HASH_ELEM2INFO_OFFSET(type_size);
	int16_t hashOffset = FP_HASH_ELEM2HASH_OFFSET(type_size);
	if(!table || fp_empty(table)) return __fp_hash_invalid_position(); // Needed because this function gets called at the start of insert to indicate that we should rehash!

	for(size_t i = 0; i < FP_HASH_NEIGHBORHOOD_SIZE; ++i) {
		size_t probe = __fp_hash_element_modulo(table, start + i, type_size);
		if(!__fp_hash_entry_is_occupied(table, probe + infoOffset))
			return probe;
	}
	return __fp_hash_invalid_position();
}

inline static size_t __fp_hash_find_nearest_neighbor(void* table, size_t start, size_t type_size) FP_NOEXCEPT {
	int16_t infoOffset = FP_HASH_ELEM2INFO_OFFSET(type_size);
	int16_t hashOffset = FP_HASH_ELEM2HASH_OFFSET(type_size);
	assert(table); assert(!fp_empty(table));

	for(size_t i = 0; i < FP_HASH_NEIGHBORHOOD_SIZE; ++i) {
		size_t probe = __fp_hash_element_modulo(table, start + i, type_size);
		if((*__fp_hash_entry_hop_info(table, probe + infoOffset) & (1 << i)) && !__fp_hash_entry_is_occupied(table, probe + infoOffset))
			return probe;
	}
	return __fp_hash_invalid_position();
}

inline static bool __fp_hash_is_in_neighborhood(void* table, size_t start, size_t needle, size_t type_size) FP_NOEXCEPT {
	int16_t infoOffset = FP_HASH_ELEM2INFO_OFFSET(type_size);
	int16_t hashOffset = FP_HASH_ELEM2HASH_OFFSET(type_size);
	assert(table); assert(!fp_empty(table));

	if(FP_HASH_NEIGHBORHOOD_SIZE > fpda_size(table)) return true;
	size_t end = __fp_hash_element_modulo(table, start + FP_HASH_NEIGHBORHOOD_SIZE, type_size);
	if(start <= end)
		return start <= needle && needle <= end;
	else // The neighborhood range wraps around the end of the table
		return start <= needle || needle <= end;
}

// This function requires a linear scan over all the cells to determine how many are occupied
inline static size_t __fp_hash_size(void* table, size_t type_size) FP_NOEXCEPT {
	int16_t infoOffset = FP_HASH_ELEM2INFO_OFFSET(type_size);
	int16_t hashOffset = FP_HASH_ELEM2HASH_OFFSET(type_size);
	assert(table); assert(!fp_empty(table));

	size_t sum = 0;
	for(size_t i = __fp_hash_elements_to_skip(type_size), size = fpda_size(table); i < size; ++i)
		if(__fp_hash_entry_is_occupied(table, i + infoOffset))
			++sum;
	return sum;
}
#define fp_hash_size(type, table) __fp_hash_size(table, sizeof(type))

void __fp_hash_ensure_extra_information_size(void* table, size_t new_size, bool store_hashes_while_initializing, bool initializing) FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	struct __FatHashTableHeader* h = __fp_hash_header(table);
	uint32_t* hops = nullptr;
	fpda_grow_to_size_and_initialize(hops, new_size + fp_hash_infos_to_skip(), 0);
	if(!initializing) {
		memcpy(hops, h, fpda_size(h) * sizeof(uint32_t));
		fpda_free(h);
	}
	*(uint32_t**)table = hops;

	h = __fp_hash_header(table);
	if(initializing) h->hashes = nullptr;
	if(store_hashes_while_initializing || h->hashes) fpda_grow_to_size(h->hashes, new_size);
}
#else
;
#endif
#define fp_hash_ensure_extra_information_size(table, new_size, store_hashes_while_initializing) __fp_hash_ensure_extra_information_size((table), (new_size), (store_hashes_while_initializing))

void __fp_hash_double_size(void** table, bool store_hashes_while_initializing, size_t type_size) FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	size_t size = fpda_size(*table);
	if(size > 0) size -= __fp_hash_elements_to_skip(type_size);

	size_t newSize = size * 2;
	bool initalizing = newSize == 0;
	// if(newSize < 2) newSize = 2;
	if(newSize < FP_HASH_NEIGHBORHOOD_SIZE) newSize = FP_HASH_NEIGHBORHOOD_SIZE;

	char* p = (char*)*table;
	__fpda_maybe_grow((void**)&p, type_size, newSize + __fp_hash_elements_to_skip(type_size), true, true);
	// fpda_grow_to_size(p, (newSize + __fp_hash_elements_to_skip(type_size)) * type_size);
	{
		auto h = __fpda_header(p);
		// h->capacity /= type_size;
		h->h.size = newSize + __fp_hash_elements_to_skip(type_size);
		h->h.magic = FP_HASH_MAGIC_NUMBER;
	}
	*table = p;

	__fp_hash_ensure_extra_information_size(*table, newSize, store_hashes_while_initializing, initalizing);
}
#else
;
#endif
#define fp_hash_create_empty_table(type, table, store_hashes_while_initializing) __fp_hash_double_size((void**)&table, store_hashes_while_initializing, sizeof(type))


inline static bool __fp_hash_double_size_and_rehash(void** table, bool store_hashes_while_initializing, size_t retries /*= 0*/, size_t type_size) FP_NOEXCEPT;

bool __fp_hash_rehash(void** table, bool store_hashes_while_initializing, size_t retries /*= 0*/, bool resized /*= false*/, size_t type_size) FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	int16_t infoOffset = FP_HASH_ELEM2INFO_OFFSET(type_size);
	int16_t hashOffset = FP_HASH_ELEM2HASH_OFFSET(type_size);
	assert(*table);

	// Clear the neighborhood information
	size_t size = fpda_size(*table), half = size / 2;
	char* tableC = (char*)*table;
	for(size_t i = __fp_hash_elements_to_skip(type_size); i < size; ++i) {
		bool occupied = __fp_hash_entry_is_occupied(*table, i + infoOffset);
		*__fp_hash_entry_hop_info(*table, i + infoOffset) = 0;
		if(resized && occupied && i < half && (i % 2) == 1) { // Distribute every other element to the second half of the newly resized space
			// if(!Base::swap(scene, i, size - i, true)) return false;
			__fp_hash_swap(*table, tableC + i * type_size, tableC + (size - i) * type_size, type_size);
			__fp_hash_entry_set_occupied(*table, i + infoOffset, false);
			__fp_hash_entry_set_occupied(*table, size - i + infoOffset, occupied);
		} else __fp_hash_entry_set_occupied(*table, i + infoOffset, occupied);
	}

	// Traverse through the old table and "reinsert" elements into the table
	size_t* hashes = __fp_hash_header(*table)->hashes;
	for(size_t i = __fp_hash_elements_to_skip(type_size); i < size; ++i) {
		if(__fp_hash_entry_is_occupied(*table, i + infoOffset)) {
			fp_void_view key = fp_void_view_literal(tableC + i * type_size, type_size);
			size_t hash = __fp_hash(*table, key, type_size);

			// If the value is already in the correct neighborhood... no need to move around just mark as present
			if(__fp_hash_is_in_neighborhood(*table, hash, i, type_size)) {
				if (hashes) *__fp_hash_entry_hash(*table, i + hashOffset) = hash;
				size_t distance = i > hash ? i - hash : size - __fp_hash_elements_to_skip(type_size) - __fp_hash_element_modulo(table, hash - i, type_size);
				*__fp_hash_entry_hop_info(*table, hash + infoOffset) |= (1 << distance);
				continue;
			}

			// Find an empty spot in the new table starting from the new hash value
			auto emptyIndex = __fp_hash_find_empty_spot(*table, hash, type_size);
			if(emptyIndex == __fp_hash_invalid_position()) {
				if(retries >= FP_HASH_MAX_FAIL_RETRIES) return false;
				return __fp_hash_double_size_and_rehash(table, store_hashes_while_initializing, retries + 1, type_size); // TODO: We can probably use a better strategy than "resize and try again"
			}

			// Move the element to its new position in the table
			uint32_t* hopInfoIP = __fp_hash_entry_hop_info(*table, i + infoOffset), *hopInfoEmptyP = __fp_hash_entry_hop_info(*table, emptyIndex + infoOffset);
			uint32_t hopInfoI = *hopInfoIP, hopInfoEmpty = *hopInfoEmptyP;
			// if(!Base::swap(scene, *emptyIndex, i, true)) return false;
			__fp_hash_swap(*table, tableC + emptyIndex * type_size, tableC + i * type_size, type_size);
			*hopInfoIP = hopInfoI;
			__fp_hash_entry_set_occupied(*table, i + infoOffset, false);
			*hopInfoEmptyP = hopInfoEmpty;
			__fp_hash_entry_set_occupied(*table, emptyIndex + infoOffset, true);

			// Mark it as present in the element it hashes to
			size_t distance = emptyIndex > hash ? emptyIndex - hash : size - __fp_hash_elements_to_skip(type_size) - __fp_hash_element_modulo(table, hash - emptyIndex, type_size);
			*hopInfoIP |= (1 << distance);
		}
	}
	return true;
}
#else
;
#endif
#define fp_hash_rehash(type, table, store_hashes_while_initializing) __fp_hash_double_size_and_rehash((void**)&table, store_hashes_while_initializing, 0, false, sizeof(type))

inline static bool __fp_hash_double_size_and_rehash(void** table, bool store_hashes_while_initializing, size_t retries /*= 0*/, size_t type_size) FP_NOEXCEPT {
	__fp_hash_double_size(table, store_hashes_while_initializing, type_size);
	return __fp_hash_rehash(table, store_hashes_while_initializing, retries, true, type_size);
}
#define fp_hash_double_size_and_rehash(type, table, store_hashes_while_initializing) __fp_hash_double_size_and_rehash((void**)&table, store_hashes_while_initializing, 0, sizeof(type))

inline static void* __fp_hash_insert(void** table, void* key, bool store_hashes_while_initializing, size_t type_size, size_t retries /*= 0*/) {
	int16_t infoOffset = FP_HASH_ELEM2INFO_OFFSET(type_size);
	int16_t hashOffset = FP_HASH_ELEM2HASH_OFFSET(type_size);
	size_t hash = *table ? __fp_hash(*table, fp_void_view_literal(key, type_size), type_size) : 0;

	auto emptyIndex = __fp_hash_find_empty_spot(*table, hash, type_size);
	if(emptyIndex == __fp_hash_invalid_position()) {
		if(retries >= FP_HASH_MAX_FAIL_RETRIES) return nullptr;
		if(!__fp_hash_double_size_and_rehash(table, store_hashes_while_initializing, retries, type_size)) return nullptr;
		return __fp_hash_insert(table, key, store_hashes_while_initializing, type_size, retries + 1);
	}

	void* result = ((char*)*table) + emptyIndex * type_size;
	__fp_hash_copy(*table, result, key, type_size);
	__fp_hash_entry_set_occupied(*table, emptyIndex + infoOffset, true);

	size_t* hashes = __fp_hash_header(*table)->hashes;
	if(hashes) hashes[emptyIndex + hashOffset] = hash;

	size_t distance = emptyIndex > hash ? emptyIndex - hash : fpda_size(*table) - __fp_hash_elements_to_skip(type_size) - __fp_hash_element_modulo(table, hash - emptyIndex, type_size);
	*__fp_hash_entry_hop_info(*table, hash + infoOffset) |= (1 << distance);
	return result;
}
#define fp_hash_insert_store_hashes(type, table, key, store_hashes_while_initializing) ((type*)__fp_hash_insert((void**)&table, &key, (store_hashes_while_initializing), sizeof(type), 0))
#define fp_hash_insert(type, table, key) fp_hash_insert_store_hashes(type, table, key, false)

inline static void* __fp_hash_find(void* table, const void* key, size_t type_size) FP_NOEXCEPT {
	size_t index = __fp_hash_find_position(table, key, type_size);
	if(index == __fp_hash_invalid_position()) return NULL;
	return ((char*)table) + index * type_size;
}
#define fp_hash_find(type, table, key) ((type*)__fp_hash_find((table), &key, sizeof(type)))
#define fp_hash_find_index(type, table, key) ((size_t)(fp_hash_find(type, (table), key) - (table)))
#define fp_hash_contains(type, table, key) (__fp_hash_find((table), &key, sizeof(type)) != NULL)

inline static void* __fp_hash_rehash_and_find(void** table, const void* key, size_t type_size) FP_NOEXCEPT {
	if(!__fp_hash_rehash(table, false, 0, false, type_size)) return NULL;
	return __fp_hash_find(*table, key, type_size);
}
#define fp_hash_rehash_and_find(type, table, key) ((type*)__fp_hash_find((void**)&table, &key, sizeof(type)))
#define fp_hash_rehash_and_find_index(type, table, key) ((size_t)(fp_hash_find(type, table, key) - table))

inline static void* __fp_hash_insert_or_replace(void** table, void* key, size_t type_size) FP_NOEXCEPT {
	auto res = __fp_hash_find(*table, key, type_size);
	if(!res) res = __fp_hash_insert(table, key, false, type_size, 0);
	// By always copying, we allow for maps where we only compare/hash half the key, this updates the value half
	__fp_hash_copy(*table, res, key, type_size);
	return res;
}
#define fp_hash_insert_or_replace(type, table, key) ((type*)__fp_hash_insert_or_replace((void**)&table, &key, sizeof(type)))

inline static void* __fp_hash_convert_array(void* a, size_t starting_offset, bool store_hashes_while_initializing, bool free_original, bool type_size_considered_by_array, size_t type_size, void* table /*= nullptr*/) {
	if(!is_fp(a)) return nullptr;
	if(is_fp_hash(a)) return a; // TODO: Should we always rehash when you call this function?

	__fp_hash_double_size(&table, store_hashes_while_initializing, type_size);

	char* aStart = ((char*)a) + starting_offset * type_size;
	size_t size = fpda_size(a) * (type_size_considered_by_array ? 1 : type_size);
	for(size_t i = 0; i < size; i++)
		__fp_hash_insert(&table, aStart + i * type_size, store_hashes_while_initializing, type_size, 0); // TODO: Surely there is a better solution than just inserting every element!

	if(free_original && is_fpda(a)) fpda_free(a);
	else if(free_original && !fp_is_stack_allocated(a)) fp_free(a);
	return table;
}
#define fp_hash_convert_array_expert_with_existing(type, a, starting_offset, store_hashes_while_initializing, free_original, type_size_considered_by_array, existing_table)\
	((type*)__fp_hash_convert_array((a), (starting_offset), (store_hashes_while_initializing), (free_original), (type_size_considered_by_array), sizeof(type), (existing_table)))
#define fp_hash_convert_array_expert(type, a, starting_offset, store_hashes_while_initializing, free_original, type_size_considered_by_array)\
	fp_hash_convert_array_expert_with_existing(type, (a), (starting_offset), (store_hashes_while_initializing), (free_original), (type_size_considered_by_array), nullptr)
#define fp_hash_convert_array_with_existing(type, a, existing_table)\
	fp_hash_convert_array_expert_with_existing(type, (a), /*starting_offset*/0, /*store_hashes_while_initializing*/false, /*free_original*/false, /*type_size_considered_by_array*/true, (existing_table))
#define fp_hash_convert_array(type, a) fp_hash_convert_array_with_existing(type, (a), nullptr)

#ifdef __cplusplus
}
#endif

#endif // __LIB_FAT_POINTER_HASH_TABLE_H__
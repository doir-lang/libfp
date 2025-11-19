/** \addtogroup capi-dynarray
 *  @{
 */

/**
 * @file dynarray.h
 * @brief Dynamic array implementation with automatic growth and fat pointer integration
 *
 * This header provides a dynamic array (vector-like) implementation built on top of
 * the fat pointer library. Dynamic arrays automatically grow as needed, providing
 * amortized O(1) push operations while maintaining contiguous memory layout.
 *
 * Key features:
 * - Automatic capacity management with power-of-two growth
 * - Efficient insertion and deletion operations
 * - Compatible with fat pointer interface (size, iteration, etc.)
 * - View integration for efficient subarray operations
 *
 * @section example_basic Basic Dynarray Usage
 * @code
 * // Create empty dynamic array
 * fp_dynarray(int) arr = NULL;
 *
 * // Push elements (automatically grows)
 * fpda_push_back(arr, 10);
 * fpda_push_back(arr, 20);
 * fpda_push_back(arr, 30);
 *
 * printf("Size: %zu, Capacity: %zu\n", fpda_size(arr), fpda_capacity(arr));
 *
 * // Access elements
 * for(size_t i = 0; i < fpda_size(arr); i++)
 *     printf("%d ", arr[i]);
 *
 * fpda_free_and_null(arr);
 * @endcode
 *
 * @section example_operations Common Dynarray Operations
 * @code
 * fp_dynarray(int) numbers = NULL;
 *
 * // Reserve capacity
 * fpda_reserve(numbers, 100);
 *
 * // Add elements
 * for(int i = 0; i < 50; i++)
 *     fpda_push_back(numbers, i);
 *
 * // Insert in middle
 * fpda_insert(numbers, 25, 999);
 *
 * // Delete element
 * fpda_delete(numbers, 10);
 *
 * // Pop from back
 * fpda_pop_back(numbers);
 *
 * // Clear all elements (keeps capacity)
 * fpda_clear(numbers);
 *
 * fpda_free_and_null(numbers);
 * @endcode
 *
 * @section example_advanced Advanced Dynarray Features
 * @code
 * fp_dynarray(float) data = NULL;
 *
 * // Grow and initialize
 * fpda_grow_and_initialize(data, 10, 3.14f);
 *
 * // Swap elements
 * fpda_swap(data, 0, 9);
 *
 * // Clone array
 * fp_dynarray(float) copy = fpda_clone(data);
 *
 * // Concatenate arrays
 * fpda_concatenate_in_place(data, copy);
 *
 * // Shrink to fit (free excess capacity)
 * fpda_shrink_to_fit(data);
 *
 * fpda_free_and_null(data);
 * fpda_free_and_null(copy);
 * @endcode
 */

#ifndef __LIB_FAT_POINTER_DYN_ARRAY_H__
#define __LIB_FAT_POINTER_DYN_ARRAY_H__

#include "pointer.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Define a dynamic array type
 * @param type Element type
 *
 * Creates a typed dynamic array pointer. The array starts as NULL and grows
 * automatically as elements are added.
 *
 * @code
 * fp_dynarray(int) integers = NULL;
 * fp_dynarray(float) floats = NULL;
 * fp_dynarray(MyStruct) structs = NULL;
 * @endcode
 */
#define fp_dynarray(type) type*

/**
 * @brief Default initial allocation size in bytes (defaults to 16)
 *
 * When a dynamic array is first used, it allocates at least this many bytes.
 * Can be overridden by defining before including this header.
 *
 * @code
 * #define FPDA_DEFAULT_SIZE_BYTES 64
 * #include "dynarray.h"
 * @endcode
 */
#ifndef FPDA_DEFAULT_SIZE_BYTES
#define FPDA_DEFAULT_SIZE_BYTES 16
#endif

// From: https://stackoverflow.com/a/466278
/**
 * @brief Calculate next power of two greater than or equal to v
 * @param v Input value
 * @return Next power of two >= v
 *
 * Used internally for capacity growth. Ensures efficient memory usage
 * with power-of-two allocations.
 *
 * @code
 * assert(fp_upper_power_of_two(5) == 8);
 * assert(fp_upper_power_of_two(16) == 16);
 * assert(fp_upper_power_of_two(100) == 128);
 * @endcode
 */
FP_CONSTEXPR inline static uint64_t fp_upper_power_of_two(uint64_t v) FP_NOEXCEPT {
	--v;
	v |= v >> 1;
	v |= v >> 2;
	v |= v >> 4;
	v |= v >> 8;
	v |= v >> 16;
	v |= v >> 32;
	++v;
	return v;
}

/**
 * @brief Header structure for dynamic arrays
 *
 * Extends the fat pointer header with capacity information. Layout:
 * [__FatDynamicArrayHeader][__FatPointerHeader][user data...][null terminator]
 *                                              ^ returned pointer
 */
struct __FatDynamicArrayHeader {
	size_t capacity;                   ///< Total allocated capacity
	struct __FatPointerHeader h;       ///< Base fat pointer header (contains size)
};

#ifndef __cplusplus
	/// @brief Size of dynamic array header in bytes
	#define FPDA_HEADER_SIZE sizeof(struct __FatDynamicArrayHeader)
#else
	/// @brief Size of dynamic array header in bytes (C++ version)
	static constexpr size_t FPDA_HEADER_SIZE = sizeof(__FatDynamicArrayHeader) - detail::completed_sizeof_v<decltype(__FatPointerHeader{}.data)>;
#endif

/**
 * @brief Get reference to null dynamic array header
 * @return Pointer to static null header
 * @internal
 */
struct __FatDynamicArrayHeader* __fpda_header_null_ref() FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	static struct __FatDynamicArrayHeader ref = {
		.capacity = 0,
		.h = {
			.magic = 0,
			.size = 0,
		}
	};
	return &ref;
}
#else
;
#endif

/**
 * @brief Get dynamic array header from data pointer
 * @param da Dynamic array pointer
 * @return Pointer to header (or null ref if da is NULL)
 * @internal
 */
inline static struct __FatDynamicArrayHeader* __fpda_header(const void* da) FP_NOEXCEPT {
	if(da == NULL) return __fpda_header_null_ref();

	uint8_t* p = (uint8_t*)da;
	p -= FPDA_HEADER_SIZE;
	return (struct __FatDynamicArrayHeader*)p;
}

/**
 * @brief Internal allocation function for dynamic arrays
 * @param _size Size in bytes to allocate
 * @param extra_header_size Extra header size to allocate, allows hash tables to use the same function!
 * @return Pointer to allocated data
 * @internal
 */
void* __fpda_malloc(size_t _size, size_t extra_header_size) FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	assert(_size > 0);
	size_t size = FPDA_HEADER_SIZE + extra_header_size + _size + 1;
	uint8_t* p = (uint8_t*)__fp_alloc(NULL, size);
	p += FPDA_HEADER_SIZE + extra_header_size;
	if(!p) return 0;
	auto h = __fpda_header(p);
	h->capacity = _size;
	h->h.magic = FP_DYNARRAY_MAGIC_NUMBER;
	h->h.size = 0;
	h->h.data[_size] = 0;
	return p;
}
#else
;
#endif

/**
 * @brief Allocate a dynamic array with initial capacity
 * @param type Element type
 * @param _size Initial capacity in elements
 * @return Dynamic array with specified capacity and size
 *
 * @code
 * // Allocate with capacity for 100 integers
 * fp_dynarray(int) arr = fpda_malloc(int, 100);
 * assert(fpda_capacity(arr) == 100);
 * assert(fpda_size(arr) == 0);  // Size is 0 until elements added
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_malloc(type, _size) ((type*)((uint8_t*)(*__fpda_header(__fpda_malloc(NULL, sizeof(type) * (_size), 0)) = (struct __FatDynamicArrayHeader){\
	.capacity = 0,\
	.h = {\
		.magic = FP_DYNARRAY_MAGIC_NUMBER,\
		.size = (_size),\
	}\
}).h.data))

#ifdef __GNUC__
__attribute__((no_sanitize_address))
#endif
/**
 * @brief Check if pointer is a dynamic array
 * @param da Pointer to check
 * @return true if da is a valid dynamic array
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * assert(!is_fpda(arr));  // NULL is not a dynamic array
 *
 * fpda_push_back(arr, 42);
 * assert(is_fpda(arr));   // Now it is
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
inline static bool is_fpda(const void* da) FP_NOEXCEPT {
	return __fpda_header(da)->h.magic == FP_DYNARRAY_MAGIC_NUMBER;
}

/**
 * @brief Free a dynamic array
 * @param da Dynamic array to free
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_push_back(arr, 10);
 * fpda_free(arr);
 * // arr is now invalid - do not use
 * @endcode
 */
void fpda_free(void* da) FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	auto h = __fpda_header(da);
	if(h != __fpda_header_null_ref())
		__fp_alloc(h, 0);
}
#else
;
#endif

/**
 * @brief Free a dynamic array and set pointer to NULL
 * @param da Dynamic array to free
 *
 * Safer than fpda_free() as it prevents use-after-free.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_push_back(arr, 42);
 * fpda_free_and_null(arr);
 * assert(arr == NULL);
 * @endcode
 */
#define fpda_free_and_null(da) (fpda_free(da), da = NULL)

/**
 * @brief Get number of elements in dynamic array
 *
 * Alias for fp_length. Returns the count of elements currently in use,
 * not the capacity.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_reserve(arr, 100);
 * fpda_push_back(arr, 1);
 * fpda_push_back(arr, 2);
 *
 * assert(fpda_length(arr) == 2);      // Elements in use
 * assert(fpda_capacity(arr) == 100);  // Allocated capacity
 * @endcode
 */
#define fpda_length fp_length

/// @brief Alias for fpda_length
#define fpda_size fp_size

/**
 * @brief Check if dynamic array is empty
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * assert(fpda_empty(arr));
 *
 * fpda_push_back(arr, 42);
 * assert(!fpda_empty(arr));
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_empty fp_empty

/// @brief Get pointer to first element
#define fpda_front(a) fp_front(a)

/// @brief Get iterator to beginning (alias for fpda_front)
#define fpda_begin(a) fp_begin(a)

/// @brief Get pointer to last element
#define fpda_back(a) fp_back(a)

/// @brief Get iterator to one past end
#define fpda_end(a) fp_end(a)

/**
 * @brief Iterate over dynamic array with named iterator
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * for(int i = 0; i < 10; i++)
 *     fpda_push_back(arr, i);
 *
 * fpda_iterate_named(arr, ptr)
 *     *ptr *= 2;
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_iterate_named fp_iterate_named

/// @brief Iterate over dynamic array (iterator named 'i')
#define fpda_iterate fp_iterate

/// @brief Calculate index from iterator
#define fpda_iterate_calculate_index fp_iterate_calculate_index

/**
 * @brief Get allocated capacity of dynamic array
 * @param da Dynamic array
 * @return Number of elements that can be stored without reallocation
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_reserve(arr, 50);
 *
 * assert(fpda_capacity(arr) == 50);
 * assert(fpda_size(arr) == 0);
 *
 * // Add 30 elements - no reallocation
 * for(int i = 0; i < 30; i++)
 *     fpda_push_back(arr, i);
 *
 * assert(fpda_capacity(arr) == 50);  // Still has room
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
inline static size_t fpda_capacity(const void* da) FP_NOEXCEPT {
	if(!is_fpda(da)) return 0;
	return __fpda_header(da)->capacity;
}

#define __FP_MAYBE_GROW_IMPL(da, type_size, new_size, update_utilized, exact_sizing,\
							malloc_fn, free_fn, header_fn, is_valid_fn,\
							GET_CAPACITY, SET_CAPACITY, GET_SIZE, SET_SIZE,\
							GET_DATA, COPY_EXTRA)\
do {\
	if(*(da) == NULL) {\
		size_t initial_size = (exact_sizing) ? (new_size) : FPDA_DEFAULT_SIZE_BYTES / (type_size);\
		if(initial_size == 0) initial_size++;\
		*(da) = malloc_fn(initial_size * (type_size));\
		auto _h_init = header_fn(*(da));\
		SET_CAPACITY(_h_init, GET_CAPACITY(_h_init) / (type_size));\
		SET_SIZE(_h_init, 0);\
	}\
\
	assert(is_valid_fn(*(da)));\
\
	auto _h = header_fn(*(da));\
	if(GET_CAPACITY(_h) >= (new_size)) {\
		if(update_utilized) {\
			size_t _cur = GET_SIZE(_h);\
			SET_SIZE(_h, _cur > (new_size) ? _cur : (new_size));\
		}\
		return GET_DATA(_h) + ((type_size) * ((new_size) - 1));\
	}\
\
	size_t _size2 = (exact_sizing) ? (new_size) : fp_upper_power_of_two(new_size);\
	void* _new = malloc_fn((type_size) * _size2);\
	auto _newH = header_fn(_new);\
	if(update_utilized) {\
		size_t _cur = GET_SIZE(_h);\
		SET_SIZE(_newH, _cur > (new_size) ? _cur : (new_size));\
	}\
	SET_CAPACITY(_newH, _size2);\
	COPY_EXTRA(_newH, _h);\
	memcpy(GET_DATA(_newH), GET_DATA(_h), (type_size) * GET_SIZE(_h));\
\
	free_fn(*(da));\
	*(da) = _new;\
	return GET_DATA(_newH) + ((type_size) * ((new_size) - 1));\
} while(0)

// Accessor macros for fpda
#define __FPDA_GET_CAPACITY(H) ((H)->capacity)
#define __FPDA_SET_CAPACITY(H, v) ((H)->capacity = (v))
#define __FPDA_GET_SIZE(H) ((H)->h.size)
#define __FPDA_SET_SIZE(H, v) ((H)->h.size = (v))
#define __FPDA_GET_DATA(H) ((H)->h.data)
#define __FPDA_COPY_EXTRA(newH, oldH) ((void)0)

inline static void* __fpda_maybe_grow(void** da, size_t type_size, size_t new_size, bool update_utilized, bool exact_sizing) FP_NOEXCEPT {
#define __fpda_malloc_impl(size) __fpda_malloc(size, 0)
	__FP_MAYBE_GROW_IMPL(da, type_size, new_size, update_utilized, exact_sizing,
						__fpda_malloc_impl, fpda_free, __fpda_header, is_fpda,
						__FPDA_GET_CAPACITY, __FPDA_SET_CAPACITY,
						__FPDA_GET_SIZE, __FPDA_SET_SIZE,
						__FPDA_GET_DATA, __FPDA_COPY_EXTRA);
#undef __fpda_malloc_impl
}

/// @cond INTERNAL
#define __fpda_maybe_grow_short(a, _size) ((FP_TYPE_OF_REMOVE_POINTER(a)*)__fpda_maybe_grow((void**)&a, sizeof(*a), (_size), true, false))
/// @endcond

/**
 * @brief Reserve capacity for at least _size elements
 * @param a Dynamic array
 * @param _size Minimum capacity to reserve
 *
 * Ensures the array can hold at least _size elements without reallocation.
 * Does not change the size, only the capacity.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 *
 * // Reserve space for 1000 elements
 * fpda_reserve(arr, 1000);
 *
 * // Add elements without reallocation
 * for(int i = 0; i < 1000; i++)
 *     fpda_push_back(arr, i);  // No reallocations
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_reserve(a, _size) ((FP_TYPE_OF_REMOVE_POINTER(a)*)__fpda_maybe_grow((void**)&a, sizeof(*a), (_size), false, true))

/**
 * @brief Reserve capacity (void pointer version)
 * @param a Dynamic array (void*)
 * @param type_size Size of each element
 * @param _size Minimum capacity to reserve
 * @internal
 */
#define fpda_reserve_void_pointer(a, type_size, _size) (__fpda_maybe_grow((void**)&a, type_size, (_size), false, true))

/**
 * @brief Grow array to exact size
 * @param a Dynamic array
 * @param _size New size (updates both size and ensures capacity)
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_grow_to_size(arr, 50);
 *
 * assert(fpda_size(arr) == 50);
 * assert(fpda_capacity(arr) >= 50);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_grow_to_size(a, _size) ((FP_TYPE_OF_REMOVE_POINTER(a)*)__fpda_maybe_grow((void**)&a, sizeof(*a), (_size), true, true))

/**
 * @brief Grow array by adding elements
 * @param a Dynamic array
 * @param _to_add Number of elements to add
 *
 * Increases size by _to_add. New elements are uninitialized.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_push_back(arr, 1);
 * fpda_push_back(arr, 2);
 *
 * fpda_grow(arr, 3);  // Add 3 more elements
 * assert(fpda_size(arr) == 5);
 *
 * // Initialize new elements
 * arr[2] = 3;
 * arr[3] = 4;
 * arr[4] = 5;
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_grow(a, _to_add) (__fpda_maybe_grow_short(a, __fpda_header(a)->h.size + _to_add))

/**
 * @brief Add element to end of array
 * @param a Dynamic array
 * @param _value Value to add
 *
 * Automatically grows array if needed. Amortized O(1) operation.
 *
 * @code
 * fp_dynarray(int) numbers = NULL;
 *
 * for(int i = 0; i < 100; i++)
 *     fpda_push_back(numbers, i * i);
 *
 * assert(fpda_size(numbers) == 100);
 * assert(numbers[50] == 2500);
 *
 * fpda_free(numbers);
 * @endcode
 */
#define fpda_push_back(a, _value) (*__fpda_maybe_grow_short(a, __fpda_header(a)->h.size + 1) = (_value))

/**
 * @brief Grow array and initialize new elements
 * @param a Dynamic array
 * @param _to_add Number of elements to add
 * @param _value Value to initialize new elements with
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_push_back(arr, 1);
 * fpda_push_back(arr, 2);
 *
 * // Add 5 more elements, all initialized to 99
 * fpda_grow_and_initialize(arr, 5, 99);
 *
 * assert(fpda_size(arr) == 7);
 * assert(arr[2] == 99);
 * assert(arr[6] == 99);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_grow_and_initialize(a, _to_add, _value) do {\
		size_t __fp_oldSize = fpda_size(a); \
		fpda_grow(a, (_to_add));\
		for(size_t __fp_i = __fp_oldSize, __fp_size = fpda_size(a); __fp_i < __fp_size; ++__fp_i)\
			(a)[__fp_i] = (_value);\
	} while(false)

/**
 * @brief Grow to size and initialize new elements
 * @param a Dynamic array
 * @param _size Target size
 * @param _value Value to initialize new elements with
 *
 * @code
 * fp_dynarray(float) data = NULL;
 * fpda_grow_to_size_and_initialize(data, 100, 3.14f);
 *
 * assert(fpda_size(data) == 100);
 * for(size_t i = 0; i < fpda_size(data); i++)
 *     assert(data[i] == 3.14f);
 *
 * fpda_free_and_null(data);
 * @endcode
 */
#define fpda_grow_to_size_and_initialize(a, _size, _value) do {\
		size_t __fp_oldSize = fpda_size(a); \
		fpda_grow_to_size(a, (_size));\
		for(size_t __fp_i = __fp_oldSize, __fp_size = fpda_size(a); __fp_i < __fp_size; ++__fp_i)\
			(a)[__fp_i] = (_value);\
	} while(false)

// TODO: What happens when count > size?
/**
 * @brief Remove last n elements
 * @param a Dynamic array
 * @param _count Number of elements to remove
 * @return Pointer to first removed element (the element after the new last element/now invalid)
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * for(int i = 0; i < 10; i++)
 *     fpda_push_back(arr, i);
 *
 * fpda_pop_back_n(arr, 3);  // Remove last 3 elements
 * assert(fpda_size(arr) == 7);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_pop_back_n(a, _count) (assert(_count <= fpda_size(a)), __fpda_maybe_grow_short(a, __fpda_header(a)->h.size <= 0 ? 0 : (__fpda_header(a)->h.size -= (_count))) + 1)

/**
 * @brief Remove last element
 * @param a Dynamic array
 * @return Pointer to removed element (now invalid)
 *
 * @code
 * fp_dynarray(int) stack = NULL;
 * fpda_push_back(stack, 10);
 * fpda_push_back(stack, 20);
 * fpda_push_back(stack, 30);
 *
 * fpda_pop_back(stack);
 * assert(fpda_size(stack) == 2);
 * assert(stack[fpda_size(stack) - 1] == 20);
 *
 * fpda_free_and_null(stack);
 * @endcode
 */
#define fpda_pop_back(a) fpda_pop_back_n(a, 1)

/**
 * @brief Pop elements until size reaches target
 * @param a Dynamic array
 * @param size Target size
 * @return Pointer to first removed element (the element after the new last element/now invalid)
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * for(int i = 0; i < 100; i++)
 *     fpda_push_back(arr, i);
 *
 * fpda_pop_back_to_size(arr, 50);
 * assert(fpda_size(arr) == 50);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_pop_back_to_size(a, size) fpda_pop_back_n(a, FP_MAX(((int64_t)fpda_size(a)) - size, 0))

/**
 * @brief Internal function for insert with growth
 * @internal
 */
inline static void* __fpda_maybe_grow_insert(void** da, size_t type_size, size_t new_index, size_t new_size, bool exact_sizing) FP_NOEXCEPT {
	assert(new_size > 0);
	assert(new_index <= fpda_size(*da));

	__fpda_maybe_grow(da, type_size, fpda_size(*da) + new_size, /*update_utilized*/true, exact_sizing);

	uint8_t* raw = (uint8_t*)*da;
	uint8_t* oldStart = raw + new_index * type_size;
	uint8_t* newStart = oldStart + new_size * type_size;
	size_t length = (raw + fpda_size(*da) * type_size) - newStart;
	memmove(newStart, oldStart, length);
	return oldStart;
}

/**
 * @brief Insert element at position
 * @param a Dynamic array
 * @param _pos Position to insert at
 * @param _val Value to insert
 *
 * Elements after _pos are shifted right. O(n) operation.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_push_back(arr, 1);
 * fpda_push_back(arr, 2);
 * fpda_push_back(arr, 4);
 * fpda_push_back(arr, 5);
 *
 * // Insert 3 at index 2
 * fpda_insert(arr, 2, 3);
 *
 * // arr is now: [1, 2, 3, 4, 5]
 * assert(fpda_size(arr) == 5);
 * assert(arr[2] == 3);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_insert(a, _pos, _val) ((*(FP_TYPE_OF(*a)*)__fpda_maybe_grow_insert((void**)&a, sizeof(*a), (_pos), 1, false)) = _val)

/**
 * @brief Insert element at front
 * @param a Dynamic array
 * @param _val Value to insert
 *
 * @code
 * fp_dynarray(int) deque = NULL;
 * fpda_push_front(deque, 3);
 * fpda_push_front(deque, 2);
 * fpda_push_front(deque, 1);
 *
 * // deque is now: [1, 2, 3]
 * assert(deque[0] == 1);
 *
 * fpda_free_and_null(deque);
 * @endcode
 */
#define fpda_push_front(a, _val) fpda_insert(a, 0, _val)

/**
 * @brief Insert uninitialized elements
 * @param a Dynamic array
 * @param _pos Position to insert at
 * @param _count Number of elements to insert
 * @return Pointer to first new uninitialized element
 *
 * Useful for bulk insertion where you'll initialize elements manually.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_push_back(arr, 1);
 * fpda_push_back(arr, 5);
 *
 * // Insert 3 uninitialized elements at position 1
 * int* new_elems = fpda_insert_uninitialized(arr, 1, 3);
 * // TODO: Would this be 1, 3 or 0, 3?
 * new_elems[0] = 2;
 * new_elems[1] = 3;
 * new_elems[2] = 4;
 *
 * // arr is now: [1, 2, 3, 4, 5]
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_insert_uninitialized(a, _pos, _count) ((FP_TYPE_OF(*a)*)__fpda_maybe_grow_insert((void**)&a, sizeof(*a), (_pos), (_count), false))


/**
 * @brief Internal function for deletion
 * @internal
 */
inline static void* __fpda_delete(void** da, size_t type_size, size_t start, size_t count, bool make_size_match_capacity) FP_NOEXCEPT {
	assert(start + count <= fpda_size(*da));

	uint8_t* raw = (uint8_t*)*da;
	uint8_t* newStart = raw + start * type_size;
	uint8_t* oldStart = newStart + count * type_size;
	size_t length = (raw + fpda_size(raw) * type_size) - oldStart;

	if(make_size_match_capacity) {
		fp_dynarray(uint8_t) new_ = NULL;
		size_t newLength = fpda_size(raw) - count;
		fpda_grow_to_size(new_, newLength * type_size);
		__fpda_header(new_)->h.size = newLength;
		__fpda_header(new_)->capacity = newLength;

		newStart = new_ + start * type_size;
		if(oldStart != raw) memcpy(new_, raw, newStart - new_);
		memcpy(newStart, oldStart, length);

		fpda_free(*da);
		*da = new_;

	} else if(count > 0) {
		__fpda_header(*da)->h.size -= count;
		memmove(newStart, oldStart, length);
	}

	return newStart;
}

/// @cond INTERNAL
#define __fpda_delete_impl(a, _pos, _count, _match_size) ((FP_TYPE_OF(*a)*)__fpda_delete((void**)&a, sizeof(*a), (_pos), (_count), (_match_size)))
/// @endcond

/**
 * @brief Delete range of elements
 * @param a Dynamic array
 * @param _pos Starting position
 * @param _count Number of elements to delete
 * @return Modified a.
 *
 * Removes elements and shifts remaining elements left. Does not reduce capacity.
 * O(n) operation.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * for(int i = 0; i < 10; i++)
 *     fpda_push_back(arr, i);
 * // arr: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
 *
 * fpda_delete_range(arr, 3, 4);
 * // arr: [0, 1, 2, 7, 8, 9]
 *
 * assert(fpda_size(arr) == 6);
 * assert(arr[3] == 7);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_delete_range(a, _pos, _count) __fpda_delete_impl(a, _pos, _count, false)

/**
 * @brief Delete single element
 * @param a Dynamic array
 * @param _pos Position of element to delete
 * @return Modified a.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * for(int i = 0; i < 5; i++)
 *     fpda_push_back(arr, i * 10);
 * // arr: [0, 10, 20, 30, 40]
 *
 * fpda_delete(arr, 2);
 * // arr: [0, 10, 30, 40]
 *
 * assert(fpda_size(arr) == 4);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_delete(a, _pos) fpda_delete_range(a, _pos, 1)

/**
 * @brief Delete range using start and end indices
 * @param a Dynamic array
 * @param _start Starting index (inclusive)
 * @param _end Ending index (inclusive)
 * @return Modified a.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * for(int i = 0; i < 10; i++)
 *     fpda_push_back(arr, i);
 *
 * // Delete elements 3 through 7 (inclusive)
 * fpda_delete_start_end(arr, 3, 7);
 * // arr: [0, 1, 2, 8, 9]
 *
 * assert(fpda_size(arr) == 5);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_delete_start_end(a, _start, _end) fpda_delete_range(a, _start, ((_end) - (_start) + 1))

/**
 * @brief Delete range and shrink capacity to match size
 * @param a Dynamic array
 * @param _pos Starting position
 * @param _count Number of elements to delete
 * @return Modified a.
 *
 * Like fpda_delete_range but also reallocates to free unused capacity.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_reserve(arr, 100);
 * for(int i = 0; i < 50; i++)
 *     fpda_push_back(arr, i);
 *
 * assert(fpda_capacity(arr) == 100);
 *
 * fpda_shrink_delete_range(arr, 0, 40);
 * // Only 10 elements remain
 * assert(fpda_size(arr) == 10);
 * assert(fpda_capacity(arr) == 10);  // Capacity shrunk
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_shrink_delete_range(a, _pos, _count) __fpda_delete_impl(a, _pos, _count, true)

/**
 * @brief Delete single element and shrink capacity
 * @param a Dynamic array
 * @param _pos Position to delete
 * @return Modified a.
 */
#define fpda_shrink_delete(a, _pos) fpda_shrink_delete_range(a, _pos, 1)

/**
 * @brief Delete range and shrink using start/end indices
 * @param a Dynamic array
 * @param _start Starting index (inclusive)
 * @param _end Ending index (inclusive)
 * @return Modified a.
 */
#define fpda_shrink_delete_start_end(a, _start, _end) fpda_shrink_delete_range(a, _start, ((_end) - (_start) + 1))

/**
 * @brief Resize array to new size
 * @param a Dynamic array
 * @param _size New size
 *
 * If new size is larger, capacity grows and new elements are uninitialized.
 * If new size is smaller, elements are deleted and capacity shrinks.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * for(int i = 0; i < 10; i++)
 *     fpda_push_back(arr, i);
 *
 * // Grow
 * fpda_resize(arr, 20);
 * assert(fpda_size(arr) == 20);
 *
 * // Shrink
 * fpda_resize(arr, 5);
 * assert(fpda_size(arr) == 5);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_resize(a, _size) do { auto __fp_size = (_size);\
		if((size_t)__fp_size > fpda_capacity(a)) fpda_grow_to_size(a, __fp_size);\
		else { auto __fp_count = fpda_size(a) - __fp_size; fpda_shrink_delete_range(a, fpda_size(a) - __fp_count, __fp_count); }\
	} while(false)

/**
 * @brief Shrink capacity to match current size
 * @param a Dynamic array
 *
 * Frees unused capacity. Useful after removing many elements.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_reserve(arr, 1000);
 * for(int i = 0; i < 100; i++)
 *     fpda_push_back(arr, i);
 *
 * assert(fpda_capacity(arr) == 1000);
 * assert(fpda_size(arr) == 100);
 *
 * fpda_shrink_to_fit(arr);
 * assert(fpda_capacity(arr) == 100);  // Freed 900 elements worth of memory
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_shrink_to_fit(a) __fpda_delete_impl(a, 0, 0, true)


/**
 * @brief Internal function for swapping ranges
 * @internal
 */
inline static void __fpda_swap_range(void* da, size_t type_size, size_t range1_start, size_t range2_start, size_t count, bool bidirectional) FP_NOEXCEPT {
	assert(range1_start + count <= fpda_size(da));
	assert(range2_start + count <= fpda_size(da));

	uint8_t* start1 = ((uint8_t*)da) + type_size * range1_start;
	uint8_t* start2 = ((uint8_t*)da) + type_size * range2_start;
	uint8_t* end1 = start1 + count * type_size - 1;
	uint8_t* end2 = start2 + count * type_size - 1;
	bool overlapping = !(end1 <= start2 || end2 <= start1);
	size_t length = count * type_size;

	uint8_t* scratch = NULL;
	if(overlapping) {
		if(fpda_capacity(da) - fpda_size(da) > count)
			scratch = ((uint8_t*)da) + type_size * fpda_size(da) - length;
		else scratch = fp_alloca(uint8_t, length);
	}

	if(bidirectional)
		memswap(start1, start2, length);
	else if(overlapping) {
		memcpy(scratch, start1, length);
		memcpy(start2, scratch, length);
	} else memcpy(start2, start1, length);
}

/**
 * @brief Swap two ranges of elements
 * @param a Dynamic array
 * @param _start1 Start of first range
 * @param _start2 Start of second range
 * @param _count Number of elements to swap
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * for(int i = 0; i < 10; i++)
 *     fpda_push_back(arr, i);
 * // arr: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
 *
 * // Swap [0,1,2] with [7,8,9]
 * fpda_swap_range(arr, 0, 7, 3);
 * // arr: [7, 8, 9, 3, 4, 5, 6, 0, 1, 2]
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_swap_range(a, _start1, _start2, _count) (__fpda_swap_range(a, sizeof(*a), (_start1), (_start2), (_count), true))

/**
 * @brief Swap two elements
 * @param a Dynamic array
 * @param _pos1 First position
 * @param _pos2 Second position
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_push_back(arr, 10);
 * fpda_push_back(arr, 20);
 * fpda_push_back(arr, 30);
 *
 * fpda_swap(arr, 0, 2);
 * // arr: [30, 20, 10]
 *
 * assert(arr[0] == 30);
 * assert(arr[2] == 10);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_swap(a, _pos1, _pos2) fpda_swap_range(a, _pos1, _pos2, 1)

/**
 * @brief Swap range to end and delete
 * @param a Dynamic array
 * @param _pos Starting position
 * @param _count Number of elements
 *
 * Efficiently deletes by swapping with end elements instead of shifting.
 * O(1) operation but doesn't preserve order.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * for(int i = 0; i < 10; i++)
 *     fpda_push_back(arr, i);
 * // arr: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
 *
 * // Delete elements at positions 2-3 by swapping with end
 * fpda_swap_delete_range(arr, 2, 2);
 * // arr: [0, 1, 8, 9, 4, 5, 6, 7]
 *
 * assert(fpda_size(arr) == 8);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_swap_delete_range(a, _pos, _count) (__fpda_swap_range(a, sizeof(*a), fpda_size(a) - (_count), (_pos), (_count), false), __fpda_header(a)->h.size -= _count)

/**
 * @brief Swap element to end and delete
 * @param a Dynamic array
 * @param _pos Position to delete
 *
 * Fast O(1) deletion that doesn't preserve order.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * for(int i = 0; i < 5; i++)
 *     fpda_push_back(arr, i * 10);
 * // arr: [0, 10, 20, 30, 40]
 *
 * fpda_swap_delete(arr, 1);
 * // arr: [0, 40, 20, 30]  (40 moved to position 1)
 *
 * assert(fpda_size(arr) == 4);
 * assert(arr[1] == 40);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_swap_delete(a, _pos) fpda_swap_delete_range(a, _pos, 1)

/**
 * @brief Swap range to end and delete using start/end indices
 * @param a Dynamic array
 * @param _start Starting index (inclusive)
 * @param _end Ending index (inclusive)
 */
#define fpda_swap_delete_start_end(a, _start, _end) fpda_swap_delete_range(a, _start, ((_end) - (_start) + 1))

// TODO: Why is this not just a swap delete?
/**
 * @brief Internal function for deleting the first element
 * @internal
 */
inline static void* __fpda_pop_front(void* _da, size_t type_size) FP_NOEXCEPT {
	auto da = (char*)_da;
	auto size = fpda_size(da);
	if(size <= 1) return da;

	auto tmp = fp_alloca(char, type_size);
	memcpy(tmp, da, type_size);
	memmove(da, da+type_size, (size - 1) * type_size);
	memcpy(da + size * type_size, tmp, type_size);
	__fpda_header(da)->h.size -= 1;
	return da + size * type_size;
}

/**
 * @brief Remove and return first element
 * @param a Dynamic array
 * @return Pointer to removed element (now at end of array)
 *
 * Shifts all elements left. O(n) operation.
 *
 * @note The final element is just shifted to the end, so the pointer to it is valid as long as the array is.
 *
 * @code
 * fp_dynarray(int) queue = NULL;
 * fpda_push_back(queue, 1);
 * fpda_push_back(queue, 2);
 * fpda_push_back(queue, 3);
 *
 * fpda_pop_front(queue);
 * // queue: [2, 3]
 *
 * assert(fpda_size(queue) == 2);
 * assert(queue[0] == 2);
 *
 * fpda_free_and_null(queue);
 * @endcode
 */
#define fpda_pop_front(a) ((FP_TYPE_OF_REMOVE_POINTER(a)*)__fpda_pop_front(a, sizeof(*a)))

/**
 * @brief Internal function for cloning to destination
 * @internal
 */
inline static void __fpda_clone_to(void** dest, const void* src, size_t type_size, bool shrink_to_fit) FP_NOEXCEPT {
	uint8_t* rawDest = (uint8_t*)*dest;
	size_t newCapacity = shrink_to_fit ? fpda_size(src) : fpda_capacity(src);
	fpda_grow_to_size(rawDest, newCapacity * type_size);
	memcpy(rawDest, src, fpda_size(rawDest));
	auto h = __fpda_header(rawDest);
	h->capacity = newCapacity;
	h->h.size = fpda_size(src);
	*dest = rawDest;
}

/**
 * @brief Clone array to destination
 * @param dest Destination array
 * @param src Source array
 *
 * Copies all elements and capacity from src to dest.
 *
 * @code
 * fp_dynarray(int) original = NULL;
 * for(int i = 0; i < 10; i++)
 *     fpda_push_back(original, i);
 *
 * fp_dynarray(int) copy = NULL;
 * fpda_clone_to(copy, original);
 *
 * assert(fpda_size(copy) == 10);
 * assert(copy[5] == 5);
 *
 * fpda_free_and_null(original);
 * fpda_free_and_null(copy);
 * @endcode
 */
#define fpda_clone_to(dest, src) __fpda_clone_to((void**)&dest, (src), sizeof(*dest), false)

/// @brief Alias for fpda_clone_to
#define fpda_assign(dest, src) fpda_clone_to(dest, src)

/**
 * @brief Clone array to destination with minimal capacity
 * @param dest Destination array
 * @param src Source array
 *
 * Like fpda_clone_to but capacity matches size exactly.
 */
#define fpda_clone_to_shrink(dest, src) __fpda_clone_to((void**)&dest, (src), sizeof(*dest), true)

/**
 * @brief Internal function for cloning
 * @internal
 */
inline static void* __fpda_clone(const void* src, size_t type_size) FP_NOEXCEPT {
	void* out = NULL;
	if(src == NULL) return out;
	__fpda_clone_to(&out, src, type_size, true);
	return out;
}

/**
 * @brief Create a clone of dynamic array
 * @param src Source array
 * @return New array with copied data
 *
 * @code
 * fp_dynarray(int) original = NULL;
 * for(int i = 0; i < 5; i++)
 *     fpda_push_back(original, i * i);
 *
 * fp_dynarray(int) clone = fpda_clone(original);
 *
 * clone[0] = 999;  // Doesn't affect original
 * assert(original[0] == 0);
 * assert(clone[0] == 999);
 *
 * fpda_free_and_null(original);
 * fpda_free_and_null(clone);
 * @endcode
 */
#define fpda_clone(src) ((FP_TYPE_OF(*src)*)__fpda_clone((src), sizeof(*src)))

/// @brief Alias for fpda_clone
#define fpda_copy(src) fpda_clone(src)

/**
 * @brief Clear all elements (keeps capacity)
 * @param a Dynamic array
 *
 * Sets size to 0 but doesn't free memory.
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_reserve(arr, 100);
 * for(int i = 0; i < 50; i++)
 *     fpda_push_back(arr, i);
 *
 * assert(fpda_size(arr) == 50);
 * assert(fpda_capacity(arr) == 100);
 *
 * fpda_clear(arr);
 *
 * assert(fpda_size(arr) == 0);
 * assert(fpda_capacity(arr) == 100);  // Capacity unchanged
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_clear(a) __fpda_header(a)->h.size = 0


/// @cond INTERNAL
static thread_local void* __fpda_global_concatenate_pointer;
/// @endcond

/**
 * @brief Internal function for concatenating view in place
 * @internal
 */
inline static void* __fpda_concatenate_view_in_place(void** dest, const fp_void_view src, size_t type_size) FP_NOEXCEPT {
	size_t src_size = fp_view_size(src);
	size_t pre_size = fpda_size(*dest);
	__fpda_maybe_grow(dest, type_size, pre_size + src_size, true, false);
	memcpy(((char*)*dest) + pre_size * type_size, fp_view_data_void(src), src_size * type_size);
	return *dest;
}

/**
 * @brief Concatenate view to array in place
 * @param dest Destination array (modified)
 * @param src Source view
 *
 * @code
 * fp_dynarray(int) arr = NULL;
 * fpda_push_back(arr, 1);
 * fpda_push_back(arr, 2);
 *
 * int more[] = {3, 4, 5};
 * fp_view(int) v = fp_view_literal(int, more, 3);
 *
 * fpda_concatenate_view_in_place(arr, v);
 * // arr: [1, 2, 3, 4, 5]
 *
 * assert(fpda_size(arr) == 5);
 *
 * fpda_free_and_null(arr);
 * @endcode
 */
#define fpda_concatenate_view_in_place(dest, src) (__fpda_concatenate_view_in_place((void**)&dest, (fp_void_view)(src), sizeof(*src)))

/**
 * @brief Concatenate view to array (returns new array)
 * @param dest Source array (not modified)
 * @param src View to append
 * @return New array with concatenated data
 *
 * @code
 * fp_dynarray(int) arr1 = NULL;
 * fpda_push_back(arr1, 1);
 * fpda_push_back(arr1, 2);
 *
 * int extra[] = {3, 4};
 * fp_view(int) v = fp_view_literal(int, extra, 2);
 *
 * fp_dynarray(int) result = fpda_concatenate_view(arr1, v);
 * // result: [1, 2, 3, 4]
 * // arr1: [1, 2] (unchanged)
 *
 * fpda_free_and_null(arr1);
 * fpda_free_and_null(result);
 * @endcode
 */
#define fpda_concatenate_view(dest, src) (__fpda_global_concatenate_pointer = (void*)fpda_clone(dest), fpda_concatenate_view_in_place(__fpda_global_concatenate_pointer, (src)))

/**
 * @brief Concatenate two arrays in place
 * @param dest Destination array (modified)
 * @param src Source array
 *
 * @code
 * fp_dynarray(int) arr1 = NULL;
 * fp_dynarray(int) arr2 = NULL;
 *
 * fpda_push_back(arr1, 1);
 * fpda_push_back(arr1, 2);
 * fpda_push_back(arr2, 3);
 * fpda_push_back(arr2, 4);
 *
 * fpda_concatenate_in_place(arr1, arr2);
 * // arr1: [1, 2, 3, 4]
 * // arr2: [3, 4] (unchanged)
 *
 * fpda_free_and_null(arr1);
 * fpda_free_and_null(arr2);
 * @endcode
 */
#define fpda_concatenate_in_place(dest, src) ((FP_TYPE_OF(*src)*)__fpda_concatenate_view_in_place((void**)&dest, fp_void_view_literal((src), fpda_size(src)), sizeof(*src)))

/**
 * @brief Concatenate two arrays (returns new array)
 * @param dest First array (not modified)
 * @param src Second array (not modified)
 * @return New array with concatenated data
 *
 * @code
 * fp_dynarray(int) arr1 = NULL;
 * fp_dynarray(int) arr2 = NULL;
 *
 * fpda_push_back(arr1, 1);
 * fpda_push_back(arr1, 2);
 * fpda_push_back(arr2, 3);
 * fpda_push_back(arr2, 4);
 *
 * fp_dynarray(int) combined = fpda_concatenate(arr1, arr2);
 * // combined: [1, 2, 3, 4]
 * // arr1 and arr2 unchanged
 *
 * assert(fpda_size(combined) == 4);
 *
 * fpda_free_and_null(arr1);
 * fpda_free_and_null(arr2);
 * fpda_free_and_null(combined);
 * @endcode
 */
#define fpda_concatenate(dest, src) (__fpda_global_concatenate_pointer = (void*)fpda_clone(dest), fpda_concatenate_in_place(__fpda_global_concatenate_pointer, (src)))

#ifdef __cplusplus
} // extern "C"
#endif

#endif // __LIB_FAT_POINTER_DYN_ARRAY_H__

/** @}*/

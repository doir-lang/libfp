/** \addtogroup capi
 *  @{
 */

/**
 * @file pointer.h
 * @brief Fat Pointer Library - Memory-safe pointer implementation with bounds checking
 *
 * This library provides "fat pointers" - pointers with embedded size information that enable
 * runtime bounds checking and memory safety. Fat pointers store metadata (size, magic number)
 * in a header just before the actual data, allowing automatic length tracking and validation.
 *
 * @section features Features
 * - Automatic bounds tracking for allocated memory
 * - Stack and heap allocation support
 * - Views (non-owning references to memory regions)
 * - Iterator support for range-based operations
 * - C and C++ compatibility
 *
 * @section single_header Single Header Library
 *
 * This library can be used standalone from the rest of the library... however certain
 * functions need FP_IMPLEMENTATION defined before the library is included to get definitions.
 * Be sure to #define FP_IMPLEMENTATION in only one source file!
 *
 * @section example_basic Basic Usage Example
 * @code{.cpp}
 * // Allocate a fat pointer array, notice that the result is a standard pointer and completely
 * //	compatible with all interfaces expecting a pointer.
 * int* arr = fp_malloc(int, 20);
 *
 * // Access with automatic bounds information
 * for(size_t i = 0; i < fp_length(arr); i++)
 *     arr[i] = i * 2;
 *
 * // Reallocate, the one place where C standard library functions won't work is when
 * //	reallocating or freeing fp memory... use the fp_ versions instead!
 * arr = fp_realloc(int, arr, 30);
 *
 * // Clean up... see the note on fp_realloc
 * fp_free_and_null(arr);
 * @endcode
 *
 * @section example_stack Stack Allocation Example
 * @code{.cpp}
 * void process_data() {
 *     // Stack-allocated fat pointer (automatically freed)
 *     float* temp = fp_alloca(float, 100);
 *
 *     // Use it like a normal array
 *     for(size_t i = 0; i < fp_length(temp); i++)
 *         temp[i] = i * 1.5f;
 *
 *     // Automatically freed when function returns
 * }
 * @endcode
 *
 * @section example_views Views Example
 * @code{.cpp}
 * int* data = fp_malloc(int, 100);
 *
 * // Create a view of a portion of the data
 * fp_view(int) subrange = fp_view_make(int, data, 10, 20);
 *
 * // Iterate over the view
 * fp_view_iterate_named(int, subrange, item)
 *     printf("%d\n", *item);
 *
 * fp_free_and_null(data);
 * @endcode
 */

#ifndef __LIB_FAT_POINTER_H__
#define __LIB_FAT_POINTER_H__

/**
 * @brief Executes an action and asserts a condition based on the result in debug mode
 * @param action Expression to execute (result stored in 'res')
 * @param assertion Condition to assert (can reference 'res')
 *
 * The action is always executed, but the assertion only fires in debug builds.
 * This ensures side effects occur in both debug and release builds.
 *
 * @code{.cpp}
 * do_and_assert(fopen("file.txt", "r"), res != NULL);
 * @endcode
 */
#define do_and_assert(action, assertion) do {\
	auto res = action;\
	assert(assertion);\
	(void)res;\
} while(false)

/**
 * @brief Assert macro where the condition itself has side effects that must always execute
 * @param assertion Expression to evaluate (always executed, assertion checked in debug)
 *
 * @code{.cpp}
 * assert_with_side_effects(write(fd, buffer, size) == size);
 * @endcode
 */
#define assert_with_side_effects(assertion) do_and_assert(assertion, res)

/// @cond INTERNAL
#define FP_DO_EXPAND(VAL) VAL ## 1
#define FP_EXPAND(VAL) FP_DO_EXPAND(VAL)

#ifndef __cplusplus
	#define FP_TYPE_OF(x) typeof(x)
	#define FP_TYPE_OF_REMOVE_POINTER(x) FP_TYPE_OF(*x)
#elif _MSC_VER
	#include <type_traits>
	template<typename T>
	using fp_type_of_t = std::remove_reference_t<T>;
	#define FP_TYPE_OF(x) fp_type_of_t<decltype(x)>
	template<typename T>
	using fp_type_of_remove_pointer_t = std::remove_pointer_t<fp_type_of_t<T>>;
	#define FP_TYPE_OF_REMOVE_POINTER(x) fp_type_of_remove_pointer_t<decltype(x)>
#else
	#include <type_traits>
	template<typename T>
	using fp_type_of_t = typename std::remove_reference<T>::type;
	#define FP_TYPE_OF(x) fp_type_of_t<decltype(x)>
	template<typename T>
	using fp_type_of_remove_pointer_t = typename std::remove_pointer<fp_type_of_t<T>>::type;
	#define FP_TYPE_OF_REMOVE_POINTER(x) fp_type_of_remove_pointer_t<decltype(x)>
#endif

#ifdef __cplusplus
#include <bit>
#include <type_traits>
#ifdef FP_ENABLE_STD_RANGES
#include <ranges>
#endif

#if defined(__cpp_lib_span) && __cpp_lib_span >= 202002L
	#include <span>
#endif

// From: https://stackoverflow.com/a/21121104
namespace detail {
	template <typename T>
	struct is_complete_helper {
		template <typename U>
		static auto test(U*)  -> std::integral_constant<bool, sizeof(U) == sizeof(U)>;
		static auto test(...) -> std::false_type;
		using type = decltype(test((T*)0));
	};

	template <typename T>
	struct is_complete : is_complete_helper<T>::type {};
	template <typename T>
	static constexpr bool is_complete_v = is_complete<T>::value;

	template<typename T>
	struct completed_sizeof{};
	template<typename T>
	requires(is_complete_v<T>)
	struct completed_sizeof<T> : std::integral_constant<std::size_t, sizeof(T)> {};
	template<typename T>
	requires(!is_complete_v<T>)
	struct completed_sizeof<T> : std::integral_constant<std::size_t, 0> {};

	template <typename T>
	static constexpr std::size_t completed_sizeof_v = completed_sizeof<T>::value;
}
/// @endcond

#ifndef FP_NOEXCEPT
	/**
	 * @brief `noexcept` in C++, empty in C
	 */
	#define FP_NOEXCEPT noexcept
#endif
#ifndef FP_CONSTEXPR
	/**
	 * @brief `constexpr` in C++, empty in C
	 */
	#define FP_CONSTEXPR constexpr
#endif

extern "C" {
#else
#ifndef FP_NOEXCEPT
	/**
	 * @brief `noexcept` in C++, empty in C
	 */
	#define FP_NOEXCEPT
#endif
#ifndef FP_CONSTEXPR
	/**
	 * @brief `constexpr` in C++, empty in C
	 */
	#define FP_CONSTEXPR
#endif
#endif

#include <stddef.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>

#ifndef FP_ALLOCATION_FUNCTION
	/**
	* @brief Default memory allocation function used by the fat pointer library
	* @param p Pointer to reallocate (NULL for new allocation)
	* @param size Size in bytes to allocate (0 to free)
	* @return Pointer to allocated memory or NULL if freed
	*
	* This function handles allocation, reallocation, and deallocation:
	* - If p is NULL and size > 0: allocates new memory
	* - If p is not NULL and size > 0: reallocates and copies data
	* - If size is 0: frees memory and returns NULL
	* - If size equals current allocation size: may return p unchanged
	*
	* You can override this by defining FP_ALLOCATION_FUNCTION before including this header.
	*
	* @code{.cpp}
	* // Custom allocator example
	* void* my_allocator(void* p, size_t size) {
	*     // Your custom allocation logic
	*     return custom_realloc(p, size);
	* }
	* #define FP_ALLOCATION_FUNCTION my_allocator
	* @endcode
	*/
	inline static void* __fp_alloc_default_impl(void* p, size_t size) FP_NOEXCEPT {
		if(size == 0) {
			if(p) free(p);
			return NULL;
		}

		return realloc(p, size);
	}
#define FP_ALLOCATION_FUNCTION __fp_alloc_default_impl
#endif

/**
 * @brief Magic numbers used to identify fat pointer types
 *
 * These magic numbers are stored in the header of each fat pointer to
 * identify its allocation type and validate that a pointer is indeed a fat pointer.
 *
 * @note These were chosen explicitly to be invalid unicode code points.
 */
enum FP_MagicNumbers {
	FP_MAGIC_NUMBER = 0xFE00,           ///< Base magic number (high byte mask)
	FP_HEAP_MAGIC_NUMBER = 0xFEFE,      ///< Heap-allocated fat pointer
	FP_STACK_MAGIC_NUMBER = 0xFEFF,     ///< Stack-allocated fat pointer
	FP_DYNARRAY_MAGIC_NUMBER = 0xFEFD,  ///< Dynamic array fat pointer
};

/// @cond INTERNAL
struct __FatPointerHeaderTruncated { // TODO: Make sure to keep this struct in sync with the following one
	uint16_t magic;
	size_t size;
};
/// @endcond

/** @}*/

/**
 * @brief Internal header structure stored before fat pointer data
 *
 * This structure is stored immediately before the pointer returned to the user.
 * It contains metadata about the allocation including size and type.
 *
 * Memory layout:
 * [__FatPointerHeader][user data...][null terminator]
 *                     ^ returned pointer
 * @internal
 */
struct __FatPointerHeader {
	uint16_t magic;  ///< Magic number identifying pointer type
	size_t size;     ///< Number of elements (not bytes) in the allocation
#ifndef __cplusplus
	uint8_t data[];  ///< Flexible array member for user data
#else
	uint8_t data[8]; ///< C++ doesn't support flexible arrays, use fixed size
#endif
};

#ifndef __cplusplus
	/// @brief Size of the fat pointer header in bytes
	#define FP_HEADER_SIZE sizeof(struct __FatPointerHeader)
#else
	/// @brief Size of the fat pointer header in bytes (C++ version)
	static constexpr size_t FP_HEADER_SIZE = sizeof(__FatPointerHeader) - detail::completed_sizeof_v<decltype(__FatPointerHeader{}.data)>;
#endif

/// @cond INTERNAL
#define FP_CONCAT_(x,y) x##y
#define FP_CONCAT(x,y) FP_CONCAT_(x,y)
/// @endcond

/** \addtogroup capi
 *  @{
 */

#ifdef __GNUC__
// From: https://stackoverflow.com/a/58532788
/**
 * @brief Safe maximum of two values (GNU C extension)
 * @param a First value
 * @param b Second value
 * @return Maximum of a and b
 */
#define FP_MAX(a,b)\
	({\
		__typeof__ (a) __FP_a = (a);\
		__typeof__ (a) __FP_b = (b);\
		__FP_a > __FP_b ? __FP_a : __FP_b;\
	})
/**
 * @brief Safe minimum of two values (GNU C extension)
 * @param a First value
 * @param b Second value
 * @return Minimum of a and b
 */
#define FP_MIN(a,b)\
	({\
		__typeof__ (a) __FP_a = (a);\
		__typeof__ (a) __FP_b = (b);\
		__FP_a < __FP_b ? __FP_a : __FP_b;\
	})
#elif defined(__cplusplus)
#include <algorithm>
/**
 * @brief Safe minimum of two values
 * @param a First value
 * @param b Second value
 * @return Minimum of a and b
 */
#define FP_MIN(a, b) (std::min((a), (FP_TYPE_OF(a))(b)))
/**
 * @brief Safe maximum of two values
 * @param a First value
 * @param b Second value
 * @return Maximum of a and b
 */
#define FP_MAX(a, b) (std::max((a), (FP_TYPE_OF(a))(b)))
#else
#pragma message("Unsafe Min / Max macros")
/**
 * @brief Maximum of two values
 * @param a First value
 * @param b Second value
 * @return Maximum of a and b
 */
#define FP_MAX(a,b) ((a) > (b) ? (a) : (b))
/**
 * @brief Minimum of two values
 * @param a First value
 * @param b Second value
 * @return Minimum of a and b
 */
#define FP_MIN(a,b) ((a) < (b) ? (a) : (b))
#endif

#ifndef __cplusplus
/**
 * @brief Thread local header utilized as an intermediate by fp_alloca and fp_alloca_void
 */
static thread_local struct __FatPointerHeader* __fp_global_header;
/**
 * @brief Allocate a fat pointer on the stack (generic version)
 * @param _typesize Size of each element in bytes
 * @param _size Number of elements to allocate
 * @return Void pointer to allocated stack memory with fat pointer header
 *
 * Stack-allocated fat pointers are automatically freed when the scope exits.
 * Use fp_alloca() macro for type-safe version.
 *
 * @warning Stack allocations have limited size. Use fp_malloc() for large allocations.
 *
 * @code{.cpp}
 * void process() {
 *     void* buffer = fp_alloca_void(1, 1024); // 1024 bytes
 *     // Use buffer...
 *     // Automatically freed on return
 * }
 * @endcode
 */
#define fp_alloca_void(_typesize, _size) (__fp_global_header = (struct __FatPointerHeader*)alloca(FP_HEADER_SIZE + _typesize * _size + 1),\
	*__fp_global_header = (struct __FatPointerHeader) {\
		.magic = FP_STACK_MAGIC_NUMBER,\
		.size = (_size),\
	}, (void*)(((uint8_t*)__fp_global_header) + FP_HEADER_SIZE))
#elif defined(_WIN32)
#include <malloc.h>
/**
 * @brief Allocate a fat pointer on the stack (generic version)
 * @param _typesize Size of each element in bytes
 * @param _size Number of elements to allocate
 * @return Void pointer to allocated stack memory with fat pointer header
 *
 * Stack-allocated fat pointers are automatically freed when the scope exits.
 * Use fp_alloca() macro for type-safe version.
 *
 * @warning Stack allocations have limited size. Use fp_malloc() for large allocations.
 *
 * @code{.cpp}
 * void process() {
 *     void* buffer = fp_alloca_void(1, 1024); // 1024 bytes
 *     // Use buffer...
 *     // Automatically freed on return
 * }
 * @endcode
 */
#define fp_alloca_void(_typesize, _size) ((void*)(((uint8_t*)&((*(__FatPointerHeader*)_alloca(FP_HEADER_SIZE + _typesize * FP_MAX(_size, 8) + 1)) = \
	__FatPointerHeader {\
		.magic = FP_STACK_MAGIC_NUMBER,\
		.size = (_size),\
	})) + FP_HEADER_SIZE))
#else
#include <alloca.h>
/**
 * @brief Allocate a fat pointer on the stack (generic version)
 * @param _typesize Size of each element in bytes
 * @param _size Number of elements to allocate
 * @return Void pointer to allocated stack memory with fat pointer header
 *
 * Stack-allocated fat pointers are automatically freed when the scope exits.
 * Use fp_alloca() macro for type-safe version.
 *
 * @warning Stack allocations have limited size. Use fp_malloc() for large allocations.
 *
 * @code{.cpp}
 * void process() {
 *     void* buffer = fp_alloca_void(1, 1024); // 1024 bytes
 *     // Use buffer...
 *     // Automatically freed on return
 * }
 * @endcode
 */
#define fp_alloca_void(_typesize, _size) ((void*)(((uint8_t*)&((*(__FatPointerHeader*)alloca(FP_HEADER_SIZE + _typesize * FP_MAX(_size, 8) + 1)) = \
	__FatPointerHeader {\
		.magic = FP_STACK_MAGIC_NUMBER,\
		.size = (_size),\
	})) + FP_HEADER_SIZE))
#endif

/**
 * @brief Allocate a typed fat pointer on the stack
 * @param type Element type
 * @param _size Number of elements to allocate
 * @return Typed pointer to allocated stack memory
 *
 * @warning Stack allocations have limited size. Use fp_malloc() for large allocations.
 * @warning Stack memory is only valid within the current scope. Do not return
 *          stack-allocated pointers from functions.
 *
 * Best practices:
 * - Use fp_alloca() for temporary buffers < 10KB
 * - Use fp_malloc() for anything larger or with dynamic lifetime
 * - Never return stack-allocated pointers
 * - Be careful with recursion and stack allocations
 *
 * @see fp_alloca() for type-safe version
 * @see fp_malloc() for heap allocation
 * @see fp_is_stack_allocated() to check allocation type
 *
 * @code{.cpp}
 * void compute() {
 *     int* numbers = fp_alloca(int, 50);
 *     for(int i = 0; i < 50; i++) {
 *         numbers[i] = i * i;
 *     }
 *     printf("Length: %zu\n", fp_length(numbers));
 *     // Automatically freed
 * }
 * @endcode
 */
#define fp_alloca(type, _size) ((type*)fp_alloca_void(sizeof(type), _size))

/** @} */

/**
 * @brief Get the header of a fat pointer
 * @param _p Fat pointer
 * @return Pointer to the header structure
 * @internal
 */
FP_CONSTEXPR inline static struct __FatPointerHeader* __fp_header(const void* _p) FP_NOEXCEPT {
	uint8_t* p = (uint8_t*)_p;
	p -= FP_HEADER_SIZE;
#if FP_EXPAND(FP_CONSTEXPR) == 1
	return (struct __FatPointerHeader*)p;
#else
	return (struct __FatPointerHeader*)(void*)p;
#endif
}

/**
 * @brief Internal allocation function for fat pointers
 * @param _p Existing fat pointer to reallocate (NULL for new allocation)
 * @param _size Size in bytes to allocate
 * @return Fat pointer to allocated memory
 * @internal
 */
void* __fp_alloc(void* _p, size_t _size) FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	if(_p == NULL && _size == 0) return NULL;
	if(_size == 0)
		return FP_ALLOCATION_FUNCTION(__fp_header(_p), 0);

	_p = _p == NULL ? _p : __fp_header(_p);
#ifdef __cplusplus
	_size = FP_MAX(_size, 8); // Since the C++ header assumes the buffer is 8 elements large, it will overwrite memory out to 8 bytes... thus we must reserve at least that much memory
#endif
	size_t size = FP_HEADER_SIZE + _size + 1;
	uint8_t* p = (uint8_t*)FP_ALLOCATION_FUNCTION(_p, size);
	if(!p) return 0;
	p += FP_HEADER_SIZE;
	auto h = __fp_header(p);
	h->magic = FP_HEAP_MAGIC_NUMBER;
	h->size = _size;
	h->data[_size] = 0;
	return p;
}
#else
;
#endif

/**
 * @brief Internal reallocation function for fat pointers (properly updates the header for the specific type)
 * @param p Existing fat pointer
 * @param type_size Size of each element
 * @param count Number of elements
 * @return Reallocated fat pointer
 * @internal
 */
inline static void* __fp_realloc(void* p, size_t type_size, size_t count) FP_NOEXCEPT {
	auto out = __fp_alloc(p, type_size * count);
	auto h = __fp_header(out);
	h->magic = FP_HEAP_MAGIC_NUMBER;
	h->size = count;
	return out;
}

/** \addtogroup capi
 *  @{
 */

/**
 * @brief Allocate a typed fat pointer on the heap
 * @param type Element type
 * @param _size Number of elements to allocate
 * @return Typed pointer to allocated heap memory
 *
 * @code{.cpp}
 * int* data = fp_malloc(int, 100);
 * for(size_t i = 0; i < fp_length(data); i++) {
 *     data[i] = rand();
 * }
 * fp_free_and_null(data);
 * @endcode
 */
#define fp_malloc(type, _size) ((type*)__fp_realloc(nullptr, sizeof(type), (_size)))

/**
 * @brief Reallocate a fat pointer with a new size
 * @param type Element type
 * @param p Existing fat pointer
 * @param _size New number of elements
 * @return Reallocated typed pointer (may be different address)
 *
 * Existing data is preserved up to the minimum of old and new sizes.
 *
 * @code{.cpp}
 * float* values = fp_malloc(float, 50);
 * // ... use values ...
 * values = fp_realloc(float, values, 100); // Expand to 100 elements
 * @endcode
 */
#define fp_realloc(type, p, _size) ((type*)__fp_realloc(p, sizeof(type), (_size)))

/**
 * @brief Check if a pointer is a valid fat pointer
 * @param p Pointer to check
 * @return true if p is a valid fat pointer, false otherwise
 *
 * @code{.cpp}
 * int* arr = fp_malloc(int, 10);
 * int* regular = malloc(sizeof(int) * 10);
 *
 * assert(is_fp(arr) == true);
 * assert(is_fp(regular) == false);
 * assert(is_fp(NULL) == false);
 *
 * fp_free_and_null(arr);
 * free(regular);
 * @endcode
 */
#ifdef __GNUC__
__attribute__((no_sanitize_address)) // Don't let this function which routinely peaks out of valid bounds trigger the address sanitizer
#endif
FP_CONSTEXPR inline static bool is_fp(const void* p) FP_NOEXCEPT {
	if(p == NULL) return false;
	auto h = __fp_header(p);
	auto capacity = (size_t*)(((char*)h) - sizeof(size_t)); // Manually access fpda capacity
	return (h->magic & 0xFF00) == FP_MAGIC_NUMBER && (h->size > 0 || *capacity > 0);
}

/**
 * @brief Get the magic number of a fat pointer
 * @param p Fat pointer
 * @return Magic number identifying the allocation type
 *
 * @see FP_MagicNumbers
 */
FP_CONSTEXPR inline static size_t fp_magic_number(const void* p) FP_NOEXCEPT {
	if(p == NULL) return false;
	auto h = __fp_header(p);
	return h->magic;
}

/**
 * @brief Check if a fat pointer is stack-allocated
 * @param p Fat pointer
 * @return true if stack-allocated, false otherwise
 *
 * @code{.cpp}
 * int* heap = fp_malloc(int, 10);
 * int* stack = fp_alloca(int, 10);
 *
 * assert(!fp_is_stack_allocated(heap));
 * assert(fp_is_stack_allocated(stack));
 * @endcode
 */
FP_CONSTEXPR inline static bool fp_is_stack_allocated(const void* p) FP_NOEXCEPT {
	return fp_magic_number(p) == FP_STACK_MAGIC_NUMBER;
}

/**
 * @brief Check if a fat pointer is heap-allocated
 * @param p Fat pointer
 * @return true if heap-allocated, false otherwise
*
 * @code{.cpp}
 * int* heap = fp_malloc(int, 10);
 * int* stack = fp_alloca(int, 10);
 *
 * assert(fp_is_heap_allocated(heap));
 * assert(!fp_is_heap_allocated(stack));
 * @endcode
 */
FP_CONSTEXPR inline static bool fp_is_heap_allocated(const void* p) FP_NOEXCEPT {
	return fp_magic_number(p) == FP_HEAP_MAGIC_NUMBER || fp_magic_number(p) == FP_DYNARRAY_MAGIC_NUMBER;
}

/**
 * @brief Free a heap-allocated fat pointer
 * @param p Fat pointer to free
 *
 * @warning Only use with heap-allocated fat pointers (from fp_malloc/fp_realloc).
 *          Stack-allocated pointers are freed automatically.
 *
 * @code{.cpp}
 * int* data = fp_malloc(int, 100);
 * // ... use data ...
 * fp_free(data);
 * @endcode
 */
inline static void fp_free(void* p) FP_NOEXCEPT { __fp_alloc(p, 0); }

/**
 * @brief Free a fat pointer and set it to NULL
 * @param p Fat pointer to free
 *
 * In general this macro is safer than using fp_free directly
 *
 * @code{.cpp}
 * int* data = fp_malloc(int, 50);
 * fp_free_and_null(data);
 * assert(data == NULL);
 * @endcode
 */
#define fp_free_and_null(p) (fp_free(p), p = NULL)

/**
 * @brief Get the number of elements in a fat pointer
 * @param p Fat pointer
 * @return Number of elements (not bytes) in the allocation
 *
 * @code{.cpp}
 * double* arr = fp_malloc(double, 75);
 * printf("Array has %zu elements\n", fp_length(arr)); // Prints: 75
 * @endcode
 */
FP_CONSTEXPR inline static size_t fp_length(const void* p) FP_NOEXCEPT {
	if(!is_fp(p)) return 0;
	return __fp_header(p)->size;
}

/**
 * @brief Alias for #fp_length()
 */
#define fp_size fp_length // TODO: Why doesn't this link?

/**
 * @brief Check if a fat pointer is empty (zero length)
 * @param p Fat pointer
 * @return true if empty, false otherwise
 *
 * @code{.cpp}
 * int* empty = fp_malloc(int, 0);
 * int* full = fp_malloc(int, 10);
 * assert(fp_empty(empty));
 * assert(!fp_empty(full));
 * @endcode
 */
FP_CONSTEXPR inline static bool fp_empty(const void* p) FP_NOEXCEPT {
	return fp_length(p) == 0;
}

/**
 * @brief Get pointer to the first element
 * @param a Fat pointer
 * @return Pointer to first element
 */
#define fp_front(a) (a)

/// @brief Alias for fp_front
#define fp_begin(a) fp_front(a)

/** @} */

/**
 * @brief Get pointer to the last element (internal implementation)
 * @param a Fat pointer
 * @param type_size Size of each element
 * @return Pointer to last element
 * @internal \ingroup capi-implementation
 */
FP_CONSTEXPR inline static void* __fp_back(void* a, size_t type_size) {
	return ((uint8_t*)a) + (fp_size(a) > 0 ? fp_size(a) - 1 : 0) * type_size;
}

/** \addtogroup capi
 *  @{
 */

/**
 * @brief Get pointer to the last element
 * @param a Fat pointer
 * @return Typed pointer to last element
 *
 * @code{.cpp}
 * int* arr = fp_malloc(int, 10);
 * *fp_front(arr) = 1;   // First element
 * *fp_back(arr) = 100;  // Last element
 * @endcode
 */
#define fp_back(a) ((FP_TYPE_OF_REMOVE_POINTER(a)*)__fp_back((a), sizeof(*a)))

/**
 * @brief Get pointer to one past the last element (end iterator)
 * @param a Fat pointer
 * @return Pointer to one past the end
 *
 * @code{.cpp}
 * int* arr = fp_malloc(int, 5);
 * for(int* p = fp_begin(arr); p != fp_end(arr); ++p) {
 *     *p = 0;
 * }
 * @endcode
 */
#define fp_end(a) (fp_size(a) ? fp_back(a) + 1 : fp_begin(a))

#if defined __cplusplus && defined FP_ENABLE_STD_RANGES
/**
 * @brief Convert fat pointer to std::ranges::subrange
 * @param a Fat pointer
 * @return std::ranges::subrange over the fat pointer
 *
 * Requires FP_ENABLE_STD_RANGES to be defined.
 *
 * @code{.cpp}
 * int* arr = fp_malloc(int, 100);
 * auto range = fp_as_std_range(arr);
 * for(int val : range) {
 *     std::cout << val << "\n";
 * }
 * @endcode
 */
#define fp_as_std_range(a) (std::ranges::subrange(fp_begin(a), fp_end(a)))
#endif

/**
 * @brief Iterate over fat pointer with named iterator
 * @param a Fat pointer
 * @param iter Iterator variable name
 *
 * @code{.cpp}
 * int* arr = fp_malloc(int, 10);
 * fp_iterate_named(arr, ptr) {
 *     *ptr = ptr - arr; // Set to index
 * }
 * @endcode
 */
#define fp_iterate_named(a, iter) for(auto __fp_start = (a), iter = __fp_start; iter < __fp_start + fp_length(__fp_start); ++iter)

/**
 * @brief Iterate over fat pointer (iterator named 'i')
 * @param a Fat pointer
 *
 * @code{.cpp}
 * float* values = fp_malloc(float, 20);
 * fp_iterate(values) {
 *     *i = 3.14f;
 * }
 * @endcode
 */
#define fp_iterate(a) fp_iterate_named((a), i)

/**
 * @brief Calculate index from iterator and base pointer
 * @param a Base fat pointer
 * @param i Iterator pointer
 * @return Index as size_t
 *
 * @code{.cpp}
 * int* arr = fp_malloc(int, 100);
 * fp_iterate_named(arr, ptr) {
 *     size_t idx = fp_iterate_calculate_index(arr, ptr);
 *     printf("Index: %zu, Value: %d\n", idx, *ptr);
 * }
 * @endcode
 */
#define fp_iterate_calculate_index(a, i) ((i) - (a))

/**
 * @brief Iterate over fat pointer in reverse with named iterator
 * @param a Fat pointer
 * @param iter Iterator variable name
 *
 * @code{.cpp}
 * int* arr = fp_malloc(int, 5);
 * int val = 0;
 * fp_iterate(arr) { *i = val++; }
 *
 * fp_iterate_reverse(arr, item) {
 *     printf("%d ", *item); // Prints: 4 3 2 1 0
 * }
 * @endcode
 */
#define fp_iterate_reverse_named(a, iter) for(auto __fp_start = (a), iter = __fp_start + fp_length(__fp_start) - 1; iter >= __fp_start; --iter)

/**
 * @brief Iterate over fat pointer in reverse (iterator named 'i')
 * @param a Fat pointer
 *
 * @code{.cpp}
 * int* arr = fp_malloc(int, 5);
 * int val = 0;
 * fp_iterate(arr) { *i = val++; }
 *
 * fp_iterate_reverse(arr) {
 *     printf("%d ", *i); // Prints: 4 3 2 1 0
 * }
 * @endcode
 */
#define fp_iterate_reverse(a) fp_iterate_reverse_named((a), i)

/**
 * @brief Swap memory contents of two regions
 * @param a First memory region
 * @param b Second memory region
 * @param n Number of bytes to swap
 * @return Pointer to first region (second before the swap), or NULL if regions are identical
 *
 * @code{.cpp}
 * int x = 10, y = 20;
 * memswap(&x, &y, sizeof(int));
 * // Now x == 20, y == 10
 * @endcode
 */
void* memswap(void* a, void* b, size_t n) FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	if (a == b) return nullptr;
	char* buffer = fp_alloca(char, n);
	memcpy(buffer, a, n);
	memmove(a, b, n);
	memcpy(b, buffer, n);
	return a;
}
#else
;
#endif

/**
 * @brief Swap contents of two fat pointers
 * @param a First fat pointer
 * @param b Second fat pointer
 * @return true if swap succeeded, false if sizes don't match
 *
 * Both pointers must have the same size for the swap to succeed.
 *
 * @code{.cpp}
 * int* arr1 = fp_malloc(int, 5);
 * int* arr2 = fp_malloc(int, 5);
 *
 * fp_iterate(arr1) { *i = 1; }
 * fp_iterate(arr2) { *i = 2; }
 *
 * fp_swap(arr1, arr2);
 * // Now arr1 contains all 2s, arr2 contains all 1s
 * @endcode
 */
inline static bool fp_swap(void* a, void* b) FP_NOEXCEPT {
	assert(is_fp(a) && is_fp(b));

	size_t size = fp_size(a);
	if(size != fp_size(b)) return false;
	return memswap(a, b, size) != nullptr;
}

/** @} */

/**
 * @brief Internal implementation for cloning a fat pointer
 * @param ptr Fat pointer to clone
 * @param type_size Size of each element
 * @return New fat pointer with copied data
 * @internal
 */
inline static void* __fp_clone(const void* ptr, size_t type_size) FP_NOEXCEPT {
	assert(is_fp(ptr));

	size_t size = fp_size(ptr);
	auto out = __fp_realloc(nullptr, type_size, size);
	memcpy(out, ptr, size * type_size);
	return out;
}

/** \addtogroup capi
 *  @{
 */

/**
 * @brief Create a shallow copy of a fat pointer
 * @param a Fat pointer to clone
 * @return New heap-allocated fat pointer with copied data
 *
 * Creates an independent copy of the data. The new pointer must be freed separately.
 *
 * @code{.cpp}
 * int* original = fp_malloc(int, 10);
 * fp_iterate(original) { *i = 42; }
 *
 * int* copy = fp_clone(original);
 * copy[0] = 99; // Doesn't affect original
 *
 * fp_free_and_null(original);
 * fp_free_and_null(copy);
 * @endcode
 */
#define fp_clone(a) ((FP_TYPE_OF_REMOVE_POINTER(a)*)__fp_clone((a), sizeof(*a)))

/** @} */

/**
 * @brief Internal implementation for checking if fat pointer contains a value
 * @param a Fat pointer to search
 * @param needle Pointer to value to find
 * @param type_size Size of each element
 * @return true if value found, false otherwise
 * @internal
 */
inline static bool __fp_contains(void* a, void* needle, size_t type_size) {
	auto __fp_start = (char*)a;
	for(auto iter = __fp_start; iter < __fp_start + fp_length(__fp_start) * type_size; iter += type_size)
		if(memcmp(iter, needle, type_size) == 0)
			return true;
	return false;
}

/** \addtogroup capi
 *  @{
 */

/**
 * @brief Check if a fat pointer contains a specific value
 * @param a Fat pointer to search
 * @param needle Value to find
 * @return true if value found, false otherwise
 *
 * Uses memcmp for comparison, so works with any type.
 *
 * @code{.cpp}
 * int* numbers = fp_malloc(int, 100);
 * numbers[50] = 42;
 *
 * assert(fp_contains(numbers, 42));
 * assert(!fp_contains(numbers, 999));
 * @endcode
 */
#define fp_contains(a, needle) (__fp_contains((a), (&needle), sizeof(*a)))

/**
 * @brief Sentinel value indicating element not found in search operations
 *
 * This value is returned by fp_find and fp_rfind when the searched element
 * is not present in the fat pointer. It is set to SIZE_MAX, the maximum
 * value of size_t, which cannot be a valid index.
 *
 * @code{.cpp}
 * int* arr = fp_malloc(int, 10);
 * size_t idx = fp_find(arr, 42);
 * if(idx == fp_not_found) {
 *     printf("Value not found\n");
 * }
 * @endcode
 */
#define fp_not_found SIZE_MAX

/** @} */

/**
 * @brief Internal implementation for finding a value in a fat pointer
 * @param a Fat pointer to search
 * @param needle Pointer to value to find
 * @param type_size Size of each element
 * @return Index of found element, or fp_not_found if not found
 * @internal
 */
inline static size_t __fp_find(void* a, void* needle, size_t type_size) {
	auto __fp_start = (char*)a;
	size_t index = 0;
	for(auto iter = __fp_start; iter < __fp_start + fp_length(__fp_start) * type_size; iter += type_size, ++index)
		if(memcmp(iter, needle, type_size) == 0)
			return index;
	return fp_not_found;
}

/** \addtogroup capi
 *  @{
 */

/**
 * @brief Find the index of a specific value in a fat pointer
 * @param a Fat pointer to search
 * @param needle Value to find
 * @return Index of first occurrence (size_t), or fp_not_found if not found
 *
 * Uses memcmp for comparison, so works with any type.
 * Returns fp_not_found (SIZE_MAX) if the element is not present.
 *
 * @code{.cpp}
 * int* numbers = fp_malloc(int, 100);
 * for(size_t i = 0; i < fp_length(numbers); i++) {
 *     numbers[i] = i * 2;
 * }
 * numbers[50] = 999;
 *
 * size_t idx = fp_find(numbers, 999);
 * if(idx != fp_not_found) {
 *     printf("Found at index: %zu\n", idx); // Prints: 50
 * } else {
 *     printf("Not found\n");
 * }
 *
 * // Not found case
 * assert(fp_find(numbers, 777) == fp_not_found);
 * @endcode
 */
#define fp_find(a, needle) (__fp_find((a), (&needle), sizeof(*a)))

/** @} */

/**
 * @brief Internal implementation for finding a value from the end of a fat pointer
 * @param a Fat pointer to search
 * @param needle Pointer to value to find
 * @param type_size Size of each element
 * @return Index of found element, or fp_not_found if not found
 * @internal
 */
inline static size_t __fp_rfind(void* a, void* needle, size_t type_size) {
	auto __fp_start = (char*)a;
	size_t length = fp_length(__fp_start);
	if(length == 0) return fp_not_found;

	size_t index = length - 1;
	for(auto iter = __fp_start + (length - 1) * type_size; iter >= __fp_start; iter -= type_size, --index)
		if(memcmp(iter, needle, type_size) == 0)
			return index;
	return fp_not_found;
}

/** \addtogroup capi
 *  @{
 */

/**
 * @brief Find the index of a specific value searching from the end (reverse find)
 * @param a Fat pointer to search
 * @param needle Value to find
 * @return Index of last occurrence (size_t), or fp_not_found if not found
 *
 * Searches backwards through the fat pointer, returning the index of the last
 * occurrence of the value. Uses memcmp for comparison, so works with any type.
 * Returns fp_not_found (SIZE_MAX) if the element is not present.
 *
 * @code{.cpp}
 * int* numbers = fp_malloc(int, 100);
 * for(size_t i = 0; i < fp_length(numbers); i++) {
 *     numbers[i] = i % 10;  // 0,1,2,...,9,0,1,2,...
 * }
 *
 * // Find last occurrence of 5
 * size_t first = fp_find(numbers, 5);   // Returns 5
 * size_t last = fp_rfind(numbers, 5);   // Returns 95
 *
 * printf("First occurrence: %zu\n", first);
 * printf("Last occurrence: %zu\n", last);
 *
 * // Not found case
 * assert(fp_rfind(numbers, 999) == fp_not_found);
 * @endcode
 */
#define fp_rfind(a, needle) (__fp_rfind((a), (&needle), sizeof(*a)))

#ifdef __cplusplus
}

/**
 * @brief View structure for non-owning references to memory regions (C++ template version)
 * @tparam T Element type
 *
 * A view is a non-owning reference to a contiguous memory region. It stores a pointer
 * and size but does not manage the lifetime of the data.
 */
template<typename T>
struct __fp_view {
	T* data;        ///< Pointer to data
	size_t size;    ///< Number of elements

	/**
	 * @brief Convert view to another type
	 * @tparam To Target element type
	 * @return View with reinterpreted pointer type
	 */
	template<typename To>
	explicit operator __fp_view<To>() const { return {(To*)data, size}; }
};

/**
 * @brief Define a view type for a specific element type
 * @param type Element type
 *
 * @code{.cpp}
 * fp_view(int) my_view;
 * fp_view(char) str_view;
 * @endcode
 */
#define fp_view(type) __fp_view<type>

/**
 * @brief Create a view literal
 * @param type Element type
 * @param data Pointer to data
 * @param size Number of elements
 * @return View structure
 *
 * @code{.cpp}
 * int buffer[10];
 * fp_view(int) v = fp_view_literal(int, buffer, 10);
 * @endcode
 */
#define fp_view_literal(type, data, size) (fp_view(type){(type*)(data), (size)})

/// @brief View type for untyped (void) data
using fp_void_view = fp_view(void);

extern "C" {
#else
/**
 * @brief View structure for non-owning references to memory regions (C version)
 *
 * In C, all views are untyped. Use casting to access typed data.
 */
struct __fp_view {
	void* data;     ///< Pointer to data
	size_t size;    ///< Number of elements
};

/**
 * @brief Define a view type for a specific element type (C version)
 * @param type Element type
 *
 * @code{.cpp}
 * fp_view(int) my_view;
 * fp_view(char) str_view;
 * @endcode
 */
#define fp_view(type) struct __fp_view

/**
 * @brief Create a view literal (C version)
 * @param type Element type
 * @param data Pointer to data
 * @param size Number of elements
 * @return View structure
 *
 * @code{.cpp}
 * int buffer[10];
 * fp_view(int) v = fp_view_literal(int, buffer, 10);
 * @endcode
 */
#define fp_view_literal(type, data, size) ((fp_view(type)) {(void*)(data), (size)})

/// @brief View type for untyped (void) data
typedef fp_view(void) fp_void_view;
#endif

/**
 * @brief Create a void view literal
 * @param data Pointer to data
 * @param size Number of elements
 * @return Untyped view
 */
#define fp_void_view_literal(data, size) fp_view_literal(void, data, size)

/**
 * @brief Create a view from a single variable
 * @param type Element type
 * @param var Variable to create view of
 * @return View with size 1 pointing to the variable
 *
 * @code{.cpp}
 * int x = 42;
 * fp_view(int) v = fp_view_from_variable(int, x);
 * assert(fp_view_size(v) == 1);
 * assert(*fp_view_data(int, v) == 42);
 * @endcode
 */
#define fp_view_from_variable(type, var) fp_view_literal(type, &(var), 1)

/**
 * @brief Convert a variable to a void view
 * @param type Type of variable
 * @param data Variable
 * @return Void view of the variable's memory
 *
 * @code{.cpp}
 * double value = 3.14;
 * fp_void_view v = fp_variable_to_void_view(double, value);
 * assert(fp_view_size(v) == sizeof(double));
 * @endcode
 */
#define fp_variable_to_void_view(type, data) fp_void_view_literal(&data, sizeof(type))

#if defined(_MSC_VER)
}
#endif

/** @} */

/**
 * @brief Internal implementation for creating a view from a fat pointer
 * @param p Fat pointer
 * @param type_size Size of each element
 * @param start Starting index
 * @param length Number of elements
 * @return Void view of the specified range
 * @internal
 */
FP_CONSTEXPR inline static fp_void_view __fp_make_view(void* p, size_t type_size, size_t start, size_t length) FP_NOEXCEPT {
	assert(start + length <= fp_size(p));
#ifdef __cplusplus
	return fp_void_view
#else
	return (fp_void_view)
#endif
		{((uint8_t*)p) + type_size * start, length};
}

#if defined(_MSC_VER)
extern "C" {
#endif

/** \addtogroup capi
 *  @{
 */

/**
 * @brief Create a view from a range within a fat pointer
 * @param type Element type
 * @param p Fat pointer
 * @param start Starting index (inclusive)
 * @param length Number of elements
 * @return Typed view of the specified range
 *
 * @code{.cpp}
 * int* arr = fp_malloc(int, 100);
 *
 * // Create view of elements 10-29 (20 elements)
 * fp_view(int) middle = fp_view_make(int, arr, 10, 20);
 *
 * fp_view_iterate(int, middle) {
 *     *i = 999;
 * }
 * @endcode
 */
#define fp_view_make(type, p, start, length) ((fp_view(type))__fp_make_view((p), sizeof(*(p)), (start), (length)))

/**
 * @brief Create a view of an entire fat pointer
 * @param type Element type
 * @param p Fat pointer
 * @return View covering all elements
 *
 * @code{.cpp}
 * float* data = fp_malloc(float, 50);
 * fp_view(float) full = fp_view_make_full(float, data);
 * assert(fp_view_size(full) == 50);
 * @endcode
 */
#define fp_view_make_full(type, p) fp_view_make(type, p, 0, fp_size(p))

/**
 * @brief Create a view using start and end indices
 * @param type Element type
 * @param p Fat pointer
 * @param start Starting index (inclusive)
 * @param end Ending index (inclusive)
 * @return View of the range [start, end]
 *
 * @code{.cpp}
 * int* arr = fp_malloc(int, 100);
 * // View elements 20-30 (inclusive)
 * fp_view(int) slice = fp_view_make_start_end(int, arr, 20, 30);
 * assert(fp_view_size(slice) == 11);
 * @endcode
 */
#define fp_view_make_start_end(type, p, start, end) fp_view_make(type, p, (start), ((end) - (start) + 1))

/**
 * @brief Get the number of elements in a view
 * @param view View structure
 * @return Number of elements
 */
#define fp_view_length(view) ((view).size)

/// @brief Alias for fp_view_length
#define fp_view_size(view) fp_view_length(view)

/**
 * @brief Get untyped data pointer from view
 * @param view View structure
 * @return Void pointer to data
 */
#define fp_view_data_void(view) ((void*)(view).data)

/**
 * @brief Get typed data pointer from view
 * @param type Element type
 * @param view View structure
 * @return Typed pointer to data
 *
 * @code{.cpp}
 * fp_view(double) v = ...;
 * double* ptr = fp_view_data(double, v);
 * @endcode
 */
#define fp_view_data(type, view) ((type*)fp_view_data_void(view))

/**
 * @brief Access element in view by index
 * @param type Element type
 * @param view View structure
 * @param index Index to access
 * @return Pointer to element at index
 *
 * Asserts that index is within bounds.
 *
 * @code{.cpp}
 * fp_view(int) v = ...;
 * int* elem = fp_view_access(int, v, 5);
 * *elem = 42;
 * @endcode
 */
#define fp_view_access(type, view, index) (assert((index) < fp_view_length(view)), fp_view_data(type, view) + (index))

/// @brief Alias for fp_view_access
#define fp_view_subscript(type, view, index) fp_view_access(type, view, index)

/**
 * @brief Convert a typed view to a byte view
 * @param type Original element type
 * @param view View to convert
 * @return View of bytes (fp_view(uint8_t))
 *
 * @code{.cpp}
 * fp_view(int) int_view = ...;
 * fp_view(uint8_t) bytes = fp_view_to_byte_view(int, int_view);
 * // bytes.size == int_view.size * sizeof(int)
 * @endcode
 */
#define fp_view_to_byte_view(type, view) fp_view_literal(uint8_t, fp_view_data(type, (view)), fp_view_size((view)) * sizeof(type))

/**
 * @brief Get pointer to first element in view
 * @param type Element type
 * @param view View structure
 * @return Pointer to first element
 */
#define fp_view_front(type, view) fp_view_data(type, view)

/// @brief Alias for fp_view_front
#define fp_view_begin(type, view) fp_view_front(type, view)

/** @} */

/**
 * @brief Internal implementation for getting last element pointer
 * @param view Void view
 * @param type_size Size of each element
 * @return Pointer to last element
 * @internal
 */
FP_CONSTEXPR inline static void* __fp_view_back(fp_void_view view, size_t type_size) {
	return (fp_view_data(uint8_t, view)) + (fp_view_size(view) > 0 ? fp_view_size(view) - 1 : 0) * type_size;
}

/** \addtogroup capi
 *  @{
 */

/**
 * @brief Get pointer to last element in view
 * @param type Element type
 * @param view View structure
 * @return Pointer to last element
 *
 * @code{.cpp}
 * fp_view(int) v = ...;
 * *fp_view_front(int, v) = 1;
 * *fp_view_back(int, v) = 100;
 * @endcode
 */
#define fp_view_back(type, view) ((type*)__fp_view_back((fp_void_view)(view), sizeof(type)))

/**
 * @brief Get pointer to one past the last element (end iterator)
 * @param type Element type
 * @param view View structure
 * @return Pointer to one past the end
 */
#define fp_view_end(type, view) (fp_view_size(view) ? fp_view_back(type,view) + 1 : fp_view_begin(type, view))

#if defined __cplusplus && defined FP_ENABLE_STD_RANGES
/**
 * @brief Convert view to std::ranges::subrange
 * @param type Element type
 * @param view View structure
 * @return std::ranges::subrange
 *
 * Requires FP_ENABLE_STD_RANGES.
 */
#define fp_view_as_std_range(type, view) (std::ranges::subrange(fp_view_begin(type, (view)), fp_view_end(type, (view))))
#endif

/** @} */

/**
 * @brief Internal implementation for creating subview
 * @param view Parent view
 * @param type_size Size of each element
 * @param start Starting index
 * @param length Number of elements
 * @return Subview of the specified range
 * @internal
 */
FP_CONSTEXPR inline static fp_void_view __fp_make_subview(const fp_void_view view, size_t type_size, size_t start, size_t length) FP_NOEXCEPT {
	assert(start + length <= fp_view_size(view));
#ifdef __cplusplus
	return fp_void_view
#else
	return (fp_void_view)
#endif
		{((uint8_t*)fp_view_data_void(view)) + type_size * start, length};
}

/** \addtogroup capi
 *  @{
 */

/**
 * @brief Create a subview from an existing view
 * @param type Element type
 * @param view Parent view
 * @param start Starting index
 * @param length Number of elements
 * @return Subview of the specified range
 *
 * @code{.cpp}
 * fp_view(int) full = fp_view_make_full(int, arr);
 * fp_view(int) first_half = fp_view_subview(int, full, 0, fp_view_size(full) / 2);
 * @endcode
 */
#define fp_view_subview(type, view, start, length) ((fp_view(type))__fp_make_subview((fp_void_view)(view), sizeof(type), (start), (length)))

/**
 * @brief Create a subview using start and end indices
 * @param type Element type
 * @param view Parent view
 * @param start Starting index (inclusive)
 * @param end Ending index (inclusive)
 * @return Subview of the range [start, end]
 */
#define fp_view_subview_start_end(type, view, start, end) fp_view_subview(type, view, (start), ((end) - (start) + 1))

#ifdef __cplusplus
} // extern "C"

	/**
	 * @brief Compare two views for equality (C++ template version)
	 * @tparam T Element type
	 * @param a First view
	 * @param b Second view
	 * @return 0 if equal, non-zero otherwise
	 *
	 * @code{.cpp}
	 * fp_view(int) v1 = ...;
	 * fp_view(int) v2 = ...;
	 * if(fp_view_compare(v1, v2) == 0) {
	 *     printf("Views contain identical data\n");
	 * }
	 * @endcode
	 */
	template<typename T>
	FP_CONSTEXPR inline static int fp_view_compare(const fp_view(T) a, const fp_view(T) b) FP_NOEXCEPT {
		if(fp_view_size(a) != fp_view_size(b)) return false;
		return memcmp(fp_view_data_void(a), fp_view_data_void(b), fp_view_size(a));
	}

	/**
	 * @brief Check if two views are equal (C++ template version)
	 * @tparam T Element type
	 * @param a First view
	 * @param b Second view
	 * @return true if views have same size and content, false otherwise
	 */
	template<typename T>
	FP_CONSTEXPR inline static bool fp_view_equal(const fp_view(T) a, const fp_view(T) b) FP_NOEXCEPT {
		return fp_view_compare(a, b) == 0;
	}

	/**
	 * @brief Swap contents of two views (C++ template version)
	 * @tparam T Element type
	 * @param a First view
	 * @param b Second view
	 * @return true if swap succeeded, false if sizes don't match
	 *
	 * @code{.cpp}
	 * int arr1[5] = {1, 2, 3, 4, 5};
	 * int arr2[5] = {6, 7, 8, 9, 10};
	 * fp_view(int) v1 = fp_view_literal(int, arr1, 5);
	 * fp_view(int) v2 = fp_view_literal(int, arr2, 5);
	 * fp_view_swap(v1, v2);
	 * // arr1 now contains {6, 7, 8, 9, 10}
	 * @endcode
	 */
	template<typename T>
	inline bool static fp_view_swap(fp_view(T) a, fp_view(T) b) FP_NOEXCEPT {
		size_t size = fp_view_size(a);
		if(size != fp_view_size(b)) return false;
		return memswap(fp_view_data_void(a), fp_view_data_void(b), size) != nullptr;
	}
extern "C" {
#endif

/**
 * @brief Compare two void views for equality
 * @param a First view
 * @param b Second view
 * @return 0 if equal, non-zero otherwise
 */
FP_CONSTEXPR inline static int fp_view_compare(const fp_void_view a, const fp_void_view b) FP_NOEXCEPT {
	if(fp_view_size(a) != fp_view_size(b)) return false;
	return memcmp(fp_view_data_void(a), fp_view_data_void(b), fp_view_size(a));
}

/**
 * @brief Check if two void views are equal
 * @param a First view
 * @param b Second view
 * @return true if views have same size and content, false otherwise
 */
FP_CONSTEXPR inline static bool fp_view_equal(const fp_void_view a, const fp_void_view b) FP_NOEXCEPT {
	return fp_view_compare(a, b) == 0;
}

/**
 * @brief Swap contents of two void views
 * @param a First view
 * @param b Second view
 * @return true if swap succeeded, false if sizes don't match
 */
inline bool static fp_view_swap(fp_void_view a, fp_void_view b) FP_NOEXCEPT {
	size_t size = fp_view_size(a);
	if(size != fp_view_size(b)) return false;
	return memswap(fp_view_data_void(a), fp_view_data_void(b), size) != nullptr;
}

/**
 * @brief Iterate over view with named iterator
 * @param type Element type
 * @param view View structure
 * @param iter Iterator variable name
 *
 * @code{.cpp}
 * fp_view(float) v = ...;
 * fp_view_iterate_named(float, v, ptr) {
 *     *ptr *= 2.0f;
 * }
 * @endcode
 */
#define fp_view_iterate_named(type, view, iter) for(type* __fp_start = fp_view_data(type, view), *iter = __fp_start; iter < __fp_start + fp_view_length(view); ++iter)

/**
 * @brief Iterate over view (iterator named 'i')
 * @param type Element type
 * @param view View structure
 *
 * @code{.cpp}
 * fp_view(int) v = ...;
 * fp_view_iterate(int, v) {
 *     printf("%d ", *i);
 * }
 * @endcode
 */
#define fp_view_iterate(type, view) fp_view_iterate_named(type, (view), i)

/**
 * @brief Calculate index from iterator and view
 * @param type Element type
 * @param view View structure
 * @param i Iterator pointer
 * @return Index as size_t
 *
 * @code{.cpp}
 * fp_view(int) v = ...;
 * fp_view_iterate_named(int, v, ptr) {
 *     size_t idx = fp_view_iterate_calculate_index(int, v, ptr);
 *     printf("Index %zu: %d\n", idx, *ptr);
 * }
 * @endcode
 */
#define fp_view_iterate_calculate_index(type, view, i) ((i) - fp_view_data(type, view))

/** @} */

/**
 * @brief Internal implementation for creating a heap-allocated copy of a view
 * @param view View to copy
 * @param type_size Size of each element
 * @return New heap-allocated fat pointer with view's data
 * @internal
 */
inline static void* __fp_view_make_dynamic(fp_void_view view, size_t type_size) FP_NOEXCEPT {
	size_t size = fp_view_size(view);
	auto out = __fp_realloc(nullptr, type_size, size);
	memcpy(out, fp_view_data_void(view), size * type_size);
	return out;
}

/** \addtogroup capi
 *  @{
 */

/**
 * @brief Create a heap-allocated fat pointer from a view
 * @param type Element type
 * @param view View to copy
 * @return New heap-allocated fat pointer (must be freed with e.g. fp_free)
 *
 * This creates an owning copy of the view's data.
 *
 * @code{.cpp}
 * int buffer[100];
 * fp_view(int) v = fp_view_literal(int, buffer, 100);
 *
 * // Create owning copy
 * int* owned = fp_view_make_dynamic(int, v);
 *
 * // Can modify independently
 * owned[0] = 999;
 *
 * fp_free_and_null(owned);
 * @endcode
 */
#define fp_view_make_dynamic(type, view) ((type*)__fp_view_make_dynamic((fp_void_view)(view), sizeof(type)))


#ifdef __cplusplus
}
#endif

#if defined(__cpp_lib_span) && __cpp_lib_span >= 202002L
/**
 * @brief Convert fat pointer view to std::span
 * @tparam T Element type
 * @param view View to convert
 * @return std::span over the view's data
 *
 * Requires C++20 and <span> header.
 *
 * @code{.cpp}
 * fp_view(int) v = ...;
 * std::span<int> s = fp_view_to_std(v);
 * for(int val : s) {
 *     std::cout << val << "\n";
 * }
 * @endcode
 */
template<typename T>
FP_CONSTEXPR inline std::span<T> fp_view_to_std(fp_view(T) view) {
	return std::span{fp_view_data(T, view), fp_view_size(view)};
}

/**
 * @brief Convert std::span to fat pointer view
 * @tparam T Element type
 * @param view std::span to convert
 * @return Fat pointer view
 *
 * Requires C++20 and <span> header.
 *
 * @code{.cpp}
 * std::vector<int> vec = {1, 2, 3, 4, 5};
 * std::span<int> s{vec};
 * fp_view(int) v = fp_std_to_view(s);
 * @endcode
 */
template<typename T>
FP_CONSTEXPR inline fp_view(T) fp_std_to_view(std::span<T> view) {
	return fp_void_view_literal((T*)view.data(), view.size());
}
#endif

#endif // __LIB_FAT_POINTER_H__

/** @}*/

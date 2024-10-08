#ifndef __LIB_FAT_POINTER_H__
#define __LIB_FAT_POINTER_H__

// Assert that always performs an action and then calculates an assertation based on it in debug mode
#define do_and_assert(action, assertation) do {\
	auto res = action;\
	assert(assertation);\
	(void)res;\
} while(false)

// Assert whoes side effects are always evaluated (even in release mode)
#define assert_with_side_effects(assertation) do_and_assert(assertation, res)

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

#ifndef FP_NOEXCEPT
	#define FP_NOEXCEPT noexcept
#endif
#ifndef FP_CONSTEXPR
	#define FP_CONSTEXPR constexpr
#endif

extern "C" {
#else
#ifndef FP_NOEXCEPT
	#define FP_NOEXCEPT
#endif
#ifndef FP_CONSTEXPR
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
	* @brief Function used by libFP to allocate memory
	* @param p pointer to reallocate
	* @note if \p p is null, then new memory is expected to be allocated, otherwise a reallocation and data copy is expected to occur
	* @param size the size in raw bytes to allocate
	* @note if \p size is 0, then the memory pointed to by \p p should be freed
	* @note if \p size is the same as the size of the current allocation of \p p it is valid to simply return \p p
	* @return a pointer to the new allocation or null if the allocation was freed
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

enum FP_MagicNumbers {
	FP_MAGIC_NUMBER = 0xFE00,
	FP_HEAP_MAGIC_NUMBER = 0xFEFE,
	FP_STACK_MAGIC_NUMBER = 0xFEFF
};

struct __FatPointerHeaderTruncated { // TODO: Make sure to keep this struct in sync with the following one
	uint16_t magic;
	size_t size;
};
struct __FatPointerHeader {
	uint16_t magic;
	size_t size;
#ifndef __cplusplus
	uint8_t data[];
#else
	uint8_t data[8];
#endif
};
#ifndef __cplusplus
	#define FP_HEADER_SIZE sizeof(struct __FatPointerHeader)
#else
	static constexpr size_t FP_HEADER_SIZE = sizeof(__FatPointerHeader) - detail::completed_sizeof_v<decltype(__FatPointerHeader{}.data)>;
#endif

#define FP_CONCAT_(x,y) x##y
#define FP_CONCAT(x,y) FP_CONCAT_(x,y)

#ifdef __GNUC__
	// From: https://stackoverflow.com/a/58532788
#define FP_MAX(a,b)\
	({\
		__typeof__ (a) __FP_a = (a);\
		__typeof__ (a) __FP_b = (b);\
		__FP_a > __FP_b ? __FP_a : __FP_b;\
	})
#define FP_MIN(a,b)\
	({\
		__typeof__ (a) __FP_a = (a);\
		__typeof__ (a) __FP_b = (b);\
		__FP_a < __FP_b ? __FP_a : __FP_b;\
	})
#elif defined(__cplusplus)
#include <algorithm>
#define FP_MIN(a, b) (std::min((a), (FP_TYPE_OF(a))(b)))
#define FP_MAX(a, b) (std::max((a), (FP_TYPE_OF(a))(b)))
#else
#pragma message("Unsafe Min / Max macros")
#define FP_MAX(a,b) ((a) > (b) ? (a) : (b))
#define FP_MIN(a,b) ((a) < (b) ? (a) : (b))
#endif

// TODO: How do we mark the final byte as being zero?
#ifndef __cplusplus
static thread_local struct __FatPointerHeader* __fp_global_header;
#define fp_alloca_void(_typesize, _size) (__fp_global_header = (struct __FatPointerHeader*)alloca(FP_HEADER_SIZE + _typesize * _size + 1),\
	*__fp_global_header = (struct __FatPointerHeader) {\
		.magic = FP_STACK_MAGIC_NUMBER,\
		.size = (_size),\
	}, (void*)(((uint8_t*)__fp_global_header) + FP_HEADER_SIZE))
#elif defined(_WIN32)
#include <malloc.h>
#define fp_alloca_void(_typesize, _size) ((void*)(((uint8_t*)&((*(__FatPointerHeader*)_alloca(FP_HEADER_SIZE + _typesize * FP_MAX(_size, 8) + 1)) = \
	__FatPointerHeader {\
		.magic = FP_STACK_MAGIC_NUMBER,\
		.size = (_size),\
	})) + FP_HEADER_SIZE))
#else
#include <alloca.h>
#define fp_alloca_void(_typesize, _size) ((void*)(((uint8_t*)&((*(__FatPointerHeader*)alloca(FP_HEADER_SIZE + _typesize * FP_MAX(_size, 8) + 1)) = \
	__FatPointerHeader {\
		.magic = FP_STACK_MAGIC_NUMBER,\
		.size = (_size),\
	})) + FP_HEADER_SIZE))
#endif
#define fp_alloca(type, _size) ((type*)fp_alloca_void(sizeof(type), _size))

FP_CONSTEXPR inline static struct __FatPointerHeader* __fp_header(const void* _p) FP_NOEXCEPT {
	uint8_t* p = (uint8_t*)_p;
	p -= FP_HEADER_SIZE;
#if FP_EXPAND(FP_CONSTEXPR) == 1 // Used when function not defined constexpr
	return (struct __FatPointerHeader*)p;
#else
	return (struct __FatPointerHeader*)(void*)p;
#endif
}


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
	p += FP_HEADER_SIZE;
	if(!p) return 0;
	auto h = __fp_header(p);
	h->magic = FP_HEAP_MAGIC_NUMBER;
	h->size = _size;
	h->data[_size] = 0;
	return p;
}
#else
;
#endif

inline static void* __fp_malloc(size_t type_size, size_t count) FP_NOEXCEPT {
	auto out = __fp_alloc(NULL, type_size * count);
	auto h = __fp_header(out);
	h->magic = FP_HEAP_MAGIC_NUMBER;
	h->size = count;
	return out;
}

#define fp_malloc(type, _size) ((type*)__fp_malloc(sizeof(type), (_size)))

#ifndef __cplusplus
	#define fp_realloc(type, p, _size) ((type*)((uint8_t*)(*__fp_header(__fp_alloc((p), sizeof(type) * (_size))) = (struct __FatPointerHeader){\
		.magic = FP_HEAP_MAGIC_NUMBER,\
		.size = (_size),\
	}).data))
#else
	#define fp_realloc(type, p, _size) ((type*)((uint8_t*)(*__fp_header(__fp_alloc((p), sizeof(type) * (_size))) = __FatPointerHeader{\
		.magic = FP_HEAP_MAGIC_NUMBER,\
		.size = (_size),\
	}).data))
#endif

#ifdef __GNUC__
__attribute__((no_sanitize_address)) // Don't let this function which routinely peaks out of valid bounds trigger the address sanitizer
#endif
FP_CONSTEXPR inline static bool is_fp(const void* p) FP_NOEXCEPT {
	if(p == NULL) return false;
	auto h = __fp_header(p);
	auto capacity = (size_t*)(((char*)h) - sizeof(size_t)); // Manually access fpda capacity
	return (h->magic & 0xFF00) == FP_MAGIC_NUMBER && (h->size > 0 || *capacity > 0);
}

FP_CONSTEXPR inline static size_t fp_magic_number(const void* p) FP_NOEXCEPT {
	if(p == NULL) return false;
	auto h = __fp_header(p);
	return h->magic;
}

FP_CONSTEXPR inline static bool fp_is_stack_allocated(const void* p) FP_NOEXCEPT { return fp_magic_number(p) == FP_STACK_MAGIC_NUMBER; }
FP_CONSTEXPR inline static bool fp_is_heap_allocated(const void* p) FP_NOEXCEPT { return fp_magic_number(p) == FP_HEAP_MAGIC_NUMBER; }

inline static void fp_free(void* p) FP_NOEXCEPT { __fp_alloc(p, 0); }
#define fp_free_and_null(p) (fp_free(p), p = NULL)

FP_CONSTEXPR inline static size_t fp_length(const void* p) FP_NOEXCEPT {
	if(!is_fp(p)) return 0;
	return __fp_header(p)->size;
}
#define fp_size fp_length
FP_CONSTEXPR inline static bool fp_empty(const void* p) FP_NOEXCEPT { return fp_length(p) == 0; }

#define fp_front(a) (a)
#define fp_begin(a) fp_front(a)
FP_CONSTEXPR inline static void* __fp_back(void* a, size_t type_size) { return ((uint8_t*)a) + (fp_size(a) > 0 ? fp_size(a) - 1 : 0) * type_size; }
#define fp_back(a) ((FP_TYPE_OF_REMOVE_POINTER(a)*)__fp_back((a), sizeof(*a)))
#define fp_end(a) (fp_size(a) ? fp_back(a) + 1 : fp_begin(a))

#if defined __cplusplus && defined FP_ENABLE_STD_RANGES
#define fp_as_std_range(a) (std::ranges::subrange(fp_begin(a), fp_end(a)))
#endif

#define fp_iterate_named(a, iter) for(auto __fp_start = (a), iter = __fp_start; iter < __fp_start + fp_length(__fp_start); ++iter)
#define fp_iterate(a) fp_iterate_named((a), i)
#define fp_iterate_calculate_index(a, i) ((i) - (a))

#define fp_iterate_reverse_named(a, iter) for(auto __fp_start = (a), iter = __fp_start + fp_length(__fp_start) - 1; iter >= __fp_start; --iter)
#define fp_iterate_reverse(a) fp_iterate_reverse_named((a), i)

void* memswap(void* a, void* b, size_t n) FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	if (a == b) return nullptr;
	char* buffer = fp_alloca(char, n);
	memcpy(buffer, a, n);
	memcpy(a, b, n);
	memcpy(b, buffer, n);
	return a;
}
#else
;
#endif

inline static bool fp_swap(void* a, void* b) FP_NOEXCEPT {
	assert(is_fp(a) && is_fp(b));

	size_t size = fp_size(a);
	if(size != fp_size(b)) return false;
	return memswap(a, b, size) != nullptr;
}

inline static void* __fp_clone(const void* ptr, size_t type_size) FP_NOEXCEPT {
	assert(is_fp(ptr));

	size_t size = fp_size(ptr);
	auto out = __fp_malloc(type_size, size);
	memcpy(out, ptr, size * type_size);
	return out;
}
#define fp_clone(a) ((FP_TYPE_OF_REMOVE_POINTER(a)*)__fp_clone((a), sizeof(*a)))

inline static bool __fp_contains(void* a, void* needle, size_t type_size) {
	auto __fp_start = (char*)a;
	for(auto iter = __fp_start; iter < __fp_start + fp_length(__fp_start) * type_size; iter += type_size)
		if(memcmp(iter, needle, type_size) == 0)
			return true;
	return false;
}
#define fp_contains(a, needle) (__fp_contains((a), (&needle), sizeof(*a)))

#ifdef __cplusplus
}

template<typename T>
struct __fp_view {
	T* data;
	size_t size;

	template<typename To>
	explicit operator __fp_view<To>() const { return {(To*)data, size}; }
};
#define fp_view(type) __fp_view<type>
#define fp_view_literal(type, data, size) (fp_view(type){(type*)(data), (size)})
using fp_void_view = fp_view(void);

// #if !(defined _MSC_VER || defined __APPLE__)
extern "C" {
// #endif // _MSC_VER || __APPLE__
#else
struct __fp_view {
	void* data;
	size_t size;
};

#define fp_view(type) struct __fp_view
#define fp_view_literal(type, data, size) ((fp_view(type)) {(void*)(data), (size)})
typedef fp_view(void) fp_void_view;
#endif
#define fp_void_view_literal(data, size) fp_view_literal(void, data, size)
#define fp_view_from_variable(type, var) fp_view_literal(type, &(var), 1)

#define fp_variable_to_void_view(type, data) fp_void_view_literal(&data, sizeof(type))

#if defined(_MSC_VER)
}
#endif // _MSC_VER
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
#endif // _MSC_VER

#define fp_view_make(type, p, start, length) ((fp_view(type))__fp_make_view((p), sizeof(*(p)), (start), (length)))
#define fp_view_make_full(type, p) fp_view_make(type, p, 0, fp_size(p))
#define fp_view_make_start_end(type, p, start, end) fp_view_make(type, p, (start), ((end) - (start) + 1))

#define fp_view_length(view) ((view).size)
#define fp_view_size(view) fp_view_length(view)
#define fp_view_data_void(view) ((void*)(view).data)
#define fp_view_data(type, view) ((type*)fp_view_data_void(view))
#define fp_view_access(type, view, index) (assert((index) < fp_view_length(view)), fp_view_data(type, view) + (index))
#define fp_view_subscript(type, view, index) fp_view_access(type, view, index)

#define fp_view_to_byte_view(type, view) fp_view_literal(uint8_t, fp_view_data(type, (view)), fp_view_size((view)) * sizeof(type))

#define fp_view_front(type, view) fp_view_data(type, view)
#define fp_view_begin(type, view) fp_view_front(type, view)
FP_CONSTEXPR inline static void* __fp_view_back(fp_void_view view, size_t type_size) { return (fp_view_data(uint8_t, view)) + (fp_view_size(view) > 0 ? fp_view_size(view) - 1 : 0) * type_size; }
#define fp_view_back(type, view) ((type*)__fp_view_back((fp_void_view)(view), sizeof(type)))
#define fp_view_end(type, view) (fp_view_size(view) ? fp_view_back(type,view) + 1 : fp_view_begin(type, view))


#if defined __cplusplus && defined FP_ENABLE_STD_RANGES
#define fp_view_as_std_range(type, view) (std::ranges::subrange(fp_view_begin(type, (view)), fp_view_end(type, (view))))
#endif

FP_CONSTEXPR inline static fp_void_view __fp_make_subview(const fp_void_view view, size_t type_size, size_t start, size_t length) FP_NOEXCEPT {
	assert(start + length <= fp_view_size(view));
#ifdef __cplusplus
	return fp_void_view
#else
	return (fp_void_view)
#endif
		{((uint8_t*)fp_view_data_void(view)) + type_size * start, length};
}
#define fp_view_subview(type, view, start, length) ((fp_view(type))__fp_make_subview((fp_void_view)(view), sizeof(type), (start), (length)))
#define fp_view_subview_start_end(type, view, start, end) fp_view_subview(type, view, (start), ((end) - (start) + 1))

#ifdef __cplusplus
} // extern "C"
	template<typename T>
	FP_CONSTEXPR inline static int fp_view_compare(const fp_view(T) a, const fp_view(T) b) FP_NOEXCEPT {
		if(fp_view_size(a) != fp_view_size(b)) return false;
		return memcmp(fp_view_data_void(a), fp_view_data_void(b), fp_view_size(a));
	}
	template<typename T>
	FP_CONSTEXPR inline static bool fp_view_equal(const fp_view(T) a, const fp_view(T) b) FP_NOEXCEPT {
		return fp_view_compare(a, b) == 0;
	}

	template<typename T>
	inline bool static fp_view_swap(fp_view(T) a, fp_view(T) b) FP_NOEXCEPT {
		size_t size = fp_view_size(a);
		if(size != fp_view_size(b)) return false;
		return memswap(fp_view_data_void(a), fp_view_data_void(b), size) != nullptr;
	}
extern "C" {
#endif
FP_CONSTEXPR inline static int fp_view_compare(const fp_void_view a, const fp_void_view b) FP_NOEXCEPT {
	if(fp_view_size(a) != fp_view_size(b)) return false;
	return memcmp(fp_view_data_void(a), fp_view_data_void(b), fp_view_size(a));
}
FP_CONSTEXPR inline static bool fp_view_equal(const fp_void_view a, const fp_void_view b) FP_NOEXCEPT {
	return fp_view_compare(a, b) == 0;
}

inline bool static fp_view_swap(fp_void_view a, fp_void_view b) FP_NOEXCEPT {
	size_t size = fp_view_size(a);
	if(size != fp_view_size(b)) return false;
	return memswap(fp_view_data_void(a), fp_view_data_void(b), size) != nullptr;
}

#define fp_view_iterate_named(type, view, iter) for(type* __fp_start = fp_view_data(type, view), *iter = __fp_start; iter < __fp_start + fp_view_length(view); ++iter)
#define fp_view_iterate(type, view) fp_view_iterate_named(type, (view), i)
#define fp_view_iterate_calculate_index(type, view, i) ((i) - fp_view_data(type, view))

#ifdef __cplusplus
}
#endif

#if defined(__cpp_lib_span) && __cpp_lib_span >= 202002L
template<typename T>
FP_CONSTEXPR inline std::span<T> fp_view_to_std(fp_view(T) view) {
	return std::span{fp_view_data(T, view), fp_view_size(view)};
}

template<typename T>
FP_CONSTEXPR inline fp_view(T) fp_std_to_view(std::span<T> view) {
	return fp_void_view_literal((T*)view.data(), view.size());
}
#endif

#endif

// #include <stdio.h>

// int main() {
// 	// int* arr = fp_alloca(int, 20);
// 	int* arr = fp_malloc(int, 20);
// 	arr = fp_realloc(int, arr, 25);
// 	arr[20] = 6;

// 	printf(is_fp(arr) ? "true\n" : "false\n");
// 	printf("%lu\n", fp_length(arr));
// 	printf("%d\n", arr[20]);
// 	printf("%lu\n", sizeof(struct __FatPointerHeader));

// 	fp_free(arr);
// }
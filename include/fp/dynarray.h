#ifndef __LIB_FAT_POINTER_DYN_ARRAY_H__
#define __LIB_FAT_POINTER_DYN_ARRAY_H__

#include "pointer.h"

#ifdef __cplusplus
extern "C" {
#endif

#define fp_dynarray(type) type*

#ifndef FPDA_DEFAULT_SIZE_BYTES
#define FPDA_DEFAULT_SIZE_BYTES 16
#endif

// From: https://stackoverflow.com/a/466278
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

struct __FatDynamicArrayHeader {
	size_t capacity;
	struct __FatPointerHeader h;
};
#ifndef __cplusplus
	#define FPDA_HEADER_SIZE sizeof(struct __FatDynamicArrayHeader)
#else
	static constexpr size_t FPDA_HEADER_SIZE = sizeof(__FatDynamicArrayHeader) - detail::completed_sizeof_v<decltype(__FatPointerHeader{}.data)>;
#endif

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

inline static struct __FatDynamicArrayHeader* __fpda_header(const void* da) FP_NOEXCEPT {
	if(da == NULL) return __fpda_header_null_ref();

	uint8_t* p = (uint8_t*)da;
	p -= FPDA_HEADER_SIZE;
	return (struct __FatDynamicArrayHeader*)p;
}

void* __fpda_malloc(size_t _size) FP_NOEXCEPT
#ifdef FP_IMPLEMENTATION
{
	assert(_size > 0);
	size_t size = FPDA_HEADER_SIZE + _size + 1;
	uint8_t* p = (uint8_t*)__fp_alloc(NULL, size);
	p += FPDA_HEADER_SIZE;
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

#define fpda_malloc(type, _size) ((type*)((uint8_t*)(*__fpda_header(__fpda_malloc(nullptr, sizeof(type) * (_size))) = (struct __FatDynamicArrayHeader){\
	.utilized_size = 0,\
	.h = {\
		.magic = FP_DYNARRAY_MAGIC_NUMBER,\
		.size = (_size),\
	}\
}).h.data))

#ifdef __GNUC__
__attribute__((no_sanitize_address)) // Don't let this function which routinely peaks out of valid bounds trigger the address sanitizer
#endif
inline static bool is_fpda(const void* da) FP_NOEXCEPT { return __fpda_header(da)->h.magic == FP_DYNARRAY_MAGIC_NUMBER; }

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

#define fpda_free_and_null(da) (fpda_free(da), da = NULL)

#define fpda_length fp_length
#define fpda_size fp_size
#define fpda_empty fp_empty

#define fpda_front(a) fp_front(a)
#define fpda_begin(a) fp_begin(a)
#define fpda_back(a) fp_back(a)
#define fpda_end(a) fp_end(a)

#define fpda_iterate_named fp_iterate_named
#define fpda_iterate fp_iterate
#define fpda_iterate_calculate_index fp_iterate_calculate_index

inline static size_t fpda_capacity(const void* da) FP_NOEXCEPT {
	if(!is_fp(da)) return 0;
	return __fpda_header(da)->capacity;
}

inline static void* __fpda_maybe_grow(void** da, size_t type_size, size_t new_size, bool update_utilized, bool exact_sizing) FP_NOEXCEPT {
	if(*da == NULL) {
		size_t initial_size = exact_sizing ? new_size : FPDA_DEFAULT_SIZE_BYTES / type_size;
		if(initial_size == 0) initial_size++; // If the size would wind up being 0, make sure the initial size is 1
		*da = __fpda_malloc(initial_size * type_size);
		auto h = __fpda_header(*da);
		h->capacity /= type_size;
		h->h.size = 0;
	}

	auto h = __fpda_header(*da);
	if(h->capacity >= new_size) {
		if(update_utilized) h->h.size = h->h.size > new_size ? h->h.size : new_size;
		return h->h.data + (type_size * (new_size - 1));
	}

	size_t size2 = exact_sizing ? new_size : fp_upper_power_of_two(new_size);
	void* new_ = __fpda_malloc(type_size * size2);
	auto newH = __fpda_header(new_);
	if(update_utilized)
		newH->h.size = h->h.size > new_size ? h->h.size : new_size;
	newH->capacity = size2;
	memcpy(newH->h.data, h->h.data, type_size * h->h.size);

	fpda_free(*da);
	*da = new_;
	return newH->h.data + (type_size * (new_size - 1));
}
#define __fpda_maybe_grow_short(a, _size) ((FP_TYPE_OF_REMOVE_POINTER(a)*)__fpda_maybe_grow((void**)&a, sizeof(*a), (_size), true, false))

#define fpda_reserve(a, _size) ((FP_TYPE_OF_REMOVE_POINTER(a)*)__fpda_maybe_grow((void**)&a, sizeof(*a), (_size), false, true))
#define fpda_reserve_void_pointer(a, type_size, _size) (__fpda_maybe_grow((void**)&a, type_size, (_size), false, true))
#define fpda_grow_to_size(a, _size) ((FP_TYPE_OF_REMOVE_POINTER(a)*)__fpda_maybe_grow((void**)&a, sizeof(*a), (_size), true, true))
#define fpda_grow(a, _to_add) (__fpda_maybe_grow_short(a, __fpda_header(a)->h.size + _to_add))
#define fpda_push_back(a, _value) (*__fpda_maybe_grow_short(a, __fpda_header(a)->h.size + 1) = (_value))

#define fpda_grow_and_initialize(a, _to_add, _value) do {\
		size_t __fp_oldSize = fpda_size(a); \
		fpda_grow(a, (_to_add));\
		for(size_t __fp_i = __fp_oldSize, __fp_size = fpda_size(a); __fp_i < __fp_size; ++__fp_i)\
			(a)[__fp_i] = (_value);\
	} while(false)
#define fpda_grow_to_size_and_initialize(a, _size, _value) do {\
		size_t __fp_oldSize = fpda_size(a); \
		fpda_grow_to_size(a, (_size));\
		for(size_t __fp_i = __fp_oldSize, __fp_size = fpda_size(a); __fp_i < __fp_size; ++__fp_i)\
			(a)[__fp_i] = (_value);\
	} while(false)

#define fpda_pop_back_n(a, _count) (__fpda_maybe_grow_short(a, __fpda_header(a)->h.size <= 0 ? 0 : (__fpda_header(a)->h.size -= (_count))) + 1)
// Marks the last element of the array as gone and returns a pointer to it
#define fpda_pop_back(a) fpda_pop_back_n(a, 1)
#define fpda_pop_back_to_size(a, size) fpda_pop_back_n(a, FP_MAX(((int64_t)fpda_size(a)) - size, 0))

inline static void* __fpda_maybe_grow_insert(void** da, size_t type_size, size_t new_index, size_t new_size, bool exact_sizing) FP_NOEXCEPT {
	assert(new_size > 0);
	assert(new_index <= fpda_size(*da)); // TODO: What should the comparison operator be?

	__fpda_maybe_grow(da, type_size, fpda_size(*da) + new_size, /*update_utilized*/true, exact_sizing);

	uint8_t* raw = (uint8_t*)*da;
	uint8_t* oldStart = raw + new_index * type_size;
	uint8_t* newStart = oldStart + new_size * type_size;
	size_t length = (raw + fpda_size(*da) * type_size) - newStart;
	memmove(newStart, oldStart, length);
	return oldStart;
}

#define fpda_insert(a, _pos, _val) ((*(FP_TYPE_OF(*a)*)__fpda_maybe_grow_insert((void**)&a, sizeof(*a), (_pos), 1, false)) = _val)
#define fpda_push_front(a, _val) fpda_insert(a, 0, _val)

// Returns a pointer to the first uninitialized element
#define fpda_insert_uninitialized(a, _pos, _count) ((FP_TYPE_OF(*a)*)__fpda_maybe_grow_insert((void**)&a, sizeof(*a), (_pos), (_count), false))


inline static void* __fpda_delete(void** da, size_t type_size, size_t start, size_t count, bool make_size_match_capacity) FP_NOEXCEPT {
	assert(start + count <= fpda_size(*da));

	uint8_t* raw = (uint8_t*)*da;
	uint8_t* newStart = raw + start * type_size;
	uint8_t* oldStart = newStart + count * type_size;
	size_t length = (raw + fpda_size(raw) * type_size) - oldStart;

	if(make_size_match_capacity) {
		fp_dynarray(uint8_t) new_ = nullptr;
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
#define __fpda_delete_impl(a, _pos, _count, _match_size) ((FP_TYPE_OF(*a)*)__fpda_delete((void**)&a, sizeof(*a), (_pos), (_count), (_match_size)))

#define fpda_delete_range(a, _pos, _count) __fpda_delete_impl(a, _pos, _count, false)
#define fpda_delete(a, _pos) fpda_delete_range(a, _pos, 1)
#define fpda_delete_start_end(a, _start, _end) fpda_delete_range(a, _start, ((_end) - (_start) + 1))

#define fpda_shrink_delete_range(a, _pos, _count) __fpda_delete_impl(a, _pos, _count, true)
#define fpda_shrink_delete(a, _pos) fpda_shrink_delete_range(a, _pos, 1)
#define fpda_shrink_delete_start_end(a, _start, _end) fpda_shrink_delete_range(a, _start, ((_end) - (_start) + 1))

#define fpda_resize(a, _size) do { auto __fp_size = (_size);\
		if((size_t)__fp_size > fpda_capacity(a)) fpda_grow_to_size(a, __fp_size);\
		else { auto __fp_count = fpda_size(a) - __fp_size; fpda_shrink_delete_range(a, fpda_size(a) - __fp_count, __fp_count); }\
	} while(false)

#define fpda_shrink_to_fit(a) __fpda_delete_impl(a, 0, 0, true)


inline static void __fpda_swap_range(void* da, size_t type_size, size_t range1_start, size_t range2_start, size_t count, bool bidirectional) FP_NOEXCEPT {
	assert(range1_start + count <= fpda_size(da));
	assert(range2_start + count <= fpda_size(da));

	uint8_t* start1 = ((uint8_t*)da) + type_size * range1_start;
	uint8_t* start2 = ((uint8_t*)da) + type_size * range2_start;
	uint8_t* end1 = start1 + count * type_size - 1;
	uint8_t* end2 = start2 + count * type_size - 1;
	bool overlapping = !(end1 < start2 || end2 < start1);
	size_t length = count * type_size;

	uint8_t* scratch = NULL;
	if(overlapping) {
		if(fpda_capacity(da) - fpda_size(da) > count) // We can use the excess capacity
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

#define fpda_swap_range(a, _start1, _start2, _count) (__fpda_swap_range(a, sizeof(*a), (_start1), (_start2), (_count), true))
#define fpda_swap(a, _pos1, _pos2) fpda_swap_range(a, _pos1, _pos2, 1)

#define fpda_swap_delete_range(a, _pos, _count) (__fpda_swap_range(a, sizeof(*a), fpda_size(a) - (_count), (_pos), (_count), false), __fpda_header(a)->h.size -= _count)
#define fpda_swap_delete(a, _pos) fpda_swap_delete_range(a, _pos, 1)
#define fpda_swap_delete_start_end(a, _start, _end) fpda_swap_delete_range(a, _start, ((_end) - (_start) + 1))

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
#define fpda_pop_front(a) ((FP_TYPE_OF_REMOVE_POINTER(a)*)__fpda_pop_front(a, sizeof(*a)))

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

#define fpda_clone_to(dest, src) __fpda_clone_to((void**)&dest, (src), sizeof(*dest), false)
#define fpda_assign(dest, src) fpda_clone_to(dest, src)
#define fpda_clone_to_shrink(dest, src) __fpda_clone_to((void**)&dest, (src), sizeof(*dest), true)

inline static void* __fpda_clone(const void* src, size_t type_size) FP_NOEXCEPT {
	void* out = NULL;
	__fpda_clone_to(&out, src, type_size, true);
	return out;
}

#define fpda_clone(src) ((FP_TYPE_OF(*src)*)__fpda_clone((src), sizeof(*src)))
#define fpda_copy(src) fpda_clone(src)

#define fpda_clear(a) __fpda_header(a)->h.size = 0

#ifdef __cplusplus
}
#endif

#endif // __LIB_FAT_POINTER_DYN_ARRAY_H__


// #include <stdio.h>

// int main() {

// 	fp_dynarray(int) arr = nullptr;
// 	fpda_reserve(arr, 20);
// 	fpda_push(arr, 5);

// 	printf("%d\n", arr[0]);

//	fpda_free(arr);

// }
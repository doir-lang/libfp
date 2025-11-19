#ifndef __LIB_FAT_POINTER_FNV1A_H__
#define __LIB_FAT_POINTER_FNV1A_H__

#include "pointer.h"

#ifdef __cplusplus
extern "C" {
#endif

inline static uint64_t fp_fnv1a_hash(fp_view(uint8_t) view) FP_NOEXCEPT {
	static uint64_t FNV_OFFSET_BASIS = 14695981039346656037u;
	static uint64_t FNV_PRIME = 1099511628211u;

	uint64_t hash = FNV_OFFSET_BASIS;
	for(size_t i = fp_view_size(view); i--; ) {
		hash ^= (uint64_t)(fp_view_data(uint8_t, view)[i]);
		hash *= FNV_PRIME;
	}
	return hash;
}

inline static uint64_t fp_fnv1a_hash_void(fp_void_view view) FP_NOEXCEPT {
	return fp_fnv1a_hash((fp_view(uint8_t))view);
}

#ifdef __cplusplus
} // extern "C"
#endif

#endif // __LIB_FAT_POINTER_FNV1A_H__
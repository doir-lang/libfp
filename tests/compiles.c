#define FP_IMPLEMENTATION
#include <fp/pointer.h>

// void* __heap_end;

void check_stack(void) {
	int* arr = fp_alloca(int, 20);
	arr[10] = 6;

	assert_with_side_effects(is_fp(arr));
	assert_with_side_effects(fp_is_stack_allocated(arr));
	assert_with_side_effects(!fp_is_heap_allocated(arr));
	assert_with_side_effects(fp_length(arr) == 20);
	assert_with_side_effects(arr[10] == 6);
}

void check_heap(void) {
	int* arr = fp_malloc(int, 20);
	arr = fp_realloc(int, arr, 25);
	arr[20] = 6;

	assert_with_side_effects(is_fp(arr));
	assert_with_side_effects(!fp_is_stack_allocated(arr));
	assert_with_side_effects(fp_is_heap_allocated(arr));
	assert_with_side_effects(fp_length(arr) == 25);
	assert_with_side_effects(arr[20] == 6);

	fp_free(arr);
}

void check_view(void) {
	int* arr = fp_alloca(int, 20);
	arr[10] = 6;

	fp_view(int) view = fp_view_make(int, arr, 10, 3);
	assert_with_side_effects(fp_view_size(view) == 3);
	assert_with_side_effects(*fp_view_access(int, view, 0) == 6);
	*fp_view_access(int, view, 1) = 8;
	*fp_view_access(int, view, 2) = 6;

	fp_view(int) sub = fp_view_subview(int, view, 1, 1);
	assert_with_side_effects(*fp_view_access(int, sub, 0) == 8);
	*fp_view_access(int, sub, 0) = 6;

	fp_view_iterate(int, view) assert_with_side_effects(*i == 6);
}
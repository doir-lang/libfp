#define FP_IMPLEMENTATION
#include <fp/pointer.h>
#include <fp/dynarray.h>

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

void check_dynarray(void) {
	fp_dynarray(int) arr = nullptr;
	fpda_reserve(arr, 20);
	assert_with_side_effects(fpda_capacity(arr) == 20); // NOTE: FPDAs aren't valid until they have had at least one element added!
	assert_with_side_effects(fpda_size(arr) == 0);

	fpda_push_back(arr, 5);
	assert_with_side_effects(fpda_capacity(arr) == 20);
	assert_with_side_effects(fpda_size(arr) == 1);
	assert_with_side_effects(arr[0] == 5);

	fpda_push_front(arr, 6);
	assert_with_side_effects(fpda_capacity(arr) == 20);
	assert_with_side_effects(fpda_size(arr) == 2);
	assert_with_side_effects(arr[0] == 6);
	assert_with_side_effects(arr[1] == 5);
	assert_with_side_effects(*fpda_front(arr) == 6);
	assert_with_side_effects(*fpda_back(arr) == 5);

	fpda_push_back(arr, 7);
	assert_with_side_effects(fpda_capacity(arr) == 20);
	assert_with_side_effects(fpda_size(arr) == 3);
	assert_with_side_effects(arr[0] == 6);
	assert_with_side_effects(arr[1] == 5);
	assert_with_side_effects(arr[2] == 7);
	assert_with_side_effects(*fpda_front(arr) == 6);
	assert_with_side_effects(*fpda_back(arr) == 7);

	fpda_delete(arr, 1);
	assert_with_side_effects(fpda_capacity(arr) == 20);
	assert_with_side_effects(fpda_size(arr) == 2);
	assert_with_side_effects(arr[0] == 6);
	assert_with_side_effects(arr[1] == 7);

	fpda_swap(arr, 0, 1);
	assert_with_side_effects(fpda_capacity(arr) == 20);
	assert_with_side_effects(fpda_size(arr) == 2);
	assert_with_side_effects(arr[0] == 7);
	assert_with_side_effects(arr[1] == 6);

	fp_dynarray(int) arr2 = NULL;
	fpda_clone_to(arr2, arr);
	assert_with_side_effects(arr2 != arr);
	assert_with_side_effects(fpda_capacity(arr) == 20);
	assert_with_side_effects(fpda_capacity(arr2) == 20);
	assert_with_side_effects(fpda_size(arr) == 2);
	assert_with_side_effects(fpda_size(arr2) == 2);
	assert_with_side_effects(arr[0] == 7);
	assert_with_side_effects(arr2[0] == 7);
	assert_with_side_effects(arr[1] == 6);
	assert_with_side_effects(arr2[1] == 6);

	fpda_shrink_to_fit(arr);
	assert_with_side_effects(fpda_capacity(arr) == 2);
	assert_with_side_effects(fpda_size(arr) == 2);
	assert_with_side_effects(arr[0] == 7);
	assert_with_side_effects(arr[1] == 6);

	fpda_free(arr);
	fpda_free(arr2);
}
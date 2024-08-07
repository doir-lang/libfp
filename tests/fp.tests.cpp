#ifdef _MSC_VER
#define FP_IMPLEMENTATION
#endif

#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>
// #include "doctest_stubs.hpp"

#include <fp/pointer.h>
#include <fp/dynarray.h>

extern "C" {
void check_stack();
void check_heap();
void check_view();
void check_dynarray();
}

#define DISCARD_RESULT (void)

TEST_SUITE("LibFP") {

	TEST_CASE("Stack") {
		int* arr = fp_alloca(int, 20);
		arr[10] = 6;

		CHECK(is_fp(arr));
		CHECK(!is_fp(nullptr));
		CHECK(fp_is_stack_allocated(arr));
		CHECK(!fp_is_heap_allocated(arr));
		CHECK(fp_length(arr) == 20);
		CHECK(arr[10] == 6);
	}

	TEST_CASE("Heap") {
		int* arr = fp_malloc(int, 20);
		arr = fp_realloc(int, arr, 25);
		arr[20] = 6;

		CHECK(is_fp(arr));
		CHECK(!is_fp(nullptr));
		CHECK(!fp_is_stack_allocated(arr));
		CHECK(fp_is_heap_allocated(arr));
		CHECK(fp_length(arr) == 25);
		CHECK(arr[20] == 6);

		fp_free(arr);
	}

	TEST_CASE("View") {
		int* arr = fp_alloca(int, 20);
		arr[10] = 6;

		fp_view(int) view = fp_view_make(int, arr, 10, 3);
		CHECK(fp_view_size(view) == 3);
		CHECK(*fp_view_access(int, view, 0) == 6);
		*fp_view_access(int, view, 1) = 8;
		*fp_view_access(int, view, 2) = 6;

		auto sub = fp_view_subview(int, view, 1, 1);
		CHECK(*fp_view_access(int, sub, 0) == 8);
		*fp_view_access(int, sub, 0) = 6;

		fp_view_iterate(int, view) CHECK(*i == 6);
	}

	TEST_CASE("Dynamic Array - Basic") {
		fp_dynarray(int) arr = nullptr;
		fpda_reserve(arr, 20);
		CHECK(fpda_capacity(arr) == 20); // NOTE: FPDAs aren't valid until they have had at least one element added!
		CHECK(fpda_size(arr) == 0);

		fpda_push_back(arr, 5);
		CHECK(fpda_capacity(arr) == 20);
		CHECK(fpda_size(arr) == 1);
		CHECK(arr[0] == 5);

		fpda_push_front(arr, 6);
		CHECK(fpda_capacity(arr) == 20);
		CHECK(fpda_size(arr) == 2);
		CHECK(arr[0] == 6);
		CHECK(arr[1] == 5);
		CHECK(*fpda_front(arr) == 6);
		CHECK(*fpda_back(arr) == 5);

		fpda_push_back(arr, 7);
		CHECK(fpda_capacity(arr) == 20);
		CHECK(fpda_size(arr) == 3);
		CHECK(arr[0] == 6);
		CHECK(arr[1] == 5);
		CHECK(arr[2] == 7);
		CHECK(*fpda_front(arr) == 6);
		CHECK(*fpda_back(arr) == 7);

		fpda_delete(arr, 1);
		CHECK(fpda_capacity(arr) == 20);
		CHECK(fpda_size(arr) == 2);
		CHECK(arr[0] == 6);
		CHECK(arr[1] == 7);

		fpda_swap(arr, 0, 1);
		CHECK(fpda_capacity(arr) == 20);
		CHECK(fpda_size(arr) == 2);
		CHECK(arr[0] == 7);
		CHECK(arr[1] == 6);

		fp_dynarray(int) arr2 = nullptr;
		fpda_clone_to(arr2, arr);
		CHECK(arr2 != arr);
		CHECK(fpda_capacity(arr) == 20);
		CHECK(fpda_capacity(arr2) == 20);
		CHECK(fpda_size(arr) == 2);
		CHECK(fpda_size(arr2) == 2);
		CHECK(arr[0] == 7);
		CHECK(arr2[0] == 7);
		CHECK(arr[1] == 6);
		CHECK(arr2[1] == 6);

		fpda_grow_to_size_and_initialize(arr2, 5, 8);
		CHECK(fpda_capacity(arr2) == 20);
		CHECK(fpda_size(arr2) == 5);
		CHECK(arr2[0] == 7);
		CHECK(arr2[1] == 6);
		CHECK(arr2[2] == 8);
		CHECK(arr2[3] == 8);
		CHECK(arr2[4] == 8);

		fpda_shrink_to_fit(arr);
		CHECK(fpda_capacity(arr) == 2);
		CHECK(fpda_size(arr) == 2);
		CHECK(arr[0] == 7);
		CHECK(arr[1] == 6);

		fpda_free(arr);
		fpda_free(arr2);
	}

	TEST_CASE("Dynamic Array - Miscellaneous") {
		fp_dynarray(int) arr = nullptr;
		for(size_t i = 0; i < 5; i++) {
			fpda_push_back(arr, i);
			CHECK(arr[i] == i);
		}
		CHECK(is_fp(arr));
		CHECK(is_fpda(arr));
		CHECK(!fp_is_stack_allocated(arr));
		CHECK(fp_is_heap_allocated(arr));


		SUBCASE("fpda_grow_to_size") {
			fpda_grow_to_size(arr, 5);
			CHECK(fpda_capacity(arr) == 8); // NOTE: Resize can't shrink... it can only grow
			CHECK(fpda_size(arr) == 5);
			CHECK(arr[0] == 0);
			CHECK(arr[4] == 4);
		}
		SUBCASE("fpda_grow") {
			fpda_grow(arr, 5);
			CHECK(fpda_capacity(arr) == 16);
			CHECK(fpda_size(arr) == 10);
			CHECK(arr[0] == 0);
			CHECK(arr[4] == 4);
		}
		SUBCASE("fpda_pop_back") {
			DISCARD_RESULT fpda_pop_back(arr);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 4);
			CHECK(arr[0] == 0);
			CHECK(arr[3] == 3);
		}
		SUBCASE("fpda_insert") {
			fpda_insert(arr, 3, 5);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 6);
			CHECK(arr[0] == 0);
			CHECK(arr[2] == 2);
			CHECK(arr[3] == 5);
			CHECK(arr[4] == 3);
			CHECK(arr[5] == 4);
		}
		SUBCASE("fpda_insert_uninitialized") {
			fpda_insert_uninitialized(arr, 3, 3);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 8);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 1);
			CHECK(arr[2] == 2);
			// CHECK(arr[3] == 3); // NOTE: Uninitialized -> whatever was there before is still there!
			// CHECK(arr[4] == 4); // NOTE: Uninitialized -> whatever was there before is still there!
			// CHECK(arr[5] == 0); // NOTE: Uninitialized -> whatever was there before is still there!
			CHECK(arr[6] == 3);
			CHECK(arr[7] == 4);
		}
		SUBCASE("fpda_delete_range") {
			fpda_delete_range(arr, 2, 2);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 3);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 1);
			CHECK(arr[2] == 4);
		}
		SUBCASE("fpda_delete_start_end") {
			fpda_delete_start_end(arr, 1, 3);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 2);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 4);
		}
		SUBCASE("fpda_shrink_delete_range") {
			fpda_shrink_delete_range(arr, 2, 2);
			CHECK(fpda_capacity(arr) == 3);
			CHECK(fpda_size(arr) == 3);
			CHECK(arr[0] == 0);
			CHECK(arr[2] == 4);
		}
		SUBCASE("fpda_shrink_delete") {
			fpda_shrink_delete(arr, 3);
			CHECK(fpda_capacity(arr) == 4);
			CHECK(fpda_size(arr) == 4);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 1);
			CHECK(arr[2] == 2);
			CHECK(arr[3] == 4);
		}
		SUBCASE("fpda_shrink_delete_start_end") {
			fpda_shrink_delete_start_end(arr, 1, 3);
			CHECK(fpda_capacity(arr) == 2);
			CHECK(fpda_size(arr) == 2);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 4);
		}
		SUBCASE("fpda_resize (grow)") {
			fpda_resize(arr, 10);
			CHECK(fpda_capacity(arr) == 10);
			CHECK(fpda_size(arr) == 10);
			CHECK(arr[0] == 0);
			CHECK(arr[4] == 4);
		}
		SUBCASE("fpda_resize (shrink)") {
			fpda_resize(arr, 3);
			CHECK(fpda_capacity(arr) == 3);
			CHECK(fpda_size(arr) == 3);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 1);
			CHECK(arr[2] == 2);
		}
		SUBCASE("fpda_swap_range 1") {
			fpda_swap_range(arr, 1, 3, 1);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 5);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 3);
			CHECK(arr[2] == 2);
			CHECK(arr[3] == 1);
			CHECK(arr[4] == 4);
		}
		SUBCASE("fpda_swap_range 2") {
			fpda_swap_range(arr, 1, 3, 2);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 5);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 3);
			CHECK(arr[2] == 4);
			CHECK(arr[3] == 1);
			CHECK(arr[4] == 2);
		}
		SUBCASE("fpda_swap_range_overlapping") { // TODO: What behavior do we want this to have?
			fpda_swap_range(arr, 1, 2, 2);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 5);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 2);
			CHECK(arr[2] == 1);
			CHECK(arr[3] == 2);
			CHECK(arr[4] == 4);
		}
		SUBCASE("fpda_swap_delete_range") {
			fpda_swap_delete_range(arr, 2, 2);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 3);
			// pre: 0 1 2 3 4
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 1);
			CHECK(arr[2] == 3);
			CHECK(arr[3] == 4);
			// post: replace 2 3 with 3 4 -> 0 1 3 4
		}
		SUBCASE("fpda_swap_delete") {
			fpda_swap_delete(arr, 3);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 4);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 1);
			CHECK(arr[2] == 2);
			CHECK(arr[3] == 4);
			// CHECK(arr[4] == 4);
		}
		SUBCASE("fpda_swap_delete_start_end") {
			fpda_swap_delete_start_end(arr, 1, 3);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 2);
			// pre: 0 1 2 3 4
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 2);
			CHECK(arr[2] == 3);
			CHECK(arr[3] == 4);
			// replace 1 2 3 with 2 3 4 -> 0 2 3 4
			// CHECK(arr[4] == 4);
		}

		fpda_free(arr);
	}

#if !(defined _MSC_VER || defined __APPLE__)
	TEST_CASE("C") {
		check_stack();
		check_heap();
		check_view();
		check_dynarray();
	}
#endif
}
#ifdef _MSC_VER
#define FP_IMPLEMENTATION
#endif

#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>
// #include "doctest_stubs.hpp"

#include <fp/pointer.h>

extern "C" {
void check_stack();
void check_heap();
void check_view();
}

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

#if !(defined _MSC_VER || defined __APPLE__)
	TEST_CASE("C") {
		check_stack();
		check_heap();
		check_view();
	}
#endif
}
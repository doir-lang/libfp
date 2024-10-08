#include <doctest/doctest.h>
// #include "doctest_stubs.hpp"

#include <fp/pointer.hpp>

TEST_SUITE("LibFP::C++") {

	TEST_CASE("Stack") {
        fp::array<int, 20> arr = {};
		arr[10] = 6;

		CHECK(arr.is_fp());
		CHECK(arr.stack_allocated());
		CHECK(!arr.heap_allocated());
		CHECK(arr.length() == 20);
		CHECK(arr[10] == 6);
	}

	TEST_CASE("Empty For") {
		fp::pointer<int> p = nullptr;
		bool run = false;
		for(int x: p) {
			CHECK(x == 0);
			run = true; // Should never run
		}
		CHECK(run == false);
	}

	TEST_CASE("Heap (Manual)") {
		auto arr = fp::malloc<int>(20);
		arr = fp::realloc(arr, 25);
		arr[20] = 6;

		CHECK(arr.is_fp());
		CHECK(!arr.stack_allocated());
		CHECK(arr.heap_allocated());
		CHECK(arr.length() == 25);
		CHECK(arr[20] == 6);

		arr.free();
	}

	TEST_CASE("Heap (RAII)") {
		fp::raii::pointer arr = fp::malloc<int>(20);
		arr.realloc(25);
		arr[20] = 6;
		arr.realloc(26);

		CHECK(arr.is_fp());
		CHECK(!arr.stack_allocated());
		CHECK(arr.heap_allocated());
		CHECK(arr.length() == 26);
		CHECK(arr[20] == 6);

		auto arr2 = arr;
		CHECK(arr2 != arr);
		CHECK(arr.is_fp());
		CHECK(!arr.stack_allocated());
		CHECK(arr.heap_allocated());
		CHECK(arr.length() == 26);
		CHECK(arr[20] == 6);
	}

    TEST_CASE("View") {
		fp::array<int, 20> arr = {};
		arr[10] = 6;

        auto view = arr.view(10, 3);
		CHECK(view.size() == 3);
		CHECK(view[0] == 6);
		view[1] = 8;
		view[2] = 6;

		auto sub = view.subview(1, 1);
		CHECK(sub[0] == 8);
		sub[0] = 6;

		for(auto& i: view) CHECK(i == 6);
	}

}
#include <doctest/doctest.h>
// #include "doctest_stubs.hpp"

#include <fp/pointer.hpp>
#include <fp/dynarray.hpp>

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
		CHECK(arr2.raw != arr.raw);
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

	TEST_CASE("Dynamic Array - Basic") {
		fp::dynarray<int> arr = {};
		arr.reserve(20);
		CHECK(arr.capacity() == 20); // NOTE: FPDAs aren't valid until they have had at least one element added!
		CHECK(arr.size() == 0);

		arr.push_back(5);
		CHECK(arr.capacity() == 20);
		CHECK(arr.size() == 1);
		CHECK(arr[0] == 5);

		arr.push_front(6);
		CHECK(arr.capacity() == 20);
		CHECK(arr.size() == 2);
		CHECK(arr[0] == 6);
		CHECK(arr[1] == 5);
		CHECK(arr.front() == 6);
		CHECK(arr.back() == 5);

		arr.push_back(7);
		CHECK(arr.capacity() == 20);
		CHECK(arr.size() == 3);
		CHECK(arr[0] == 6);
		CHECK(arr[1] == 5);
		CHECK(arr[2] == 7);
		CHECK(arr.front() == 6);
		CHECK(arr.back() == 7);

		arr.delete_(1);
		CHECK(arr.capacity() == 20);
		CHECK(arr.size() == 2);
		CHECK(arr[0] == 6);
		CHECK(arr[1] == 7);

		arr.swap(0, 1);
		CHECK(arr.capacity() == 20);
		CHECK(arr.size() == 2);
		CHECK(arr[0] == 7);
		CHECK(arr[1] == 6);

		fp::raii::dynarray<int> arr2 = arr;
		CHECK(arr2.raw != arr.raw);
		CHECK(arr.capacity() == 20);
		CHECK(arr2.capacity() == 2);
		CHECK(arr.size() == 2);
		CHECK(arr2.size() == 2);
		CHECK(arr[0] == 7);
		CHECK(arr2[0] == 7);
		CHECK(arr[1] == 6);
		CHECK(arr2[1] == 6);

		arr2.grow_to_size(5, 8);
		CHECK(arr2.capacity() == 5);
		CHECK(arr2.size() == 5);
		CHECK(arr2[0] == 7);
		CHECK(arr2[1] == 6);
		CHECK(arr2[2] == 8);
		CHECK(arr2[3] == 8);
		CHECK(arr2[4] == 8);

		arr.shrink_to_fit();
		CHECK(arr.capacity() == 2);
		CHECK(arr.size() == 2);
		CHECK(arr[0] == 7);
		CHECK(arr[1] == 6);

		arr.free_and_null();
	}

}
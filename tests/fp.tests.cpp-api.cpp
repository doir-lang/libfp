#include <doctest/doctest.h>
// #include "doctest_stubs.hpp"

#include <format>

#include <fp/pointer.hpp>
#include <fp/dynarray.hpp>
#include <fp/string.hpp>
#include <fp/hash.hpp>

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

	TEST_CASE("Stack (Dynamic Size)") {
		fp::pointer<int> arr = fp_alloca(int, 20);
		arr.fill(42);

		CHECK(arr.is_fp());
		CHECK(arr.stack_allocated());
		CHECK(!arr.heap_allocated());
		CHECK(arr.length() == 20);
		CHECK(arr[10] == 42);
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
		fp::auto_free arr = fp::malloc<int>(20);
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

		fp::auto_free arr2 = arr;
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

		arr.free();
	}

	TEST_CASE("String") {
		auto str = fp::raii::string{"Hello World"};
		CHECK(str.is_fp());
		CHECK(str.is_dynarray());
		CHECK(!str.stack_allocated());
		CHECK(str.heap_allocated());
		CHECK(str.size() == 11);
		CHECK(str == str);
		// CHECK(str[str.size()] == 0); // fp_strings are null terminated! This check is out of bounds and will thus assert!

		auto concat = str.concatenate("!").auto_free();
		CHECK(str < concat);
		CHECK(concat > str);
		CHECK(concat == "Hello World!");
		concat.concatenate_inplace(" bob");
		CHECK(concat == "Hello World! bob");
		CHECK(concat.contains("World!"));
		CHECK(concat.find("World!") == 6);

		auto concatN = fp::builder::string{nullptr} << "Hello" << " " << "World" << "!";
		CHECK(concatN == "Hello World!");

		auto clone = str;
		fp::raii::string append = clone + '!';
		CHECK(append == "Hello World!");

#ifndef _MSC_VER
		auto fmt = fp::raii::string{"%s %s%c\n"}.c_format("Hello", "World", '!').auto_free();
		CHECK(fmt == "Hello World!\n");
#endif
		auto fmt2 = fp::string::format("{} {}{}\n", "Hello", "World", '!').auto_free();
		CHECK(fmt2 == "Hello World!\n");

		auto repl = str.replicate(5).auto_free();
		CHECK(repl == "Hello WorldHello WorldHello WorldHello WorldHello World");

		auto replaced = repl.replace("World", "Bob", 0).auto_free();
		CHECK(replaced == "Hello BobHello BobHello BobHello BobHello Bob");
		CHECK(replaced.starts_with("Hello"));
		CHECK(replaced.ends_with("Bob"));

		replaced.replace_inplace("Bob", "World!"); // TODO: Leaks
		CHECK(replaced == "Hello World!Hello World!Hello World!Hello World!Hello World!");
		CHECK(replaced.starts_with("Hello"));
		CHECK(replaced.ends_with("World!"));
		CHECK(!replaced.ends_with("World"));
	}

	TEST_CASE("String::Equal_Replace") {
		auto str = fp::raii::string{"ball"}.replicate(5).auto_free();
		auto replaced = str.replace("ball", "look", 0).auto_free();
		CHECK(replaced == "looklooklooklooklook");
	}

	TEST_CASE("UTF32") {
		auto cp = fp::wrapped::string{"Hello, 世界"}.to_codepoints();
		std::array<uint32_t, 9> real = {'H', 'e', 'l', 'l', 'o', ',', ' ', 0x4E16, 0x754C};
		CHECK(cp.size() == real.size());
		CHECK(cp.view_full() == fp::view<uint32_t>{real.data(), real.size()});

		auto utf8 = fp::string::from_codepoints(cp).auto_free();
		cp.free();
		CHECK(utf8 == "Hello, 世界");
	}

	TEST_CASE("Hashtable") {
		fp::auto_free table = fp::hash_table<int>::create();
		CHECK(table.raw != nullptr);
		CHECK(table.is_hash_table());

		CHECK(table.insert(5, true) == 5);

		auto p = table.find_position(5);
		CHECK(p == 6);
		CHECK(table[p] == 5);
		auto v = table.find(5);
		CHECK(*v == 5);

		auto v2 = &table.insert(5);
		CHECK(v2 == v);

		v = &table.insert(6);
		CHECK(v != v2);
		CHECK(*v == 6);

		auto failed_index = table.double_size_and_rehash();
		REQUIRE(failed_index == fp_not_found);

		CHECK(*table.find(5) == 5);
		CHECK(*table.find(6) == 6);
		CHECK(table.find(7) == nullptr);

		table.remove(5);

		CHECK(table.find(5) == nullptr);
	}

	TEST_CASE("Hashmap") {
		fp::hash_map<fp::raii::string, int> map;
		for(size_t i = 0; i < 100; ++i)
			map[fp::raii::string::format("{}", i)] = i;

		for(size_t i = 0; i < 100; ++i) {
			fp::auto_free s = fp::string::format("{}", i);
			CHECK(map[s] == i);
		}
	}
}

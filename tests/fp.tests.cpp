#ifdef _MSC_VER
#define FP_IMPLEMENTATION
#endif

#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>
// #include "doctest_stubs.hpp"

#include <fp/pointer.h>
#include <fp/dynarray.h>
#include <fp/string.h>
#include <fp/hash.h>

extern "C" {
void check_stack();
void check_heap();
void check_view();
void check_dynarray();
void check_string();
void check_utf32();
void check_hashtable();
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

	TEST_CASE("String") {
		fp_string str = fp_string_promote_literal("Hello World");
		CHECK(is_fp(str));
		CHECK(is_fpda(str));
		CHECK(!fp_is_stack_allocated(str));
		CHECK(fp_is_heap_allocated(str));
		CHECK(fpda_size(str) == 11);
		CHECK(fp_string_compare(str, str) == 0);
		CHECK(str[fp_string_length(str)] == 0); // fp_strings are null terminated!

		auto concat = fp_string_concatenate(str, "!");
		CHECK(fp_string_compare(str, concat) < 0);
		CHECK(fp_string_compare(concat, str) > 0);
		CHECK(fp_string_compare(concat, "Hello World!") == 0);
		fp_string_concatenate_inplace(concat, " bob");
		CHECK(fp_string_compare(concat, "Hello World! bob") == 0);
		CHECK(fp_string_contains(concat, "World!", 0));
		CHECK(fp_string_find(concat, "World!", 0) == 6);
		CHECK(fp_string_find(concat, "Not here!", 0) == fp_not_found);
		fp_string_free(concat);
		// printf("%s\n", concat);

		fp_string concatN = fp_string_concatenate_n(4, "Hello", " ", "World", "!");
		CHECK(fp_string_compare(concatN, "Hello World!"));
		fp_string_free(concatN);

		auto clone = fp_string_make_dynamic(str);
		auto append = fp_string_append(clone, '!');
		CHECK(fp_string_compare(append, "Hello World!") == 0);
		fp_string_free(append);

		auto fmt = fp_string_format("%s %s%c\n", "Hello", "World", '!');
		CHECK(fp_string_compare(fmt, "Hello World!\n") == 0);
		fp_string_free(fmt);

		auto repl = fp_string_replicate("Hello World", 5);
		CHECK(fp_string_compare(repl, "Hello WorldHello WorldHello WorldHello WorldHello World") == 0);

		auto replaced = fp_string_replace(repl, "World", "Bob", 0);
		fp_string_free(repl);
		CHECK(fp_string_compare(replaced, "Hello BobHello BobHello BobHello BobHello Bob") == 0);
		CHECK(fp_string_starts_with(replaced, "Hello", 0));
		CHECK(fp_string_ends_with(replaced, "Bob", 0));
		fp_string_replace_inplace(&replaced, fp_string_to_view_const("Bob"), fp_string_to_view_const("World!"), 0);
		CHECK(fp_string_compare(replaced, "Hello World!Hello World!Hello World!Hello World!Hello World!") == 0);
		CHECK(fp_string_starts_with(replaced, "Hello", 0));
		CHECK(fp_string_ends_with(replaced, "World!", 0));
		CHECK(!fp_string_ends_with(replaced, "World", 0));
		fp_string_free(replaced);

		fp_string_free(str);
	}

	TEST_CASE("String::Equal_Replace") {
		auto str = fp_string_replicate("ball", 5);
		auto replaced = fp_string_replace(str, "ball", "look", 0);
		CHECK(fp_string_equal(replaced, "looklooklooklooklook"));
		fp_string_free(str);
		fp_string_free(replaced);
	}

	TEST_CASE("UTF32") {
		auto cp = fp_string_to_codepoints("Hello, 世界");
		uint32_t real[] = {'H', 'e', 'l', 'l', 'o', ',', ' ', 0x4E16, 0x754C};
		size_t real_len = sizeof(real)/sizeof(real[0]);
		CHECK(fpda_size(cp) == real_len);
		CHECK(fp_view_equal(fp_view_make_full(uint32_t, cp), fp_view_literal(uint32_t, real, real_len)));

		auto utf8 = fp_codepoints_to_string(cp);
		fpda_free(cp);
		CHECK(fp_string_equal(utf8, "Hello, 世界"));
		fp_string_free(utf8);
	}

	TEST_CASE("Hashtable") {
		fp_hashtable(int) table = fp_create_default_hash_table(int);
		CHECK(table != nullptr);
		CHECK(is_fpht(table));

		int key = 5;
		auto v = fpht_insert_assume_unique(table, key);
		CHECK(*v == key);

		auto p = fpht_find_position(table, key);
		CHECK(p == 6);
		CHECK(table[p] == key);
		v = fpht_find(table, key);
		CHECK(*v == key);

		auto v2 = fpht_insert(table, key);
		CHECK(v2 == v);

		key = 6;
		v = fpht_insert(table, key);
		CHECK(v != v2);
		CHECK(*v == 6);

		auto failed_index = fpht_double_size_and_rehash(table);
		REQUIRE(failed_index == fp_not_found);

		key = 5;
		v = fpht_find(table, key);
		CHECK(*v == 5);
		key = 6;
		v = fpht_find(table, key);
		CHECK(*v == 6);
		key = 7;
		v = fpht_find(table, key);
		CHECK(v == nullptr);

		key = 5;
		fpht_remove(table, key);

		v = fpht_find(table, key);
		CHECK(v == nullptr);

		fpht_free_and_null(table);
	}

	TEST_CASE("Hashtable from view") {
		float* values = fp_alloca(float, 5);
		for(size_t i = 0; i < fp_size(values); ++i)
			values[i] = i;

		auto table = fp_create_default_hash_table_from_array(values);
		float key = 3;
		auto v = fpht_find(table, key);
		CHECK(*v == key);
		key = 20;
		v = fpht_find(table, key);
		CHECK(v == nullptr);
		fpht_free_and_null(table);

		for(size_t i = 0; i < fp_size(values); ++i)
			values[i] = 3;
		table = fp_create_default_hash_table_from_array(values);
		key = 3;
		v = fpht_find(table, key);
		CHECK(*v == key);
		key = 20;
		v = fpht_find(table, key);
		CHECK(v == nullptr);
		fpht_free_and_null(table);
	}

#if !(defined _MSC_VER || defined __APPLE__)
	TEST_CASE("C") {
		check_stack();
		check_heap();
		check_view();
		check_dynarray();
		check_string();
		check_utf32();
		check_hashtable();
	}
#endif
}

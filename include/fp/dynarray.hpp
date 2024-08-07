/**
 * @file dynarray.hpp
 * @brief C++ wrapper for dynamic arrays with modern C++ features
 *
 * This header provides a modern C++ interface to the dynamic array (vector-like)
 * implementation, including:
 * - RAII automatic memory management
 * - Move semantics and perfect forwarding
 * - Automatic destructor calls for non-trivial types
 * - Method chaining for fluent interface
 * - Initializer list construction
 * - STL-compatible interface
 *
 * @section example_basic Basic Dynarray Usage
 * @code
 * #include "dynarray.hpp"
 *
 * // Create empty dynamic array
 * fp::dynarray<int> numbers;
 *
 * // Add elements
 * numbers.push_back(10);
 * numbers.push_back(20);
 * numbers.push_back(30);
 *
 * // Method chaining
 * numbers.reserve(100).grow(5, 42);
 *
 * // Access elements
 * for(auto& n : numbers)
 *     std::cout << n << " ";
 *
 * // Manually freed
 * numbers.free();
 * @endcode
 *
 * @section example_raii RAII Dynarray Usage
 * @code
 * {
 *     fp::raii::dynarray<std::string> names;
 *     names.push_back("Alice");
 *     names.push_back("Bob");
 *     names.emplace_back("Charlie");
 *
 *     // Strings automatically destructed and memory freed
 * }
 * @endcode
 *
 * @section example_complex Complex Types in a Dynarray
 * @code
 * struct Widget {
 *     int id;
 *     std::string name;
 *     Widget(int i, std::string n) : id(i), name(std::move(n)) {}
 * };
 *
 * fp::raii::dynarray<Widget> widgets;
 *
 * // In-place construction
 * widgets.emplace_back(1, "Foo");
 * widgets.emplace_back(2, "Bar");
 *
 * // Widget destructors called automatically on clear/free
 * widgets.clear();
 * @endcode
 */

#pragma once

#include "pointer.hpp"
#include "dynarray.h"
#include <type_traits>

namespace fp {

	/**
	 * @brief CRTP base providing dynamic array operations
	 * @tparam T Element type
	 * @tparam Derived The derived class (CRTP pattern)
	 *
	 * This class uses the Curiously Recurring Template Pattern (CRTP) to provide
	 * dynamic array operations to derived classes. It handles automatic destructor
	 * calls for non-trivial types and provides method chaining.
	 */
	template<typename T, typename Derived>
	struct dynarray_crtp {
		/**
		 * @brief Check if this is a valid dynamic array
		 * @return true if this is a dynamic array
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * assert(!arr.is_dynarray());  // Empty/null
		 *
		 * arr.push_back(42);
		 * assert(arr.is_dynarray());   // Now valid
		 * @endcode
		 */
		inline bool is_dynarray() const { return is_fpda(ptr()); }

		/**
		 * @brief Get allocated capacity
		 * @return Number of elements that can be stored without reallocation
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * arr.reserve(50);
		 *
		 * assert(arr.capacity() == 50);
		 * assert(arr.size() == 0);
		 *
		 * arr.push_back(1);
		 * assert(arr.capacity() == 50);  // No reallocation
		 * @endcode
		 */
		inline size_t capacity() const { return fpda_capacity(ptr()); }

		/**
		 * @brief Free the dynamic array
		 * @param nullify If true, sets pointer to null (default: true)
		 *
		 * Calls destructors for non-trivial types before freeing memory.
		 *
		 * @code
		 * fp::dynarray<std::string> strings;
		 * strings.push_back("Hello");
		 * strings.push_back("World");
		 *
		 * strings.free();  // Destructors called, memory freed, ptr nulled
		 * assert(!strings);
		 * @endcode
		 */
		inline void free(bool nullify = true) {
			if constexpr (!std::is_trivially_destructible_v<T>) {
				for(auto& e: *derived())
					e.~T();
			}
			fpda_free(ptr());
			if(nullify) ptr() = nullptr;
		}

		/**
		 * @brief Free the dynamic array (const version)
		 *
		 * @warning Does not nullify pointer. Prefer non-const version.
		 */
		inline void free() const {
			if constexpr (!std::is_trivially_destructible_v<T>) {
				for(auto& e: *derived())
					e.~T();
			}
			fpda_free((void*)ptr());
		}

		/**
		 * @brief Reserve capacity for at least size elements
		 * @param size Minimum capacity to reserve
		 * @return Reference to this array for chaining
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 *
		 * // Reserve and chain operations
		 * arr.reserve(1000)
		 *    .push_back(42);
		 * arr.push_back(99);
		 *
		 * // No reallocations for next 998 elements
		 * @endcode
		 */
		inline Derived& reserve(size_t size) {
			fpda_reserve(ptr(), size);
			return *derived();
		}

		/**
		 * @brief Grow array by adding initialized elements
		 * @param to_add Number of elements to add
		 * @param value Value to initialize new elements with (default-constructed if omitted)
		 * @return Reference to this array for chaining
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * arr.push_back(1);
		 * arr.push_back(2);
		 *
		 * // Add 5 elements, all initialized to 99
		 * arr.grow(5, 99);
		 *
		 * assert(arr.size() == 7);
		 * assert(arr[2] == 99);
		 * @endcode
		 */
		inline Derived& grow(size_t to_add, const T& value = {}) {
			fpda_grow_and_initialize(ptr(), to_add, value);
			return *derived();
		}

		/**
		 * @brief Grow array with uninitialized elements
		 * @param to_add Number of elements to add
		 * @return Reference to this array for chaining
		 *
		 * New elements are uninitialized - you must initialize them before use.
		 * Useful for performance when you'll immediately overwrite values.
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * arr.push_back(1);
		 *
		 * size_t old_size = arr.size();
		 * arr.grow_uninitialized(10);
		 *
		 * // Initialize new elements
		 * for(size_t i = old_size; i < arr.size(); i++)
		 *     arr[i] = i * 10;
		 * @endcode
		 */
		inline Derived& grow_uninitialized(size_t to_add) {
			fpda_grow(ptr(), to_add);
			return *derived();
		}

		/**
		 * @brief Grow to exact size with initialized elements
		 * @param size Target size
		 * @param value Value to initialize new elements with (default-constructed if omitted)
		 * @return Reference to this array for chaining
		 *
		 * @note If size is smaller than the current size, this function does nothing!
		 *
		 * @code
		 * fp::raii::dynarray<float> data;
		 * data.grow_to_size(100, 3.14f);
		 *
		 * assert(data.size() == 100);
		 * for(auto& val : data)
		 *     assert(val == 3.14f);
		 * @endcode
		 */
		inline Derived& grow_to_size(size_t size, const T& value = {}) {
			fpda_grow_to_size_and_initialize(ptr(), size, value);
			return *derived();
		}

		/**
		 * @brief Grow to exact size with uninitialized elements
		 * @param size Target size
		 * @return Reference to this array for chaining
		 */
		inline Derived& grow_to_size_uninitialized(size_t size) {
			fpda_grow_to_size(ptr(), size);
			return *derived();
		}

		/**
		 * @brief Add element to end of array
		 * @param value Value to add
		 * @return Reference to the newly added element
		 *
		 * @code
		 * fp::raii::dynarray<std::string> names;
		 * names.push_back("Alice");
		 * names.push_back("Bob");
		 *
		 * std::string& ref = names.push_back("Charlie");
		 * ref += " Smith";  // Modify in place
		 *
		 * assert(names[2] == "Charlie Smith");
		 * @endcode
		 */
		inline T& push_back(const T& value) {
			return fpda_push_back(ptr(), value);
		}

		/**
		 * @brief Construct element in-place at end of array
		 * @tparam Targs Constructor argument types
		 * @param args Constructor arguments
		 * @return Reference to the newly constructed element
		 *
		 * Constructs the element directly in the array without copying/moving.
		 *
		 * @code
		 * struct Point {
		 *     int x, y;
		 *     Point(int x_, int y_) : x(x_), y(y_) {}
		 * };
		 *
		 * fp::raii::dynarray<Point> points;
		 *
		 * // Construct directly in array
		 * points.emplace_back(10, 20);
		 * points.emplace_back(30, 40);
		 *
		 * assert(points[0].x == 10);
		 * @endcode
		 */
		template<typename... Targs>
		inline T& emplace_back(Targs... args) {
			auto out = fpda_grow(ptr(), 1);
			return *(new(out) T(std::forward<Targs>(args)...));
		}

		/**
		 * @brief Remove last n elements
		 * @param count Number of elements to remove
		 * @return Reference to first element removed (one after the new last element)
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * for(int i = 0; i < 10; i++) arr.push_back(i);
		 *
		 * arr.pop_back_n(3);
		 * assert(arr.size() == 7);
		 * @endcode
		 */
		inline T& pop_back_n(size_t count) {
			return *fpda_pop_back_n(ptr(), count);
		}

		/**
		 * @brief Remove last element
		 * @return Reference to removed element (now invalid)
		 *
		 * @code
		 * fp::raii::dynarray<int> stack;
		 * stack.push_back(10);
		 * stack.push_back(20);
		 * stack.push_back(30);
		 *
		 * stack.pop_back();
		 * assert(stack.size() == 2);
		 * assert(stack.back() == 20);
		 * @endcode
		 */
		inline T& pop_back() {
			return *fpda_pop_back(ptr());
		}

		/**
		 * @brief Pop elements until size reaches target
		 * @param size Target size
		 * @return Reference to first element removed (one after the new last element)
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * for(int i = 0; i < 100; i++) arr.push_back(i);
		 *
		 * arr.pop_back_to_size(50);
		 * assert(arr.size() == 50);
		 * @endcode
		 */
		inline T& pop_back_to_size(size_t size) {
			assert(size < fpda_size(ptr()));
			return *fpda_pop_back_to_size(ptr(), size);
		}

		/**
		 * @brief Insert element at position
		 * @param pos Position to insert at
		 * @param value Value to insert (default-constructed if omitted)
		 * @return Reference to inserted element
		 *
		 * Elements after pos are shifted right. O(n) operation.
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * arr.push_back(1);
		 * arr.push_back(2);
		 * arr.push_back(4);
		 *
		 * arr.insert(2, 3);
		 * // arr: [1, 2, 3, 4]
		 *
		 * assert(arr[2] == 3);
		 * @endcode
		 */
		inline T& insert(size_t pos, const T& value = {}) {
			return fpda_insert(ptr(), pos, value);
		}

		/**
		 * @brief Construct element in-place at position
		 * @tparam Targs Constructor argument types
		 * @param pos Position to insert at
		 * @param args Constructor arguments
		 * @return Reference to inserted element
		 *
		 * Elements after pos are shifted right. O(n) operation.
		 *
		 * @code
		 * struct Widget {
		 *     int id;
		 *     std::string name;
		 *     Widget(int i, std::string n) : id(i), name(std::move(n)) {}
		 * };
		 *
		 * fp::raii::dynarray<Widget> widgets;
		 * widgets.emplace_back(1, "First");
		 * widgets.emplace_back(3, "Third");
		 *
		 * widgets.emplace(1, 2, "Second");
		 * // widgets: [(1,"First"), (2,"Second"), (3,"Third")]
		 * @endcode
		 */
		template<typename... Targs>
		inline T& emplace(size_t pos, Targs... args) {
			auto out = fpda_insert_uninitialized(ptr(), pos, 1);
			return *(new(out) T(std::forward<Targs>(args)...));
		}

		/**
		 * @brief Insert element at front
		 * @param value Value to insert
		 * @return Reference to inserted element
		 *
		 * All current elements are shifted right. O(n) operation.
		 *
		 * @code
		 * fp::raii::dynarray<int> deque;
		 * deque.push_front(3);
		 * deque.push_front(2);
		 * deque.push_front(1);
		 *
		 * // deque: [1, 2, 3]
		 * assert(deque[0] == 1);
		 * @endcode
		 */
		inline T& push_front(const T& value = {}) {
			return fpda_push_front(ptr(), value);
		}

		/**
		 * @brief Construct element in-place at front
		 * @tparam Targs Constructor argument types
		 * @param args Constructor arguments
		 * @return Reference to newly constructed element
		 *
		 * All current elements are shifted right. O(n) operation.
		 *
		 * @code
		 * fp::raii::dynarray<std::string> list;
		 * list.emplace_front("World");
		 * list.emplace_front("Hello");
		 *
		 * // list: ["Hello", "World"]
		 * @endcode
		 */
		template<typename... Targs>
		inline T& emplace_front(Targs... args) {
			return emplace(0, std::forward<Targs>(args)...);
		}

		/**
		 * @brief Insert uninitialized elements
		 * @param pos Position to insert at
		 * @param count Number of elements to insert (default: 1)
		 * @return View over the inserted uninitialized elements
		 *
		 * Elements after pos are shifted right. O(n) operation.
		 *
		 * @code
		 * fp::dynarray<int> arr;
		 * arr.push_back(1);
		 * arr.push_back(5);
		 *
		 * auto view = arr.insert_uninitialized(1, 3);
		 * view[0] = 2;
		 * view[1] = 3;
		 * view[2] = 4;
		 *
		 * // arr: [1, 2, 3, 4, 5]
		 * @endcode
		 */
		inline view<T> insert_uninitialized(size_t pos, size_t count = 1) {
			fpda_insert_uninitialized(ptr(), pos, count);
			return derived()->view(pos, count);
		}

		/**
		 * @brief Delete range of elements
		 * @param pos Starting position
		 * @param count Number of elements to delete
		 * @return Reference to this array for chaining
		 *
		 * Elements after pos + count are shifted left. O(n) operation.
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * for(int i = 0; i < 10; i++) arr.push_back(i);
		 *
		 * arr.delete_range(3, 4)
		 *    .push_back(99);
		 *
		 * assert(arr.size() == 7);
		 * @endcode
		 */
		inline Derived& delete_range(size_t pos, size_t count) {
			if constexpr (!std::is_trivially_destructible_v<T>)
				__destroy({ptr() + pos, count});
			fpda_delete_range(ptr(), pos, count);
			return *derived();
		}

		/**
		 * @brief Delete single element
		 * @param pos Position to delete
		 * @return Reference to this array for chaining
		 *
		 * Elements after pos are shifted left. O(n) operation.
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * arr.push_back(1).push_back(2).push_back(3);
		 *
		 * arr.delete_(1);
		 * // arr: [1, 3]
		 * @endcode
		 */
		inline Derived& delete_(size_t pos) {
			if constexpr (!std::is_trivially_destructible_v<T>)
				__destroy({ptr() + pos, 1});
			fpda_delete(ptr(), pos);
			return *derived();
		}

		/// @brief Alias for delete_
		inline Derived& remove(size_t pos) { return delete_(pos); }

		/**
		 * @brief Delete range using start and end indices
		 * @param start Starting index (inclusive)
		 * @param end Ending index (inclusive)
		 * @return Reference to this array for chaining
		 *
		 * Elements after end are shifted left. O(n) operation.
		 */
		inline Derived& delete_start_end(size_t start, size_t end) {
			if constexpr (!std::is_trivially_destructible_v<T>)
				__destroy({ptr() + start, end - start + 1});
			fpda_delete_start_end(ptr(), start, end);
			return *derived();
		}

		/**
		 * @brief Delete range and shrink capacity
		 * @param pos Starting position
		 * @param count Number of elements to delete
		 * @return Reference to this array for chaining
		 *
		 * Like delete_range but also reallocates to free unused capacity.
		 * All elements are copied. O(n) operation.
		 */
		inline Derived& shrink_delete_range(size_t pos, size_t count) {
			if constexpr (!std::is_trivially_destructible_v<T>)
				__destroy({ptr() + pos, count});
			fpda_shrink_delete_range(ptr(), pos, count);
			return *derived();
		}

		/**
		 * @brief Delete element and shrink capacity
		 * @param pos Position to delete
		 * @return Reference to this array for chaining
		 *
		 * Like delete_ but also reallocates to free unused capacity.
		 * All elements are copied. O(n) operation.
		 */
		inline Derived& shrink_delete(size_t pos) {
			if constexpr (!std::is_trivially_destructible_v<T>)
				__destroy({ptr() + pos, 1});
			fpda_shrink_delete(ptr(), pos);
			return *derived();
		}

		/**
		 * @brief Delete range and shrink using start/end indices
		 * @param start Starting index (inclusive)
		 * @param end Ending index (inclusive)
		 * @return Reference to this array for chaining
		 *
		 * Like delete_start_end but also reallocates to free unused capacity.
		 * All elements are copied. O(n) operation.
		 */
		inline Derived& shrink_delete_start_end(size_t start, size_t end) {
			if constexpr (!std::is_trivially_destructible_v<T>)
				__destroy({ptr() + start, end - start + 1});
			fpda_shrink_delete_start_end(ptr(), start, end);
			return *derived();
		}

		/**
		 * @brief Resize array to new size
		 * @param size New size
		 * @return Reference to this array for chaining
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * for(int i = 0; i < 10; i++) arr.push_back(i);
		 *
		 * arr.resize(20);  // Grow
		 * assert(arr.size() == 20);
		 *
		 * arr.resize(5);   // Shrink
		 * assert(arr.size() == 5);
		 * @endcode
		 */
		inline Derived& resize(size_t size) {
			fpda_resize(ptr(), size);
			return *derived();
		}

		/**
		 * @brief Shrink capacity to match size
		 * @return Reference to this array for chaining
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * arr.reserve(1000);
		 * for(int i = 0; i < 100; i++) arr.push_back(i);
		 *
		 * assert(arr.capacity() == 1000);
		 *
		 * arr.shrink_to_fit();
		 * assert(arr.capacity() == 100);
		 * @endcode
		 */
		inline Derived& shrink_to_fit() {
			fpda_shrink_to_fit(ptr());
			return *derived();
		}

		/**
		 * @brief Swap two ranges of elements
		 * @param start1 Start of first range
		 * @param start2 Start of second range
		 * @param count Number of elements to swap
		 * @return Reference to this array for chaining
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * for(int i = 0; i < 10; i++) arr.push_back(i);
		 *
		 * arr.swap_range(0, 7, 3);
		 * // Swapped [0,1,2] with [7,8,9]
		 * @endcode
		 */
		inline Derived& swap_range(size_t start1, size_t start2, size_t count) {
			fpda_swap_range(ptr(), start1, start2, count);
			return *derived();
		}

		/**
		 * @brief Swap two elements
		 * @param pos1 First position
		 * @param pos2 Second position
		 * @return Reference to this array for chaining
		 *
		 * @code
		 * fp::raii::dynarray<int> arr = {10, 20, 30};
		 * arr.swap(0, 2);
		 * // arr: [30, 20, 10]
		 * @endcode
		 */
		inline Derived& swap(size_t pos1, size_t pos2) {
			fpda_swap(ptr(), pos1, pos2);
			return *derived();
		}

		/**
		 * @brief Swap range to end and delete
		 * @param pos Starting position
		 * @param count Number of elements
		 * @return Reference to this array for chaining
		 *
		 * O(1) deletion that doesn't preserve order.
		 *
		 * @code
		 * fp::dynarray<int> arr;
		 * for(int i = 0; i < 10; i++) arr.push_back(i);
		 *
		 * arr.swap_delete_range(2, 2);
		 * // Deleted elements at 2-3 by swapping with end
		 * assert(arr.size() == 8);
		 * @endcode
		 */
		inline Derived& swap_delete_range(size_t pos, size_t count) {
			if constexpr (!std::is_trivially_destructible_v<T>)
				__destroy({ptr() + pos, count});
			fpda_swap_delete_range(ptr(), pos, count);
			return *derived();
		}

		/**
		 * @brief Swap element to end and delete
		 * @param pos Position to delete
		 * @return Reference to this array for chaining
		 *
		 * Fast O(1) unordered deletion.
		 *
		 * @code
		 * fp::dynarray<int> arr = {0, 10, 20, 30, 40};
		 * arr.swap_delete(1);
		 * // arr: [0, 40, 20, 30]  (40 moved to position 1)
		 * @endcode
		 */
		inline Derived& swap_delete(size_t pos) {
			if constexpr (!std::is_trivially_destructible_v<T>)
				__destroy({ptr() + pos, 1});
			fpda_swap_delete(ptr(), pos);
			return *derived();
		}

		/**
		 * @brief Swap range to end and delete using start/end indices
		 * @param start Starting index (inclusive)
		 * @param end Ending index (inclusive)
		 * @return Reference to this array for chaining
		 *
		 * O(1) deletion that doesn't preserve order.
		 */
		inline Derived& swap_delete_start_end(size_t start, size_t end) {
			if constexpr (!std::is_trivially_destructible_v<T>)
				__destroy({ptr() + start, end - start + 1});
			fpda_swap_delete_start_end(ptr(), start, end);
			return *derived();
		}

		/**
		 * @brief Remove and return first element
		 * @return Reference to removed element (now invalid)
		 *
		 * Shifts all elements left. O(n) operation.
		 *
		 * @code
		 * fp::dynarray<int> queue;
		 * queue.push_back(1).push_back(2).push_back(3);
		 *
		 * queue.pop_front();
		 * // queue: [2, 3]
		 * @endcode
		 */
		inline T& pop_front() {
			if constexpr (!std::is_trivially_destructible_v<T>)
				__destroy({ptr(), 1});
			return *fpda_pop_front(ptr());
		}

		/**
		 * @brief Create a copy of this array
		 * @return New array with copied data
		 *
		 * @code
		 * fp::raii::dynarray<int> original;
		 * original.push_back(1);
		 * original.push_back(2);
		 * original.push_back(3);
		 *
		 * fp::raii::dynarray<int> copy = original.clone();
		 * copy[0] = 999;  // Doesn't affect original
		 *
		 * assert(original[0] == 1);
		 * assert(copy[0] == 999);
		 * @endcode
		 */
		inline Derived clone() const {
			return (T*)fpda_clone(ptr());
		}

		/**
		 * @brief Clear all elements (keeps capacity)
		 * @return Reference to this array for chaining
		 *
		 * Calls destructors for non-trivial types.
		 *
		 * @code
		 * fp::raii::dynarray<std::string> strings;
		 * strings.push_back("Hello");
		 * strings.push_back("World");
		 *
		 * assert(strings.size() == 2);
		 *
		 * strings.clear();
		 *
		 * assert(strings.size() == 0);
		 * assert(strings.capacity() > 0);  // Capacity unchanged
		 * @endcode
		 */
		inline Derived& clear() {
			if constexpr (!std::is_trivially_destructible_v<T>) {
				for(auto& e: *derived())
					e.~T();
			}
			fpda_clear(ptr());
			return *derived();
		}

		/**
		 * @brief Concatenate view to this array in place
		 * @param view View to append
		 * @return Reference to this array for chaining
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * arr.push_back(1);
		 * arr.push_back(2);
		 *
		 * int more[] = {3, 4, 5};
		 * arr.concatenate_view_in_place({more, 3});
		 * // arr: [1, 2, 3, 4, 5]
		 * @endcode
		 */
		inline Derived& concatenate_view_in_place(const view<const T> view) {
			fpda_concatenate_view_in_place(ptr(), view);
			return *derived();
		}

		/**
		 * @brief Concatenate view (returns new array)
		 * @param view View to append
		 * @return New array with concatenated data
		 *
		 * @code
		 * fp::raii::dynarray<int> arr;
		 * arr.push_back(1);
		 * arr.push_back(2);
		 *
		 * int more[] = {3, 4, 5};
		 * fp::raii::dynarray<int> combined = arr.concatenate_view({more, 3});
		 * // combined: [1, 2, 3, 4, 5]
		 * @endcode
		 */
		inline Derived concatenate_view(const view<const T> view) const {
			return (T*)fpda_concatenate_view(ptr(), view);
		}

		/**
		 * @brief Concatenate other array to this one in place
		 * @param other Array to append
		 * @return Reference to this array for chaining
		 *
		 * @code
		 * fp::raii::dynarray<int> arr1, arr2;
		 * arr1.push_back(1);
		 * arr1.push_back(2);
		 * arr2.push_back(3);
		 * arr2.push_back(4);
		 *
		 * arr1.concatenate_in_place(arr2);
		 * // arr1: [1, 2, 3, 4]
		 * // arr2: [3, 4] (unchanged)
		 * @endcode
		 */
		inline Derived& concatenate_in_place(const Derived& other) {
			fpda_concatenate_in_place(ptr(), other.ptr());
			return *derived();
		}


		/**
		 * @brief Concatenate two arrays (returns new array)
		 * @param other Array to append
		 * @return New array with concatenated data
		 *
		 * @code
		 * fp::dynarray<int> arr1, arr2;
		 * arr1.push_back(1);
		 * arr1.push_back(2);
		 * arr2.push_back(3);
		 * arr2.push_back(4);
		 *
		 * fp::dynarray<int> combined = arr1.concatenate(arr2);
		 * // combined: [1, 2, 3, 4]
		 * // arr1 and arr2 unchanged
		 * @endcode
		 */
		inline Derived concatenate(const Derived& other) const {
			return (T*)fpda_concatenate(ptr(), other.ptr());
		}

	protected:
		/// @brief Get derived class pointer
		inline Derived* derived() { return (Derived*)this; }

		/// @brief Get derived class pointer (const version)
		inline const Derived* derived() const { return (Derived*)this; }

		/// @brief Get reference to internal pointer
		inline T*& ptr() { return derived()->ptr(); }

		/// @brief Get reference to internal pointer (const version)
		inline const T* const & ptr() const { return derived()->ptr(); }
	};

	/**
	 * @brief Dynamic array with manual memory management
	 * @tparam T Element type
	 *
	 * fp::dynarray is a std::vector-like container built on fat pointers. Provides automatic growth,
	 * efficient insertion/deletion, and full iterator support. Requires manual free()
	 * call or use fp::raii::dynarray for automatic cleanup.
	 *
	 * Features:
	 * - Automatic capacity management with amortized O(1) push
	 * - Method chaining for fluent interface
	 * - Perfect forwarding with emplace operations
	 * - Automatic destructor calls for non-trivial types
	 * - STL-compatible interface
	 *
	 * @section example_basic Basic Usage
	 * @code
	 * fp::dynarray<int> numbers;
	 *
	 * // Add elements
	 * numbers.push_back(10);
	 * numbers.push_back(20);
	 * numbers.push_back(30);
	 *
	 * // Method chaining
	 * numbers.reserve(100)
	 *        .grow(5, 42)
	 *        .push_back(99);
	 *
	 * // Iteration
	 * for(auto& n : numbers)
	 *     std::cout << n << " ";
	 *
	 * // Manual cleanup
	 * numbers.free();
	 * @endcode
	 *
	 * @section example_initializer Initializer List
	 * @code
	 * fp::dynarray<int> numbers = {1, 2, 3, 4, 5};
	 * assert(numbers.size() == 5);
	 * assert(numbers[2] == 3);
	 *
	 * fp::dynarray<std::string> names = {"Alice", "Bob", "Charlie"};
	 * assert(names.size() == 3);
	 *
	 * numbers.free();
	 * names.free();
	 * @endcode
	 *
	 * @section example_complex Complex Types
	 * @code
	 * struct Person {
	 *     std::string name;
	 *     int age;
	 *     Person(std::string n, int a) : name(std::move(n)), age(a) {}
	 * };
	 *
	 * fp::dynarray<Person> people;
	 *
	 * // In-place construction (no copies)
	 * people.emplace_back("Alice", 30);
	 * people.emplace_back("Bob", 25);
	 * people.emplace(1, "Charlie", 35);  // Insert at position 1
	 *
	 * // people: [Alice(30), Charlie(35), Bob(25)]
	 *
	 * people.free();  // Destructors called automatically
	 * @endcode
	 *
	 * @section example_operations Advanced Operations
	 * @code
	 * fp::dynarray<int> data;
	 * for(int i = 0; i < 100; i++)
	 *     data.push_back(i);
	 *
	 * // Delete range
	 * data.delete_range(10, 20);
	 *
	 * // Fast unordered delete (O(1))
	 * data.swap_delete(5);
	 *
	 * // Insert multiple elements
	 * auto view = data.insert_uninitialized(0, 5);
	 * for(size_t i = 0; i < view.size(); i++)
	 *     view[i] = -1;
	 *
	 * // Clone and concatenate
	 * fp::dynarray<int> copy = data.clone();
	 * data.concatenate_in_place(copy);
	 *
	 * data.free();
	 * copy.free();
	 * @endcode
	 *
	 * @section example_stl STL Compatibility
	 * @code
	 * fp::dynarray<int> arr = {5, 2, 8, 1, 9};
	 *
	 * // Use STL algorithms
	 * std::sort(arr.begin(), arr.end());
	 * std::reverse(arr.begin(), arr.end());
	 *
	 * // Find element
	 * auto it = std::find(arr.begin(), arr.end(), 5);
	 * if(it != arr.end())
	 *     std::cout << "Found at position: " << (it - arr.begin()) << "\n";
	 *
	 * // Use with span (C++20)
	 * std::span<int> s = arr.span();
	 *
	 * arr.free();
	 * @endcode
	 */
	template<typename T>
	struct dynarray: public pointer<T>, public dynarray_crtp<T, dynarray<T>> {
		using super = pointer<T>;
		using super::super;
		using super::ptr;

		/**
		 * @brief Construct from initializer list
		 * @param init Initializer list of values
		 *
		 * @code
		 * fp::dynarray<int> numbers = {1, 2, 3, 4, 5};
		 * fp::dynarray<double> values = {3.14, 2.71, 1.41};
		 * fp::dynarray<std::string> names = {"Alice", "Bob", "Charlie"};
		 *
		 * assert(numbers.size() == 5);
		 * assert(values.size() == 3);
		 * assert(names[1] == "Bob");
		 *
		 * numbers.free();
		 * values.free();
		 * names.free();
		 * @endcode
		 */
		dynarray(std::initializer_list<T> init) {
			crtp::reserve(init.size());
			for(auto& i: init)
				crtp::push_back(std::move(i));
		}

		FP_HPP_DEFAULT_CONSTRUCTOR_BLOCK(dynarray, super);

		using crtp = dynarray_crtp<T, dynarray<T>>;
		using crtp::free;
		using crtp::clone;

		/**
		 * @brief Implicit conversion to const dynarray
		 *
		 * Allows passing non-const arrays to functions expecting const arrays.
		 *
		 * @code
		 * void print_numbers(const fp::dynarray<const int>& arr) {
		 *     for(auto& n : arr)
		 *         std::cout << n << " ";
		 * }
		 *
		 * fp::dynarray<int> numbers = {1, 2, 3};
		 * print_numbers(numbers);  // Implicit conversion
		 * numbers.free();
		 * @endcode
		 */
		inline operator dynarray<std::add_const_t<T>>() const { return *(dynarray<std::add_const_t<T>>*)this; }

		fp::auto_free<dynarray> auto_free() { return std::move(*this); }
	};

	/**
	 * @namespace fp::raii
	 * @brief Namespace for RAII (automatic memory management) types
	 */
	namespace raii {
		/**
		 * @brief RAII version of dynarray with automatic memory management
		 * @tparam T Element type
		 *
		 * This dynarray automatically frees its memory when it goes out of scope.
		 * Ideal for exception-safe code and avoiding manual memory management.
		 * All destructors for non-trivial types are called automatically.
		 *
		 * @code
		 * void process_data() {
		 *     fp::raii::dynarray<std::string> names;
		 *     names.push_back("Alice");
		 *     names.push_back("Bob");
		 *     names.emplace_back("Charlie");
		 *
		 *     if(error_occurred())
		 *         return;  // Strings destructed, memory freed automatically
		 *
		 *     // Memory automatically freed when function returns
		 * }
		 * @endcode
		 *
		 * @section example_complex Complex Types
		 * @code
		 * struct Resource {
		 *     FILE* file;
		 *     Resource(const char* path) : file(fopen(path, "r")) {}
		 *     ~Resource() { if(file) fclose(file); }
		 * };
		 *
		 * {
		 *     fp::raii::dynarray<Resource> resources;
		 *     resources.emplace_back("file1.txt");
		 *     resources.emplace_back("file2.txt");
		 *
		 *     // Use resources...
		 *
		 *     // Destructors called automatically:
		 *     // 1. Resource destructors (close files)
		 *     // 2. Array memory freed
		 * }
		 * @endcode
		 *
		 * @section example_move Move Semantics
		 * @code
		 * fp::raii::dynarray<int> create_numbers() {
		 *     fp::raii::dynarray<int> nums;
		 *     for(int i = 0; i < 100; i++)
		 *         nums.push_back(i);
		 *     return nums;  // Moved, not freed
		 * }
		 *
		 * auto numbers = create_numbers();
		 * // numbers owns the data now
		 * // Freed when numbers goes out of scope
		 * @endcode
		 *
		 * @section example_containers Use in Containers
		 * @code
		 * std::vector<fp::raii::dynarray<int>> matrix;
		 *
		 * for(int i = 0; i < 10; i++) {
		 *     fp::raii::dynarray<int> row;
		 *     for(int j = 0; j < 10; j++)
		 *         row.push_back(i * 10 + j);
		 *     matrix.push_back(std::move(row));
		 * }
		 *
		 * // All rows automatically freed when matrix is destroyed
		 * @endcode
		 *
		 * @section example_exception Exception Safety
		 * @code
		 * void risky_operation() {
		 *     fp::raii::dynarray<std::string> data;
		 *     data.push_back("Important");
		 *     data.push_back("Data");
		 *
		 *     // This might throw
		 *     perform_network_operation();
		 *
		 *     // This might throw
		 *     parse_user_input();
		 *
		 *     // Even if exceptions occur, data is cleaned up properly
		 * }
		 * @endcode
		 *
		 * @section example_comparison RAII vs Manual
		 * @code
		 * // Manual management - prone to leaks
		 * void manual() {
		 *     fp::dynarray<std::string> data;
		 *     data.push_back("Hello");
		 *
		 *     if(early_return()) {
		 *         data.free();  // Must remember!
		 *         return;
		 *     }
		 *
		 *     process(data);
		 *     data.free();  // Must remember!
		 * }
		 *
		 * // RAII - always safe
		 * void automatic() {
		 *     fp::raii::dynarray<std::string> data;
		 *     data.push_back("Hello");
		 *
		 *     if(early_return())
		 *         return;  // Automatic cleanup
		 *
		 *     process(data);
		 *     // Automatic cleanup
		 * }
		 * @endcode
		 *
		 * @see fp::dynarray for manual memory management version
		 * @see fp::raii::pointer for RAII fat pointers
		 */
		template<typename T>
		using dynarray = auto_free<fp::dynarray<T>>;
	}
}

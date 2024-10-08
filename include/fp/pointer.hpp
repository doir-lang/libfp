/**
 * @file pointer.hpp
 * @brief C++ wrapper for the Fat Pointer library providing RAII and modern C++ interfaces
 *
 * This header provides modern C++ wrappers around the C-style fat pointer library,
 * including:
 * - RAII automatic memory management
 * - Type-safe view classes
 * - STL-compatible iterators and ranges
 * - Convenient operator overloads
 * - Compile-time sized arrays
 *
 * @section example_basic Basic C++ Usage
 * @code{.cpp}
 * #include "pointer.hpp"
 *
 * // Automatic memory management
 * fp::auto_free numbers = fp::malloc<int>(100);
 * for(size_t i = 0; i < numbers.size(); i++)
 *     numbers[i] = i * 2;
 * // Automatically freed when goes out of scope
 *
 * // Manual memory management
 * fp::pointer<float> data = fp::malloc<float>(50);
 * data.fill(3.14f);
 * data.free();
 *
 * // Compile-time sized array
 * fp::array<double, 10> fixed;
 * fixed[0] = 1.0;
 * @endcode
 *
 * @section example_views View Usage
 * @code{.cpp}
 * fp::auto_free arr = fp::malloc<int>(100);
 *
 * // Create a view of part of the array
 * fp::view<int> v = arr.view(10, 20);
 *
 * // Iterate over view
 * for(int& val : v)
 *     val = 2;
 *
 * // Create subviews
 * auto subv = v.subview(5, 10);
 * @endcode
 *
 * @section example_ranges STL Integration
 * @code{.cpp}
 * fp::auto_free data = fp::malloc<int>(50);
 *
 * // Convert to std::span
 * std::span<int> s = data.span();
 *
 * // Use with STL algorithms
 * std::sort(data.begin(), data.end());
 * std::fill(data.begin(), data.end(), 42);
 *
 * // Range-based for loops
 * for(int& val : data)
 *     std::cout << val << "\n";
 * @endcode
 *
 * @section example_stack_allocation Dynamic Stack Allocation
 * @code{.cpp}
 * fp::pointer<int> arr = fp_alloca(int, 100);
 * arr.fill(42);
 *
 * // Range-based for loops
 * for(int& val : data)
 *     std::cout << val << "\n";
 *
 * // Don't free this pointer our store it in a RAII type!
 * // arr.free()
 * @endcode
 */

#pragma once

#include <algorithm>
#include <cstddef>
#include <utility>
#include <cstring>
#include <array>

#include "pointer.h"

#ifdef FP_ENABLE_STD_RANGES
	#include <ranges>
#endif
#if defined(__cpp_lib_span) && __cpp_lib_span >= 202002L
	#include <span>
#endif

/**
 * @namespace fp
 * @brief Main namespace for C++ fat pointer wrappers
 */
namespace fp {
	// Helper since c++ doesn't come with a free standing contains function for some reason...
	template< class InputIt, class T >
	bool contains( InputIt first, InputIt last, const T& value ) {
		return std::find(first, last, value) != last;
	}

	/**
	 * @brief Sentinel value indicating element not found in search operations
	 *
	 * This value is returned by fp_find and fp_rfind when the searched element
	 * is not present in the fat pointer. It is set to SIZE_MAX, the maximum
	 * value of size_t, which cannot be a valid index.
	 *
	 * @code{.cpp}
	 * fp::auto_free arr = fp::malloc(int, 10);
	 * size_t idx = arr.find(42);
	 * if(idx == fp::not_found)
	 *     printf("Value not found\n");
	 * @endcode
	 */
	constexpr size_t not_found = fp_not_found;

	/**
	 * @brief RAII wrapper that automatically frees the wrapped pointer on destruction
	 * @tparam T Wrapped pointer type (e.g., fp::pointer<int>)
	 *
	 * This class wraps any type with a .free method a bool convertible raw field and
	 * construction from a (possibly null) pointer and ensures automatic cleanup when
	 * the object goes out of scope. It implements proper move semantics and copy on
	 * assignment.
	 *
	 * @code{.cpp}
	 * void process() {
	 *     auto_free<fp::pointer<int>> data(fp::malloc<int>(100));
	 *     data[0] = 42;
	 *     // Automatically freed when data goes out of scope
	 * }
	 *
	 * // Move semantics work correctly
	 * auto_free<fp::pointer<int>> create() {
	 *     auto_free<fp::pointer<int>> temp(fp::malloc<int>(10));
	 *     return temp; // Moved, not freed
	 * }
	 * @endcode
	 */
	template<typename T>
	struct auto_free: public T {
		/// @brief Default constructor - initializes to nullptr
		constexpr auto_free(): T(nullptr) {}

		/// @brief Construct from nullptr
		constexpr auto_free(std::nullptr_t): T(nullptr) {}

		/// @brief Construct from raw pointer (takes ownership)
		constexpr auto_free(T* ptr): T(ptr) {}

		/// @brief Copy constructor - clones the underlying data
		constexpr auto_free(const T& o): T(o.clone()) {}

		/// @brief Move constructor - transfers ownership
		constexpr auto_free(T&& o): T(std::exchange(o.raw, nullptr)) {}

		/// @brief Copy constructor from another auto_free - clones the data
		constexpr auto_free(const auto_free& o): T(o.clone()) {}

		/// @brief Move constructor from another auto_free - transfers ownership
		constexpr auto_free(auto_free&& o): T(std::exchange(o.raw, nullptr)) {}

		/// @brief Copy assignment - clones the data, frees old data
		constexpr auto_free& operator=(const T& o) { ~auto_free(); T::raw = o.clone(); return *this;}

		/// @brief Move assignment from T - transfers ownership, frees old data
		constexpr auto_free& operator=(T&& o) { ~auto_free(); T::raw = std::exchange(o.raw, nullptr); return *this; }

		/// @brief Copy assignment from auto_free - clones the data, frees old data
		constexpr auto_free& operator=(const auto_free& o) { ~auto_free(); T::raw = o.clone(); return *this;}

		/// @brief Move assignment from auto_free - transfers ownership, frees old data
		constexpr auto_free& operator=(auto_free&& o) { ~auto_free(); T::raw = std::exchange(o.raw, nullptr); return *this; }

		/// @brief Destructor - automatically frees the pointer if non-null
		~auto_free() { if(T::raw) T::free(true); }
	};

	namespace wrapped {
		/**
		 * @brief Base wrapper for raw pointers with basic pointer semantics
		 * @tparam T Element type
		 *
		 * Provides basic pointer wrapper functionality without fat pointer
		 * specifics. Used as a base for more specialized pointer types.
		 */
		template<typename T>
		struct pointer {
			T* raw; ///< Raw pointer to data

			/// @brief Default constructor - initializes to nullptr
			constexpr pointer(): raw(nullptr) {}

			/// @brief Construct from nullptr
			constexpr pointer(std::nullptr_t): raw(nullptr) {}

			/// @brief Construct from raw pointer
			constexpr pointer(T* ptr_): raw(ptr_) {}

			/// @brief Copy constructor
			constexpr pointer(const pointer& o) = default;

			/// @brief Move constructor - transfers ownership
			constexpr pointer(pointer&& o): raw(std::exchange(o.raw, nullptr)) {}

			/// @brief Copy assignment
			constexpr pointer& operator=(const pointer& o) = default;

			/// @brief Move assignment - transfers ownership
			constexpr pointer& operator=(pointer&& o) { raw = std::exchange(o.raw, nullptr); return *this; }

			/// @brief Implicit conversion to const version
			inline operator pointer<std::add_const_t<T>>() const { return *(pointer<std::add_const_t<T>>*)this; }

			/// @brief Get the raw pointer
			T* data() { return raw; }

			/// @brief Get the raw pointer (const version)
			const T* data() const { return raw; }

			///@{
			/**
			 * @brief Dereference operator
			 * @return Reference to the pointed-to value
			 */
			inline T& operator*() {
				assert(raw);
				return *raw;
			}

			// @brief Dereference operator (const version)
			inline const T& operator*() const {
				assert(raw);
				return *raw;
			}
			///@}

			///@{
			/**
			 * @brief Arrow operator for member access
			 * @return Raw pointer
			 */
			inline T* operator->() {
				assert(raw);
				return raw;
			}

			// @brief Arrow operator (const version)
			inline const T* operator->() const {
				assert(raw);
				return raw;
			}
			///@}

		protected:
			/// @brief Get reference to internal pointer
			inline T*& ptr() { return raw; }

			/// @brief Get reference to internal pointer (const version)
			inline const T* const & ptr() const { return raw; }
		};
	}



	/**
	 * @brief Non-owning view (fp::view) over a contiguous sequence of elements
	 * @tparam T Element type
	 *
	 * A view is a lightweight, non-owning reference to a contiguous block of memory.
	 * It stores a pointer and size but does not manage the lifetime of the data.
	 * Views support subviews, iteration, and conversion to/from std::span (if
	 * previously included).
	 *
	 * @code{.cpp}
	 * fp::auto_free arr = fp::malloc<int>(100);
	 *
	 * // Create view of entire array
	 * fp::view<int> full = fp::view<int>::make_full(arr.data());
	 *
	 * // Create view of subset
	 * fp::view<int> partial = full.subview(10, 20);
	 *
	 * // Iterate
	 * for(int& val : partial)
	 *     val = 2;
	 *
	 * // Access elements
	 * partial[0] = 999;
	 * @endcode
	 */
	template<typename T>
	struct view: public fp_view(T) {
		constexpr view(T* data = nullptr, size_t size = 0): fp_view(T)(fp_view_literal(T, data, size)) {}
		constexpr view(fp_view(T) o) : fp_view(T)(o) {}

		constexpr view(const view&) = default;
		constexpr view(view&&) = default;
		constexpr view& operator=(const view&) = default;
		constexpr view& operator=(view&&) = default;

		/**
		 * @brief Implicit conversion to const view
		 *
		 * Allows passing non-const views to functions expecting const views.
		 */
		inline operator view<std::add_const_t<T>>() const { return *(view<std::add_const_t<T>>*)this; }

		/**
		 * @brief Get the underlying C-style view
		 *
		 * @code{.cpp}
		 * fp::view<int> v = ...;
		 * fp_view(int)& c_style = v.raw();
		 * // Can now use C-style fp_view functions
		 * @endcode
		 */
		fp_view(T)& raw() { return *this; }

		auto make_dynamic();

		/**
		 * @brief Create a view from a fat pointer with start index and length
		 * @param p Fat pointer
		 * @param start Starting index
		 * @param length Number of elements
		 * @return View over the specified range
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 *
		 * // View elements 10-29 (20 elements starting at index 10)
		 * fp::view<int> v = fp::view<int>::make(arr.data(), 10, 20);
		 * assert(v.size() == 20);
		 *
		 * // Modify through view
		 * for(size_t i = 0; i < v.size(); i++) {
		 *     v[i] = 999;
		 * }
		 *
		 * assert(arr[10] == 999);  // Original array modified
		 * @endcode
		 */
		static view make(T* p, size_t start, size_t length) {
			assert(fp_size(p) >= start + length);
			return {fp_view_make(T, p, start, length)};
		}

		/**
		 * @brief Create a view over an entire fat pointer
		 * @param p Fat pointer
		 * @return View covering all elements
		 *
		 * @code{.cpp}
		 * fp::auto_free data = fp::malloc<float>(50);
		 * data.fill(3.14f);
		 *
		 * // Create view of entire array
		 * fp::view<float> full = fp::view<float>::make_full(data.data());
		 * assert(full.size() == 50);
		 *
		 * // View references original data
		 * full[0] = 2.71f;
		 * assert(data[0] == 2.71f);
		 * @endcode
		 */
		static view make_full(T* p) {
			assert(is_fp(p));
			return {fp_view_make_full(T, p)};
		}

		/**
		 * @brief Create a view using start and end indices
		 * @param p Fat pointer
		 * @param start Starting index (inclusive)
		 * @param end Ending index (inclusive)
		 * @return View over the range [start, end]
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 *
		 * // View elements 20 through 30 (inclusive) - 11 elements total
		 * fp::view<int> v = fp::view<int>::make_start_end(arr.data(), 20, 30);
		 * assert(v.size() == 11);
		 *
		 * v.fill(42);
		 * assert(arr[20] == 42);
		 * assert(arr[30] == 42);
		 * @endcode
		 */
		static view make_start_end(T* p, size_t start, size_t end) {
			assert(start < end);
			assert(fp_size(p) >= end);
			return {fp_view_make_start_end(T, p, start, end)};
		}

		/**
		 * @brief Create a view from a single variable
		 * @param var Variable to view
		 * @return View with size 1
		 *
		 * @code{.cpp}
		 * int x = 42;
		 * fp::view<int> v = fp::view<int>::from_variable(x);
		 *
		 * assert(v.size() == 1);
		 * assert(v[0] == 42);
		 *
		 * v[0] = 99;
		 * assert(x == 99);  // Variable modified through view
		 *
		 * // Useful for generic functions
		 * template<typename T>
		 * void process_view(fp::view<T> data) {
		 *     for(auto& val : data) val *= 2;
		 * }
		 *
		 * int single = 10;
		 * process_view(fp::view<int>::from_variable(single));
		 * assert(single == 20);
		 * @endcode
		 */
		static view from_variable(T& var) { return {&var, 1}; }

		///@{
		/**
		 * @brief Get pointer to the data
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(10);
		 * fp::view<int> v = arr.view_full();
		 *
		 * int* ptr = v.data();
		 * ptr[0] = 42;  // Direct pointer access
		 *
		 * // Pass to C functions
		 * qsort(v.data(), v.size(), sizeof(int), compare_func);
		 * @endcode
		 */
		inline T* data() { return fp_view_data(T, view_()); }

		// @brief Get pointer to the data (const version)
		inline const T* data() const { return fp_view_data(T, view_()); }
		///@}

		/**
		 * @brief Get the number of elements in the view
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 * fp::view<int> v1 = arr.view(0, 50);
		 * fp::view<int> v2 = arr.view(50, 50);
		 *
		 * assert(v1.length() == 50);
		 * assert(v2.length() == 50);
		 * assert(v1.length() + v2.length() == arr.size());
		 * @endcode
		 */
		inline size_t length() const { return fp_view_length(view_()); }

		/// @brief Get the number of elements in the view (alias for length)
		inline size_t size() const { return fp_view_size(view_()); }

		/**
		 * @brief Check if the view is empty
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(10);
		 *
		 * fp::view<int> full = arr.view_full();
		 * assert(!full.empty());
		 *
		 * fp::view<int> empty = arr.view(5, 0);
		 * assert(empty.empty());
		 *
		 * if(!full.empty())
		 *     full[0] = 42;  // Safe to access
		 * @endcode
		 */
		inline bool empty() const { return size() == 0; }

		/**
		 * @brief Create a subview with specified start and length
		 * @param start Starting index
		 * @param length Number of elements
		 * @return Subview of this view
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 * fp::view<int> v = arr.view_full();
		 *
		 * // Create subview of elements 10-29
		 * fp::view<int> sub = v.subview(10, 20);
		 * assert(sub.size() == 20);
		 *
		 * // Subviews can be chained
		 * fp::view<int> subsub = sub.subview(5, 10);
		 * assert(subsub.size() == 10);
		 *
		 * // All views reference the same data
		 * subsub[0] = 999;
		 * assert(arr[15] == 999);  // 10 + 5 = index 15 in original
		 * @endcode
		 */
		inline view subview(size_t start, size_t length) {
			assert(start + length <= size());
			return {fp_view_subview(T, view_(), start, length)};
		}

		/**
		 * @brief Create a subview with maximum available length
		 * @param start Starting index
		 * @param length Maximum number of elements (clamped to available size)
		 * @return Subview of this view
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 * fp::view<int> v = arr.view_full();
		 *
		 * // Request 30 elements starting at index 80
		 * // Only 20 available, so view will have 20 elements
		 * fp::view<int> clamped = v.subview_max_size(80, 30);
		 * assert(clamped.size() == 20);  // Clamped to available size
		 *
		 * // Useful when you don't know exact bounds
		 * for(size_t i = 0; i < v.size(); i += 25) {
		 *     fp::view<int> chunk = v.subview_max_size(i, 25);
		 *     process_chunk(chunk);  // Always valid, size may vary
		 * }
		 * @endcode
		 */
		inline view subview_max_size(size_t start, size_t length) { return subview(start, std::min(size() - start, length)); }

		/**
		 * @brief Create a subview from start to end of view
		 * @param start Starting index
		 * @return Subview from start to end
		 *
		 * @code{.cpp}
		 * fp::pointer<int> arr = fp::malloc<int>(100);
		 * fp::view<int> v = arr.view_full();
		 *
		 * // Get everything from index 50 to end
		 * fp::view<int> tail = v.subview(50);
		 * assert(tail.size() == 50);
		 *
		 * // Useful for skipping a header
		 * struct Header { int magic; size_t count; };
		 * fp::pointer<char> buffer = fp::malloc<char>(1024);
		 * fp::view<char> v_buf = buffer.view_full();
		 *
		 * // Skip header and get remaining data
		 * fp::view<char> data = v_buf.subview(sizeof(Header));
		 *
		 * buffer.free();
		 * arr.free();
		 * @endcode
		 */
		inline view subview(size_t start) { return subview(start, size() - start); }

		/**
		 * @brief Create a subview using start and end indices
		 * @param start Starting index (inclusive)
		 * @param end Ending index (inclusive)
		 * @return Subview over the range [start, end]
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 * fp::view<int> v = arr.view_full();
		 *
		 * // Elements 20 through 30 (inclusive) - 11 elements
		 * fp::view<int> sub = v.subview_start_end(20, 30);
		 * assert(sub.size() == 11);
		 *
		 * // Split view into thirds
		 * size_t third = v.size() / 3;
		 * fp::view<int> first = v.subview_start_end(0, third - 1);
		 * fp::view<int> second = v.subview_start_end(third, 2 * third - 1);
		 * fp::view<int> third_part = v.subview_start_end(2 * third, v.size() - 1);
		 * @endcode
		 */
		inline view subview_start_end(size_t start, size_t end) {
			assert(start <= end);
			assert(end <= size());
			return {fp_view_subview_start_end(T, view_(), start, end)};
		}

		/// @brief Create a subview (const version)
		inline view<T> subview(size_t start, size_t length) const {
			assert(start + length <= size());
			return {fp_view_subview(T, view_(), start, length)};
		}

		/// @brief Create a subview with max size (const version)
		inline view<T> subview_max_size(size_t start, size_t length) const { return subview(start, std::min(size() - start, length)); }

		/// @brief Create a subview from start to end (const version)
		inline view<T> subview(size_t start) const { return subview(start, size() - start); }

		/// @brief Create a subview with start/end indices (const version)
		inline view<T> subview_start_end(size_t start, size_t end) const {
			assert(start <= end);
			assert(end <= size());
			return {fp_view_subview_start_end(T, view_(), start, end)};
		}

		///@{
		/**
		 * @brief Create a byte view of this view's memory
		 * @return View of the underlying bytes
		 *
		 * @code{.cpp}
		 * struct Point { int x, y; };
		 * fp::auto_free points = fp::malloc<Point>(10);
		 * fp::view<Point> v = points.view_full();
		 *
		 * // Access raw bytes
		 * fp::view<std::byte> bytes = v.byte_view();
		 * assert(bytes.size() == 10 * sizeof(Point));
		 *
		 * // Useful for serialization
		 * void write_binary(fp::view<std::byte> data) {
		 *     fwrite(data.data(), 1, data.size(), file);
		 * }
		 *
		 * write_binary(v.byte_view());
		 * @endcode
		 */
		inline view<std::byte> byte_view() { return {(std::byte*)data(), size() * sizeof(T)}; }

		// @brief Create a byte view (const version)
		inline view<const std::byte> byte_view() const { return {(const std::byte*)data(), size() * sizeof(T)}; }
		///@}

		/**
		 * @brief Get iterator to beginning
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(10);
		 * fp::view<int> v = arr.view_full();
		 *
		 * // Manual iteration
		 * for(int* it = v.begin(); it != v.end(); ++it)
		 *     *it = 42;
		 *
		 * // Use with STL algorithms
		 * std::sort(v.begin(), v.end());
		 * std::reverse(v.begin(), v.end());
		 * @endcode
		 */
		inline T* begin() { return fp_view_begin(T, view_()); }

		/**
		 * @brief Get iterator to end
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 * fp::view<int> v = arr.view_full();
		 *
		 * // Find first element > 50
		 * auto it = std::find_if(v.begin(), v.end(),
		 *                        [](int x) { return x > 50; });
		 *
		 * if(it != v.end())
		 *     std::cout << "Found: " << *it << "\n";
		 * @endcode
		 */
		inline T* end() { return fp_view_end(T, view_()); } // TODO: Fails on MSVC?

		/**
		 * @brief Compare this view with another
		 * @param other View to compare with
		 * @return Comparison result (negative, 0, or positive)
		 *
		 * @code{.cpp}
		 * fp::auto_free arr1 = fp::malloc<int>(5);
		 * fp::auto_free arr2 = fp::malloc<int>(5);
		 * arr1.fill(1);
		 * arr2.fill(2);
		 *
		 * fp::view<int> v1 = arr1.view_full();
		 * fp::view<int> v2 = arr2.view_full();
		 *
		 * auto result = v1.compare(v2);
		 * if(result < 0) std::cout << "v1 < v2\n";
		 * else if(result > 0) std::cout << "v1 > v2\n";
		 * else std::cout << "v1 == v2\n";
		 * @endcode
		 */
		size_t compare(const view other) const { return fp_view_compare(view_(), other); }

		/**
		 * @brief Three-way comparison operator
		 * @param o View to compare with
		 * @return std::strong_ordering result
		 *
		 * @code{.cpp}
		 * fp::auto_free arr1 = fp::malloc<int>(5);
		 * fp::auto_free arr2 = fp::malloc<int>(5);
		 * arr1.fill(10);
		 * arr2.fill(20);
		 *
		 * fp::view<int> v1 = arr1.view_full();
		 * fp::view<int> v2 = arr2.view_full();
		 *
		 * if(v1 < v2) std::cout << "v1 is less\n";
		 * if(v1 <= v2) std::cout << "v1 is less or equal\n";
		 * if(v1 > v2) std::cout << "v1 is greater\n";
		 * @endcode
		 */
		std::strong_ordering operator<=>(const view o) const {
			auto res = compare(o);
			if(res < 0) return std::strong_ordering::less;
			if(res > 0) return std::strong_ordering::greater;
			return std::strong_ordering::equal;
		}

		/**
		 * @brief Equality comparison
		 * @param o View to compare with
		 * @return true if views are equal
		 *
		 * @code{.cpp}
		 * fp::auto_free arr1 = fp::malloc<int>(5);
		 * fp::auto_free arr2 = fp::malloc<int>(5);
		 * arr1.fill(42);
		 * arr2.fill(42);
		 *
		 * fp::view<int> v1 = arr1.view_full();
		 * fp::view<int> v2 = arr2.view_full();
		 *
		 * if(v1 == v2)
		 *     std::cout << "Views contain identical data\n";
		 * @endcode
		 */
		bool operator==(const view o) const { return this->operator<=>(o) == std::strong_ordering::equal; }

#ifdef FP_ENABLE_STD_RANGES
		/**
		 * @brief Get a std::ranges::subrange over this view
		 * @return std::ranges::subrange
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 * fp::view<int> v = arr.view_full();
		 *
		 * // Use with range algorithms
		 * auto r = v.range();
		 * auto filtered = r | std::views::filter([](int x) { return x % 2 == 0; });
		 * auto transformed = filtered | std::views::transform([](int x) { return x * 2; });
		 *
		 * for(int val : transformed)
		 *     std::cout << val << " ";
		 * @endcode
		 */
		inline auto range() { return std::ranges::subrange(begin(), end()); }
#endif

#if defined(__cpp_lib_span) && __cpp_lib_span >= 202002L
		/**
		 * @brief Construct from std::span
		 * @param span std::span to create view from
		 *
		 * @code{.cpp}
		 * std::vector<int> vec = {1, 2, 3, 4, 5};
		 * std::span<int> s{vec};
		 *
		 * fp::view<int> v(s);
		 * assert(v.size() == 5);
		 *
		 * // Modify through view
		 * v[0] = 999;
		 * assert(vec[0] == 999);
		 * @endcode
		 */
		view(const std::span<T> span) : fp_view(T)(span.data(), span.size()) {}

		/**
		 * @brief Convert to std::span
		 * @return std::span over this view's data
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(50);
		 * fp::view<int> v = arr.view_full();
		 *
		 * // Convert to span for STL interop
		 * std::span<int> s = v.span();
		 *
		 * // Use with span operations
		 * auto first_half = s.first(25);
		 * auto last_half = s.last(25);
		 * @endcode
		 */
		inline std::span<T> span() { return {data(), size()}; }

		/**
		 * @brief Implicit conversion to std::span
		 *
		 * @code{.cpp}
		 * void process_span(std::span<int> data) {
		 *     for(auto& val : data) val = 2;
		 * }
		 *
		 * fp::auto_free arr = fp::malloc<int>(10);
		 * fp::view<int> v = arr.view_full();
		 *
		 * process_span(v);  // Implicit conversion
		 * @endcode
		 */
		inline operator std::span<T>() { return span(); }
#endif

		///@{
		/**
		 * @brief Dereference operator - access first element
		 * @return Reference to first element
		 */
		inline T& operator*() {
			assert(!empty());
			return *data();
		}

		// @brief Dereference operator (const version)
		inline const T& operator*() const {
			assert(!empty());
			return *data();
		}
		///@}

		///@{
		/**
		 * @brief Arrow operator - access first element's members
		 * @return Pointer to first element
		 */
		inline T* operator->() {
			assert(!empty());
			return data();
		}

		// @brief Arrow operator (const version)
		inline const T* operator->() const {
			assert(!empty());
			return data();
		}
		///@}

		///@{
		/**
		 * @brief Subscript operator - access element by index
		 * @param i Index
		 * @return Reference to element at index
		 */
		inline T& operator[](size_t i) {
			assert(!empty());
			assert(i < size());
			return data()[i];
		}

		// @brief Subscript operator (const version)
		inline const T& operator[](size_t i) const {
			assert(!empty());
			assert(i < size());
			return data()[i];
		}
		///@}

	protected:
		/// @brief Get underlying C-style view
		inline fp_view(T) view_() { return *this; }

		/// @brief Get underlying C-style view (const version)
		inline const fp_view(T) view_() const { return *this; }

		/// @brief Get as void view
		inline fp_void_view void_view() { return *(fp_void_view*)this; }

		/// @brief Get as void view (const version)
		inline const fp_void_view void_view() const { return *(fp_void_view*)this; }
	};




	/**
	 * @brief CRTP base providing common fat pointer operations
	 * @tparam T Element type
	 * @tparam Derived The derived class (CRTP pattern)
	 *
	 * This class uses the Curiously Recurring Template Pattern (CRTP) to provide
	 * common fat pointer operations to derived classes. It expects the derived
	 * class to provide a ptr() method that returns a reference to the underlying
	 * fat pointer.
	 *
	 * @code{.cpp}
	 * template<typename T>
	 * struct my_pointer : public pointer_crtp<T, my_pointer<T>> {
	 *     T* raw_ptr;
	 * protected:
	 *     T*& ptr() { return raw_ptr; }
	 *     const T* const& ptr() const { return raw_ptr; }
	 * };
	 *
	 * // Now my_pointer has all fat pointer operations
	 * my_pointer<int> p;
	 * p.raw_ptr = fp_malloc(int, 10);
	 * assert(p.size() == 10);
	 * p.fill(42);
	 * fp_free(p.data());
	 * @endcode
	 */
	template<typename T, typename Derived>
	struct pointer_crtp {
		using view_t = fp::view<T>; ///< View type for this pointer

		///@{
		/**
		 * @brief Get raw pointer to data
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(10);
		 * int* raw = arr.data();
		 *
		 * // Use with C functions
		 * memset(raw, 0, arr.size() * sizeof(int));
		 *
		 * // Pass to C APIs
		 * qsort(arr.data(), arr.size(), sizeof(int), compare_func);
		 * @endcode
		 */
		inline T* data() { return ptr(); }

		// @brief Get raw pointer to data (const version)
		inline const T* data() const { return ptr(); }
		///@}

		///@{
		/**
		 * @brief Explicit conversion to raw pointer
		 *
		 * Requires explicit cast to prevent accidental implicit conversions.
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(10);
		 *
		 * // Explicit cast required
		 * int* ptr = (int*)arr;
		 *
		 * // Won't compile (good!):
		 * // int* ptr2 = arr;
		 * @endcode
		 */
		explicit inline operator T*() { return ptr(); }

		// @brief Explicit conversion to raw pointer (const version)
		explicit inline operator const T*() const { return ptr(); }
		///@}

		/**
		 * @brief Release ownership of the pointer
		 * @return The raw pointer (ownership transferred to caller)
		 *
		 * After calling release(), the pointer object no longer owns the memory.
		 * The caller becomes responsible for freeing it.
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(10).fill(42);
		 *
		 * // Transfer ownership
		 * int* raw = arr.release();
		 * assert(arr.data() == nullptr);
		 *
		 * // Now we must manually free
		 * fp_free(raw);
		 * @endcode
		 */
		T* release() { return std::exchange(ptr(), nullptr); }

		/**
		 * @brief Check if this is a valid fat pointer
		 *
		 * @code{.cpp}
		 * int regular[10];
		 * fp::auto_free arr = fp::malloc<int>(10);
		 * fp::pointer<int> null_ptr;
		 *
		 * assert(arr.is_fp());
		 * assert(!null_ptr.is_fp());
		 * @endcode
		 */
		inline bool is_fp() const { return ::is_fp(ptr()); }

		/**
		 * @brief Check if this is stack-allocated
		 *
		 * @code{.cpp}
		 * fp::array<int, 10> stack_arr;
		 * fp::auto_free heap_arr = fp::malloc<int>(10);
		 *
		 * assert(stack_arr.stack_allocated());
		 * assert(!heap_arr.stack_allocated());
		 * @endcode
		 */
		inline bool stack_allocated() const { return fp_is_stack_allocated(ptr()); }

		/**
		 * @brief Check if this is heap-allocated
		 *
		 * @code{.cpp}
		 * fp::array<int, 10> stack_arr;
		 * fp::auto_free heap_arr = fp::malloc<int>(10);
		 *
		 * assert(!stack_arr.heap_allocated());
		 * assert(heap_arr.heap_allocated());
		 * @endcode
		 */
		inline bool heap_allocated() const { return fp_is_heap_allocated(ptr()); }

		/**
		 * @brief Check if pointer is non-null
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(10);
		 * fp::pointer<int> null_ptr;
		 *
		 * if(arr)
		 *     std::cout << "Array is valid\n";
		 *
		 * if(!null_ptr)
		 *     std::cout << "Null pointer\n";
		 *
		 * // Safe access pattern
		 * if(arr && arr.size() > 0)
		 *     arr[0] = 42;
		 * @endcode
		 */
		inline operator bool() const { return data() != nullptr; }

		///@{
		/**
		 * @brief Get the number of elements
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(50);
		 *
		 * std::cout << "Array has " << arr.length() << " elements\n";
		 *
		 * // Use in loops
		 * for(size_t i = 0; i < arr.length(); i++)
		 *     arr[i] = i;
		 * @endcode
		 */
		inline size_t length() const { return fp_length(ptr()); }

		// @brief Get the number of elements (alias for length)
		inline size_t size() const { return fp_size(ptr()); }
		///@}

		/**
		 * @brief Check if the pointer is empty
		 *
		 * @code{.cpp}
		 * fp::auto_free arr1 = fp::malloc<int>(10);
		 * fp::auto_free arr2 = fp::malloc<int>(0);
		 *
		 * assert(!arr1.empty());
		 * assert(arr2.empty());
		 *
		 * // Safe access pattern
		 * if(!arr1.empty())
		 *     arr1[0] = 42;
		 * @endcode
		 */
		inline bool empty() const { return fp_empty(ptr()); }

		/**
		 * @brief Create a view of a portion of this pointer
		 * @param start Starting index
		 * @param length Number of elements
		 * @return View over the specified range
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 *
		 * // View elements 20-39
		 * auto v = arr.view(20, 20);
		 * v.fill(999);
		 *
		 * assert(arr[20] == 999);
		 * assert(arr[39] == 999);
		 * assert(arr[19] != 999);  // Outside view
		 *
		 * // Process data in chunks
		 * for(size_t i = 0; i < arr.size(); i += 10) {
		 *     auto chunk = arr.view(i, 10);
		 *     process_chunk(chunk);
		 * }
		 * @endcode
		 */
		inline view_t view(size_t start, size_t length) { return view_t::make(ptr(), start, length); }

		/**
		 * @brief Create a view of the entire pointer
		 * @return View over all elements
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(50);
		 *
		 * // Create full view
		 * auto v = arr.view_full();
		 * assert(v.size() == arr.size());
		 *
		 * // Useful for passing to functions expecting views
		 * void process_view(fp::view<int> data) {
		 *     for(auto& val : data) val *= 2;
		 * }
		 *
		 * process_view(arr.view_full());
		 * @endcode
		 */
		inline view_t view_full() { return view_t::make_full(ptr()); }

		/**
		 * @brief Alias for view_full
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(50);
		 *
		 * // Both are equivalent
		 * auto v1 = arr.view_full();
		 * auto v2 = arr.full_view();
		 *
		 * assert(v1.size() == v2.size());
		 * @endcode
		 */
		inline view_t full_view() { return view_t::make_full(ptr()); }

		/**
		 * @brief Create a view using start and end indices
		 * @param start Starting index (inclusive)
		 * @param end Ending index (inclusive)
		 * @return View over the range [start, end]
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 *
		 * // View elements 10 through 20 (inclusive) - 11 elements
		 * auto v = arr.view_start_end(10, 20);
		 * assert(v.size() == 11);
		 *
		 * // Process quarters
		 * size_t quarter = arr.size() / 4;
		 * auto q1 = arr.view_start_end(0, quarter - 1);
		 * auto q2 = arr.view_start_end(quarter, 2 * quarter - 1);
		 * auto q3 = arr.view_start_end(2 * quarter, 3 * quarter - 1);
		 * auto q4 = arr.view_start_end(3 * quarter, arr.size() - 1);
		 * @endcode
		 */
		inline view_t view_start_end(size_t start, size_t end) { return view_t::make_start_end(ptr(), start, end); }

		/// @brief Create a view (const version)
		inline const view_t view(size_t start, size_t length) const { return view_t::make((T*)ptr(), start, length); }

		/// @brief Create a full view (const version)
		inline const view_t view_full() const { return view_t::make_full((T*)ptr()); }

		/// @brief Alias for view_full (const version)
		inline const view_t full_view() const { return view_t::make_full((T*)ptr()); }

		/// @brief Create a view with start/end indices (const version)
		inline const view_t view_start_end(size_t start, size_t end) const { return view_t::make_start_end((T*)ptr(), start, end); }

		/**
		 * @brief Get reference to first element
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(10).fill(5);
		 *
		 * arr.front() = 100;
		 * assert(arr[0] == 100);
		 *
		 * // Useful for algorithms
		 * int first = arr.front();
		 * int last = arr.back();
		 * @endcode
		 */
		inline T& front() { return *fp_front(ptr()); }

		/**
		 * @brief Get reference to last element
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(10);
		 * arr.fill(5);
		 *
		 * arr.back() = 999;
		 * assert(arr[arr.size() - 1] == 999);
		 *
		 * // Access both ends
		 * if(!arr.empty()) {
		 *     arr.front() = 1;
		 *     arr.back() = 100;
		 * }
		 * @endcode
		 */
		inline T& back() { return *fp_back(ptr()); }

		///@{
		/**
		 * @brief Get iterator to beginning
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(50);
		 *
		 * // Manual iteration
		 * for(int* it = arr.begin(); it != arr.end(); ++it)
		 *     *it = 42;
		 *
		 * // Use with STL algorithms
		 * std::iota(arr.begin(), arr.end(), 0);
		 * std::sort(arr.begin(), arr.end());
		 * std::reverse(arr.begin(), arr.end());
		 *
		 * // Distance
		 * size_t count = std::distance(arr.begin(), arr.end());
		 * assert(count == arr.size());
		 * @endcode
		 */
		inline T* begin() { return fp_begin(ptr()); }

		// @brief Get iterator to beginning (const version)
		inline const T* begin() const { return fp_begin(ptr()); }
		///@}

		///@{
		/**
		 * @brief Get iterator to end
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 * arr.fill(1);
		 *
		 * // Range-based for loop
		 * for(int& val : arr)
		 *     val *= 2;
		 *
		 * // Find operations
		 * auto it = std::find(arr.begin(), arr.end(), 42);
		 * if(it != arr.end())
		 *     std::cout << "Found at index: " << (it - arr.begin()) << "\n";
		 *
		 * // Accumulate
		 * int sum = std::accumulate(arr.begin(), arr.end(), 0);
		 * @endcode
		 */
		inline T* end() { return fp_end(ptr()); }

		// @brief Get iterator to end (const version)
		inline const T* end() const { return fp_end((T*)ptr()); }
		///@}

#ifdef FP_ENABLE_STD_RANGES
		/**
		 * @brief Get a std::ranges::subrange over this pointer
		 * @return std::ranges::subrange
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 * std::iota(arr.begin(), arr.end(), 1);
		 *
		 * // Use with range algorithms
		 * auto r = arr.range();
		 *
		 * // Filter and transform
		 * auto evens = r | std::views::filter([](int x) { return x % 2 == 0; });
		 * auto doubled = evens | std::views::transform([](int x) { return x * 2; });
		 *
		 * for(int val : doubled)
		 *     std::cout << val << " ";
		 *
		 * // Take first 10 elements
		 * for(int val : r | std::views::take(10))
		 *     std::cout << val << " ";
		 * @endcode
		 */
		inline auto range() { return std::ranges::subrange(begin(), end()); }
#endif

#if defined(__cpp_lib_span) && __cpp_lib_span >= 202002L
		/**
		 * @brief Convert to std::span
		 * @return std::span over this pointer's data
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 *
		 * // Convert to span
		 * std::span<int> s = arr.span();
		 *
		 * // Use span operations
		 * auto first_half = s.first(50);
		 * auto last_half = s.last(50);
		 *
		 * // Subspan
		 * auto middle = s.subspan(25, 50);
		 *
		 * // Pass to functions expecting span
		 * void process(std::span<int> data) {
		 *     for(auto& val : data) val = 2;
		 * }
		 * process(arr.span());
		 * @endcode
		 */
		inline std::span<T> span() { return {data(), size()}; }
#endif

		/**
		 * @brief Fill all elements with a value
		 * @param value Value to fill with (default-constructed if not provided)
		 * @return Reference to derived class for chaining
		 *
		 * @code{.cpp}
		 * fp::auto_free arr = fp::malloc<int>(100);
		 *
		 * // Fill with specific value
		 * arr.fill(42);
		 * assert(arr[0] == 42);
		 * assert(arr[99] == 42);
		 *
		 * // Fill with default value (0 for int)
		 * arr.fill();
		 * assert(arr[0] == 0);
		 *
		 * // Method chaining
		 * fp::auto_free data = fp::malloc<float>(50).fill(3.14f);
		 *
		 * // Fill with custom types
		 * struct Point { int x = 0, y = 0; };
		 * fp::auto_free points = fp::malloc<Point>(10);
		 * points.fill(Point{5, 10});
		 * @endcode
		 */
		inline Derived& fill(const T& value = {}) {
			std::fill(begin(), end(), value);
			return *(Derived*)this;
		}

		///@{
		/**
		 * @brief Dereference operator - access first element
		 * @return Reference to first element
		 */
		inline T& operator*() {
			assert(!empty());
			return *data();
		}

		// @brief Dereference operator (const version)
		inline const T& operator*() const {
			assert(!empty());
			return *data();
		}
		///@}

		///@{
		/**
		 * @brief Arrow operator - access first element's members
		 * @return Pointer to first element
		 */
		inline T* operator->() {
			assert(!empty());
			return data();
		}

		// @brief Arrow operator (const version)
		inline const T* operator->() const {
			assert(!empty());
			return data();
		}
		///@}

		///@{
		/**
		 * @brief Subscript operator - access element by index
		 * @param i Index
		 * @return Reference to element at index
		 * @note Bounds checked in debug!
		 */
		inline T& operator[](size_t i) {
			assert(!empty());
			assert(i < size());
			return data()[i];
		}

		// @brief Subscript operator (const version)
		inline const T& operator[](size_t i) const {
			assert(!empty());
			assert(i < size());
			return data()[i];
		}
		///@}

	protected:
		/// @brief Get reference to internal pointer (implemented by derived class)
		inline T*& ptr() { return ((Derived*)this)->ptr(); }

		/// @brief Get reference to internal pointer (const version)
		inline const T* const & ptr() const { return (((const Derived*)this)->ptr()); }
	};

	/**
	 * @brief Internal function used to free all elements in a view
	 * @internal
	 */
	template<typename T>
	inline void __destroy(view<T> view) {
		if constexpr (!std::is_trivially_destructible_v<T>)
			for(T& elem: view)
				elem.~T();
	}

/**
 * @brief Helper macro for generating default constructors and assignment operators
 * @param self The class name
 * @param super The parent class name
 *
 * This macro generates boilerplate copy/move constructors and assignment operators
 * that properly delegate to the parent class.
 */
#define FP_HPP_DEFAULT_CONSTRUCTOR_BLOCK(self, super)\
	self(const super& p) : super(p) {}\
	self(super&& p) : super(std::move(p)) {}\
	self& operator=(const super& p) { *this = p; return *this; }\
	self& operator=(super&& p) { *this = std::move(p); return *this; }\
	self(const self& p) = default;\
	self(self&& p) = default;\
	self& operator=(const self& p) = default;\
	self& operator=(self&& p) = default;

	/**
	 * @brief Main fat pointer class (fp::pointer) with manual memory management
	 * @tparam T Element type
	 *
	 * This is the primary fat pointer class that provides manual memory management
	 * with explicit free() calls. For automatic memory management, use fp::raii::pointer or fp::auto_free.
	 *
	 * The pointer class combines the wrapped::pointer base (for raw pointer access)
	 * with pointer_crtp (for fat pointer operations), providing a complete interface
	 * for working with dynamically allocated arrays with bounds checking.
	 *
	 * @code{.cpp}
	 * // Manual memory management
	 * fp::pointer<int> data = fp::malloc<int>(100);
	 * data[0] = 42;
	 * data.realloc(200);  // Resize to 200 elements
	 * data.free();
	 *
	 * // Or use clone for deep copy
	 * fp::auto_free original = fp::malloc<int>(10);
	 * original.fill(5);
	 * fp::pointer<int> copy = original.clone();
	 * copy.free();
	 * original.free(false); // ERROR: Using non-nullifying free on an auto_free type will result in a double free!
	 * @endcode
	 *
	 * @section example_iteration Iteration Examples
	 * @code{.cpp}
	 * fp::auto_free arr = fp::malloc<int>(50);
	 *
	 * // Range-based for loop
	 * for(int& val : arr)
	 *     val = 10;
	 *
	 * // STL algorithms
	 * std::sort(arr.begin(), arr.end());
	 * std::iota(arr.begin(), arr.end(), 0);
	 *
	 * // Manual iteration
	 * for(size_t i = 0; i < arr.size(); i++)
	 *     arr[i] *= 2;
	 * @endcode
	 *
	 * @section example_views_ptr Working with Views
	 * @code{.cpp}
	 * fp::auto_free data = fp::malloc<int>(100);
	 *
	 * // Create view of middle section
	 * auto middle = data.view(25, 50);
	 * for(int& val : middle) {
	 *     val = 999;
	 * }
	 *
	 * // Create multiple views
	 * auto first_half = data.view(0, 50);
	 * auto second_half = data.view(50, 50);
	 * @endcode
	 */
	template<typename T>
	struct pointer: public wrapped::pointer<T>, public pointer_crtp<T, pointer<T>> {
		using super = wrapped::pointer<T>;
		using super::super;
		using super::raw;
		using pointer_crtp<T, pointer<T>>::data;

		FP_HPP_DEFAULT_CONSTRUCTOR_BLOCK(pointer, super);

		/**
		 * @brief Construct from raw fat pointer
		 * @param ptr_ Raw fat pointer (must be null or valid fat pointer)
		 *
		 * @code{.cpp}
		 * // From C-style allocation
		 * int* c_style = fp_malloc(int, 20);
		 * fp::pointer<int> wrapper(c_style);
		 * assert(wrapper.size() == 20);
		 * wrapper.free();
		 * @endcode
		 */
		constexpr pointer(T* ptr_): wrapped::pointer<T>(ptr_) { assert(ptr_ == nullptr || this->is_fp()); }

		/**
		 * @brief Implicit conversion to const pointer
		 *
		 * Allows passing non-const pointers to functions expecting const pointers.
		 *
		 * @code{.cpp}
		 * void print_data(fp::pointer<const int> data) {
		 *     for(size_t i = 0; i < data.size(); i++) {
		 *         std::cout << data[i] << " ";
		 *     }
		 * }
		 *
		 * fp::auto_release arr = fp::malloc<int>(5).fill(42);
		 * print_data(arr);  // Implicit conversion
		 * @endcode
		 */
		inline operator pointer<std::add_const_t<T>>() const { return *(pointer<std::add_const_t<T>>*)this; }

		/**
		 * @brief Free the allocated memory
		 * @param nullify If true, sets the internal pointer to nullptr after freeing (default: true)
		 *
		 * Releases the memory allocated for this fat pointer. By default, the internal
		 * pointer is set to nullptr after freeing to prevent use-after-free bugs.
		 *
		 * This is the preferred method for freeing memory as it provides safety by default.
		 * The pointer object remains valid but will be null after this call.
		 *
		 * @warning After calling free(), any views or references to the data become invalid.
		 * @warning Only call free() on heap-allocated pointers, not stack-allocated ones.
		 *
		 * @code
		 * fp::pointer<int> arr = fp::malloc<int>(20);
		 *
		 * // Default: nullifies after free
		 * arr.free();
		 * assert(arr.data() == nullptr);
		 *
		 * // Explicit: don't nullify (use with caution)
		 * fp::pointer<int> arr2 = fp::malloc<int>(20);
		 * arr2.free(false);
		 * // arr2.data() is now a dangling pointer - DANGEROUS!
		 *
		 * // Better: use default behavior
		 * fp::pointer<int> arr3 = fp::malloc<int>(20);
		 * arr3.free(true);  // Explicit, but default
		 * @endcode
		 *
		 * @section example_raii RAII Alternative
		 * @code
		 * // If you don't want to call free() manually, use RAII
		 * {
		 *     fp::raii::pointer<int> auto_arr = fp::malloc<int>(100);
		 *     // or fp::auto_free auto_arr = ...
		 *     // Use auto_arr...
		 *     // Automatically freed when scope exits
		 * }
		 * @endcode
		 *
		 * @see fp::raii::pointer for automatic memory management
		 */
		inline void free(bool nullify = true) {
			if constexpr (!std::is_trivially_destructible_v<T>)
				__destroy(this->view_full());
			fp_free(raw);
			if(nullify) raw = nullptr;
		}

		/**
		 * @brief Free the allocated memory (const version)
		 *
		 * This overload is provided for const pointers and does not nullify the
		 * internal pointer. Use with extreme caution as the pointer will be left
		 * in a dangling state.
		 *
		 * @warning This version does not nullify the pointer, making it dangerous.
		 *          Prefer the non-const version whenever possible.
		 * @warning The pointer becomes invalid but the const object cannot be modified.
		 *
		 * This overload exists primarily for compatibility with const contexts, but
		 * its use is discouraged. Consider restructuring your code to avoid freeing
		 * through const references.
		 *
		 * @code
		 * // Dangerous usage (avoid if possible)
		 * void unsafe_free(const fp::pointer<int>& arr) {
		 *     arr.free();  // Calls const version
		 *     // arr.data() is now dangling but we can't nullify it
		 * }
		 * @endcode
		 *
		 * @see free(bool) for the safer, non-const version
		 */
		inline void free() const {
			if constexpr (!std::is_trivially_destructible_v<T>)
				__destroy(this->view_full());
			fp_free(raw);
		}

		/**
		 * @brief Reallocate with a new size
		 * @param new_count New number of elements
		 * @return Reference to this pointer (may have new address)
		 *
		 * Existing data is preserved up to the minimum of old and new sizes.
		 * The pointer address may change, but the reference is updated automatically.
		 *
		 * @code{.cpp}
		 * fp::pointer<int> arr = fp::malloc<int>(10);
		 * for(size_t i = 0; i < arr.size(); i++)
		 *     arr[i] = i;
		 *
		 * // Expand to 20 elements (first 10 preserved)
		 * arr.realloc(20);
		 * assert(arr.size() == 20);
		 * assert(arr[5] == 5);  // Old data still there
		 *
		 * // Shrink to 5 elements
		 * arr.realloc(5);
		 * assert(arr.size() == 5);
		 *
		 * arr.free();
		 * @endcode
		 */
		inline pointer& realloc(size_t new_count) { raw = fp_realloc(T, raw, new_count); return *this; }

		/**
		 * @brief Create a copy of this pointer
		 * @return New pointer with copied data (must be freed separately)
		 *
		 * Creates an independent copy of the data. Modifications to the clone
		 * do not affect the original.
		 *
		 * @code{.cpp}
		 * fp::auto_free original = fp::malloc<int>(5).fill(42);
		 *
		 * fp::pointer<int> copy = original.clone();
		 * copy[0] = 99;  // Doesn't affect original
		 *
		 * assert(original[0] == 42);
		 * assert(copy[0] == 99);
		 *
		 * copy.free();
		 * @endcode
		 */
		inline pointer clone() const { return fp_clone(raw); }

		fp::auto_free<pointer> auto_free() { return std::move(*this); }

	protected:
		friend pointer_crtp<T, pointer<T>>;
		inline T*& ptr() { return raw; }
		inline const T* const & ptr() const { return raw; }
	};

	/**
	 * @namespace fp::raii
	 * @brief Namespace for RAII (automatic memory management) pointer types
	 *
	 * Contains RAII wrappers that automatically free memory when objects go out of scope,
	 * providing exception-safe memory management without manual free() calls.
	 */
	namespace raii {
		/**
		 * @brief RAII version of fp::pointer with automatic memory management
		 * @tparam T Element type
		 *
		 * This pointer automatically frees its memory when it goes out of scope.
		 * Ideal for exception-safe code and avoiding manual memory management.
		 * Implements proper move semantics to avoid double-free issues.
		 *
		 * @note This type is simply an alias for fp::auto_free<fp::pointer<T>>
		 *
		 * @code{.cpp}
		 * void process_data() {
		 *     fp::raii::pointer<double> data = fp::malloc<double>(1000);
		 *     // Equivalent to writing fp::auto_free data = ...
		 *
		 *     for(size_t i = 0; i < data.size(); i++)
		 *         data[i] = i * 3.14;
		 *
		 *     if(some_error())
		 *         return;  // Memory automatically freed
		 *
		 *     // Memory automatically freed when function returns
		 * }
		 *
		 * // Move semantics work correctly
		 * fp::raii::pointer<int> create_array() {
		 *     fp::raii::pointer<int> arr = fp::malloc<int>(100).fill(42);
		 *     return arr;  // Moved, not freed
		 * }
		 * @endcode
		 *
		 * @section example_exception Exception Safety
		 * @code{.cpp}
		 * void risky_operation() {
		 *     fp::raii::pointer<int> data = fp::malloc<int>(1000);
		 *
		 *     // Even if this throws, data is automatically cleaned up
		 *     process_data(data);
		 *
		 *     // Even if this throws, data is automatically cleaned up
		 *     write_to_file(data);
		 * }
		 * @endcode
		 *
		 * @section example_containers Using in Containers
		 * @code{.cpp}
		 * std::vector<fp::raii::pointer<int>> arrays;
		 * // Or "equivalently" fp::dynarray<fp::raii::pointer<int>> arrays;
		 *
		 * for(int i = 0; i < 10; i++)
		 *     arrays.push_back(fp::malloc<int>(100));
		 *
		 * // All arrays automatically freed when vector is destroyed
		 * @endcode
		 */
		template<typename T>
		using pointer = auto_free<fp::pointer<T>>;
	}

	/**
	 * @brief Allocate a fat pointer on the heap
	 * @tparam T Element type
	 * @param count Number of elements to allocate (default: 1)
	 * @return New fat pointer with allocated memory
	 *
	 * @see fp_alloc() for a version that dynamically stack allocates.
	 *
	 * @code{.cpp}
	 * // Allocate single element
	 * fp::pointer<int> single = fp::malloc<int>();
	 * *single = 42;
	 *
	 * // Allocate array
	 * fp::pointer<float> arr = fp::malloc<float>(100);
	 * for(size_t i = 0; i < arr.size(); i++)
	 *     arr[i] = i * 1.5f;
	 *
	 * // Allocate for complex types
	 * struct Point { int x, y; };
	 * fp::pointer<Point> points = fp::malloc<Point>(50);
	 * points[0] = {10, 20};
	 *
	 * single.free();
	 * arr.free();
	 * points.free();
	 * @endcode
	 *
	 * @section example_raii_malloc RAII Allocation
	 * @code{.cpp}
	 * // Use with RAII for automatic cleanup
	 * fp::raii::pointer<int> auto_arr = fp::malloc<int>(100);
	 * fp::auto_free same_as_above = fp::malloc<int>(100);
	 * // No need to call free() - automatic cleanup
	 * @endcode
	 */
	template<typename T>
	inline pointer<T> malloc(size_t count = 1) {
		return fp_malloc(T, count);
	}

	/**
	 * @brief Reallocate a fat pointer with a new size
	 * @tparam T Element type
	 * @param ptr Pointer to reallocate
	 * @param new_count New number of elements
	 * @return Reallocated pointer (may have different address)
	 *
	 * This is equivalent to calling ptr.realloc(new_count).
	 *
	 * @code{.cpp}
	 * fp::pointer<int> arr = fp::malloc<int>(10);
	 * arr = fp::realloc(arr, 20);
	 * assert(arr.size() == 20);
	 * arr.free();
	 * @endcode
	 */
	template<typename T>
	inline pointer<T> realloc(pointer<T> ptr, size_t new_count) {
		return ptr.realloc(new_count);
	}

	/**
	 * @brief Free a fat pointer (functional style)
	 * @tparam T Element type
	 * @param ptr Pointer to free (passed by reference)
	 * @param nullify If true, sets the pointer to nullptr after freeing (default: true)
	 *
	 * This is a functional-style interface to free memory, equivalent to calling ptr.free().
	 * The pointer is passed by reference and will be nullified by default, preventing
	 * use-after-free bugs.
	 *
	 * This function provides a familiar interface for developers used to C-style free(),
	 * while maintaining the safety guarantees of the C++ wrapper.
	 *
	 * @code
	 * // Functional style (like C's free)
	 * fp::pointer<int> arr = fp::malloc<int>(50);
	 * fp::free(arr);  // Equivalent to arr.free()
	 * assert(!arr);   // Pointer is null
	 *
	 * // Member function style
	 * fp::pointer<int> arr2 = fp::malloc<int>(50);
	 * arr2.free();    // Same effect
	 * @endcode
	 *
	 * @see fp::pointer::free() for member function version
	 * @see fp::raii::pointer for automatic memory management
	 */
	template<typename T>
	inline void free(pointer<T>& ptr, bool nullify = true) {
		ptr.free(nullify);
	}

	/**
	 * @brief Free a fat pointer and explicitly set it to null
	 * @tparam T Element type
	 * @param ptr Pointer to free (passed by reference, will be nullified)
	 *
	 * @deprecated This function is redundant since fp::free() nullifies by default.
	 *             Use fp::free(ptr) instead, which has the same behavior.
	 *
	 * This function frees the allocated memory and sets the pointer to nullptr.
	 * It exists for clarity and backwards compatibility, but is functionally
	 * identical to calling fp::free(ptr) with default parameters.
	 *
	 * The explicit name makes the nullification behavior clear in code, which
	 * can improve readability in some contexts.
	 *
	 * @code
	 * fp::pointer<int> arr = fp::malloc<int>(50);
	 * arr.fill(42);
	 *
	 * // These are exactly equivalent:
	 * fp::free_and_null(arr);  // Explicit name
	 * fp::free(arr);           // Default behavior (preferred)
	 *
	 * // Both result in:
	 * assert(arr.data() == nullptr);
	 * assert(!arr);
	 * @endcode
	 *
	 * @see fp::free() for the preferred interface
	 * @see fp::pointer::free() for member function version
	 * @see fp::raii::pointer for automatic memory management
	 */
	template<typename T>
	inline void free_and_null(pointer<T>& ptr) {
		free(ptr, true);
	}

	/**
	 * @brief Free a fat pointer (const version)
	 * @tparam T Element type
	 * @param ptr Const pointer to free
	 *
	 * This is a functional-style interface for freeing through const references.
	 * This overload does not nullify the pointer since the reference is const.
	 *
	 * @warning This version does not nullify the pointer, making it dangerous.
	 *          The pointer becomes invalid but cannot be modified through the const reference.
	 * @warning Strongly prefer the non-const version or RAII pointers.
	 *
	 * This overload exists primarily for compatibility with const contexts and generic
	 * code that may receive const references. However, its use is discouraged as it
	 * leaves the pointer in a dangerous dangling state.
	 *
	 * @code
	 * // Dangerous usage (avoid if possible)
	 * void unsafe_cleanup(const fp::pointer<int>& arr) {
	 *     // Process data
	 *     for(size_t i = 0; i < arr.size(); i++) {
	 *         process(arr[i]);
	 *     }
	 *
	 *     fp::free(arr);  // Calls const version - doesn't nullify
	 *     // arr is now dangling but we can't nullify it
	 * }
	 *
	 * fp::pointer<int> data = fp::malloc<int>(10);
	 * unsafe_cleanup(data);
	 * // data still appears non-null but is invalid - DANGEROUS!
	 * @endcode
	 *
	 * @section example_why_avoid Why to Avoid
	 * @code
	 * void demonstrate_danger() {
	 *     fp::pointer<int> arr = fp::malloc<int>(5);
	 *     arr.fill(42);
	 *
	 *     const fp::pointer<int>& const_ref = arr;
	 *
	 *     fp::free(const_ref);  // Const version called
	 *
	 *     // arr is now invalid but still appears non-null
	 *     if(arr) {  // Returns true - MISLEADING!
	 *         // arr[0] = 99;  // UNDEFINED BEHAVIOR - use after free!
	 *     }
	 * }
	 * @endcode
	 *
	 * @see free(pointer<T>&, bool) for the safer, non-const version
	 * @see fp::pointer::free() for member function version
	 * @see fp::raii::pointer for automatic, safe memory management
	 */
	template<typename T>
	inline void free(const pointer<T>& ptr) {
		ptr.free();
	}

	template<typename T>
	auto view<T>::make_dynamic() {
		return pointer<T>(fp_view_make_dynamic(T, *this));
	}

	/**
	 * @brief Fixed-size array (fp::array) with fat pointer interface
	 * @tparam T Element type
	 * @tparam N Number of elements (compile-time constant)
	 *
	 * This class provides a stack-allocated array with the same interface as
	 * fat pointers. It's useful when you know the size at compile time and
	 * want to avoid heap allocation. The array is automatically destroyed
	 * when it goes out of scope.
	 *
	 * @code{.cpp}
	 * // Create fixed-size array
	 * fp::array<int, 10> arr;
	 *
	 * // Initialize with initializer list
	 * fp::array<float, 5> values = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f};
	 *
	 * // Access elements
	 * arr[0] = 42;
	 * arr.fill(99);
	 *
	 * // Use like any other fat pointer
	 * for(int& val : arr)
	 *     val *= 2;
	 *
	 * // Create views
	 * auto v = arr.view(2, 5);
	 *
	 * // Check properties
	 * assert(arr.size() == 10);
	 * assert(arr.stack_allocated());
	 * assert(!arr.heap_allocated());
	 *
	 * // No need to free - automatically destroyed
	 * @endcode
	 *
	 * @section example_constexpr Compile-Time Usage
	 * @code{.cpp}
	 * constexpr fp::array<int, 5> get_primes() {
	 *     fp::array<int, 5> primes;
	 *     primes[0] = 2;
	 *     primes[1] = 3;
	 *     primes[2] = 5;
	 *     primes[3] = 7;
	 *     primes[4] = 11;
	 *     return primes;
	 * }
	 *
	 * constexpr auto primes = get_primes();
	 * static_assert(primes[2] == 5);
	 * @endcode
	 *
	 * @section example_function_param Using as Function Parameters
	 * @code{.cpp}
	 * template<size_t N>
	 * void process(fp::array<int, N>& arr) {
	 *     for(size_t i = 0; i < arr.size(); i++)
	 *         arr[i] *= 2;
	 * }
	 *
	 * fp::array<int, 10> data;
	 * data.fill(5);
	 * process(data);
	 * assert(data[0] == 10);
	 * @endcode
	 *
	 * @section example_stl STL Integration
	 * @code{.cpp}
	 * fp::array<int, 20> numbers;
	 *
	 * // Use with STL algorithms
	 * std::iota(numbers.begin(), numbers.end(), 1);
	 * std::reverse(numbers.begin(), numbers.end());
	 *
	 * // Convert to span
	 * std::span<int> s = numbers.span();
	 * @endcode
	 *
	 * @section example_aggregate Aggregate Operations
	 * @code{.cpp}
	 * fp::array<double, 100> data;
	 * data.fill(1.0);
	 *
	 * // Use front() and back()
	 * data.front() = 0.0;
	 * data.back() = 100.0;
	 *
	 * // Create subviews
	 * auto first_quarter = data.view(0, 25);
	 * auto last_quarter = data.view(75, 25);
	 *
	 * first_quarter.fill(2.0);
	 * last_quarter.fill(3.0);
	 * @endcode
	 */
	template<typename T, size_t N>
	struct array: public pointer_crtp<T, array<T, N>> {
		/// @brief Default header for stack-allocated arrays
		constexpr static __FatPointerHeaderTruncated __default_header = {
			.magic = FP_STACK_MAGIC_NUMBER,
			.size = N,
		};

		__FatPointerHeaderTruncated __header = __default_header; ///< Fat pointer header with metadata
		T raw[N]; ///< Actual array storage

		/// @brief Default constructor - elements are default-initialized
		constexpr array() = default;

		/// @brief Copy constructor
		constexpr array(const array&) = default;

		/// @brief Move constructor
		constexpr array(array&&) = default;

		/// @brief Copy assignment operator
		constexpr array& operator=(const array&) = default;

		/// @brief Move assignment operator
		constexpr array& operator=(array&&) = default;

		/**
		 * @brief Construct from initializer list
		 * @param init Initializer list of values (must have exactly N elements)
		 *
		 * @code{.cpp}
		 * fp::array<int, 5> arr = {1, 2, 3, 4, 5};
		 * fp::array<fp::raii::string, 3> names = {"Alice", "Bob", "Charlie"};
		 *
		 * // This would fail assertion:
		 * // fp::array<int, 5> bad = {1, 2, 3};  // Only 3 elements!
		 * @endcode
		 */
		constexpr array(std::initializer_list<T> init): __header(__default_header) {
			static_assert(init.size() == __header.size, "Incorrect number of default initializers provided!");
			size_t i = 0;
			for(auto& ini: init)
				raw[i++] = std::move(ini);
		}

		/**
		 * @brief Implicit conversion to const array
		 *
		 * Allows passing non-const arrays to functions expecting const arrays.
		 *
		 * @code{.cpp}
		 * void print_array(const fp::array<const int, 5>& arr) {
		 *     for(const auto& val : arr) {
		 *         std::cout << val << " ";
		 *     }
		 * }
		 *
		 * fp::array<int, 5> data = {1, 2, 3, 4, 5};
		 * print_array(data);  // Implicit conversion
		 * @endcode
		 */
		inline operator array<std::add_const_t<T>, N>() const { return *(array<std::add_const_t<T>, N>*)this; }

	protected:
		friend pointer_crtp<T, array<T, N>>;
		inline T*& ptr() {
			thread_local static auto tmp = &raw[0];
			tmp = &raw[0];
			return tmp;
		}
		inline const T* const & ptr() const { return const_cast<array*>(this)->ptr(); }
	};

}

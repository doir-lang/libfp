# Welcome to LibFP's C++ Documentorial!

```{toctree}
:maxdepth: 2
:caption: Contents:
```

This documentation page is designed less like a direct reference and more like a tutorial.
If you would instead prefer a reference... {doc}`full generated documentation can be found here <doxygen>`.

This is the C++ version of this document {doc}`the C version can be found here <index>`.

## Features

- Automatic bounds tracking for allocated memory
- Stack and heap allocation support
- Views (non-owning references to memory regions)
- Iterator support for range-based operations
- {doc}`C <index>` and {doc}`C++ <cpp>` compatibility

This header provides modern C++ wrappers around the C-style fat pointer library,
including:

- RAII automatic memory management
- Type-safe view classes
- STL-compatible iterators and ranges
- Convenient operator overloads
- Compile-time sized arrays

## Single Header Library

This library can be used standalone from the rest of the library... however certain
functions need `FP_IMPLEMENTATION` defined before the library is included to get definitions.
Be sure to `#define FP_IMPLEMENTATION` in only one source file!


## Basic C++ Usage

```cpp
#include "pointer.hpp"
// Automatic memory management
fp::auto_free numbers = fp::malloc<int>(100);
for(size_t i = 0; i < numbers.size(); i++)
    numbers[i] = i * 2;

// Automatically freed when goes out of scope
// Manual memory management
fp::pointer<float> data = fp::malloc<float>(50);
data.fill(3.14f);
data.free_and_null(); // Preferred over .free()
// Compile-time sized array
fp::array<double, 10> fixed;
fixed[0] = 1.0;
```

```{doxygenstruct} fp::auto_free
:project: fp_doxygen
:path: include/fp/pointer.hpp
```

```{doxygenfunction} fp::malloc
:project: fp_doxygen
:path: include/fp/pointer.hpp
```

```{doxygenstruct} fp::pointer
:project: fp_doxygen
:path: include/fp/pointer.hpp
```

```{doxygenstruct} fp::array
:project: fp_doxygen
:path: include/fp/pointer.hpp
```

## View Usage

```cpp
fp::auto_free arr = fp::malloc<int>(100);
// Create a view of part of the array
fp::view<int> v = arr.view(10, 20);
// Iterate over view
for(int& val : v)
    val = 2;

// Create subviews
auto subv = v.subview(5, 10);
```

```{doxygenstruct} fp::view
:project: fp_doxygen
:path: include/fp/pointer.hpp
```

## STL Integration

```cpp
fp::auto_free data = fp::malloc<int>(50);
// Convert to std::span
std::span<int> s = data.span();
// Use with STL algorithms
std::sort(data.begin(), data.end());
std::fill(data.begin(), data.end(), 42);
// Range-based for loops
for(int& val : data)
    std::cout << val << "\n";
```

## Dynamic Stack Allocation
```cpp
fp::pointer<int> arr = fp_alloca(int, 100);
arr.fill(42);

// Range-based for loops
for(int& val : data)
    std::cout << val << "\n";

// Don't free this pointer our store it in a RAII type!
// arr.free()
```

```{doxygendefine} fp_alloca
:project: fp_doxygen
```

## Indices and Tables

- {ref}`genindex`
<!-- - {ref}`modindex` -->
- {ref}`search`
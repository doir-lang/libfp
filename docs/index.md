# Welcome to LibFP's Documentorial!

```{toctree}
:maxdepth: 2
:caption: Contents:
```

This documentation page is designed less like a direct reference and more like a tutorial.
If you would instead prefer a reference... {doc}`full generated documentation can be found here <doxygen>`.

This is the C version of this document {doc}`the C++ version can be found here <cpp>`.

This library provides "fat pointers" - pointers with embedded size information that enable runtime bounds checking and memory safety. Fat pointers store metadata (size, magic number) in a header just before the actual data, allowing automatic length tracking and validation. All while being fully compliant C pointers.

## Features

- Automatic bounds tracking for allocated memory
- Stack and heap allocation support
- Views (non-owning references to memory regions)
- Iterator support for range-based operations
- {doc}`C <index>` and {doc}`C++ <cpp>` compatibility

## Single Header Library

This library can be used standalone from the rest of the library... however certain
functions need `FP_IMPLEMENTATION` defined before the library is included to get definitions.
Be sure to `#define FP_IMPLEMENTATION` in only one source file!

## Basic Usage Example

```cpp
// Allocate a fat pointer array, notice that the result is a standard pointer and completely
//	compatible with all interfaces expecting a pointer.
int* arr = fp_malloc(int, 20);
// Access with automatic bounds information
for(size_t i = 0; i < fp_length(arr); i++)
    arr[i] = i * 2;

// Reallocate, the one place where C standard library functions won't work is when
//	reallocating or freeing fp memory... use the fp_ versions instead!
arr = fp_realloc(int, arr, 30);
// Clean up... see the note on fp_realloc
fp_free_and_null(arr);
```

```{doxygendefine} fp_malloc
:project: fp_doxygen
```

```{doxygenfunction} fp_length
:project: fp_doxygen
```

```{doxygendefine} fp_realloc
:project: fp_doxygen
```

```{doxygendefine} fp_free_and_null
:project: fp_doxygen
```


## Stack Allocation Example

```cpp
void process_data() {
    // Stack-allocated fat pointer (automatically freed)
    float* temp = fp_alloca(float, 100);
    // Use it like a normal array
    for(size_t i = 0; i < fp_length(temp); i++)
        temp[i] = i * 1.5f;
    // Automatically freed when function returns
}
```

```{doxygendefine} fp_alloca
:project: fp_doxygen
```

## Views Example

```cpp
int* data = fp_malloc(int, 100);
// Create a view of a portion of the data
fp_view(int) subrange = fp_view_make(int, data, 10, 20);
// Iterate over the view
fp_view_iterate_named(int, subrange, item)
    printf("%d\n", *item);

fp_free_and_null(data);
```

```{doxygendefine} fp_view
:project: fp_doxygen
```

```{doxygendefine} fp_view_make
:project: fp_doxygen
```

```{doxygendefine} fp_view_iterate_named
:project: fp_doxygen
```

## Indices and Tables

- {ref}`genindex`
<!-- - {ref}`modindex` -->
- {ref}`search`
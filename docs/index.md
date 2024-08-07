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

## Basic Dynamic Array Example

```cpp
// Create empty dynamic array
fp_dynarray(int) arr = NULL;

// Push elements (automatically grows)
fpda_push_back(arr, 10);
fpda_push_back(arr, 20);
fpda_push_back(arr, 30);

printf("Size: %zu, Capacity: %zu\n", fpda_size(arr), fpda_capacity(arr));

// Access elements
for(size_t i = 0; i < fpda_size(arr); i++)
    printf("%d ", arr[i]);

fpda_free_and_null(arr);
```

```{doxygendefine} fp_dynarray
:project: fp_doxygen
```

```{doxygendefine} fpda_push_back
:project: fp_doxygen
```

```{doxygendefine} fpda_size
:project: fp_doxygen
```

```{doxygendefine} fpda_capacity
:project: fp_doxygen
```

```{doxygendefine} fpda_free_and_null
:project: fp_doxygen
```

## Common Dynamic Array Operations

```cpp
fp_dynarray(int) numbers = NULL;

// Reserve capacity
fpda_reserve(numbers, 100);

// Add elements
for(int i = 0; i < 50; i++)
    fpda_push_back(numbers, i);

// Insert in middle
fpda_insert(numbers, 25, 999);

// Delete element
fpda_delete(numbers, 10);

// Pop from back
fpda_pop_back(numbers);

// Clear all elements (keeps capacity)
fpda_clear(numbers);

fpda_free_and_null(numbers);
```

```{doxygendefine} fpda_reserve
:project: fp_doxygen
```

```{doxygendefine} fpda_insert
:project: fp_doxygen
```

```{doxygendefine} fpda_delete
:project: fp_doxygen
```

```{doxygendefine} fpda_pop_back
:project: fp_doxygen
```

```{doxygendefine} fpda_clear
:project: fp_doxygen
```

## Advanced Dynamic Array Features

```cpp
fp_dynarray(float) data = NULL;

// Grow and initialize
fpda_grow_and_initialize(data, 10, 3.14f);

// Swap elements
fpda_swap(data, 0, 9);

// Clone array
fp_dynarray(float) copy = fpda_clone(data);

// Concatenate arrays
fpda_concatenate_in_place(data, copy);

// Shrink to fit (free excess capacity)
fpda_shrink_to_fit(data);

fpda_free_and_null(data);
fpda_free_and_null(copy);
```

```{doxygendefine} fpda_grow_and_initialize
:project: fp_doxygen
```

```{doxygendefine} fpda_swap
:project: fp_doxygen
```

```{doxygendefine} fpda_clone
:project: fp_doxygen
```

```{doxygendefine} fpda_concatenate_in_place
:project: fp_doxygen
```

```{doxygendefine} fpda_shrink_to_fit
:project: fp_doxygen
```

## Indices and Tables

- {ref}`genindex`
<!-- - {ref}`modindex` -->
- {ref}`search`
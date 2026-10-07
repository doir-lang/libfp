/// A growable array whose elements never move: storage is a table of
/// fixed-size pages, so growing allocates a new page instead of reallocating
/// the old ones. Use it where a pointer into the array must survive further
/// appends, e.g. an arena read through references while more is added to it.
///
/// Unlike `fp.dynarray` this is a plain struct rather than a fat pointer: the
/// elements are not contiguous, so there is no element pointer for a header to
/// sit in front of. The element size is a runtime value so type-erased
/// containers can use it; `get!T` is the typed view.
module fp.pagedarray;

import core.stdc.string;

import fp.pointer : allocFunction;
static import fp.dynarray;

enum size_t defaultPageBytes = 4096;

/// Plain data with no methods; every operation is a free function taking it
/// by `ref`, and `free` is the only one that releases what it owns.
struct PagedArray {
	size_t elementSize = 0;
	private size_t pageShift = 0;
	private size_t count = 0;
	private ubyte** pages = null; // dynarray of page pointers
}


@nogc nothrow: // every declaration below is @nogc nothrow unless stated otherwise


/// Pages hold a power-of-two number of elements, the fewest that fill at
/// least `pageBytes`, so an index splits into page and offset by shift and mask.
PagedArray create(size_t elementSize, size_t pageBytes = defaultPageBytes) {
	assert(elementSize > 0);
	PagedArray self;
	self.elementSize = elementSize;
	while ((size_t(1) << self.pageShift) * elementSize < pageBytes)
		++self.pageShift;
	return self;
}
PagedArray create(T)(size_t pageBytes = defaultPageBytes) {
	return create(T.sizeof, pageBytes);
}

void free(ref PagedArray self) @trusted {
	foreach (i; 0 .. fp.dynarray.length(self.pages))
		allocFunction(self.pages[i], 0);
	fp.dynarray.free(self.pages);
	self.count = 0;
}

size_t length(const ref PagedArray self) { return self.count; }
bool empty(const ref PagedArray self) { return self.count == 0; }
size_t pageElements(const ref PagedArray self) { return size_t(1) << self.pageShift; }

/// Elements storable without allocating another page.
size_t capacity(const ref PagedArray self) @trusted {
	return fp.dynarray.length(cast(ubyte**) self.pages) << self.pageShift;
}

void* get(ref PagedArray self, size_t i) @trusted {
	assert(i < self.count);
	return self.pages[i >> self.pageShift] + (i & (pageElements(self) - 1)) * self.elementSize;
}
const(void)* get(const ref PagedArray self, size_t i) @trusted {
	assert(i < self.count);
	return self.pages[i >> self.pageShift] + (i & (pageElements(self) - 1)) * self.elementSize;
}
ref T get(T)(ref PagedArray self, size_t i) @trusted {
	assert(T.sizeof == self.elementSize);
	return *cast(T*) get(self, i);
}
ref const(T) get(T)(const ref PagedArray self, size_t i) @trusted {
	assert(T.sizeof == self.elementSize);
	return *cast(const(T)*) get(self, i);
}

/// Allocates pages until `n` elements fit. Returns false if the allocator
/// refused; pages obtained before the refusal are kept as capacity.
bool reserve(ref PagedArray self, size_t n) @trusted {
	immutable pageBytes = pageElements(self) * self.elementSize;
	while (capacity(self) < n) {
		ubyte* page = cast(ubyte*) allocFunction(null, pageBytes);
		if (page is null) return false;
		if (!fp.dynarray.pushBack(self.pages, page)) {
			allocFunction(page, 0);
			return false;
		}
	}
	return true;
}

/// Appends `count` uninitialized elements and returns the first, or null
/// (length unchanged) if the allocator refused. The new elements are only
/// contiguous within a page.
void* grow(ref PagedArray self, size_t count = 1) {
	assert(count > 0);
	if (!reserve(self, self.count + count)) return null;
	self.count += count;
	return get(self, self.count - count);
}
T* grow(T)(ref PagedArray self, size_t count = 1) @trusted {
	assert(T.sizeof == self.elementSize);
	return cast(T*) grow(self, count);
}

/// Returns false if the array could not grow, leaving it unchanged.
bool pushBack(T)(ref PagedArray self, T value) @trusted {
	assert(T.sizeof == self.elementSize);
	void* slot = grow(self, 1);
	if (slot is null) return false;
	*cast(T*) slot = value;
	return true;
}

/// Ends the last `count` elements' lifetimes; their pages are kept and reused
/// (`shrinkToFit` releases them).
void popBackCount(ref PagedArray self, size_t count) {
	assert(count <= self.count);
	self.count -= count;
}
void popBack(ref PagedArray self) { popBackCount(self, 1); }

/// Sets the length to 0 without releasing any page (see `shrinkToFit`).
void clear(ref PagedArray self) { self.count = 0; }

/// Frees every page past the one holding the last element, so `capacity`
/// drops to the fewest whole pages `length` needs; after `clear` it frees
/// them all. The elements that remain do not move. The page table shrinks to
/// match where the allocator allows; if it refuses, the table only keeps its
/// spare slots, so this cannot fail.
void shrinkToFit(ref PagedArray self) @trusted {
	immutable needed = (self.count + pageElements(self) - 1) >> self.pageShift;
	immutable have = fp.dynarray.length(self.pages);
	foreach (i; needed .. have)
		allocFunction(self.pages[i], 0);
	if (needed == 0) {
		fp.dynarray.free(self.pages);
		return;
	}
	fp.dynarray.popBackCount(self.pages, have - needed);
	if (fp.dynarray.capacity(self.pages) > needed)
		fp.dynarray.shrinkToFit(self.pages);
}

/// Swaps two elements' bytes. Goes through a small stack buffer, so it never
/// allocates and cannot fail, whatever the element size.
void swap(ref PagedArray self, size_t a, size_t b) @trusted {
	if (a == b) return;
	ubyte* pa = cast(ubyte*) get(self, a);
	ubyte* pb = cast(ubyte*) get(self, b);
	ubyte[64] scratch = void;
	for (size_t left = self.elementSize; left > 0;) {
		immutable n = left < scratch.length ? left : scratch.length;
		core.stdc.string.memcpy(scratch.ptr, pa, n);
		core.stdc.string.memcpy(pa, pb, n);
		core.stdc.string.memcpy(pb, scratch.ptr, n);
		pa += n; pb += n; left -= n;
	}
}


unittest {
	// Page sizing: the fewest power-of-two elements filling `pageBytes`, and at
	// least one element even when a single element is larger than a page.
	auto ints = create(int.sizeof);
	assert(pageElements(ints) == defaultPageBytes / int.sizeof);
	auto bytes = create(1, 100);
	assert(pageElements(bytes) == 128);
	auto huge = create(5000);
	assert(pageElements(huge) == 1);
	free(ints); free(bytes); free(huge);
}

unittest {
	auto arr = create(int.sizeof, 16); // 4 ints per page
	scope(exit) free(arr);
	assert(empty(arr));
	assert(capacity(arr) == 0);

	foreach (i; 0 .. 10)
		assert(pushBack(arr, cast(int) i));
	assert(length(arr) == 10);
	assert(capacity(arr) == 12);
	foreach (i; 0 .. 10)
		assert(get!int(arr, i) == i);

	const(PagedArray)* constArr = &arr;
	assert(get!int(*constArr, 9) == 9);
	assert(*cast(const(int)*) get(*constArr, 3) == 3);
}

unittest {
	// The point of the type: growing never moves an element that exists.
	auto arr = create(int.sizeof, 16);
	scope(exit) free(arr);

	assert(pushBack(arr, 42));
	int* first = &get!int(arr, 0);
	foreach (i; 0 .. 1000)
		assert(pushBack(arr, cast(int) i));
	assert(&get!int(arr, 0) is first);
	assert(*first == 42);
}

unittest {
	// popBack/clear keep their pages, and the next growth reuses them.
	auto arr = create(int.sizeof, 16);
	scope(exit) free(arr);

	int* slot = cast(int*) grow(arr, 6);
	assert(slot is &get!int(arr, 0));
	assert(length(arr) == 6);
	immutable before = capacity(arr);

	popBack(arr);
	assert(length(arr) == 5);
	popBackCount(arr, 2);
	assert(length(arr) == 3);
	clear(arr);
	assert(length(arr) == 0);
	assert(capacity(arr) == before);

	assert(grow(arr, before) !is null);
	assert(capacity(arr) == before);
}

unittest {
	// shrinkToFit frees the pages past the last element, keeps the rest where
	// they were, and leaves the array ready to grow again.
	auto arr = create(int.sizeof, 16); // 4 ints per page
	scope(exit) free(arr);

	foreach (i; 0 .. 20)
		assert(pushBack(arr, cast(int) i));
	int* first = &get!int(arr, 0);
	int* ninth = &get!int(arr, 8);
	shrinkToFit(arr); // already full: nothing to free
	assert(capacity(arr) == 20);

	popBackCount(arr, 11); // 9 left: the third page is partly used
	shrinkToFit(arr);
	assert(capacity(arr) == 12);
	assert(fp.dynarray.capacity(arr.pages) == 3); // the table shrank too
	assert(&get!int(arr, 0) is first && &get!int(arr, 8) is ninth);
	foreach (i; 0 .. 9)
		assert(get!int(arr, i) == i);

	clear(arr);
	shrinkToFit(arr);
	assert(capacity(arr) == 0);
	assert(arr.pages is null);
	shrinkToFit(arr); // and again, with nothing at all

	assert(pushBack(arr, 5));
	assert(get!int(arr, 0) == 5 && capacity(arr) == 4);
}

unittest {
	// A refused table shrink still frees the pages; the table keeps its slots.
	import fp.dynarray : beginRationedAllocator, endRationedAllocator;

	auto arr = create(int.sizeof, 16);
	scope(exit) free(arr);
	assert(grow(arr, 32) !is null);
	popBackCount(arr, 30);
	immutable tableCapacity = fp.dynarray.capacity(arr.pages);

	auto previous = beginRationedAllocator();
	shrinkToFit(arr);
	endRationedAllocator(previous);
	assert(capacity(arr) == 4);
	assert(fp.dynarray.capacity(arr.pages) == tableCapacity);
	assert(length(arr) == 2);
}

unittest {
	// swap across pages, with an element larger than the scratch buffer.
	struct Big { ubyte[200] data; }
	auto arr = create(Big.sizeof, 1); // one element per page
	scope(exit) free(arr);

	Big a, b;
	a.data[] = 1;
	b.data[] = 2;
	assert(pushBack(arr, a));
	assert(pushBack(arr, b));

	swap(arr, 0, 1);
	assert(get!Big(arr, 0).data[199] == 2 && get!Big(arr, 0).data[0] == 2);
	assert(get!Big(arr, 1).data[199] == 1 && get!Big(arr, 1).data[0] == 1);
	swap(arr, 1, 1);
	assert(get!Big(arr, 1).data[0] == 1);
}

unittest {
	// Refused allocations leave the array as it was: first the page itself,
	// then the page table that would record it.
	import fp.dynarray : beginRationedAllocator, endRationedAllocator;

	auto arr = create(int.sizeof, 16);
	scope(exit) free(arr);
	assert(pushBack(arr, 7));

	auto previous = beginRationedAllocator();
	assert(grow(arr, 100) is null);
	endRationedAllocator(previous);
	assert(length(arr) == 1 && get!int(arr, 0) == 7);

	// Fill every page, and the page table's spare capacity, so the next element
	// needs both a new page and a bigger table.
	while (fp.dynarray.length(arr.pages) < fp.dynarray.capacity(arr.pages))
		assert(grow(arr, pageElements(arr)) !is null);
	if (length(arr) < capacity(arr))
		assert(grow(arr, capacity(arr) - length(arr)) !is null);
	immutable filled = length(arr);
	immutable pagesBefore = fp.dynarray.length(arr.pages);
	previous = beginRationedAllocator(1); // the page succeeds, the table does not
	assert(!pushBack(arr, 8));
	endRationedAllocator(previous);
	assert(length(arr) == filled);
	assert(fp.dynarray.length(arr.pages) == pagesBefore); // the orphaned page was released
}

unittest {
	// free() on a never-grown array, and twice.
	PagedArray arr = create(8);
	free(arr);
	free(arr);
	assert(length(arr) == 0);
}

unittest {
	// grow!T hands back the first new element already typed.
	PagedArray arr = create!int(16); // 4 ints per page
	scope(exit) free(arr);
	foreach (i; 0 .. 10)
		assert(pushBack(arr, cast(int) i));

	int* first = &get!int(arr, 0);
	int* slots = grow!int(arr, 3);
	assert(slots is &get!int(arr, 10));
	assert(&get!int(arr, 0) is first);
	slots[0] = 100;
	assert(get!int(arr, 10) == 100);
	assert(length(arr) == 13);
}

unittest {
	// `create!T` sizes pages exactly as `create(T.sizeof)` does.
	PagedArray typed = create!long();
	PagedArray erased = create(long.sizeof);
	scope(exit) { free(typed); free(erased); }
	assert(typed.elementSize == erased.elementSize);
	assert(pageElements(typed) == pageElements(erased));
}

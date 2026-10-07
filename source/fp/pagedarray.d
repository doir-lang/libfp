/// A growable array whose elements never move: storage is a table of fixed-size pages, so growing allocates a new page instead of reallocating the old ones. Use it where a pointer into the array must survive further appends, such as an arena read through references while more is added.
///
/// Unlike `fp.dynarray` this is a plain struct rather than a fat pointer: the elements are not contiguous, so there is no element pointer for a header to sit in front of. The element size is a runtime value so type-erased containers can use it; `PagedArrayOf!T`, which `create!T` returns, is the typed view.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int();
/// scope(exit) free(arr);
/// assert(pushBack(arr, 1));
/// int* first = &arr[0];
/// foreach (i; 0 .. 5000)
/// 	assert(pushBack(arr, i));
/// assert(&arr[0] is first);
/// ---
module fp.pagedarray;

import core.stdc.string;
static import core.checkedint;

static import fp.pointer;
static import fp.dynarray;


/// The page size `create` uses unless told otherwise.
enum size_t defaultPageBytes = 4096;

private enum size_t swapScratchBytes = 64;

/// Plain data with no methods: every operation is a free function taking it by `ref`, and `free` is the only one that releases what it owns. Copying one copies a handle to the same pages, not the elements.
///
/// Examples:
/// ---
/// PagedArray arr = create(8);
/// scope(exit) free(arr);
/// assert(arr.elementSize == 8 && empty(arr));
/// ---
struct PagedArray {
	size_t elementSize = 0; /// Bytes per element.
	private size_t pageShift = 0;
	private size_t count = 0;
	private ubyte** pages = null; // dynarray of page pointers
}


@nogc nothrow:


/// The number of elements.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int();
/// scope(exit) free(arr);
/// assert(pushBack(arr, 1) && pushBack(arr, 2));
/// assert(length(arr) == 2);
/// ---
size_t length(const ref PagedArray self) { return self.count; }
/// Ditto
alias size = length;

/// Whether the array holds no elements.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int();
/// scope(exit) free(arr);
/// assert(empty(arr));
/// assert(pushBack(arr, 1));
/// assert(!empty(arr));
/// ---
bool empty(const ref PagedArray self) { return self.count == 0; }

/// The number of elements storable without allocating another page.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int(16);
/// scope(exit) free(arr);
/// assert(pushBack(arr, 1));
/// assert(capacity(arr) == 4);
/// ---
size_t capacity(const ref PagedArray self) @trusted {
	return fp.dynarray.length(cast(ubyte**) self.pages) << self.pageShift;
}

/// The number of elements each page holds.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int(16);
/// assert(pageElements(arr) == 4);
/// ---
size_t pageElements(const ref PagedArray self) { return size_t(1) << self.pageShift; }


/// A pointer to element `i`, which stays valid until the element is popped or the array is freed or shrunk past it.
///
/// Examples:
/// ---
/// PagedArray arr = create(int.sizeof);
/// scope(exit) free(arr);
/// assert(pushBack(arr, 7));
/// assert(*cast(int*) get(arr, 0) == 7);
/// ---
void* get(ref PagedArray self, size_t i) @trusted {
	assert(i < self.count);
	return self.pages[i >> self.pageShift] + (i & (pageElements(self) - 1)) * self.elementSize;
}
/// Ditto
const(void)* get(const ref PagedArray self, size_t i) @trusted {
	assert(i < self.count);
	return self.pages[i >> self.pageShift] + (i & (pageElements(self) - 1)) * self.elementSize;
}


/// A `PagedArray` of `T`s, as `create!T` returns it: `arr[i]` is element `i` by `ref`, and every function taking a `PagedArray` accepts it.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int();
/// scope(exit) free(arr);
/// assert(pushBack(arr, 7));
/// arr[0] = 8;
/// assert(arr[0] == 8 && length(arr) == 1);
/// ---
struct PagedArrayOf(T) {
	PagedArray base; /// The type-erased array this views.
	alias base this;

	/// Element `i`, which stays where it is until popped or the array is freed or shrunk past it.
	///
	/// Examples:
	/// ---
	/// PagedArrayOf!int arr = create!int();
	/// scope(exit) free(arr);
	/// assert(pushBack(arr, 7));
	/// int* p = &arr[0];
	/// assert(*p == 7);
	/// ---
	ref T opIndex(size_t i) @trusted {
		assert(T.sizeof == base.elementSize);
		return *cast(T*) get(base, i);
	}
	/// Ditto
	ref const(T) opIndex(size_t i) const @trusted {
		assert(T.sizeof == base.elementSize);
		return *cast(const(T)*) get(base, i);
	}
}


/// An empty array of `elementSize`-byte elements, or a `PagedArrayOf!T`. Pages hold a power-of-two number of elements, the fewest that fill at least `pageBytes`, so an index splits into page and offset by shift and mask. Nothing is allocated until the first element is added.
///
/// Examples:
/// ---
/// PagedArray bytes = create(1, 100);
/// assert(pageElements(bytes) == 128);
/// free(bytes);
///
/// PagedArrayOf!int ints = create!int();
/// assert(ints.elementSize == int.sizeof);
/// free(ints);
/// ---
PagedArray create(size_t elementSize, size_t pageBytes = defaultPageBytes) {
	assert(elementSize > 0);
	PagedArray self;
	self.elementSize = elementSize;
	while ((size_t(1) << self.pageShift) * elementSize < pageBytes) {
		assert((size_t(1) << self.pageShift) <= size_t.max / elementSize / 2); // a page's byte size must fit in a size_t
		++self.pageShift;
	}
	return self;
}
/// Ditto
PagedArrayOf!T create(T)(size_t pageBytes = defaultPageBytes) {
	mixin fp.pointer.requireAlignable!T;
	return PagedArrayOf!T(create(T.sizeof, pageBytes));
}

/// Releases every page and empties the array, which stays usable: it can grow again, or be freed again harmlessly.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int();
/// assert(pushBack(arr, 1));
/// free(arr);
/// assert(length(arr) == 0 && capacity(arr) == 0);
/// ---
void free(ref PagedArray self) @trusted {
	foreach (i; 0 .. fp.dynarray.length(self.pages))
		cast(void)fp.pointer.allocFunction(self.pages[i], 0);
	fp.dynarray.free(self.pages);
	self.count = 0;
}


/// Allocates pages until `n` elements fit. Returns false if the allocator refused; pages obtained before the refusal are kept as capacity. The page table grows first, so an `n` too large for any table fails before a page is allocated.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int(16);
/// scope(exit) free(arr);
/// assert(reserve(arr, 10));
/// assert(capacity(arr) == 12 && length(arr) == 0);
/// ---
bool reserve(ref PagedArray self, size_t n) @trusted {
	immutable pageBytes = pageElements(self) * self.elementSize;
	immutable pagesNeeded = (n >> self.pageShift) + ((n & (pageElements(self) - 1)) != 0);
	if (pagesNeeded > fp.dynarray.capacity(self.pages) && fp.dynarray.maybeGrow(self.pages, pagesNeeded, false, false) is null)
		return false;
	while (capacity(self) < n) {
		ubyte* page = cast(ubyte*) fp.pointer.allocFunction(null, pageBytes);
		if (page is null) return false;
		cast(void)fp.dynarray.pushBack(self.pages, page); // the table already has room
	}
	return true;
}

/// Appends `count` uninitialized elements and returns the first, or null (length unchanged) if the allocator refused or the length would overflow. The new elements are only contiguous within a page.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int();
/// scope(exit) free(arr);
/// int* first = grow!int(arr, 3);
/// first[0] = 1;
/// assert(length(arr) == 3 && arr[0] == 1);
/// assert(grow(arr) is &arr[3]);
/// ---
void* grow(ref PagedArray self, size_t count = 1) {
	assert(count > 0);
	// A partly filled last page is already allocated, so elements fitting in its rest skip `reserve` and its page-table read.
	immutable offset = self.count & (pageElements(self) - 1);
	if (offset == 0 || count > pageElements(self) - offset) {
		bool overflow = false;
		immutable newCount = core.checkedint.addu(self.count, count, overflow);
		if (overflow || !reserve(self, newCount)) return null;
	}
	self.count += count;
	return get(self, self.count - count);
}
/// Ditto
T* grow(T)(ref PagedArray self, size_t count = 1) @trusted {
	assert(T.sizeof == self.elementSize);
	return cast(T*) grow(self, count);
}

/// Appends `value`. Returns false if the array could not grow, leaving it unchanged.
///
/// Examples:
/// ---
/// PagedArrayOf!double arr = create!double();
/// scope(exit) free(arr);
/// assert(pushBack(arr, 1.5));
/// assert(arr[0] == 1.5);
/// ---
bool pushBack(T)(ref PagedArray self, T value) @trusted {
	assert(T.sizeof == self.elementSize);
	void* slot = grow(self, 1);
	if (slot is null) return false;
	*cast(T*) slot = value;
	return true;
}


/// Ends the last `count` elements' lifetimes; their pages are kept for reuse (`shrinkToFit` releases them).
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int();
/// scope(exit) free(arr);
/// assert(grow(arr, 5) !is null);
/// popBackCount(arr, 3);
/// assert(length(arr) == 2);
/// ---
void popBackCount(ref PagedArray self, size_t count) {
	assert(count <= self.count);
	self.count -= count;
}

/// Ends the last element's lifetime; its page is kept for reuse.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int();
/// scope(exit) free(arr);
/// assert(pushBack(arr, 1));
/// popBack(arr);
/// assert(empty(arr));
/// ---
void popBack(ref PagedArray self) { popBackCount(self, 1); }

/// Sets the length to 0 without releasing any page (see `shrinkToFit`).
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int(16);
/// scope(exit) free(arr);
/// assert(grow(arr, 5) !is null);
/// clear(arr);
/// assert(empty(arr) && capacity(arr) == 8);
/// ---
void clear(ref PagedArray self) { self.count = 0; }

/// Frees every page past the one holding the last element, so `capacity` drops to the fewest whole pages `length` needs; after `clear` it frees them all. The elements that remain do not move. The page table shrinks to match where the allocator allows; if it refuses, the table only keeps its spare slots, so this cannot fail.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int(16);
/// scope(exit) free(arr);
/// assert(grow(arr, 12) !is null);
/// popBackCount(arr, 10);
/// shrinkToFit(arr);
/// assert(capacity(arr) == 4 && length(arr) == 2);
/// ---
void shrinkToFit(ref PagedArray self) @trusted {
	immutable needed = (self.count + pageElements(self) - 1) >> self.pageShift;
	immutable have = fp.dynarray.length(self.pages);
	foreach (i; needed .. have)
		cast(void)fp.pointer.allocFunction(self.pages[i], 0);
	if (needed == 0) {
		fp.dynarray.free(self.pages);
		return;
	}
	fp.dynarray.popBackCount(self.pages, have - needed);
	if (fp.dynarray.capacity(self.pages) > needed)
		cast(void)fp.dynarray.shrinkToFit(self.pages);
}


/// Swaps two elements' bytes. Goes through a small stack buffer, so it never allocates and cannot fail, whatever the element size.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int();
/// scope(exit) free(arr);
/// assert(pushBack(arr, 1) && pushBack(arr, 2));
/// swap(arr, 0, 1);
/// assert(arr[0] == 2 && arr[1] == 1);
/// ---
void swap(ref PagedArray self, size_t a, size_t b) @trusted {
	if (a == b) return;
	ubyte* pa = cast(ubyte*) get(self, a);
	ubyte* pb = cast(ubyte*) get(self, b);
	ubyte[swapScratchBytes] scratch = void;
	for (size_t left = self.elementSize; left > 0;) {
		immutable n = left < scratch.length ? left : scratch.length;
		core.stdc.string.memcpy(scratch.ptr, pa, n);
		core.stdc.string.memcpy(pa, pb, n);
		core.stdc.string.memcpy(pb, scratch.ptr, n);
		pa += n; pb += n; left -= n;
	}
}


unittest {
	// A single element larger than a page still gets a page of its own.
	PagedArray ints = create(int.sizeof);
	assert(pageElements(ints) == defaultPageBytes / int.sizeof);
	PagedArray bytes = create(1, 100);
	assert(pageElements(bytes) == 128);
	PagedArray huge = create(5000);
	assert(pageElements(huge) == 1);

	PagedArrayOf!long typed = create!long();
	PagedArray erased = create(long.sizeof);
	assert(typed.elementSize == erased.elementSize);
	assert(pageElements(typed) == pageElements(erased));

	static struct Wider { align(2 * fp.pointer.maxAlignment) ubyte b; }
	static assert(!__traits(compiles, create!Wider()));

	free(ints); free(bytes); free(huge); free(typed);
	free(erased);
	free(erased);
	assert(length(erased) == 0);
}

unittest {
	auto arr = create!int(16); // 4 ints per page
	scope(exit) free(arr);
	assert(empty(arr));
	assert(capacity(arr) == 0);

	foreach (i; 0 .. 10)
		assert(pushBack(arr, cast(int) i));
	assert(length(arr) == 10);
	assert(capacity(arr) == 12);
	foreach (i; 0 .. 10)
		assert(arr[i] == i);

	const(PagedArrayOf!int)* constArr = &arr;
	assert((*constArr)[9] == 9);
	assert(*cast(const(int)*) get(*constArr, 3) == 3);

	int* first = &arr[0];
	int* ninth = &arr[8];
	int* slots = grow!int(arr, 3);
	assert(slots is &arr[10]);
	assert(capacity(arr) == 16);
	slots[0] = 100;
	assert(arr[10] == 100);
	assert(cast(int*) grow(arr, 7) is &arr[13]);
	assert(length(arr) == 20);
	assert(&arr[0] is first);

	shrinkToFit(arr);
	assert(capacity(arr) == 20);
	popBack(arr);
	assert(length(arr) == 19);
	popBackCount(arr, 10);
	assert(length(arr) == 9);
	shrinkToFit(arr);
	assert(capacity(arr) == 12);
	assert(fp.dynarray.capacity(arr.pages) == 3);
	assert(&arr[0] is first && &arr[8] is ninth);
	foreach (i; 0 .. 9)
		assert(arr[i] == i);

	clear(arr);
	assert(length(arr) == 0);
	assert(capacity(arr) == 12);
	assert(grow(arr, 12) !is null);
	assert(capacity(arr) == 12);

	clear(arr);
	shrinkToFit(arr);
	assert(capacity(arr) == 0);
	assert(arr.pages is null);
	shrinkToFit(arr);

	assert(pushBack(arr, 5));
	assert(arr[0] == 5 && capacity(arr) == 4);
	first = &arr[0];
	foreach (i; 0 .. 1000)
		assert(pushBack(arr, cast(int) i));
	assert(&arr[0] is first);
	assert(*first == 5);
	foreach (i; 0 .. 1000)
		assert(arr[i + 1] == i);

	// Larger than the scratch buffer, so the swap takes several passes.
	struct Big { ubyte[3 * swapScratchBytes + 8] data; }
	auto bigs = create!Big(1);
	scope(exit) free(bigs);

	Big a, b;
	a.data[] = 1;
	b.data[] = 2;
	assert(pushBack(bigs, a));
	assert(pushBack(bigs, b));

	swap(bigs, 0, 1);
	assert(bigs[0].data[$ - 1] == 2 && bigs[0].data[0] == 2);
	assert(bigs[1].data[$ - 1] == 1 && bigs[1].data[0] == 1);
	swap(bigs, 1, 1);
	assert(bigs[1].data[0] == 1);
}

unittest {
	auto arr = create!int(16);
	scope(exit) free(arr);
	assert(pushBack(arr, 7));

	assert(grow(arr, size_t.max) is null);
	assert(length(arr) == 1);

	auto previous = fp.dynarray.beginRationedAllocator();
	assert(grow(arr, 100) is null);
	assert(length(arr) == 1);
	assert(grow!int(arr, 2) is &arr[1]); // the rest of the first page needs no allocation
	assert(grow(arr, 2) is null);
	fp.dynarray.endRationedAllocator(previous);
	assert(length(arr) == 3 && capacity(arr) == 4 && arr[0] == 7);

	// Fill every page and the page table's spare slots, so the next element needs a new page and a bigger table.
	while (fp.dynarray.length(arr.pages) < fp.dynarray.capacity(arr.pages))
		assert(grow(arr, pageElements(arr)) !is null);
	if (length(arr) < capacity(arr))
		assert(grow(arr, capacity(arr) - length(arr)) !is null);
	immutable filled = length(arr);
	immutable pagesBefore = fp.dynarray.length(arr.pages);
	previous = fp.dynarray.beginRationedAllocator();
	assert(!pushBack(arr, 8)); // refused at the table, before any page is allocated
	fp.dynarray.endRationedAllocator(previous);
	assert(length(arr) == filled);
	assert(fp.dynarray.length(arr.pages) == pagesBefore);

	// The table is sized first, so an impossible reservation fails at once instead of allocating pages until memory runs out.
	assert(!reserve(arr, size_t.max));
	assert(fp.dynarray.length(arr.pages) == pagesBefore);

	popBackCount(arr, filled - 2);
	immutable tableCapacity = fp.dynarray.capacity(arr.pages);
	previous = fp.dynarray.beginRationedAllocator();
	shrinkToFit(arr);
	fp.dynarray.endRationedAllocator(previous);
	assert(capacity(arr) == 4);
	assert(fp.dynarray.capacity(arr.pages) == tableCapacity);
	assert(length(arr) == 2 && arr[0] == 7);
}

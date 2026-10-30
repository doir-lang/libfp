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

static import fp.dynarray;
static import fp.lifecycle;
static import fp.pointer;
version(unittest) static import fp.testing;


/// The page size `create` uses unless told otherwise.
enum size_t defaultPageBytes = 4096;

private enum size_t swapScratchBytes = 64;

/// Plain data with no methods: every operation is a free function, taking the array by `ref` when it changes it and by value when it only reads it. `free` is the only one that releases what it owns. Copying one copies a handle to the same pages, not the elements.
///
/// Element lifetimes are ended by the `finalizeFunction` the array stores, which `create!T` sets from the element type; an array made with `create(elementSize)` has none, so its elements are treated as bytes.
///
/// Examples:
/// ---
/// PagedArray arr = create(8);
/// scope(exit) free(arr);
/// assert(arr.elementSize == 8 && empty(arr));
/// ---
struct PagedArray {
	size_t elementSize = 0; /// Bytes per element.
	fp.lifecycle.FinalizeFunction finalizeFunction = null; /// Ends an element's lifetime when it is popped, cleared or freed; null when its lifetime is its bytes.
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
size_t length(const PagedArray self) { return self.count; }
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
bool empty(const PagedArray self) { return self.count == 0; }

/// The number of elements storable without allocating another page.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int(16);
/// scope(exit) free(arr);
/// assert(pushBack(arr, 1));
/// assert(capacity(arr) == 4);
/// ---
size_t capacity(const PagedArray self) @trusted {
	return fp.dynarray.length(cast(ubyte**) self.pages) << self.pageShift;
}

/// The number of elements each page holds.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int(16);
/// assert(pageElements(arr) == 4);
/// ---
size_t pageElements(const PagedArray self) { return size_t(1) << self.pageShift; }


/// A pointer to element `i`, which must be less than the length, and stays valid until the element is popped or the array is freed or shrunk past it.
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
const(void)* get(const PagedArray self, size_t i) @trusted {
	assert(i < self.count);
	return self.pages[i >> self.pageShift] + (i & (pageElements(self) - 1)) * self.elementSize;
}

// Ends the lifetimes of elements `start` .. `end`, which are spread over pages.
private void endLifetimes(ref PagedArray self, size_t start, size_t end) @trusted {
	if (self.finalizeFunction is null) return;
	for (size_t i = start; i < end; ++i) {
		ubyte* slot = cast(ubyte*) get(self, i);
		self.finalizeFunction(cast(inout(ubyte)[]) slot[0 .. self.elementSize]);
	}
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


/// An empty array of `elementSize`-byte elements, `elementSize` greater than zero, or a `PagedArrayOf!T`. Pages hold a power-of-two number of elements, the fewest that fill at least `pageBytes`, so an index splits into page and offset by shift and mask. Nothing is allocated until the first element is added.
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
	PagedArray self = create(T.sizeof, pageBytes);
	self.finalizeFunction = fp.lifecycle.finalizeFunction!T();
	return PagedArrayOf!T(self);
}

/// Releases every page and empties the array, ending the elements' lifetimes first if the array knows them. It stays usable: it can grow again, or be freed again harmlessly.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int();
/// assert(pushBack(arr, 1));
/// free(arr);
/// assert(length(arr) == 0 && capacity(arr) == 0);
/// ---
void free(ref PagedArray self) @trusted {
	endLifetimes(self, 0, self.count);
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

/// Appends `count` elements, which must be more than zero, and returns the first, or null (length unchanged) if the allocator refused or the length would overflow. The new elements are only contiguous within a page. When the array knows element lifetimes they start empty, as the convention requires; otherwise their bytes are whatever the page allocator handed back. The `T` version leaves them empty for a type whose lifetime is not its bytes.
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
	if (self.finalizeFunction !is null) // these slots are now live, so they must read as empty rather than as the page's stale bytes
		for (size_t i = self.count - count; i < self.count; ++i)
			memset(cast(ubyte*) get(self, i), 0, self.elementSize);
	return get(self, self.count - count);
}
/// Ditto, with `T.sizeof` required to equal the array's element size.
T* grow(T)(ref PagedArray self, size_t count = 1) @trusted {
	assert(T.sizeof == self.elementSize);
	void* slot = grow(self, count);
	if (slot is null) return null; // the array is unchanged, so the loop below would otherwise wipe live elements
	static if (!fp.lifecycle.isBitMoveable!T) // the new elements are not contiguous, so they cannot be zeroed in one pass
		for (size_t i = self.count - count; i < self.count; ++i)
			fp.lifecycle.initSlots(cast(T*) get(self, i), 1);
	return cast(T*) slot;
}

/// Appends `value`, taking its lifetime over: the copy of it made for the call is left empty. `T.sizeof` must equal the array's element size. Returns false if the array could not grow, leaving it unchanged; the copy's lifetime is ended either way.
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
	if (slot is null) { fp.lifecycle.endLifetime(value); return false; }
	fp.lifecycle.initSlots(cast(T*) slot, 1);
	fp.lifecycle.moveInto(*cast(T*) slot, value);
	return true;
}


/// Ends the last `count` elements' lifetimes, `count` no greater than the length; their pages are kept for reuse (`shrinkToFit` releases them).
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
	endLifetimes(self, self.count - count, self.count);
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

/// Sets the length to 0 without releasing any page (see `shrinkToFit`), ending the elements' lifetimes.
///
/// Examples:
/// ---
/// PagedArrayOf!int arr = create!int(16);
/// scope(exit) free(arr);
/// assert(grow(arr, 5) !is null);
/// clear(arr);
/// assert(empty(arr) && capacity(arr) == 8);
/// ---
void clear(ref PagedArray self) {
	endLifetimes(self, 0, self.count);
	self.count = 0;
}

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


/// Swaps two elements' bytes, which exchanges their lifetimes too since both are live. Goes through a small stack buffer, so it never allocates and cannot fail, whatever the element size.
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


version(unittest) {
	private __gshared size_t finalizeCount;
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

	// A query takes the array by value, so a temporary is a valid argument.
	static PagedArray handle(ref PagedArray self) { return self; }
	assert(length(handle(erased)) == 0 && capacity(handle(erased)) == 0 && empty(handle(ints)));

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

	auto previous = fp.testing.beginRationedAllocator();
	assert(grow(arr, 100) is null);
	assert(length(arr) == 1);
	assert(grow!int(arr, 2) is &arr[1]); // the rest of the first page needs no allocation
	assert(grow(arr, 2) is null);
	fp.testing.endRationedAllocator(previous);
	assert(length(arr) == 3 && capacity(arr) == 4 && arr[0] == 7);

	// Fill every page and the page table's spare slots, so the next element needs a new page and a bigger table.
	while (fp.dynarray.length(arr.pages) < fp.dynarray.capacity(arr.pages))
		assert(grow(arr, pageElements(arr)) !is null);
	if (length(arr) < capacity(arr))
		assert(grow(arr, capacity(arr) - length(arr)) !is null);
	immutable filled = length(arr);
	immutable pagesBefore = fp.dynarray.length(arr.pages);
	previous = fp.testing.beginRationedAllocator();
	assert(!pushBack(arr, 8)); // refused at the table, before any page is allocated
	fp.testing.endRationedAllocator(previous);
	assert(length(arr) == filled);
	assert(fp.dynarray.length(arr.pages) == pagesBefore);

	// The table is sized first, so an impossible reservation fails at once instead of allocating pages until memory runs out.
	assert(!reserve(arr, size_t.max));
	assert(fp.dynarray.length(arr.pages) == pagesBefore);

	popBackCount(arr, filled - 2);
	immutable tableCapacity = fp.dynarray.capacity(arr.pages);
	previous = fp.testing.beginRationedAllocator();
	shrinkToFit(arr);
	fp.testing.endRationedAllocator(previous);
	assert(capacity(arr) == 4);
	assert(fp.dynarray.capacity(arr.pages) == tableCapacity);
	assert(length(arr) == 2 && arr[0] == 7);
}

unittest {
	static struct Handle {
		int* data;
		void finalize() @nogc nothrow { if (data !is null) ++finalizeCount; data = null; }
		void moveTo(ref Handle dest) @nogc nothrow { dest.data = data; data = null; }
	}

	static assert(!fp.lifecycle.isBitMoveable!Handle);

	PagedArrayOf!Handle arr = create!Handle(2 * Handle.sizeof); // two elements per page
	scope(exit) free(arr);
	finalizeCount = 0;

	assert(pushBack(arr, Handle(cast(int*) 1)) && pushBack(arr, Handle(cast(int*) 2)));
	assert(length(arr) == 2 && arr[1].data == cast(int*) 2 && finalizeCount == 0);

	popBackCount(arr, 1);
	assert(finalizeCount == 1); // the popped slot is empty, and past the length to read

	assert(pushBack(arr, Handle(cast(int*) 3)));
	swap(arr, 0, 1);
	assert(arr[0].data == cast(int*) 3 && arr[1].data == cast(int*) 1);

	clear(arr);
	assert(finalizeCount == 3 && empty(arr));

	// The cleared slots are empty, so growing into them and freeing ends nothing.
	assert(grow!Handle(arr, 3) !is null);
	assert(arr[0].data is null && arr[2].data is null);
	free(arr);
	assert(finalizeCount == 3);

	// A refused grow leaves the array alone, rather than emptying the slots the count it did not reach would have covered.
	auto rationed = fp.testing.beginRationedAllocator(0);
	assert(grow!Handle(arr, 3) is null && empty(arr));
	fp.testing.endRationedAllocator(rationed);
	assert(pushBack(arr, Handle(cast(int*) 4)) && arr[0].data == cast(int*) 4);

	// Untyped `grow` on an array that knows lifetimes starts its new slots empty, so freeing cannot end a lifetime that never began.
	finalizeCount = 0;
	auto dirty = fp.dynarray.beginDirtyAllocator();
	scope(exit) fp.dynarray.endDirtyAllocator(dirty);
	PagedArrayOf!Handle raw = create!Handle(2 * Handle.sizeof);
	assert(grow(raw, 3) !is null && length(raw) == 3);
	assert(raw[0].data is null && raw[2].data is null);
	free(raw);
	assert(finalizeCount == 0);

	// A refused append ends the value's lifetime, since the call took it over.
	finalizeCount = 0;
	PagedArrayOf!Handle tight = create!Handle(2 * Handle.sizeof);
	assert(pushBack(tight, Handle(cast(int*) 5)) && pushBack(tight, Handle(cast(int*) 6)));
	rationed = fp.testing.beginRationedAllocator(0);
	assert(!pushBack(tight, Handle(cast(int*) 7)) && finalizeCount == 1);
	fp.testing.endRationedAllocator(rationed);
	free(tight);
	assert(finalizeCount == 3);
}

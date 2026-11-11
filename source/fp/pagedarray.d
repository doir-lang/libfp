/// A growable array whose elements never move: storage is a table of fixed-size pages, so growing allocates a new page instead of reallocating the old ones.
/// Use it where a pointer into the array must survive further appends, such as an arena read through references while more is added.
///
/// Unlike `fp.dynarray` this is a plain struct rather than a fat pointer: the elements are not contiguous, so there is no element pointer for a header to sit in front of.
/// The element size is a runtime value so type-erased containers can use it; `PagedArrayOf!T`, which `create!T` returns, is the typed view.
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int();
/// scope(exit) free(array);
/// assert(pushBack(array, 1));
/// int* first = &array[0];
/// foreach (i; 0 .. 5000)
/// 	assert(pushBack(array, i));
/// assert(&array[0] is first);
/// ---
module fp.pagedarray;

static import core.stdc.string;
static import core.checkedint;

static import fp.dynarray;
static import fp.lifecycle;
static import fp.pointer;
version(unittest) static import fp.testing;


/// The page size `create` uses unless told otherwise.
enum size_t defaultPageBytes = 4096;

private enum size_t swapScratchBytes = 64;

/// Plain data with no methods: every operation is a free function, taking the array by `ref` when it changes it and by value when it only reads it.
/// `free` is the only one that releases what it owns.
/// Copying one copies a handle to the same pages, not the elements.
///
/// Element lifetimes are ended by the `finalizer` the array stores, which `create!T` sets from the element type; an array made with `create(elementSize)` has none, so its elements are treated as bytes.
///
/// Examples:
/// ---
/// PagedArray array = create(8);
/// scope(exit) free(array);
/// assert(array.elementSize == 8 && empty(array));
/// ---
struct PagedArray {
	size_t elementSize = 0; /// Bytes per element.
	fp.lifecycle.Finalizer finalizer = null; /// Ends an element's lifetime when it is popped, cleared or freed; null when its lifetime is its bytes.
	private size_t pageShift = 0;
	private size_t count = 0;
	private ubyte** pages = null; // dynarray of page pointers
}


@nogc nothrow:


// wrapper: reads a private field
/// The number of elements.
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int();
/// scope(exit) free(array);
/// assert(pushBack(array, 1) && pushBack(array, 2));
/// assert(length(array) == 2);
/// ---
size_t length(const PagedArray self) {
	assert(self.count <= capacity(self), "fp.pagedarray: more elements than its pages hold");
	return self.count;
}

/// Whether the array holds no elements.
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int();
/// scope(exit) free(array);
/// assert(empty(array));
/// assert(pushBack(array, 1));
/// assert(!empty(array));
/// ---
bool empty(const PagedArray self) {
	assert(self.count <= capacity(self), "fp.pagedarray: more elements than its pages hold");
	return self.count == 0;
}

/// The number of elements storable without allocating another page.
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int(16);
/// scope(exit) free(array);
/// assert(pushBack(array, 1));
/// assert(capacity(array) == 4);
/// ---
size_t capacity(const PagedArray self) @trusted {
	assert(self.pageShift < size_t.sizeof * 8, "fp.pagedarray: a page too large to count");
	assert(self.pages is null || fp.dynarray.valid(self.pages), "fp.pagedarray: a page table that is not a dynarray");
	return fp.dynarray.length(cast(ubyte**) self.pages) << self.pageShift;
}

/// The number of elements each page holds.
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int(16);
/// assert(pageElements(array) == 4);
/// ---
size_t pageElements(const PagedArray self) {
	assert(self.pageShift < size_t.sizeof * 8, "fp.pagedarray: a page too large to count");
	return size_t(1) << self.pageShift;
}


/// A pointer to element `i`, which must be less than the length, and stays valid until the element is popped or the array is freed or shrunk past it.
///
/// Examples:
/// ---
/// PagedArray array = create(int.sizeof);
/// scope(exit) free(array);
/// assert(pushBack(array, 7));
/// assert(*cast(int*) get(array, 0) == 7);
/// ---
void* get(ref PagedArray self, size_t i) @trusted {
	assert(i < self.count, "fp.pagedarray: an index past the end");
	assert((i >> self.pageShift) < fp.dynarray.length(self.pages), "fp.pagedarray: an element on a page that was never allocated");
	return self.pages[i >> self.pageShift] + (i & (pageElements(self) - 1)) * self.elementSize;
}
/// Ditto
const(void)* get(const PagedArray self, size_t i) @trusted {
	assert(i < self.count, "fp.pagedarray: an index past the end");
	assert((i >> self.pageShift) < fp.dynarray.length(self.pages), "fp.pagedarray: an element on a page that was never allocated");
	return self.pages[i >> self.pageShift] + (i & (pageElements(self) - 1)) * self.elementSize;
}

// Ends the lifetimes of elements `start` ..
// `end`, which are spread over pages.
private void endLifetimes(ref PagedArray self, size_t start, size_t end) @trusted {
	assert(start <= end && end <= self.count, "fp.pagedarray: ending lifetimes past the end");
	if (self.finalizer is null) return;
	for (size_t i = start; i < end; ++i) {
		ubyte* slot = cast(ubyte*) get(self, i);
		self.finalizer(cast(inout(ubyte)[]) slot[0 .. self.elementSize]);
	}
}


/// A `PagedArray` of `T`s, as `create!T` returns it: `array[i]` is element `i` by `ref`, and every function taking a `PagedArray` accepts it.
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int();
/// scope(exit) free(array);
/// assert(pushBack(array, 7));
/// array[0] = 8;
/// assert(array[0] == 8 && length(array) == 1);
/// ---
struct PagedArrayOf(T) {
	PagedArray base; /// The type-erased array this views.
	alias base this;

	/// Element `i`, which stays where it is until popped or the array is freed or shrunk past it.
	///
	/// Examples:
	/// ---
	/// PagedArrayOf!int array = create!int();
	/// scope(exit) free(array);
	/// assert(pushBack(array, 7));
	/// int* p = &array[0];
	/// assert(*p == 7);
	/// ---
	ref T opIndex(size_t i) @trusted {
		assert(T.sizeof == base.elementSize, "fp.pagedarray: viewed as elements of the wrong size");
		assert(i < base.count, "fp.pagedarray: an index past the end");
		return *cast(T*) get(base, i);
	}
	/// Ditto
	ref const(T) opIndex(size_t i) const @trusted {
		assert(T.sizeof == base.elementSize, "fp.pagedarray: viewed as elements of the wrong size");
		assert(i < base.count, "fp.pagedarray: an index past the end");
		return *cast(const(T)*) get(base, i);
	}
}


/// An empty array of `elementSize`-byte elements, `elementSize` greater than zero, or a `PagedArrayOf!T`.
/// Pages hold a power-of-two number of elements, the fewest that fill at least `pageBytes`, so an index splits into page and offset by shift and mask.
/// Nothing is allocated until the first element is added.
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
	assert(elementSize > 0, "fp.pagedarray: elements of no size");
	assert(pageBytes > 0, "fp.pagedarray: pages of no size");
	PagedArray self;
	self.elementSize = elementSize;
	while ((size_t(1) << self.pageShift) * elementSize < pageBytes) {
		assert((size_t(1) << self.pageShift) <= size_t.max / elementSize / 2); // a page's byte size must fit in a size_t
		++self.pageShift;
	}
	assert(pageElements(self) * elementSize >= pageBytes, "fp.pagedarray: a page smaller than asked for");
	return self;
}
/// Ditto
PagedArrayOf!T create(T)(size_t pageBytes = defaultPageBytes) {
	mixin fp.pointer.requireAlignable!T;
	PagedArray self = create(T.sizeof, pageBytes);
	self.finalizer = fp.lifecycle.finalizerOf!T();
	assert(self.elementSize == T.sizeof && self.count == 0, "fp.pagedarray: a new array of the wrong shape");
	return PagedArrayOf!T(self);
}

/// Releases every page and empties the array, ending the elements' lifetimes first if the array knows them.
/// It stays usable: it can grow again, or be freed again harmlessly.
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int();
/// assert(pushBack(array, 1));
/// free(array);
/// assert(length(array) == 0 && capacity(array) == 0);
/// ---
void free(ref PagedArray self) @trusted {
	assert(self.count <= capacity(self), "fp.pagedarray: more elements than its pages hold");
	endLifetimes(self, 0, self.count);
	foreach (i; 0 .. fp.dynarray.length(self.pages))
		cast(void)fp.pointer.allocator(self.pages[i], 0);
	fp.dynarray.free(self.pages);
	self.count = 0;
	assert(capacity(self) == 0, "fp.pagedarray: pages left after free");
}


/// Allocates pages until `n` elements fit.
/// Returns false if the allocator refused; pages obtained before the refusal are kept as capacity.
/// The page table grows first, so an `n` too large for any table fails before a page is allocated.
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int(16);
/// scope(exit) free(array);
/// assert(reserve(array, 10));
/// assert(capacity(array) == 12 && length(array) == 0);
/// ---
bool reserve(ref PagedArray self, size_t n) @trusted {
	assert(self.elementSize > 0, "fp.pagedarray: not an array; make one with create");
	immutable pageBytes = pageElements(self) * self.elementSize;
	immutable pagesNeeded = (n >> self.pageShift) + ((n & (pageElements(self) - 1)) != 0);
	if (pagesNeeded > fp.dynarray.capacity(self.pages) && fp.dynarray.maybeGrow(self.pages, pagesNeeded, false, false) is null)
		return false;
	while (capacity(self) < n) {
		ubyte* page = cast(ubyte*) fp.pointer.allocator(null, pageBytes);
		if (page is null) return false;
		cast(void)fp.dynarray.pushBack(self.pages, page); // the table already has room
	}
	assert(capacity(self) >= n && capacity(self) - n < pageElements(self), "fp.pagedarray: reserved the wrong number of pages");
	return true;
}

/// Appends `count` elements, which must be more than zero, and returns the first, or null (length unchanged) if the allocator refused or the length would overflow.
/// The new elements are only contiguous within a page.
/// When the array knows element lifetimes they start empty, as the convention requires; otherwise their bytes are whatever the page allocator handed back.
/// The `T` version leaves them empty for a type whose lifetime is not its bytes.
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int();
/// scope(exit) free(array);
/// int* first = grow!int(array, 3);
/// first[0] = 1;
/// assert(length(array) == 3 && array[0] == 1);
/// assert(grow(array) is &array[3]);
/// ---
void* grow(ref PagedArray self, size_t count = 1) {
	assert(count > 0, "fp.pagedarray: growing by nothing");
	assert(self.elementSize > 0, "fp.pagedarray: not an array; make one with create");
	// A partly filled last page is already allocated, so elements fitting in its rest skip `reserve` and its page-table read.
	immutable offset = self.count & (pageElements(self) - 1);
	if (offset == 0 || count > pageElements(self) - offset) {
		bool overflow = false;
		immutable newCount = core.checkedint.addu(self.count, count, overflow);
		if (overflow || !reserve(self, newCount)) return null;
	}
	self.count += count;
	assert(self.count <= capacity(self), "fp.pagedarray: grew past its pages");
	if (self.finalizer !is null) // these slots are now live, so they must read as empty rather than as the page's stale bytes
		for (size_t i = self.count - count; i < self.count; ++i)
			core.stdc.string.memset(cast(ubyte*) get(self, i), 0, self.elementSize);
	return get(self, self.count - count);
}
/// Ditto, with `T.sizeof` required to equal the array's element size.
T* grow(T)(ref PagedArray self, size_t count = 1) @trusted {
	assert(T.sizeof == self.elementSize, "fp.pagedarray: grown as elements of the wrong size");
	immutable before = self.count;
	void* slot = grow(self, count);
	if (slot is null) return null; // the array is unchanged, so the loop below would otherwise wipe live elements
	static if (!fp.lifecycle.isBitMoveable!T) // the new elements are not contiguous, so they cannot be zeroed in one pass
		for (size_t i = self.count - count; i < self.count; ++i)
			fp.lifecycle.emptySlots(cast(T*) get(self, i), 1);
	assert(self.count == before + count, "fp.pagedarray: grow added the wrong number of elements");
	return cast(T*) slot;
}

/// Appends `value`, taking its lifetime over: the copy of it made for the call is left empty.
/// `T.sizeof` must equal the array's element size.
/// Returns false if the array could not grow, leaving it unchanged; the copy's lifetime is ended either way.
///
/// Examples:
/// ---
/// PagedArrayOf!double array = create!double();
/// scope(exit) free(array);
/// assert(pushBack(array, 1.5));
/// assert(array[0] == 1.5);
/// ---
bool pushBack(T)(ref PagedArray self, T value) @trusted {
	assert(T.sizeof == self.elementSize, "fp.pagedarray: pushed an element of the wrong size");
	immutable before = self.count;
	void* slot = grow(self, 1);
	if (slot is null) {
		assert(self.count == before, "fp.pagedarray: a refused pushBack changed the length");
		fp.lifecycle.endLifetime(value);
		return false;
	}
	fp.lifecycle.emptySlots(cast(T*) slot, 1);
	fp.lifecycle.moveInto(*cast(T*) slot, value);
	assert(self.count == before + 1 && slot is get(self, before), "fp.pagedarray: pushBack did not append one element");
	return true;
}


/// Ends the last `count` elements' lifetimes, one by default, `count` no greater than the length; their pages are kept for reuse (`shrinkToFit` releases them).
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int();
/// scope(exit) free(array);
/// assert(grow(array, 5) !is null);
/// removeLast(array, 3);
/// assert(length(array) == 2);
/// removeLast(array);
/// assert(length(array) == 1);
/// ---
void removeLast(ref PagedArray self, size_t count = 1) {
	assert(count <= self.count, "fp.pagedarray: removing more elements than there are");
	immutable before = self.count;
	endLifetimes(self, self.count - count, self.count);
	self.count -= count;
	assert(self.count == before - count, "fp.pagedarray: removeLast set the wrong length");
}

/// Sets the length to 0 without releasing any page (see `shrinkToFit`), ending the elements' lifetimes.
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int(16);
/// scope(exit) free(array);
/// assert(grow(array, 5) !is null);
/// clear(array);
/// assert(empty(array) && capacity(array) == 8);
/// ---
void clear(ref PagedArray self) {
	immutable pages = capacity(self);
	endLifetimes(self, 0, self.count);
	self.count = 0;
	assert(capacity(self) == pages, "fp.pagedarray: clear changed the pages");
}

/// Frees every page past the one holding the last element, so `capacity` drops to the fewest whole pages `length` needs; after `clear` it frees them all.
/// The elements that remain do not move.
/// The page table shrinks to match where the allocator allows; if it refuses, the table only keeps its spare slots, so this cannot fail.
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int(16);
/// scope(exit) free(array);
/// assert(grow(array, 12) !is null);
/// removeLast(array, 10);
/// shrinkToFit(array);
/// assert(capacity(array) == 4 && length(array) == 2);
/// ---
void shrinkToFit(ref PagedArray self) @trusted {
	immutable needed = (self.count + pageElements(self) - 1) >> self.pageShift;
	immutable have = fp.dynarray.length(self.pages);
	assert(needed <= have, "fp.pagedarray: more elements than its pages hold");
	foreach (i; needed .. have)
		cast(void)fp.pointer.allocator(self.pages[i], 0);
	if (needed == 0) {
		fp.dynarray.free(self.pages);
		return;
	}
	cast(void)fp.dynarray.removeLast(self.pages, have - needed);
	if (fp.dynarray.capacity(self.pages) > needed)
		cast(void)fp.dynarray.shrinkToFit(self.pages);
	assert(fp.dynarray.length(self.pages) == needed && self.count <= capacity(self), "fp.pagedarray: shrinkToFit kept the wrong pages");
}


/// Swaps two elements' bytes, which exchanges their lifetimes too since both are live.
/// Goes through a small stack buffer, so it never allocates and cannot fail, whatever the element size.
///
/// Examples:
/// ---
/// PagedArrayOf!int array = create!int();
/// scope(exit) free(array);
/// assert(pushBack(array, 1) && pushBack(array, 2));
/// swap(array, 0, 1);
/// assert(array[0] == 2 && array[1] == 1);
/// ---
void swap(ref PagedArray self, size_t a, size_t b) @trusted {
	assert(a < self.count && b < self.count, "fp.pagedarray: swapping past the end");
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
	auto array = create!int(16); // 4 ints per page
	scope(exit) free(array);
	assert(empty(array));
	assert(capacity(array) == 0);

	foreach (i; 0 .. 10)
		assert(pushBack(array, cast(int) i));
	assert(length(array) == 10);
	assert(capacity(array) == 12);
	foreach (i; 0 .. 10)
		assert(array[i] == i);

	const(PagedArrayOf!int)* constArray = &array;
	assert((*constArray)[9] == 9);
	assert(*cast(const(int)*) get(*constArray, 3) == 3);

	int* first = &array[0];
	int* ninth = &array[8];
	int* slots = grow!int(array, 3);
	assert(slots is &array[10]);
	assert(capacity(array) == 16);
	slots[0] = 100;
	assert(array[10] == 100);
	assert(cast(int*) grow(array, 7) is &array[13]);
	assert(length(array) == 20);
	assert(&array[0] is first);

	shrinkToFit(array);
	assert(capacity(array) == 20);
	removeLast(array);
	assert(length(array) == 19);
	removeLast(array, 10);
	assert(length(array) == 9);
	shrinkToFit(array);
	assert(capacity(array) == 12);
	assert(fp.dynarray.capacity(array.pages) == 3);
	assert(&array[0] is first && &array[8] is ninth);
	foreach (i; 0 .. 9)
		assert(array[i] == i);

	clear(array);
	assert(length(array) == 0);
	assert(capacity(array) == 12);
	assert(grow(array, 12) !is null);
	assert(capacity(array) == 12);

	clear(array);
	shrinkToFit(array);
	assert(capacity(array) == 0);
	assert(array.pages is null);
	shrinkToFit(array);

	assert(pushBack(array, 5));
	assert(array[0] == 5 && capacity(array) == 4);
	first = &array[0];
	foreach (i; 0 .. 1000)
		assert(pushBack(array, cast(int) i));
	assert(&array[0] is first);
	assert(*first == 5);
	foreach (i; 0 .. 1000)
		assert(array[i + 1] == i);

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
	auto array = create!int(16);
	scope(exit) free(array);
	assert(pushBack(array, 7));

	assert(grow(array, size_t.max) is null);
	assert(length(array) == 1);

	auto previous = fp.testing.limitAllocations();
	assert(grow(array, 100) is null);
	assert(length(array) == 1);
	assert(grow!int(array, 2) is &array[1]); // the rest of the first page needs no allocation
	assert(grow(array, 2) is null);
	fp.testing.restoreAllocator(previous);
	assert(length(array) == 3 && capacity(array) == 4 && array[0] == 7);

	// Fill every page and the page table's spare slots, so the next element needs a new page and a bigger table.
	while (fp.dynarray.length(array.pages) < fp.dynarray.capacity(array.pages))
		assert(grow(array, pageElements(array)) !is null);
	if (length(array) < capacity(array))
		assert(grow(array, capacity(array) - length(array)) !is null);
	immutable filled = length(array);
	immutable pagesBefore = fp.dynarray.length(array.pages);
	previous = fp.testing.limitAllocations();
	assert(!pushBack(array, 8)); // refused at the table, before any page is allocated
	fp.testing.restoreAllocator(previous);
	assert(length(array) == filled);
	assert(fp.dynarray.length(array.pages) == pagesBefore);

	// The table is sized first, so an impossible reservation fails at once instead of allocating pages until memory runs out.
	assert(!reserve(array, size_t.max));
	assert(fp.dynarray.length(array.pages) == pagesBefore);

	removeLast(array, filled - 2);
	immutable tableCapacity = fp.dynarray.capacity(array.pages);
	previous = fp.testing.limitAllocations();
	shrinkToFit(array);
	fp.testing.restoreAllocator(previous);
	assert(capacity(array) == 4);
	assert(fp.dynarray.capacity(array.pages) == tableCapacity);
	assert(length(array) == 2 && array[0] == 7);
}

unittest {
	static struct Handle {
		int* data;
		void finalize() @nogc nothrow { if (data !is null) ++finalizeCount; data = null; }
		void moveTo(ref Handle destination) @nogc nothrow { destination.data = data; data = null; }
	}

	static assert(!fp.lifecycle.isBitMoveable!Handle);

	PagedArrayOf!Handle array = create!Handle(2 * Handle.sizeof); // two elements per page
	scope(exit) free(array);
	finalizeCount = 0;

	assert(pushBack(array, Handle(cast(int*) 1)) && pushBack(array, Handle(cast(int*) 2)));
	assert(length(array) == 2 && array[1].data == cast(int*) 2 && finalizeCount == 0);

	removeLast(array, 1);
	assert(finalizeCount == 1); // the popped slot is empty, and past the length to read

	assert(pushBack(array, Handle(cast(int*) 3)));
	swap(array, 0, 1);
	assert(array[0].data == cast(int*) 3 && array[1].data == cast(int*) 1);

	clear(array);
	assert(finalizeCount == 3 && empty(array));

	// The cleared slots are empty, so growing into them and freeing ends nothing.
	assert(grow!Handle(array, 3) !is null);
	assert(array[0].data is null && array[2].data is null);
	free(array);
	assert(finalizeCount == 3);

	// A refused grow leaves the array alone, rather than emptying the slots the count it did not reach would have covered.
	auto rationed = fp.testing.limitAllocations(0);
	assert(grow!Handle(array, 3) is null && empty(array));
	fp.testing.restoreAllocator(rationed);
	assert(pushBack(array, Handle(cast(int*) 4)) && array[0].data == cast(int*) 4);

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
	rationed = fp.testing.limitAllocations(0);
	assert(!pushBack(tight, Handle(cast(int*) 7)) && finalizeCount == 1);
	fp.testing.restoreAllocator(rationed);
	free(tight);
	assert(finalizeCount == 3);
}

/// Helpers for tests of code built on libfp, such as an allocator that refuses on demand, so every path that handles a refused allocation can be reached.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// int* list = null;
/// auto previous = beginRationedAllocator(0);
/// assert(!fp.dynarray.pushBack(list, 1));
/// endRationedAllocator(previous);
/// assert(fp.dynarray.pushBack(list, 1));
/// fp.dynarray.free(list);
/// ---
module fp.testing;

static import fp.pointer;

@nogc nothrow:


// --- refused allocations -----------------------------------------------------

private __gshared fp.pointer.AllocFunction rationedUnderlying;
private __gshared size_t rationedRemaining;

private void* rationedAlloc(void* p, size_t size) {
	// Frees are always forwarded, or a test could not clean up after itself.
	if (size == 0) return rationedUnderlying(p, 0);
	if (rationedRemaining == 0) return null;
	--rationedRemaining;
	return rationedUnderlying(p, size);
}

/// Makes `fp.pointer.allocFunction` grant only the next `n` allocations and refuse the rest, while still freeing, and returns the allocator it replaced; pass that to `endRationedAllocator` to restore it. It is one global for every thread, so tests using it must not run concurrently with anything that allocates.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// auto previous = beginRationedAllocator(1);
/// int* granted = fp.dynarray.create!int(1);
/// assert(granted !is null && fp.dynarray.create!int(1) is null);
/// fp.dynarray.free(granted);
/// endRationedAllocator(previous);
/// ---
fp.pointer.AllocFunction beginRationedAllocator(size_t n = 0) {
	fp.pointer.AllocFunction previous = fp.pointer.allocFunction;
	rationedUnderlying = previous;
	rationedRemaining = n;
	fp.pointer.allocFunction = &rationedAlloc;
	return previous;
}

/// Restores the allocator `beginRationedAllocator` returned.
///
/// Examples:
/// ---
/// static import fp.pointer;
/// auto previous = beginRationedAllocator();
/// endRationedAllocator(previous);
/// assert(fp.pointer.allocFunction is previous);
/// ---
void endRationedAllocator(fp.pointer.AllocFunction previous) {
	fp.pointer.allocFunction = previous;
}


unittest { // a ration counts allocations, never frees, and ends with the allocator it replaced
	static import fp.dynarray;
	auto previous = beginRationedAllocator(2);
	int* a = fp.dynarray.create!int(1), b = fp.dynarray.create!int(1);
	assert(a !is null && b !is null && fp.dynarray.create!int(1) is null);
	fp.dynarray.free(a);
	assert(fp.dynarray.create!int(1) is null);
	endRationedAllocator(previous);
	assert(fp.pointer.allocFunction is previous);
	fp.dynarray.free(b);
}

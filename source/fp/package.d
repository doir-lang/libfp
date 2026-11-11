/// libfp: fat pointers and the containers built on them, for `-betterC` D. `import fp;` pulls in every module; each can also be imported on its own.
/// Several modules define the same names — `append`, `capacity`, `clear`, `clone`, `concatenate`, `contains`, `create`, `empty`, `find`, `free`, `grow`, `insert`, `length`, `lineBreakCount`, `lineOf`, `lineStart`, `removeLast`, `pushBack`, `reserve`, `shrinkToFit`, `valid` — so an unqualified call to one of them is ambiguous and must be qualified with its module.
///
/// Examples:
/// ---
/// import fp;
///
/// int* numbers = null;
/// assert(fp.dynarray.pushBack(numbers, 1));
/// fp.dynarray.free(numbers);
///
/// char* text = fp.string.clone("hi").get;
/// assert(fp.string.length(text) == 2);
/// fp.string.free(text);
///
/// assert(hashBytes(cast(const(ubyte)[]) "hi") != hashShortBytes(cast(const(ubyte)[]) "hi"));
/// ---
module fp;

public import fp.pointer;
public import fp.lifecycle;
public import fp.dynarray;
public import fp.pagedarray;
public import fp.algorithms;
public import fp.hashtable;
public import fp.string;
public import fp.string.ascii;
public import fp.string.numbers;
public import fp.string.utf;
public import fp.io;
public import fp.rope;
public import fp.testing;

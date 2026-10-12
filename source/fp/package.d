/// libfp: fat pointers and the containers built on them, for `-betterC` D. `import fp;` pulls in every module; each can also be imported on its own. Several modules define the same names — `capacity`, `clear`, `clone`, `concatenate`, `contains`, `create`, `empty`, `find`, `free`, `grow`, `insert`, `length`, `popBack`, `popBackCount`, `pushBack`, `reserve`, `shrinkToFit`, `size`, `swap`, `valid` — so an unqualified call to one of them is ambiguous and must be qualified with its module.
///
/// Examples:
/// ---
/// import fp;
///
/// int* numbers = null;
/// assert(fp.dynarray.pushBack(numbers, 1));
/// fp.dynarray.free(numbers);
///
/// char* text = fp.string.makeDynamic("hi");
/// assert(fp.string.length(text) == 2);
/// fp.string.free(text);
/// ---
module fp;

public import fp.pointer;
public import fp.lifecycle;
public import fp.dynarray;
public import fp.pagedarray;
public import fp.fnv1a;
public import fp.hashtable;
public import fp.string;

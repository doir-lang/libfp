/// libfp: fat pointers and the containers built on them, for `-betterC` D. `import fp;` pulls in every module; each can also be imported on its own. The modules reuse function names (`length`, `free`, ...), so code that imports several of them calls through the module name.
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
public import fp.dynarray;
public import fp.pagedarray;
public import fp.fnv1a;
public import fp.hashtable;
public import fp.string;

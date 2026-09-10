/// `import fp;` pulls in every module; `import fp.pointer;` etc. still
/// works for module-qualified access only.
module fp;

public import fp.pointer;
public import fp.dynarray;
public import fp.fnv1a;
public import fp.hashtable;
public import fp.string;

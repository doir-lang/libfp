/// Manual unittest runner for -betterC: druntime's automatic test runner
/// (`core.runtime.runModuleUnitTests`) isn't available, so this discovers
/// and runs every `unittest {}` block in the `fp` package modules itself.
module runner;

import std.meta : AliasSeq;
import fp.pointer;
import fp.dynarray;
import fp.fnv1a;
import fp.hashtable;
import fp.string;

private alias ModuleList = AliasSeq!(fp.pointer, fp.dynarray, fp.fnv1a, fp.hashtable, fp.string);

extern (C) void main() {
    import core.stdc.stdio : printf;

    size_t count = 0;
    static foreach (m; ModuleList) {
        static foreach (u; __traits(getUnitTests, m)) {
            u();
            count++;
        }
    }
    printf("libfp: %zu unittests passed\n", count);
}

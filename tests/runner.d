module runner;

import core.stdc.stdio : fprintf, printf, stderr;

private enum modules = [
	"fp.pointer",
	"fp.dynarray",
	"fp.pagedarray",
	"fp.fnv1a",
	"fp.hashtable",
	"fp.string",
];

private int runEveryTest() {
	size_t total = 0;

	static foreach (name; modules) {{
		alias mod = mixin("imported!\"" ~ name ~ "\"");
		alias tests = __traits(getUnitTests, mod);
		fprintf(stderr, "%s (%d tests)\n", name.ptr, cast(int) tests.length);
		static foreach (i, test; tests) {
			fprintf(stderr, "  [%d] ", cast(int) i);
			test();
			fprintf(stderr, "ok\n");
			++total;
		}
	}}

	printf("libfp: all %d tests passed.\n", cast(int) total);
	return 0;
}

version(LibfpCoverage) {
	shared static this() {
		import core.runtime : Runtime, UnitTestResult;
		Runtime.extendedModuleUnitTester = () => UnitTestResult(0, 0, true, false);
	}

	int main() { return runEveryTest(); }
} else
	extern(C) int main() { return runEveryTest(); }

module runner;


private alias modules = imported!"std.meta".AliasSeq!(
	"fp.pointer",
	"fp.lifecycle",
	"fp.dynarray",
	"fp.pagedarray",
	"fp.algorithms",
	"fp.hashtable",
	"fp.string",
	"fp.file",
	"fp.rope",
	"fp.testing",
);

private int runEveryTest() {
	cast(void) imported!"fp.testing".runTests!modules("libfp");
	return 0;
}

version(LibfpCoverage) {
	shared static this() {
		static import core.runtime;
		core.runtime.Runtime.extendedModuleUnitTester = () => core.runtime.UnitTestResult(0, 0, true, false);
	}

	int main() { return runEveryTest(); }
} else
	extern(C) int main() { return runEveryTest(); }

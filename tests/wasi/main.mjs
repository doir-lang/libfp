// The test worker: instantiates the tests on shared memory and runs them, starting each thread they create on a worker from thread.mjs.
import { ConsoleStdout, File, OpenDirectory, OpenFile, PreopenDirectory, WASI, wasi as defs } from "./node_modules/@bjorn3/browser_wasi_shim/dist/index.js";
import { WASIThreads } from "./node_modules/@emnapi/wasi-threads/dist/wasi-threads.js";
import { channelName, onMessage, spawn } from "./env.mjs";

// The shim ignores the rights a file was opened with; enforce them so reading or writing a descriptor opened the wrong way fails.
// wasi-libc opens a file with only the rights its directory lets it inherit, which the shim reports as none.
const allRights = (1n << 64n) - 1n;
const directoryStat = OpenDirectory.prototype.fd_fdstat_get;
OpenDirectory.prototype.fd_fdstat_get = function () {
	const stat = directoryStat.call(this);
	stat.fdstat.fs_rights_base = stat.fdstat.fs_rights_inherited = allRights;
	return stat;
};
const fileStat = OpenFile.prototype.fd_fdstat_get;
OpenFile.prototype.fd_fdstat_get = function () {
	const stat = fileStat.call(this);
	stat.fdstat.fs_rights_base = this.rights ?? allRights;
	return stat;
};
const openFile = File.prototype.path_open;
File.prototype.path_open = function (oflags, rightsBase, fdFlags) {
	const opened = openFile.call(this, oflags, rightsBase, fdFlags);
	if (opened.fd_obj) opened.fd_obj.rights = BigInt(rightsBase);
	return opened;
};
const lacks = (fd, right) => fd.rights !== undefined && (fd.rights & BigInt(right)) === 0n;
for (const [name, right, refusal] of [
	["fd_read", defs.RIGHTS_FD_READ, { ret: defs.ERRNO_BADF, data: new Uint8Array() }],
	["fd_pread", defs.RIGHTS_FD_READ, { ret: defs.ERRNO_BADF, data: new Uint8Array() }],
	["fd_write", defs.RIGHTS_FD_WRITE, { ret: defs.ERRNO_BADF, nwritten: 0 }],
	["fd_pwrite", defs.RIGHTS_FD_WRITE, { ret: defs.ERRNO_BADF, nwritten: 0 }],
]) {
	const original = OpenFile.prototype[name];
	OpenFile.prototype[name] = function (...args) {
		return lacks(this, right) ? refusal : original.apply(this, args);
	};
}

// Limits of the shared memory the module imports, in 64 KiB pages; tools/wasi.py links with the same maximum.
const initialPages = 256;
const maximumPages = 16384;

const channel = new BroadcastChannel(channelName);
const say = (stream) => (line) => channel.postMessage({ stream, line });

onMessage(async ({ module }) => {
	try {
		// An empty in-memory /tmp for the file tests, which threads do not share. Without `debug: false` the shim logs every path it opens.
		const wasi = new WASI(["libfp-tests"], [], [new OpenFile(new File([])), ConsoleStdout.lineBuffered(say("stdout")), ConsoleStdout.lineBuffered(say("stderr")), new PreopenDirectory("/tmp", new Map())], { debug: false });
		const threads = new WASIThreads({
			wasi,
			// A browser starts a worker only once its creator yields, so workers are started up front and reused rather than started inside `pthread_create`.
			reuseWorker: { size: 8, strict: false },
			waitThreadStart: 1000,
			onCreateWorker: () => spawn(new URL("./thread.mjs", import.meta.url)),
		});
		const memory = new WebAssembly.Memory({ initial: initialPages, maximum: maximumPages, shared: true });
		const instance = await WebAssembly.instantiate(module, {
			env: { memory },
			wasi_snapshot_preview1: wasi.wasiImport,
			...threads.getImportObject(),
		});
		threads.setup(instance, module, memory);
		await threads.preloadWorkers();
		let code;
		try {
			code = wasi.start(instance);
		} catch (e) {
			// wasi-libc's `abort` is a trap, which WASI does not turn into an exit status.
			if (!(e instanceof WebAssembly.RuntimeError)) throw e;
			channel.postMessage({ trap: e.message });
			return;
		}
		channel.postMessage({ exit: code });
	} catch (e) {
		channel.postMessage({ error: String(e?.stack ?? e) });
	}
});

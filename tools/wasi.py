#!/usr/bin/env python3
"""Builds the unittests for wasm32-wasi with threads and runs them in a browser, or headlessly under Node, through @tybys/wasm-util's WASI and @emnapi/wasi-threads.

The build links against a wasi-sdk sysroot and compiler-rt builtins, downloaded once into bin/wasi-sdk unless WASI_SYSROOT and WASI_BUILTINS name local copies. It links with `wasm-ld` from PATH (or WASM_LD), falling back to LDC's internal linker.

Usage:
  tools/wasi.py            build bin/wasi/libfp-tests.wasm and the page that runs it
  tools/wasi.py --serve    ... then serve bin/wasi on http://localhost:8000 to open in a browser
  tools/wasi.py --node     ... then run the same page script under Node, exiting with the tests' status
"""
import argparse, functools, http.server, os, shutil, subprocess, sys, tarfile, urllib.request

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, 'bin', 'wasi')
sdk = os.path.join(root, 'bin', 'wasi-sdk')
page = os.path.join(root, 'tests', 'wasi')
compiler = os.environ.get('DC', 'ldc2')
wasm = os.path.join(out, 'libfp-tests.wasm')

sdkVersion = '34'
release = f'https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-{sdkVersion}/'
target = 'wasm32-wasip1-threads'
# Must match maximumPages in tests/wasi/main.mjs, which creates the shared memory the module imports.
maxMemory = 16384 * 65536
packages = ['@tybys/wasm-util@0.10.4', '@emnapi/wasi-threads@2.2.0']


def fetch(name):
	"""Downloads and unpacks a wasi-sdk release archive into bin/wasi-sdk, unless already there, and returns where it unpacked."""
	dest = os.path.join(sdk, name)
	if not os.path.isdir(dest):
		os.makedirs(sdk, exist_ok=True)
		archive = dest + '.tar.gz'
		print(f'downloading {name}', file=sys.stderr)
		urllib.request.urlretrieve(release + name + '.tar.gz', archive)
		with tarfile.open(archive) as tar:
			tar.extractall(sdk, filter='data')
		os.remove(archive)
	return dest


def build():
	sysroot = os.environ.get('WASI_SYSROOT') or fetch(f'wasi-sysroot-{sdkVersion}.0')
	builtins = os.environ.get('WASI_BUILTINS') or os.path.join(
		fetch(f'libclang_rt-{sdkVersion}.0'), 'wasm32-unknown-wasip1-threads', 'libclang_rt.builtins.a')
	libs = os.path.join(sysroot, 'lib', target)

	sources = [os.path.join('source', 'fp', f) for f in sorted(os.listdir(os.path.join(root, 'source', 'fp'))) if f.endswith('.d')]
	os.makedirs(out, exist_ok=True)
	compile = [compiler, '-mtriple=wasm32-unknown-wasi', '-mattr=+atomics,+bulk-memory', '-betterC', '-checkaction=C', '-unittest',
		'-Isource', '-Itests', '-od=' + out, *sources, os.path.join('tests', 'runner.d')]
	# The long-double archive replaces libc's printf, so it must come first; D's `real` is a 128-bit long double here.
	# @emnapi/wasi-threads calls the exported malloc and free to pass each spawned thread its id.
	linkArgs = [os.path.join(libs, 'crt1-command.o'), '-L' + libs, '-lc-printscan-long-double', '-lc', builtins,
		'--import-memory', '--export-memory', '--shared-memory', f'--max-memory={maxMemory}',
		'--export=malloc', '--export=free']

	linker = os.environ.get('WASM_LD') or shutil.which('wasm-ld')
	if linker:
		obj = os.path.join(out, 'libfp-tests.o')
		subprocess.run([*compile, '-c', '-of=' + obj], cwd=root, check=True)
		subprocess.run([linker, '-o', wasm, *linkArgs, obj], cwd=root, check=True)
	else:
		subprocess.run([*compile, '--link-internally', '-of=' + wasm, *('-L' + a for a in linkArgs)], cwd=root, check=True)

	for f in os.listdir(page):
		shutil.copy(os.path.join(page, f), out)
	install()


def install():
	"""Installs the WASI packages beside the page scripts, which import them by relative path in the browser and Node alike."""
	if not all(os.path.isdir(os.path.join(out, 'node_modules', *p.rpartition('@')[0].split('/'))) for p in packages):
		subprocess.run(['npm', 'install', '--no-save', '--no-package-lock', '--prefix', out, *packages],
			check=True, shell=os.name == 'nt')


class IsolatedHandler(http.server.SimpleHTTPRequestHandler):
	"""Serves with the headers that make a page cross-origin isolated, without which a browser offers no shared memory."""
	def end_headers(self):
		self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
		self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
		super().end_headers()


def serve(port):
	handler = functools.partial(IsolatedHandler, directory=out)
	with http.server.ThreadingHTTPServer(('localhost', port), handler) as server:
		print(f'open http://localhost:{port}/ to run the tests (Ctrl+C stops the server)', file=sys.stderr)
		try:
			server.serve_forever()
		except KeyboardInterrupt:
			pass


def runNode():
	return subprocess.run(['node', os.path.join(out, 'node.mjs'), wasm]).returncode


def main():
	parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
	mode = parser.add_mutually_exclusive_group()
	mode.add_argument('--serve', nargs='?', const=8000, type=int, metavar='PORT', help='serve the test page for a browser')
	mode.add_argument('--node', action='store_true', help='run the tests under Node')
	args = parser.parse_args()

	build()
	if args.serve:
		serve(args.serve)
	elif args.node:
		sys.exit(runNode())


if __name__ == '__main__':
	main()

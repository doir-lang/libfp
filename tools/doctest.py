#!/usr/bin/env python3
"""Checks libfp's DDoc against AGENTS.md: every `---` example compiles and passes under -betterC, and every public definition is documented, with an example if it is a function.

Each example becomes a unittest in a generated module that imports only the module it documents, as a user would: outside package `fp`, unless it documents a `package` definition. `#line` directives point failures back at the example's line in the source.

Usage: tools/doctest.py    (set DC to use a compiler other than ldc2)
"""
import glob, os, re, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, 'bin', 'doctest')
compiler = os.environ.get('DC', 'ldc2')
exe = os.path.join(out, 'doctests' + ('.exe' if os.name == 'nt' else ''))


def ddoc_blocks(lines):
	"""Yields (end, body) for each DDoc comment: the index of the line after it, and its (line number, text) pairs."""
	i = 0
	while i < len(lines):
		s = lines[i].strip()
		if s.startswith('///'):
			body = []
			while i < len(lines) and lines[i].strip().startswith('///'):
				t = lines[i].strip()[3:]
				body.append((i + 1, t[1:] if t.startswith(' ') else t))
				i += 1
			yield i, body
		elif s.startswith('/**') and not s.startswith('/**/'):
			body = []
			first = s[3:]
			if first.endswith('*/'):
				yield i + 1, [(i + 1, first[:-2].strip())]
				i += 1
				continue
			if first.strip():
				body.append((i + 1, first.strip()))
			i += 1
			while i < len(lines) and '*/' not in lines[i]:
				body.append((i + 1, re.sub(r'^\s*\*\s?', '', lines[i])))
				i += 1
			yield i + 1, body
			i += 1
		else:
			i += 1


def is_function(decl):
	if decl.startswith(('struct', 'enum', 'alias', 'module', 'package struct', 'package enum')):
		return decl.startswith('struct') and '(' in decl.split('{')[0]
	if '=' in decl.split('(')[0]:
		return False
	return decl.startswith(('mixin template', 'pragma(inline')) or bool(
		re.match(r'(package\s+|extern\s*\(C\)\s*)?[\w!().\[\]* ]+?\s+\w+(\([^)]*\))?\(', decl))


def check(path, lines, problems, examples):
	documented = set()
	for end, body in ddoc_blocks(lines):
		j = end
		while j < len(lines) and not lines[j].strip():
			j += 1
		documented.add(j)
		decl = lines[j].strip() if j < len(lines) else ''
		k = j
		while k < len(lines) and lines[k].strip().startswith('pragma('):
			k += 1
		package = k < len(lines) and lines[k].strip().startswith('package')
		found = []
		code = None
		for line, text in body:
			if text.strip() == '---':
				if code is None:
					code = (line + 1, [], package)
				else:
					found.append(code)
					code = None
			elif code is not None:
				code[1].append(text)
		ditto = any(t.strip().lower().startswith('ditto') for _, t in body)
		if is_function(decl) and not found and not ditto:
			problems.append(f'{path}:{j + 1}: documented without an example: {decl}')
		examples += found

	# A top-level declaration with no DDoc directly above it (past any pragma).
	skip = ('//', '/*', '*', 'import', 'static import', 'public import', 'module', 'unittest', '}', '@nogc', 'version',
		'private', 'else', '{', '~', '"', ')', ';', 'pragma(inline', 'shared static')
	depth = 0
	for k, line in enumerate(lines):
		s = line.strip()
		if depth == 0 and s and not s.startswith(skip) and re.match(r'[\w(]', s) and k not in documented:
			prev = k - 1
			while prev >= 0 and lines[prev].strip().startswith('pragma('):
				prev -= 1
			above = lines[prev].strip() if prev >= 0 else ''
			if not (above.startswith('///') or above.endswith('*/')):
				problems.append(f'{path}:{k + 1}: undocumented: {s}')
		depth += line.count('{') - line.count('}')


def main():
	os.makedirs(out, exist_ok=True)
	for old in glob.glob(os.path.join(out, '*.d')):
		os.remove(old)

	sources = sorted(glob.glob(os.path.join(root, 'source', 'fp', '*.d')))
	modules = []
	problems = []
	generated = []
	for path in sources:
		text = open(path, encoding='utf-8').read()
		module = re.search(r'^module\s+([\w.]+);', text, re.M).group(1)
		modules.append(module)
		relative = os.path.relpath(path, root).replace(os.sep, '/')
		examples = []
		check(relative, text.split('\n'), problems, examples)
		for package, prefix in ((False, 'doctest_'), (True, 'fp.doctest_')):
			chosen = [(line, code) for line, code, inside in examples if inside == package]
			if not chosen:
				continue
			name = prefix + module.replace('.', '_')
			generated.append(name)
			body = [f'module {name};', f'import {module};']
			body += [f'static import {m};' for m in modules_in(sources) if m not in (module, 'fp')]
			for k, (line, code) in enumerate(chosen):
				# A distinct line per unittest keeps their generated names apart.
				body.append(f'#line {100000 + 1000 * k} "doctest"')
				body.append('unittest {')
				body.append(f'#line {line} "{relative}"')
				body += code
				body.append('}')
			open(os.path.join(out, name.replace('.', '_') + '.d'), 'w', encoding='utf-8').write('\n'.join(body) + '\n')

	runner = ['module doctest_runner;', 'import core.stdc.stdio : printf;']
	runner += [f'static import {n};' for n in generated]
	runner += ['extern(C) int main() {', '\tint total = 0;']
	runner += [f'\tforeach (test; __traits(getUnitTests, {n})) {{ test(); ++total; }}' for n in generated]
	runner += ['\tprintf("doctest: all %d examples passed.\\n", total);', '\treturn 0;', '}']
	open(os.path.join(out, 'doctest_runner.d'), 'w', encoding='utf-8').write('\n'.join(runner) + '\n')

	for problem in problems:
		print(problem)

	command = [compiler, '-betterC', '-checkaction=C', '-unittest', '-I' + os.path.join(root, 'source'), '-I' + out,
		'-of=' + exe] + sources + sorted(glob.glob(os.path.join(out, '*.d')))
	if subprocess.run(command, cwd=root).returncode != 0:
		return 1
	if subprocess.run([exe], cwd=root).returncode != 0:
		return 1
	if problems:
		print(f'doctest: {len(problems)} documentation problems')
		return 1
	return 0


def modules_in(sources):
	return [re.search(r'^module\s+([\w.]+);', open(p, encoding='utf-8').read(), re.M).group(1) for p in sources]


if __name__ == '__main__':
	sys.exit(main())

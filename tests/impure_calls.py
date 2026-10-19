#!/usr/bin/env python3
"""Pure implementations called with `!`: sequencing, lookup, and purity."""
import argparse
import os
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--dream', default='build-dream/bin/dream')
parser.add_argument('--compiler', default='build/dreams.dream')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[2]
vm = str(pathlib.Path(args.dream).resolve())
compiler = str(pathlib.Path(args.compiler).resolve())


def run(*cmd, **options):
    return subprocess.run(cmd, text=True, capture_output=True, timeout=120, **options)


with tempfile.TemporaryDirectory(prefix='dream-impure-calls-') as directory:
    temp = pathlib.Path(directory)
    source = temp / 'main.dr'
    image = temp / 'main.dream'

    def compile_source(text, *flags):
        source.write_text(text)
        return run(vm, compiler, '-L', str(root / 'mind'), '-L', str(temp),
                   *flags, '-o', str(image), str(source))

    fixture = (root / 'dream/tests/programs/impure_calls.dr').read_text()
    expected = (root / 'dream/tests/programs/impure_calls.expected').read_text()
    for flags in ((), ('--no-opt',), ('--release',),
                  ('--units', str(temp / 'units')), ('--units', str(temp / 'units'))):
        compiled = compile_source(fixture, *flags)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        for jit in (('--no-jit',), ('--jit-threshold', '1')):
            result = run(vm, *jit, str(image), env={**os.environ, 'DREAM_JIT_SYNC': '1'})
            assert result.returncode == 0 and result.stdout == expected, result.stdout + result.stderr

    for mode in ('--check', '--no-emit', '--ir'):
        compiled = compile_source(fixture, mode)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr

    (temp / 'library.dr').write_text(
        'let f : :integer -> :integer; let f x = x + 1; '
        'let both x = :pure; let both! x = :explicit; '
        'priv let hidden x = x;')
    cases = [
        ('import library; let main! = console.print! (library.f! 2);', '3\n'),
        ('import library.{f}; let main! = console.print! (f! 2);', '3\n'),
        ('import library.{f as renamed}; let main! = console.print! (renamed! 2);', '3\n'),
        ('import library.{f!}; let main! = console.print! (f! 2);', '3\n'),
        ('import library.f! as renamed!; let main! = console.print! (renamed! 2);', '3\n'),
        ('import library; let main! = console.print! (library.both! ());', ':explicit\n'),
        ('import library.{both!}; let both x = :local; '
         'let main! = console.print! (both! ());', ':explicit\n'),
        ('import std.list; let main! = { let map f xs = :local; '
         'console.print! (map! (fn x -> x) [1]) };', ':local\n'),
        ('let main! = { let f x = x + 1; let f! x = x + 2; '
         'console.print! (f! 3) };', '5\n'),
    ]
    for body, wanted in cases:
        compiled = compile_source('import std.console; ' + body)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        result = run(vm, str(image))
        assert result.returncode == 0 and result.stdout == wanted, result.stdout + result.stderr

    # Adding or removing an explicit effectful definition invalidates a cached
    # fallback, including the other module's member table.
    for explicit, wanted in [('', '3\n'), ('let f! x = 42;', '42\n'), ('', '3\n')]:
        (temp / 'library.dr').write_text('let f x = x + 1; ' + explicit)
        compiled = compile_source('import std.console; import library; '
                                  'let main! = console.print! (library.f! 2);',
                                  '--units', str(temp / 'edits'))
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        result = run(vm, str(image))
        assert result.returncode == 0 and result.stdout == wanted, result.stdout + result.stderr

    (temp / 'library.dr').write_text(
        'let f : :integer -> :integer; let f x = x + 1; priv let hidden x = x;')

    for body, error in [
        ('let f x = x; let bad x = f! x;', 'inside the pure function `bad`'),
        ('import library; let bad x = library.f! x;', 'inside the pure function `bad`'),
        ('import library.{f as renamed}; let bad x = renamed! x;', 'inside the pure function `bad`'),
        ('let bad f = f! 1;', 'inside the pure function `bad`'),
        ('let bad x = len! x;', 'inside the pure function `bad`'),
        ('import std.math; let bad x = math.abs! x;', 'inside the pure function `bad`'),
        ('let bad host = host.abs! 1;', 'inside the pure function `bad`'),
        ('import library.{f! as callback}; let bad x = callback x;', 'inside the pure function `bad`'),
        ('import library; let main! = library.hidden! 1;', 'is private'),
        ('import library.{hidden!}; let main! = ();', 'is private'),
        ('let main! = missing! 1;', 'cannot find `missing!`'),
        ('import library; let main! = library.missing! 1;', 'has no member `missing!`'),
        ('import library; let main! = library.f! "wrong";', 'argument'),
        ('let run! : (:integer -> :integer) -> :integer; '
         'let run! f = f! "wrong"; let main! = ();', 'argument'),
    ]:
        compiled = compile_source(body)
        message = compiled.stdout + compiled.stderr
        assert compiled.returncode != 0 and error in message, message

print('impure calls of pure functions passed (lookup, sequencing, purity, interpreter and JIT)')

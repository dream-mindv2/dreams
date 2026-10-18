#!/bin/sh
# The supercompiler must change what a program costs and nothing it does.
# Run twice: through its translation alone, IR to core and back with nothing
# done in between (`--sc-roundtrip`, dreams/src/sc.dr), and through the
# driver (`--supercompile`, dreams/src/drive.dr). Either way every example
# built through it prints what it is recorded to, and the compiler built
# through it compiles itself to the same bytes as the compiler that was not.
# The second is the stronger check -- the compiler is most of the language's
# constructs, run over a large input -- and it is also the one that found a
# strict parameter turned lazy, which every example passed.
# See dreams/docs/notes/supercompilation.md.
set -u

dream=${dream:-build-dream/bin/dream}
image=${image:-build/dreams.dream}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
pass=0

for flag in --sc-roundtrip --supercompile; do
for src in examples/*.dr; do
    expected="${src%.dr}.expected"
    [ -f "$expected" ] || continue
    name=$(basename "$src" .dr)
    if ! "$dream" "$image" $flag -o "$tmp/out.dream" -L mind -L examples "$src" >"$tmp/build" 2>&1; then
        echo "FAIL $name $flag (did not compile)"
        sed 's/^/    /' "$tmp/build" | head -4
        fail=$((fail + 1))
    elif ! "$dream" "$tmp/out.dream" >"$tmp/run" 2>&1 \
         || ! diff -q "$expected" "$tmp/run" >/dev/null 2>&1; then
        echo "FAIL $name $flag (output)"
        diff "$expected" "$tmp/run" | sed 's/^/    /' | head -6
        fail=$((fail + 1))
    else
        echo "ok   $name $flag"
        pass=$((pass + 1))
    fi
done

if "$dream" "$image" $flag -L mind -L . -o "$tmp/rt.dream" dreams/src/main.dr >"$tmp/b1" 2>&1 &&
   "$dream" "$image" -L mind -L . -o "$tmp/plain.dream" dreams/src/main.dr >"$tmp/b2" 2>&1 &&
   "$dream" "$tmp/rt.dream" -L mind -L . -o "$tmp/by_rt.dream" dreams/src/main.dr >"$tmp/b3" 2>&1 &&
   cmp -s "$tmp/plain.dream" "$tmp/by_rt.dream"; then
    echo "ok   the compiler, built $flag, compiles itself to the same bytes"
    pass=$((pass + 1))
else
    echo "FAIL the compiler, built $flag, does not compile itself to the same bytes"
    cat "$tmp/b1" "$tmp/b2" "$tmp/b3" 2>/dev/null | grep -v '^compiled' | sed 's/^/    /' | head -8
    fail=$((fail + 1))
fi
done

# What the driver is for: programs it must make cheaper, not only keep the
# same. Each is held to its recorded output, and to a fraction of the
# reductions it runs as written -- half, or what its `.ratio` says as `N D`
# -- counted with the JIT off, where the count is the same from run to run.
# With the JIT on the gain is larger, since what is left is a loop the JIT
# takes, but that count moves with when the JIT gets to it.
reductions() { "$dream" --no-jit --stats "$1" 2>&1 >/dev/null | sed -n 's/^; \([0-9]*\) reductions.*/\1/p'; }
for src in dreams/tests/sc/*.dr; do
    name=$(basename "$src" .dr)
    expected="${src%.dr}.expected"
    if "$dream" "$image" -L mind -o "$tmp/plain.dream" "$src" >"$tmp/b1" 2>&1 &&
       "$dream" "$image" --supercompile -L mind -o "$tmp/sc.dream" "$src" >"$tmp/b2" 2>&1 &&
       "$dream" "$tmp/sc.dream" >"$tmp/run" 2>&1 && diff -q "$expected" "$tmp/run" >/dev/null; then
        plain=$(reductions "$tmp/plain.dream")
        driven=$(reductions "$tmp/sc.dream")
        ratio="1 2"
        [ -f "${src%.dr}.ratio" ] && ratio=$(cat "${src%.dr}.ratio")
        set -- $ratio
        if [ "$((driven * $2))" -le "$((plain * $1))" ]; then
            echo "ok   $name: $plain -> $driven reductions"
            pass=$((pass + 1))
        else
            echo "FAIL $name: $plain -> $driven reductions, more than $1/$2"
            fail=$((fail + 1))
        fi
    else
        echo "FAIL $name (did not build or run as recorded)"
        cat "$tmp/b1" "$tmp/b2" "$tmp/run" 2>/dev/null | grep -v '^compiled' | sed 's/^/    /' | head -6
        fail=$((fail + 1))
    fi
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

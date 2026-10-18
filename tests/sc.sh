#!/bin/sh
# The supercompiler's translation, IR to core and back with nothing done in
# between (`--sc-roundtrip`, dreams/src/sc.dr), must be no change at all:
# every example built through it prints what it is recorded to, and the
# compiler built through it compiles itself to the same bytes as the compiler
# that was not. The second is the stronger check -- the compiler is most of
# the language's constructs, run over a large input -- and it is also the
# one that found a strict parameter turned lazy, which every example passed.
# See milestone 1 in dreams/docs/notes/supercompilation.md.
set -u

dream=${dream:-build-dream/bin/dream}
image=${image:-build/dreams.dream}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
pass=0

for src in examples/*.dr; do
    expected="${src%.dr}.expected"
    [ -f "$expected" ] || continue
    name=$(basename "$src" .dr)
    if ! "$dream" "$image" --sc-roundtrip -o "$tmp/out.dream" -L mind -L examples "$src" >"$tmp/build" 2>&1; then
        echo "FAIL $name (did not compile)"
        sed 's/^/    /' "$tmp/build" | head -4
        fail=$((fail + 1))
    elif ! "$dream" "$tmp/out.dream" >"$tmp/run" 2>&1 \
         || ! diff -q "$expected" "$tmp/run" >/dev/null 2>&1; then
        echo "FAIL $name (output)"
        diff "$expected" "$tmp/run" | sed 's/^/    /' | head -6
        fail=$((fail + 1))
    else
        echo "ok   $name"
        pass=$((pass + 1))
    fi
done

if "$dream" "$image" --sc-roundtrip -L mind -L . -o "$tmp/rt.dream" dreams/src/main.dr >"$tmp/b1" 2>&1 &&
   "$dream" "$image" -L mind -L . -o "$tmp/plain.dream" dreams/src/main.dr >"$tmp/b2" 2>&1 &&
   "$dream" "$tmp/rt.dream" -L mind -L . -o "$tmp/by_rt.dream" dreams/src/main.dr >"$tmp/b3" 2>&1 &&
   cmp -s "$tmp/plain.dream" "$tmp/by_rt.dream"; then
    echo "ok   the compiler, round-tripped, compiles itself to the same bytes"
    pass=$((pass + 1))
else
    echo "FAIL the compiler, round-tripped, does not compile itself to the same bytes"
    cat "$tmp/b1" "$tmp/b2" "$tmp/b3" 2>/dev/null | grep -v '^compiled' | sed 's/^/    /' | head -8
    fail=$((fail + 1))
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

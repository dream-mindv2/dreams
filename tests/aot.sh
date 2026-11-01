#!/usr/bin/env bash
# `dreams --aot`: the runtime dialect by itself, and ordinary Dream on the runtime.
# Each program is compiled to an executable, run, and held to its output and exit
# status, and what cannot be compiled must be refused with no executable left behind.
# An executable naming libdream, or written beside a stray image, fails.
#
# Needs only the VM and the seed; `image` overrides the compiler under test.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
dream="${DREAM:-$root/build-dream/bin/dream}"
image="${image:-$root/build/dreams.dream}"
# Absolute, because a recipe passes them relative and this runs from a directory
# of its own.
dream="$(realpath "$dream")"
image="$(realpath "$image")"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
cd "$dir" || exit 1
failed=0

fail() { echo "aot: $1"; failed=1; }
compile() { DREAMS_CACHE= timeout 120 "$dream" "$image" --aot -L "$root/mind" "$@" 2>"$dir/said"; }

cat > print.dr <<'DR'
import rt.prim;

let digits! buf !at !n = {
    prim.store8! (buf + at) (48 + n % 10);
    if n < 10 { at } else { digits! buf (at - 1) (n / 10) }
};
let fact !n = if n < 2 { 1 } else { n * fact (n - 1) };
let main! () = {
    let buf = prim.c1! "malloc" 32;
    prim.c3! "write" 1 "fact 10 = " (prim.str_len "fact 10 = ");
    prim.store8! (buf + 31) 10;
    let from = digits! buf 30 (fact 10);
    prim.c3! "write" 1 (buf + from) (32 - from);
    0
};
DR
compile -o print print.dr || fail "print did not compile: $(cat said)"
[[ "$(timeout 10 ./print)" == "fact 10 = 3628800" ]] || fail "print printed the wrong thing"
[[ ! -e print.image ]] || fail "the intermediate image was left behind"
if command -v ldd >/dev/null && ldd ./print | grep -q libdream; then fail "print needs libdream"; fi

# A loop a real call would overflow on, with a stack it cannot hide in, and a body
# with an effect so that LLVM cannot answer it without running it.
cat > deep.dr <<'DR'
import rt.prim;

let ping! buf !i !n = if i >= n { 0 } else { prim.store64! buf i; pong! buf (i + 1) n };
let pong! buf !i !n = ping! buf i n;
let main! () = {
    let buf = prim.c1! "malloc" 8;
    ping! buf 0 3000000;
    prim.load64! buf % 251
};
DR
compile -o deep deep.dr || fail "deep did not compile: $(cat said)"
(ulimit -s 256; timeout 20 ./deep); [[ $? == $((2999999 % 251)) ]] || fail "deep: a tail call grew the stack"

# Short circuits, nested arms and each arithmetic family, by exit status.
cat > arith.dr <<'DR'
import rt.prim;

let boom! () = prim.c1! "exit" 99;
let pick !a !b = if a < b { if a == 0 { 1 } else { 2 } } else { 3 };
let main! () = {
    let right = false && boom! () == 0;
    let left = true || boom! () == 0;
    let bits = (6 & 3) + (6 | 1) + (5 ^ 1) + (1 << 3) + (16 >> 2);
    let cmp = prim.ult (0 - 1) 1 + prim.ushr (0 - 1) 63 + prim.sext32 4294967295;
    (if right { 50 } else { 0 }) + (if left { 1 } else { 50 }) + pick 0 1 + pick 1 2 + pick 2 1
        + bits + cmp + 7 / 2 + 7 % 2
};
DR
compile -o arith arith.dr || fail "arith did not compile: $(cat said)"
timeout 10 ./arith; answer=$?
[[ $answer == 36 ]] || fail "arith answered $answer, not 36"

# An image made elsewhere is an input in its own right.
DREAMS_CACHE= timeout 60 "$dream" "$image" -L "$root/mind" --host-module rt.prim -o made.dream print.dr 2>said || fail "no image"
compile -o from_image made.dream || fail "an image did not compile: $(cat said)"
[[ "$(timeout 10 ./from_image)" == "fact 10 = 3628800" ]] || fail "from_image printed the wrong thing"

# In the dialect, what needs the heap is refused, naming the function, leaving
# nothing behind.
cat > heap.dr <<'DR'
import rt.prim;
let main! () = { let pair = [1, 2]; 0 };
DR
if compile -o heap heap.dr; then fail "a list was accepted in the dialect"; fi
grep -q "main!: opcode 36" said || fail "the refusal did not name main!: $(cat said)"
[[ ! -e heap && ! -e heap.image ]] || fail "a refused build left something behind"

# Ordinary Dream, on the runtime: what it does not have yet is refused the same way.
cat > later.dr <<'DR'
let main! () = try! { 1 } catch e { 2 };
DR
if compile -o later later.dr; then fail "try! was accepted before it is built"; fi
grep -q "is not compiled yet" said || fail "the refusal did not say why: $(cat said)"

# A lazy list consumed as it is built must not be pinned, a list that is held must
# survive being copied, and recursion is bounded by memory, not a machine stack.
cat > collect.dr <<'DR'
import std.console;
let range !a !b = if a >= b { [] } else { a :: range (a + 1) b };
let sum xs !acc = match xs { [] => acc, [x, ..r] => sum r (acc + x) };
let deep n = if n == 0 { 0 } else { 1 + deep (n - 1) };
let main! () = {
    console.print! (sum (range 0 5000000) 0);
    let held = range 0 1000000;
    console.print! (sum held 0);
    console.print! (sum held 0);
    console.print! (deep 2000000);
    console.print! [:a, "s", 'c', 1, true, ()];
};
DR
compile -o collect collect.dr || fail "collect did not compile: $(cat said)"
[[ ! -e collect.lib.image && ! -e collect.rt.image ]] || fail "the runtime's images were left behind"
if command -v ldd >/dev/null && ldd ./collect | grep -q libdream; then fail "collect needs libdream"; fi
(ulimit -s 256; ulimit -v 12000000; timeout 60 ./collect) > collected
cat > collect.expected <<'OUT'
12499997500000
499999500000
499999500000
2000000
[:a, "s", 'c', 1, true, ()]
OUT
diff collected collect.expected >/dev/null || fail "collect printed: $(cat collected)"

[[ $failed == 0 ]] && echo "aot: ok"
exit $failed

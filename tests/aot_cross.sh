#!/usr/bin/env bash
# `dreams --aot --target aarch64` on an x86-64 machine, run under qemu: every recorded program, and
# std.ffi against the C sample library cross-compiled. The VM must be built with DREAM_AOT_CROSS
# (dream/CMakeLists.txt) so that its LLVM can write aarch64.
#
# It needs qemu-aarch64, an aarch64 glibc to run against and an aarch64 C compiler for the sample
# library. Each is taken from the environment, or from nixpkgs where there is a `nix-build`, and the
# script skips, saying which, when one cannot be found:
#
#   QEMU_AARCH64=qemu-aarch64 AARCH64_SYSROOT=/usr/aarch64-linux-gnu AARCH64_CC=aarch64-linux-gnu-gcc \
#       dreams/tests/aot_cross.sh [PATTERN]
#
# What it cannot test is memory order: qemu running on x86-64 keeps the host's, which is stronger than
# aarch64's, so the barriers the runtime has for aarch64 are only exercised on aarch64 itself.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
dream="$(realpath "${DREAM:-$root/build-dream/bin/dream}")"
image="$(realpath "${image:-$root/build/dreams.dream}")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

from_nix() { command -v nix-build >/dev/null 2>&1 && timeout 900 nix-build '<nixpkgs>' -A "$1" --no-out-link 2>/dev/null | tail -1; }

qemu="${QEMU_AARCH64:-$(command -v qemu-aarch64 || true)}"
[[ -z "$qemu" ]] && { q=$(from_nix qemu-user); [[ -n "$q" ]] && qemu="$q/bin/qemu-aarch64"; }
glibc="${AARCH64_SYSROOT:-}"
[[ -z "$glibc" ]] && glibc=$(from_nix pkgsCross.aarch64-multiplatform.glibc)
cc="${AARCH64_CC:-}"
[[ -z "$cc" ]] && { c=$(from_nix pkgsCross.aarch64-multiplatform.stdenv.cc); [[ -n "$c" ]] && cc="$c/bin/aarch64-unknown-linux-gnu-gcc"; }
[[ -x "$qemu" ]] || { echo "skip aot_cross: no qemu-aarch64"; exit 0; }
[[ -d "$glibc/lib" ]] || { echo "skip aot_cross: no aarch64 glibc (AARCH64_SYSROOT)"; exit 0; }

# The loader and libc where qemu looks for them: a sysroot whose `lib` holds the glibc's.
mkdir -p "$tmp/sysroot/lib"
ln -sf "$glibc"/lib/* "$tmp/sysroot/lib/"
runner="$qemu -L $tmp/sysroot -E LD_LIBRARY_PATH=/lib"

# Whether this VM can write aarch64 at all.
printf 'import std.console;\nlet main! = console.print! "hello";\n' > "$tmp/h.dr"
if ! DREAMS_CACHE= timeout 300 "$dream" "$image" --aot --target aarch64 -L "$root/mind" -o "$tmp/h" "$tmp/h.dr" >"$tmp/said" 2>&1; then
    if grep -q "unable to get target" "$tmp/said"; then echo "skip aot_cross: this VM was built without DREAM_AOT_CROSS"; exit 0; fi
    echo "aot_cross: hello did not build"; cat "$tmp/said"; exit 1
fi
[[ "$($runner "$tmp/h")" == "hello" ]] || { echo "aot_cross: hello did not run"; exit 1; }

failed=0
AOT_FLAGS="--target aarch64" AOT_RUNNER="$runner" "$here/aot_programs.sh" "${1:-}" > "$tmp/programs" 2>&1
cat "$tmp/programs"
grep -q " 0 wrong, 0 refused" "$tmp/programs" || failed=1

if [[ -n "$cc" && -x "$cc" ]]; then
    ffi="$root/dream/tests/ffi"
    "$cc" -shared -fPIC -O2 -o "$tmp/libsample.so" "$ffi/sample.c" \
        && "$dream" "$image" -L "$root/mind" --payload "sample=$tmp/libsample.so" -o "$tmp/ffi.dream" "$ffi/src/ffi.dr" >"$tmp/said" 2>&1 \
        && "$dream" "$image" --aot --target aarch64 -L "$root/mind" -o "$tmp/ffi" "$tmp/ffi.dream" >>"$tmp/said" 2>&1 \
        || { echo "aot_cross: the ffi test did not build"; cat "$tmp/said"; failed=1; }
    if [[ -x "$tmp/ffi" ]]; then
        timeout 60 $runner "$tmp/ffi" > "$tmp/ffi.out" 2>&1
        if diff -q "$tmp/ffi.out" "$ffi/ffi.expected" >/dev/null; then echo "aot_cross: ffi ok"
        else echo "aot_cross: ffi printed:"; diff "$ffi/ffi.expected" "$tmp/ffi.out" | head -20; failed=1; fi
    fi
else
    echo "skip aot_cross ffi: no aarch64 C compiler (AARCH64_CC)"
fi

# TLS: OpenSSL for aarch64 beside the glibc, found as a native program finds it, by
# DREAM_LIBRARY_PATH, and both suites held to what the VM prints.
ssl="${AARCH64_OPENSSL:-}"
[[ -z "$ssl" ]] && ssl=$(from_nix pkgsCross.aarch64-multiplatform.openssl.out)
if [[ -d "$ssl/lib" ]]; then
    tls_dir="$root/dream/tests/tls"
    for suite in tls http; do
        "$dream" "$image" -L "$root/mind" -o "$tmp/$suite.dream" "$tls_dir/$suite.dr" >"$tmp/said" 2>&1 || { echo "aot_cross: $suite did not compile"; failed=1; continue; }
        timeout 120 "$dream" "$tmp/$suite.dream" "$tls_dir" > "$tmp/$suite.vm" 2>&1
        "$dream" "$image" --aot --target aarch64 -L "$root/mind" -o "$tmp/$suite" "$tmp/$suite.dream" >"$tmp/said" 2>&1 || { echo "aot_cross: $suite did not build"; failed=1; continue; }
        timeout 300 $runner -E "DREAM_LIBRARY_PATH=$ssl/lib" "$tmp/$suite" "$tls_dir" > "$tmp/$suite.out" 2>&1
        if diff -q "$tmp/$suite.out" "$tmp/$suite.vm" >/dev/null; then echo "aot_cross: $suite ok"
        else echo "aot_cross: $suite printed:"; diff "$tmp/$suite.vm" "$tmp/$suite.out" | head -20; failed=1; fi
    done
else
    echo "skip aot_cross tls: no aarch64 OpenSSL (AARCH64_OPENSSL)"
fi

[[ $failed == 0 ]] && echo "aot_cross: ok"
exit $failed

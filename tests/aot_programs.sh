#!/usr/bin/env bash
# Every program and example that has its output recorded, built with `dreams --aot`,
# run, and compared. It reports how far the AOT has got rather than failing on what
# is not built: a program refused is counted apart from one that ran and was wrong,
# and only the second is a bug. The refusals are tallied, most common first, because
# that is the list of what to build next.
#
#   image=... DREAM=... AOT_FLAGS=--release dreams/tests/aot_programs.sh [PATTERN]

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
export dream="$(realpath "${DREAM:-$root/build-dream/bin/dream}")"
export image="$(realpath "${image:-$root/build/dreams.dream}")"
export root
export AOT_FLAGS="${AOT_FLAGS:-}"
export dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
pattern="${1:-}"

one() {
  src="$1"
  name="$(basename "$src" .dr)"
  w="$(dirname "$src")"
  cd "$w" || exit 0
  if ! DREAMS_CACHE= timeout 180 "$dream" "$image" --aot ${AOT_FLAGS:-} -L "$root/mind" -I "$w" -o "$dir/$name" "$src" >"$dir/$name.said" 2>&1; then
    grep 'error: ' "$dir/$name.said" | sed 's/^error: [^:]*: //' | sort -u > "$dir/$name.reasons"
    echo refused > "$dir/$name.verdict"
    return
  fi
  # What it printed is what is held to account: a program may mean to fail, and its
  # expected output then says so.
  (ulimit -v 16000000; timeout -s KILL 30 "$dir/$name") >"$dir/$name.out" 2>&1 </dev/null
  if diff -q "$dir/$name.out" "${src%.dr}.expected" >/dev/null; then
    echo pass > "$dir/$name.verdict"
  else
    echo wrong > "$dir/$name.verdict"
  fi
}
export -f one

for src in "$root"/dream/tests/programs/*.dr "$root"/examples/*.dr; do
  name="$(basename "$src" .dr)"
  [[ -f "${src%.dr}.expected" ]] || continue
  [[ -z "$pattern" || "$name" == *$pattern* ]] || continue
  [[ -f "${src%.dr}.env" ]] && continue
  # What the VM keeps apart from its heaps, asked about directly: with one heap there is no such area.
  [[ "$name" == share_release ]] && continue
  printf '%s\0' "$src"
done | xargs -0 -P "${AOT_JOBS:-$(( $(nproc) / 2 ))}" -I{} bash -c 'one "$@" 2>/dev/null' _ {}

count() { grep -lx "$1" "$dir"/*.verdict 2>/dev/null | wc -l; }
echo "aot programs: $(count pass) pass, $(count wrong) wrong, $(count refused) refused"
wrong=$(grep -lx wrong "$dir"/*.verdict 2>/dev/null | xargs -r -n1 basename | sed 's/\.verdict$//')
for n in $wrong; do echo "  wrong: $n"; done
refused=$(grep -lx refused "$dir"/*.verdict 2>/dev/null | xargs -r -n1 basename | sed 's/\.verdict$//')
for n in $refused; do echo "  refused: $n"; done
if ls "$dir"/*.reasons >/dev/null 2>&1; then
  echo "what stopped the refused ones, most common first:"
  cat "$dir"/*.reasons | sort | uniq -c | sort -rn | cut -c1-110
fi
[[ -z "$wrong" ]]

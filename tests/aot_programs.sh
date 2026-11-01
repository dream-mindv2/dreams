#!/usr/bin/env bash
# Every program and example that has its output recorded, built with `dreams --aot`,
# run, and compared. It reports how far the AOT has got rather than failing on what
# is not built: a program refused is counted apart from one that ran and was wrong,
# and only the second is a bug. The refusals are tallied, most common first, because
# that is the list of what to build next.
#
#   image=... DREAM=... dreams/tests/aot_programs.sh [PATTERN]

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
dream="$(realpath "${DREAM:-$root/build-dream/bin/dream}")"
image="$(realpath "${image:-$root/build/dreams.dream}")"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
pattern="${1:-}"
pass=0; wrong=0; refused=0; wrong_names=()

for src in "$root"/dream/tests/programs/*.dr "$root"/examples/*.dr; do
  expected="${src%.dr}.expected"
  name="$(basename "$src" .dr)"
  [[ -f "$expected" ]] || continue
  [[ -z "$pattern" || "$name" == *$pattern* ]] || continue
  [[ -f "${src%.dr}.env" ]] && continue
  if ! (cd "$(dirname "$src")" && DREAMS_CACHE= timeout 120 "$dream" "$image" --aot -L "$root/mind" -I "$(dirname "$src")" -o "$dir/$name" "$src") >"$dir/said" 2>&1; then
    refused=$((refused + 1))
    grep '^error:\|error: ' "$dir/said" | sed 's/^error: [^:]*: //' | sort -u >> "$dir/reasons"
    continue
  fi
  if (cd "$(dirname "$src")" && ulimit -v 16000000 && timeout 30 "$dir/$name") >"$dir/out" 2>&1 </dev/null && diff -q "$dir/out" "$expected" >/dev/null; then
    pass=$((pass + 1))
  else
    wrong=$((wrong + 1)); wrong_names+=("$name")
  fi
done

echo "aot programs: $pass pass, $wrong wrong, $refused refused"
[[ $wrong == 0 ]] || printf '  wrong: %s\n' "${wrong_names[@]}"
if [[ -f "$dir/reasons" ]]; then
  echo "what stopped the refused ones, most common first:"
  sort "$dir/reasons" | uniq -c | sort -rn | head -40 | cut -c1-110
fi
[[ $wrong == 0 ]]

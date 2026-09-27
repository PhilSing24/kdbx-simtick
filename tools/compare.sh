#!/bin/bash
# compare the working tree with the baseline: tools/compare.sh
# exits 0 when every hash is identical, 1 when one differs, 2 when it cannot run
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/tools/out
[ -s "$out/baseline.hashes" ] || { echo "compare: no baseline, run tools/baseline.sh first"; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$root" && QPATH=$root:${QPATH:-} HASHTMP=$tmp timeout 900 q "$root/tools/hashes.q" -q > "$out/now.txt" 2>&1)
grep -E " [0-9a-f]{32}$" "$out/now.txt" > "$out/now.hashes"
n=$(wc -l < "$out/now.hashes")
if diff -q "$out/baseline.hashes" "$out/now.hashes" > /dev/null; then
  echo "outputs identical to $(cat "$out/baseline.ref"): $n of $n hashes"
else
  echo "OUTPUTS DIFFER from $(cat "$out/baseline.ref")"
  diff "$out/baseline.hashes" "$out/now.hashes" | grep "^[<>]"
  grep -v -E " [0-9a-f]{32}$" "$out/now.txt" | grep "^'" | head -5
  exit 1
fi

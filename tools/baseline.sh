#!/bin/bash
# take the hashes of a reference: tools/baseline.sh [ref], ref a branch, tag or commit (default main)
# the reference is checked out in a temporary worktree, which is removed afterwards;
# the working tree, the index and the stash are not touched
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
ref=${1:-main}
out=$root/tools/out
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'git -C "$root" worktree remove --force "$tmp/ref" 2>/dev/null; rm -rf "$tmp"' EXIT
git -C "$root" worktree add -q --detach "$tmp/ref" "$ref" || { echo "baseline: cannot check out $ref"; exit 2; }
(cd "$tmp/ref" && QPATH=$tmp/ref:${QPATH:-} HASHTMP=$tmp timeout 900 q "$root/tools/hashes.q" -q > "$out/baseline.txt" 2>&1)
grep -E " [0-9a-f]{32}$" "$out/baseline.txt" > "$out/baseline.hashes"
grep -v -E " [0-9a-f]{32}$" "$out/baseline.txt" | grep -q "^'" && { echo "baseline: errors while hashing $ref, see tools/out/baseline.txt"; exit 2; }
git -C "$root" rev-parse --short "$ref" > "$out/baseline.ref"
echo "baseline: $(wc -l < "$out/baseline.hashes") hashes of $ref ($(cat "$out/baseline.ref"))"

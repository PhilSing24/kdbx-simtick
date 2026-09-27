#!/bin/bash
# run the four test suites and print the counts on one line: tools/suites.sh
# exits 0 only when every suite ran to its end and no check failed
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
out=""
ok=1
for m in simtick-config simtick simmarket simorder; do
  r=$(timeout 2400 make test-$m 2>&1 | grep -E "^(Passed|Failed|suite aborted|di.k4unit was not found)" | tr '\n' ' ')
  out="$out$m: $r| "
  echo "$r" | grep -q "Failed: 0" || ok=0
  echo "$r" | grep -q "suite aborted" && ok=0
done
echo "$out"
[ $ok = 1 ]

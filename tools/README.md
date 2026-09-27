# tools

Scripts that show a change did not alter what the modules generate. They are for changes that must leave behaviour as it is: a refactoring, a rename, a move of files, a style pass.

| Script | What it does |
|--------|--------------|
| `baseline.sh [ref]` | Takes the hashes of a reference (a branch, tag or commit, default `main`) |
| `compare.sh` | Hashes the working tree and compares with the baseline |
| `suites.sh` | Runs the four test suites and prints the counts on one line |
| `hashes.q` | The outputs that are hashed; run by the two scripts above |

## Requirements

`q` on the path, and `QPATH` set as the root README describes, with the clone of [DataIntellectTech/kdbx-modules](https://github.com/DataIntellectTech/kdbx-modules) after this repository. `suites.sh` needs `di.k4unit` from that clone. The scripts run from any directory.

## Take a baseline, then compare

```bash
tools/baseline.sh            # the hashes of main
# ... change the code ...
tools/compare.sh             # the working tree against them
tools/suites.sh              # the four suites
```

```
baseline: 24 hashes of main (e75afbf)
outputs identical to e75afbf: 24 of 24 hashes
simtick-config: Passed: 51 Failed: 0 | simtick: Passed: 218 Failed: 0 | simmarket: Passed: 242 Failed: 0 | simorder: Passed: 266 Failed: 0 |
```

When an output differs, `compare.sh` prints the lines of the baseline (`<`) and of the working tree (`>`) and exits 1:

```
OUTPUTS DIFFER from e75afbf
< describe simtick 0f3a...
> describe simtick 9b1c...
```

`baseline.sh` checks the reference out in a temporary worktree and removes it afterwards. It does not touch the working tree, the index or the stash. Take the baseline again whenever `main` moves. The results are kept in `tools/out/`, which git ignores.

Exit codes: 0 identical (or all suites passed), 1 a difference (or a failing check or an aborted suite), 2 the script could not run.

## What is hashed

Each output is serialized and hashed with md5, one line per output. All runs are seeded.

| Module | Outputs |
|--------|---------|
| `di.simtick` | A composed configuration; one day of NVDA, XOM, PG, a bare five-value stock, SGX D05 and HKEX 0005 across the three scenarios; the calendar clock with lognormal sizes; `arrivals`, `price`, `factorday`; `describe`; a configuration saved and loaded |
| `di.simmarket` | `runmany` and `run` in memory; `regimes`; `correlations`; the 2026 NYSE calendar; an SGX half day; a database written in two steps (two dates, then resumed), with its trade, quote and days partitions and `loadrun`; `describe` |

`di.simorder` is covered by its test suite only.

## Limits

- **Same code, same hashes**: identical hashes show the outputs listed are unchanged, not that every code path is. The suites cover the rest.
- **A change meant to alter an output**: the hash differs by design. List the outputs that change and why, and check that no other does.
- **An output added to `hashes.q`**: take the baseline again, so both sides are hashed by the same script.
- **A reference older than the current layout**: `hashes.q` loads `di.simtick.config`, so a reference from before that module existed cannot be hashed by it.
- **`simmarket.init`**: a silent logger is injected when the module has `init`; a reference from before it has none and needs none.

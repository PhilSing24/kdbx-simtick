# Submitting upstream

How `di.simtick` and `di.simmarket` are submitted to [DataIntellectTech/kdbx-modules](https://github.com/DataIntellectTech/kdbx-modules), and the decisions already taken. The submission is on hold; when it resumes, the branches are rebuilt from this repository's `main` by following this page.

## Decisions

| Subject | Decision |
|---------|----------|
| What goes upstream | `di.simtick` with its child `di.simtick.config`, and `di.simmarket`. `di.simorder` stays here |
| Versions | `di.simtick` 0.2.0; `di.simtick.config` and `di.simmarket` 0.1.0 |
| Pull requests | Two, each standing on its own: simtick first, then simmarket, whose description says it depends on the first and is reviewed after it |
| Migration guide | None. The simtick README opens with a short note instead (below) |
| Third-party paper | `HawkesProcessesInFinance.pdf` is not shipped; the README links to it on arXiv |
| Logging | `di.util.log` is not listed in `deps.toml`: the caller injects the logger through `simmarket.init` |
| PR #86 upstream | Superseded. Its author posts the closing comment (below) when the first new pull request is open |

## What travels

| Item | Upstream |
|------|----------|
| `init.q`, `test.csv`, `README.md`, `VERSION`, `deps.toml`, `docs/parameters.md` of the three modules | Yes |
| Config files (`markets/`, instruments, scenarios, `venues.csv`) and `calendar.csv` | Yes |
| `docs/IntradayTickSimulatorPaper.pdf` and `.tex` | Yes |
| `notebooks/config_examples.ipynb` and `requirements.txt` | Yes, with simtick |
| `di/simtick/testing.q` | No |
| `tools/`, `genparams.q`, `Makefile`, the root `README.md` | No |
| `di/simorder/` | No |

Upstream files that the simtick pull request removes: `presets.csv`, `notebooks/simtickDemo.ipynb`, `docs/HawkesProcessesInFinance.pdf`. Its `requirements.txt` is replaced by ours.

## Edits made only in the upstream branches

The code and the tests are copied unchanged. These edits are to the documents.

**Both branches**

- The `make test-...` lines are removed from the three READMEs; the q session form stays.
- `testing.q` is removed from the project structure in the simtick README, and the `.tex` is listed next to the PDF.
- The headers of the two `docs/parameters.md` no longer name `genparams.q` or `make params`.
- The simmarket README says `di.util.log` ships in the repository, not upstream of it.
- The note for users of 0.1 is added under the first paragraph of the simtick README.

**simtick branch only**, so that it does not refer to a module that is not there yet. The simmarket branch restores the text of this repository:

| Place in the simtick README | In the simtick branch |
|------------------------------|-----------------------|
| End of the co-movement section | The sentence on `di.simmarket` is removed |
| Related modules | The two-module tree and the `di.simmarket` paragraph are replaced by a sentence on the child module `di.simtick.config` |
| Configuration table, scenario row | "the day-to-day regime keys, which a single day does not read" |
| Documentation, the paper | "the mathematical foundations of the simulator" |

The mentions of `di.simmarket` in the schema descriptions of `di/simtick/init.q`, in `docs/parameters.md` and in the paper stay in both branches: they say how the parameters are used.

## The note for users of 0.1

> **Version 0.2 is a rewrite.** Code written for 0.1 will not run unchanged: the configuration is composed from layers in place of `presets.csv`, parameters were renamed, and the output tables have more columns. Start from [Usage](#usage) and the [example notebook](notebooks/config_examples.ipynb). Version 0.1 remains available at commit [`dd1057b`](https://github.com/DataIntellectTech/kdbx-modules/tree/dd1057b4ebd16fca70c9c0a035f67df09a5e09a1/di/simtick).

`dd1057b` added 0.1 upstream and was the last commit to touch `di/simtick` there as of 2026-09-28. Check it again before submitting: `git log -1 -- di/simtick` on upstream `main`. The same paragraph opens the description of the simtick pull request.

## Building the branches

In a clone of the fork, with the remote `upstream` set to DataIntellectTech/kdbx-modules:

1. **Check this repository**: on a fresh `main`, `tools/suites.sh` passes.
2. **simtick branch**: from `upstream/main`, replace `di/simtick` with ours, leave out `testing.q`, apply the edits above. One commit.
3. **simmarket branch**: from the simtick branch, add `di/simmarket`, apply its edits and restore the four places of the simtick README. One commit.
4. **Test each branch alone**, with only that tree on `QPATH` (`di.k4unit` and `di.util.log` are in it):

   ```q
   q)k4unit:use`di.k4unit
   q)k4unit.moduletest`di.simtick
   ```

   The counts must be those of `tools/suites.sh` here. The simtick branch has no `di/simmarket`.
5. **Run the notebook** in the upstream tree with `QPATH` unset.
6. **Push and open** the two pull requests only when the owner of the repository says so.

A rehearsal on 2026-09-28, on upstream `main` at `b20e58d`, passed: simtick.config 51, simtick 218, simmarket 242.

## Comment for PR #86

To be posted by its author, with the link to the new simtick pull request added:

> This PR is superseded, so please don't spend review time on it. Since I opened it, `di.simtick` has been reworked well beyond what is here, and the planned `di.simcalendar` has become `di.simmarket`.
>
> I will open new PRs against current `main` shortly: first `di.simtick` with its configuration child module `di.simtick.config`, then `di.simmarket` for multi-day, multi-stock runs. They follow `style.md` and `consistency.md` (VERSION, `deps.toml`, module-local paths, tests under `di.k4unit`, logging injected through `init`).
>
> I will close this PR when the first of them is open.

# Measuring what a task costs

Do the work normally. Measure what it costs. Post the numbers.

This page is the **durable protocol** for issue #906's cost measurements. The task itself — which issue, which shape, which concurrency level — comes from whoever dispatched the run and stays short.

It is a reference, deliberately not a skill: a skill's description is injected into every session's context (the 38 existing ones already cost ~10.7 KB before any work starts), and this serves a bounded experiment plus the occasional "did that change make things faster" question. Both are deliberately initiated, so nothing needs to discover it unprompted. Developer docs under `docs/develop/` are excluded from the Docusaurus build (CLAUDE.md rule 11), so this never reaches the public site.

## The prime directive

**Work normally.** Do not re-run a gate to produce a nicer number, do not skip one to save time, and do not restructure how you work in order to be measured. The point is what a *normal* task costs. A measurement that changed the behaviour it measured is worthless.

## Why resources, not just wall clock

Issue #863 measured this project's build storm as `io full avg300=65.95`, `dm-0` at 100% utilisation, 22 concurrent linkers, and `ld` invoking the OOM killer — while `cpu some avg300=0.08`. **The CPU was idle throughout.** A time-and-CPU-only measurement would have concluded nothing was wrong, on the very incident that produced `scripts/link-gate.sh`. So capture I/O and memory pressure alongside duration. The write-up is [`build-gate.md`](build-gate.md).

## The one instruction people get wrong

**Use `/usr/bin/time -v`, never bash's builtin `time`.** The builtin reports only wall/user/sys — no peak RSS, no I/O counters — and the omission is invisible in the output unless you already know what is missing. `command time -v` also works. Paste the real output; never retype or summarise numbers from memory.

## Per gate invocation — required fields

For every `cargo fmt`, `cargo clippy`, `cargo test-fast`, `cargo build` and any e2e run:

| field | how |
|---|---|
| wall / user / sys / %CPU / **max RSS** / FS in / FS out | `/usr/bin/time -v`, pasted verbatim |
| **UTC start and end** | epoch seconds *and* human time. Without these, gates cannot be aligned across agents or against the box sampler |
| **units rebuilt** | from cargo's own output. This is the normaliser — without it "67s versus 8.8s" is uninterpretable rather than informative |
| **cold or warm** | state explicitly whether *this worktree's* `target/` was populated before the gate. A fresh dispatch worktree starts **cold** |
| PSI before and after | `/proc/pressure/{io,memory,cpu}` |
| `uptime` before and after | every number must carry its load average, so a contended sample is never silently compared against a quiet one |
| bucket | **"my change"** or **"a pre-existing defect"** — see below |

## Per task — required fields

- **Time to first edit.** From starting work to your first file modification: the orientation cost of reading CLAUDE.md, locating code, grepping `tests/CATALOG.md`. It is a reading cost, so CPU contention does not distort it. On the #749 run this was **202s — about 89% of the entire clippy gate.**
- **Invocation counts**, and how many were **re-runs after a failure**. This separates "the gate is slow" from "the gate ran seven times".
- **CI wait**, from GitHub's own timestamps (`gh pr checks --json startedAt,completedAt`), never your own sense of elapsed time.

## Bucket your own cost separately from someone else's

The single most useful number the #749 run produced: **41% of its local gate wall clock (232.8s of 563.1s) went to reproducing and fixing two pre-existing lane-1 flakes that were not its own.** Tag every invocation as *my change* or *a pre-existing defect* and report the two totals separately. Without the split, someone else's flake silently inflates your task's apparent cost.

## Link-gate queueing

`scripts/link-gate.sh` takes a slot from a machine-wide pool via `scripts/build-gate.sh`; the budget is one slot per 4 GiB RAM, clamped to core count (**6** on a 27 GiB / 16-core box). Sample the counters and report **queue depth**, not just occupancy: a line reading `ld=10 … slots_held=6/6` means four linkers are not holding a slot. Note the mapping is approximate — `ld`/`collect2` nesting means the counts are indicative rather than exact — and say so rather than presenting it as precise.

`build-gate.sh` logs only when its 900s wait budget expires, so an individual link's wait is not directly observable without changing that script. **Do not change it** to get a number: it is the linker for every build on the machine, and modifying it during a measurement alters what is being measured.

## Concurrency levels

When the invocation names a level (N=1, N=3, N=5):

- **Report only your own processes.** Do not attempt machine-wide claims — with several agents running you cannot see the box, and an inference will be wrong. Whole-box state (PSI, `MemAvailable`, load, disk, total RSS, pool occupancy) is captured separately by [`scripts/sample-box.sh`](../../scripts/sample-box.sh), run by the coordinator, and correlated with your gates by timestamp. This is why UTC timestamps are mandatory.
- **`time -v`'s max RSS is the largest single process, not a sum.** At N>1 total memory is the binding constraint and only the box sampler can see it. Do not present your peak as the machine's.
- **Record your own start time** so "N=3" means three agents actually overlapping, rather than one finishing before another began.

## Evidence, not recollection

Paste real command output. Where you cannot evidence something and are estimating, **say so and label it an estimate** — a soft number labelled soft is useful; a soft number presented as hard is worse than none.

CLAUDE.md rule 17 governs the write-up: do not turn a narrow measured fact into a wide claim. The #749 report is the standard to match — it wrote *"That it never compiled is an **inference**, not a measurement"* rather than asserting an idle neighbour.

## Deliverables

Two, both required:

1. **The task's own deliverable** — normally a PR. The task's rules apply unchanged: CLAUDE.md rule 2's gates before every commit, rule 5's scoped tests, rule 6 on a failing test, rule 12 if it touches the daemon or protocol, rule 4 if it changes TUI behaviour.
2. **Measurement comments** on the tracking issue the invocation names. Posting an interim comment partway through a long run is encouraged.

## Before you open the PR: verify your base

    git fetch origin main
    git log --oneline origin/main..HEAD

That must list **only** your own commits. If it shows work belonging to other issues, your worktree was cut from the wrong base — rebase with `git rebase --onto origin/main <base-sha>`, then force-push this dispatch branch. If the rebase conflicts, STOP and report rather than improvising.

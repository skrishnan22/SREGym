# SRE harness exercise: documents

Build a minimal agent harness from scratch, score it on SREGym with cheap models, and improve it one change at a time.

## Start here

| # | Document | What it is for |
|---|---|---|
| 0 | [Handoff](HANDOFF.md) | Where the exercise stands and how to resume. Read first in a new session |
| 1 | [Learning guide](learning/README.md) | Three chapters to get up to speed before designing anything |
| 2 | [Execution plan](execution-plan.md) | The phases from today to a final scored harness, with owners, gates, budget and risks |
| 3 | [Improvements catalog](improvements-catalog.md) | About 95 harness changes grouped by what they touch, each tied to the failure it targets and the metric it moves |

## Supporting documents

| Document | What it is for |
|---|---|
| [Improvements evidence](improvements-evidence.md) | Research notes behind the catalog: what the top SREGym entries do, published effect sizes, source links |
| [Design](superpowers/specs/2026-11-14-sre-harness-design.md) | The agreed design: goals, dev and test sets, models, measurement rules |
| [v0 code plan](superpowers/plans/2026-11-14-sre-harness-v0.md) | Task-level plan for the plumbing code. The agent-design tasks in it (6, 8, 9) are a strawman until Phase 4 of the execution plan |

## How these were made

The learning-guide chapters and the evidence notes were researched and written by subagents on 2026-11-16 (Opus for chapter 1 and the evidence, Sonnet for chapters 2 and 3). Each lists what it could not verify. Chapter 3's statements about SREGym were read from commit `148dded`. Figures in the evidence notes carry source links but were not individually re-checked.

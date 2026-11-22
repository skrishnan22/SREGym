# Pinned settings

Everything here stays fixed for the whole exercise. Changing any of it makes scores before and after the change incomparable. If something must change, record the date and reason below and treat every earlier score as a different series.

## Benchmark

| Setting | Value |
|---|---|
| Upstream | `SREGym/SREGym` |
| Commit | `b723f54` (2026-11-21, "Put the selling upfront (#1226)") |
| Branch for our work | `harness` on `skrishnan22/SREGym` |
| Suite | `sregym-lite` (dev), held-out list in `results/sets/test.txt` (test, frozen in Phase 6) |
| Profile | `full` |
| Agent timeout | 1800 s (`--agent-timeout` default) |
| Internet access | `filtered` |

Upstream is not pulled again during the exercise. The learning guide's chapter 3 was read at `148dded`; the 14 commits between that and `b723f54` include fixes to `network_policy_block` (#1214), the edge-filter fault (#1211) and the load spike (#1215). Re-check any chapter 3 detail that a result depends on.

## Models

| Role | Model | Endpoint |
|---|---|---|
| Agent A | GLM-5.3-Flash | OpenCode Go |
| Agent B | MiMo-V2.6-Flash | OpenCode Go |
| Judge | GPT-6 Luna, passed with `--judge-model` on every run | OpenCode Go |

Exact model IDs are filled in after the Phase 3 probes.

**Fallback: OpenRouter**, used only when Go limits block a sweep. The same model can behave differently on a different backend, so a sweep runs on one provider from start to finish, never a mix. A version compared against another must use the same provider; if a version is moved to OpenRouter, its comparison baseline is re-run there too. On OpenRouter, pin the backend with `provider.order` and `allow_fallbacks: false`, and record the provider with every row.

## Agent limits (v0, matching `mini-sre`)

| Limit | Value |
|---|---|
| Commands per stage | 80 |
| Per-command timeout | 60 s |
| Diagnosis share of time | 2/3 |

## Changes to this file

| Date | Change | Reason |
|---|---|---|
| 2026-11-22 | Created | Phase 1 |

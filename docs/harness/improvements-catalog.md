# Harness improvements catalog

Every change to the harness worth considering, grouped by the part of the agent it touches. Use it in the improvement loop ([execution plan](execution-plan.md), Phase 8): classify the failures from the last sweep, then pick the cheapest item here that targets the biggest failure category.

Nothing in this list is a promise. Each item is a hypothesis to test on the dev set; several will do nothing or hurt with a given model.

## The metrics

| Metric | What moves it |
|---|---|
| Diagnosis % | Looking in the right place, reading evidence correctly, stating component and root cause clearly |
| Mitigation % | Correct diagnosis first, then a fix that addresses the cause, then checking it worked |
| End-to-end % | Both; bounded above by the lower of the two |
| Time to diagnose / mitigate | Fewer turns, faster model calls, parallel actions, knowing when to stop |
| Tokens per run | Shorter observations, less resent history, prompt caching, fewer turns |

## Failure taxonomy

Tag every failed run with one primary category. The counts decide what to work on.

| Code | Failure | Typical sign in the transcript |
|---|---|---|
| F1 | Format or protocol breakdown | Format errors, no command block, malformed tool call, never submits |
| F2 | Never looked in the right place | The faulty component or signal is never inspected |
| F3 | Saw the evidence, missed it | The decisive line is in an observation; the model moves on |
| F4 | Drowned in output | Huge logs or YAML; context fills; quality drops afterwards |
| F5 | Lost the thread | Repeats commands, loops, forgets earlier findings, drifts from the task |
| F6 | Symptom reported as cause | Diagnosis names what is broken, not why |
| F7 | Wrong or hallucinated specifics | Invented resource names, wrong namespace, misread field |
| F8 | Premature submission | Submits on the first plausible idea, without a test |
| F9 | Ran out of budget | Hits the command cap or deadline while still exploring |
| F10 | Right diagnosis, wrong fix | Fix masks the symptom, breaks something else, or does not apply |
| F11 | Fix not verified | Submits mitigation without checking health; it had not worked |
| F12 | Vague answer | Diagnosis is right in spirit but too imprecise for the judge |
| F13 | Infrastructure | API errors, rate limits, harness crash. Not an agent failure; fix and re-run |

## How to read the tables

- **Targets:** failure codes the item addresses.
- **Cost:** build effort (S, M, L) and the ongoing cost in tokens or time (↑ more, ↓ less, – neutral).
- **Risk:** the main way it backfires.

---

## A. Reliability and protocol

Do these first if F1 or F13 show up at all. A run lost to plumbing teaches nothing.

| ID | Change | Targets | Cost | Risk |
|---|---|---|---|---|
| A1 | Lenient action parsing: accept `sh`/`shell`/untagged fences, take the last block when several appear | F1 | S, – | Runs a block the model meant as an example |
| A2 | Format-repair turn: on a malformed reply, show the exact expected shape and the model's own reply back | F1 | S, ↑ small | Loops if the model cannot comply |
| A3 | Handle reasoning content: if `content` is empty but a reasoning field holds the answer, use it; keep or drop reasoning from history deliberately | F1, tokens | S, ↓ | Dropping reasoning can hurt models trained to see their own |
| A4 | Right-size `max_tokens` so replies are never cut mid-command; detect `finish_reason: length` and ask for a shorter reply | F1 | S, – | None |
| A5 | Pin sampling: low temperature, fixed seed where supported | variance | S, – | Some models degrade or loop at temperature 0 |
| A6 | Retry policy tuned to the provider: backoff on 429 and 5xx, distinguish window exhaustion from blips | F13 | S, – | Hides a real outage for too long |
| A7 | Non-interactive shell guard: close stdin, set `KUBECTL_PAGER=cat`-style env, reject `-it`, `watch`, `-w`, `-f` with an explanation | F9 | S, ↓ time | Blocks a legitimate follow |
| A8 | Per-command timeout the model can raise within a bound | F9 | S, – | Model wastes time on long waits |
| A9 | Guaranteed submission: at the hard limit, a final call that must produce an answer from the notes so far | F9, F1 | S, – | A low-quality answer replaces a blank; the blank scores zero anyway |
| A10 | Submission as a harness function, not a model-written `curl` | F1 | S, – | None; removes quoting and escaping mistakes |

## B. Action interface

How the model asks for things to happen.

| ID | Change | Targets | Cost | Risk |
|---|---|---|---|---|
| B1 | Native tool calling in place of text parsing | F1 | M, – | Some cheap models are worse at tool schemas than at text |
| B2 | Several commands per turn, run in parallel when read-only | F9, time | M, ↓ time | Larger observations per turn |
| B3 | Persistent shell session (working directory and variables survive) | F5 | M, – | Hung state carries over |
| B4 | A small set of purpose-built read tools: `pods`, `describe`, `logs`, `events`, `get_yaml`, each with sane defaults and limits | F2, F4, F7 | M, ↓ | Too many tools confuses weak models; a missing option forces a fallback to raw kubectl |
| B5 | Keep raw `bash` as an escape hatch beside the tools | F2 | S, – | Model ignores the tools |
| B6 | Observability tools: metrics query, trace search, log search (SREGym's MCP server exposes some of these) | F2, F6 | M, ↑ | Extra signal the model misreads |
| B7 | Separate read and write tools; writes need a stated reason and are logged for rollback | F10 | M, – | Friction slows mitigation |
| B8 | A patch/apply tool with server-side dry-run first and a diff shown back | F10, F7 | M, – | Extra turn per change |
| B9 | A `think` or `note` tool: a place to reason or record without acting | F5, F8 | S, ↑ small | Used as a stalling move |
| B10 | Tool descriptions written as guidance: when to use, what the output means, common mistakes | F2, F7 | S, ↑ small | Longer prompt |
| B11 | Error messages that say what to do next (wrong namespace → list of namespaces; not found → nearest names) | F7 | S, – | None |
| B12 | Name validation: check that a referenced resource exists before running, suggest close matches | F7 | M, – | Blocks valid commands on a stale cache |

## C. Observation shaping

What comes back from an action. Usually the highest-value area for small models.

| ID | Change | Targets | Cost | Risk |
|---|---|---|---|---|
| C1 | Head and tail truncation with a count of what was cut | F4 | S, ↓ | The decisive line is in the middle |
| C2 | Budget in tokens, not characters, sized to the model's context | F4 | S, ↓ | None |
| C3 | Per-command shaping: strip `managedFields`, `last-applied-configuration` and status noise from YAML | F4, F3 | S, ↓ | Removes a field that mattered |
| C4 | Collapse repeated log lines to one line with a count | F4, F3 | S, ↓ | Hides a rate change |
| C5 | Save full output to a file and return a preview plus the path, so the model can `grep` it | F4, F3 | S, ↓ | Model never goes back to the file |
| C6 | Surface error-like lines (error, fail, denied, timeout, OOM, backoff) from long output ahead of the preview | F3 | S, ↓ | Keyword bias toward noisy but harmless errors |
| C7 | Say so explicitly when output is empty or a command had no effect | F3, F7 | S, – | None |
| C8 | Attach metadata: line count, duration, exit code, whether truncated | F3 | S, – | None |
| C9 | Compact tables: drop columns the task never needs, shorten ages and hashes | F4 | S, ↓ | Dropped column mattered |
| C10 | Summarise a huge observation with a cheap model call before it enters the context | F4 | M, ↑ calls ↓ context | Summary drops or invents the key fact |
| C11 | Diff view: when the same command is repeated, show what changed since last time | F5, F11 | M, ↓ | Confusing if the model expects full output |

## D. Context and memory

What the model sees on each turn as the run grows.

| ID | Change | Targets | Cost | Risk |
|---|---|---|---|---|
| D1 | Elide old observations: keep the command and a one-line result, drop the body after N turns | F4, F5, tokens | S, ↓↓ | Model needs something that was dropped; breaks prompt caching if history is rewritten |
| D2 | Compaction: at a token threshold, replace older turns with a structured summary | F5, F9 | M, ↓ | Summary loses detail; one extra call |
| D3 | Running notes file the model maintains: hypotheses, evidence for and against, ruled out, next step | F5, F8 | M, ↑ small | Notes go stale or are never updated |
| D4 | Pin the task and the notes at the end of the context each turn | F5 | S, ↑ small | Repetition cost |
| D5 | Append-only history designed around prompt caching, with elision done in batches | tokens, time | M, ↓ cost | Constrains D1 and D2 |
| D6 | Stage handoff as a written summary: diagnosis, evidence, exact resource names, into a fresh mitigation context | F10, tokens | S, ↓ | Summary omits a detail the fix needs |
| D7 | Sub-agents for exploration: a worker investigates one question in its own context and returns a short answer | F4, F5 | L, ↑ calls | Worker lacks context; coordination errors |
| D8 | Context-size awareness: tell the model how full the context is, and what will be dropped | F5 | S, – | Distracts |

## E. Briefing and prompt

| ID | Change | Targets | Cost | Risk |
|---|---|---|---|---|
| E1 | A short investigation method: survey first, hypothesise, test, confirm cause, then answer | F2, F8 | S, ↑ small | Over-prescription makes weak models follow steps mechanically |
| E2 | Orientation: which tools exist, where metrics and traces are, what namespaces to expect | F2 | S, ↑ small | Stale or wrong orientation |
| E3 | Root cause versus symptom guidance, with a generic example not drawn from the benchmark | F6 | S, – | Model over-reaches for a deeper cause that is not there |
| E4 | Diagnosis answer template: faulty component, what is wrong with it, why that produces the symptoms, the evidence | F12, F6 | S, – | Template filled with guesses |
| E5 | Mitigation rules: fix the cause, smallest change, do not delete or restart blindly, check afterwards | F10, F11 | S, – | Too cautious to act |
| E6 | Stage-specific prompts: a different briefing for diagnosis and for mitigation | F10 | S, – | Duplicated maintenance |
| E7 | One worked example trajectory on a fault that is not in the benchmark | F1, F2 | M, ↑ | Model imitates the example's specifics |
| E8 | Output-size etiquette: always bound logs, prefer selectors and `--tail`, never dump all namespaces as YAML | F4 | S, ↓ | None |
| E9 | Prompt format tuned to the model family (plain text, XML-style tags, or markdown) | F1 | S, – | Fitting to one model |
| E10 | Mid-run reminders: restate the goal and the method every N turns or on a stall | F5 | S, ↑ small | Noise |
| E11 | Remove words: test whether each paragraph of the prompt earns its place | tokens | S, ↓ | Removes something that mattered silently |

## F. Automatic context gathering

Work the harness does before or between model calls, without asking.

| ID | Change | Targets | Cost | Risk |
|---|---|---|---|---|
| F-1 | Opening snapshot: pods, deployments, services, recent events in the namespace, shaped and given with the task | F2, F9, time | S, ↑ first turn ↓ turns | Anchors the model on what the snapshot shows |
| F-2 | Unhealthy-first view: only resources that are not ready, restarting, pending or erroring | F2, F4 | S, ↓ | A fault with no unhealthy pod looks like "all fine" |
| F-3 | Recent-change view: resources sorted by creation and last change, rollout history, recently edited ConfigMaps and policies | F2, F6 | M, – | Benchmark setup itself creates recent changes |
| F-4 | Service map: which service calls which, from Service and Endpoints objects or traces | F2, F6 | M, ↑ | Wrong map misleads |
| F-5 | Cluster-scope sweep: nodes, quotas, webhooks, network policies, CoreDNS, in a few lines | F2 | S, ↑ small | Noise on app-level faults |
| F-6 | Metric anomaly prefilter: a few standard queries (error rate, latency, restarts, saturation) summarised | F2, F6 | M, ↑ | False anomalies under synthetic load |

## G. Reasoning and control flow

| ID | Change | Targets | Cost | Risk |
|---|---|---|---|---|
| G1 | Plan first: one call to write an investigation plan before any command | F2, F5 | S, ↑ small | Plan is generic and ignored |
| G2 | Explicit hypothesis list with a test for each, updated as evidence arrives | F8, F5 | M, ↑ | Bookkeeping crowds out investigating |
| G3 | Loop detection: same or near-same command repeated, or K turns without new information, triggers a redirect | F5, F9 | S, – | False positives on legitimate re-checks |
| G4 | Reflection on stall: a step back to list what is known and what has not been checked | F5, F2 | S, ↑ small | Token cost without change in behaviour |
| G5 | Pre-submission check for diagnosis: does the answer name a component and a cause, and does cited evidence exist in the transcript | F8, F12, F7 | M, ↑ one call | Second-guesses a right answer into a wrong one |
| G6 | Critic call: a separate prompt attacks the diagnosis ("what else would explain this?") before submitting | F6, F8 | M, ↑ | Same model shares the same blind spot |
| G7 | Verify after mitigation: wait, then re-run the health checks that showed the problem | F11 | S, ↑ time | Slower time to mitigate |
| G8 | Fix loop: if verification fails, diagnose why and try again within the budget | F10, F11 | M, ↑ | Compounding changes to the cluster |
| G9 | Change log and rollback: record every mutation, undo the ones that did not help | F10 | M, – | Rollback itself fails |
| G10 | Dry-run and diff before any write | F10, F7 | S, ↑ small | None significant |
| G11 | Confirm the cause by prediction: state what should be true if the hypothesis holds, then check it | F6, F8 | S, ↑ small | Skipped by weak models unless enforced |

## H. Multiple models and multiple attempts

| ID | Change | Targets | Cost | Risk |
|---|---|---|---|---|
| H1 | Reasoning effort setting, per stage | all | S, ↑ or ↓ | Slower; some endpoints ignore it |
| H2 | Model routing: flash model explores, a stronger model writes the diagnosis and chooses the fix | F3, F6, F10 | M, ↑ cost per run | Changes what the experiment measures; record it as a separate track |
| H3 | Escalate on stall: switch to the stronger model only when G3 fires or budget is half gone | F5, F9 | M, ↑ | Same caveat as H2 |
| H4 | Self-consistency for diagnosis: draft several answers from the same evidence and pick the majority or synthesise | F6, F12 | S, ↑ calls | Agreement on a shared mistake |
| H5 | Parallel independent investigations, then a judge call chooses | F2, F8 | L, ↑↑ | Cost multiplies; cluster state is shared, so only for the read-only stage |
| H6 | Separate diagnosis and mitigation agents with different prompts and tools | F10 | M, – | Handoff loses detail |
| H7 | A cheap summariser model for C10 and D2 | tokens | S, ↓ | Summary quality |

## I. Budget and time

| ID | Change | Targets | Cost | Risk |
|---|---|---|---|---|
| I1 | Show remaining commands and minutes after every action | F9 | S, – | Induces rushing |
| I2 | Tune the split of time between diagnosis and mitigation from measured data | F9 | S, – | Fitting to dev |
| I3 | Staged urgency: explore freely, then narrow, then answer, with thresholds | F9, F8 | S, – | Cuts off a nearly finished investigation |
| I4 | Stop rule: once evidence answers the question, submit; more evidence does not improve the score | time, tokens | S, ↓ | Encourages F8 |
| I5 | Parallel read-only commands (with B2) | time | M, ↓ time | Larger observations |
| I6 | Streaming and early stop on the model call when a complete action has arrived | time | M, ↓ | Cuts useful reasoning |

## J. Knowledge the agent can consult

| ID | Change | Targets | Cost | Risk |
|---|---|---|---|---|
| J1 | A generic Kubernetes troubleshooting reference, loaded on demand by symptom (pod pending, crash loop, DNS, service has no endpoints) | F2, F6 | M, ↑ when used | Must stay generic; a runbook written around the dev problems is contamination |
| J2 | A kubectl cheat sheet with bounded-output idioms | F4, F7 | S, ↑ small | None |
| J3 | Application orientation discovered at run time from the cluster (labels, service names, traces), never hard-coded | F2 | M, ↑ | Slow first turns |
| J4 | Memory across runs (lessons learned) | F2 | L | **Off limits** unless strictly generic: it carries answers from one problem to the next |

## K. Cost and token efficiency

Changes that should leave the score alone and cut cost. Verify the "leave the score alone" part.

| ID | Change | Effect |
|---|---|---|
| K1 | Stable prefix for prompt caching: system prompt and tool schemas never change within a run | Large cut in billed input tokens on providers that cache |
| K2 | Shorter tool schemas and descriptions | Fewer tokens every turn |
| K3 | Drop reasoning text from history where the model does not need it | Fewer tokens |
| K4 | Cap `max_tokens` per reply | Bounds runaway replies |
| K5 | Elision (D1) and shaping (section C) | The main levers on tokens per run |

## L. Tooling that speeds up learning, not the score

| ID | Change | Why |
|---|---|---|
| L1 | Transcript reader | Reading failures is the whole method |
| L2 | Failure tagging file per sweep, feeding a count per taxonomy code | Decides what to work on |
| L3 | Offline replay: re-run the model on saved observations up to step N to test a prompt change without a cluster | Minutes and cents in place of a sweep; valid only up to the first changed action |
| L4 | Micro-evals: saved observations with a known answer ("what is wrong in this output?") to test reading skill directly | Isolates F3 from everything else |
| L5 | Per-step token and latency chart | Shows where the budget goes |
| L6 | Version comparison report with per-problem flips | Prevents reading noise as progress |

---

## A sensible order to try things

This is a starting guess, to be overruled by the failure counts.

1. **Make it reliable:** A1 to A4, A9, A10. Lost runs are pure waste.
2. **Stop drowning:** C1 to C5, E8. Cheap, cuts tokens, usually helps accuracy.
3. **Look in the right place sooner:** F-1 or F-2, E1, E2.
4. **Answer what the judge grades:** E3, E4.
5. **Close the mitigation loop:** E5, G7, G10, then G8.
6. **Stay on track in long runs:** D1, D3, G3.
7. **Better interface:** B1 or B4, once the failure counts say parsing or command construction is a bottleneck.
8. **Spend more per run:** G5, G6, H1, H4, and only then H2 or D7.

## What is out of bounds

- **Problem-specific hints** in prompts, runbooks or tools: anything that names a fault, a service or a fix because a dev problem needs it.
- **Reading test transcripts** to decide a change.
- **Using the fault injector's own traces as the answer.** If the agent finds leftover injection artefacts in the cluster and reads the fault off them, that is a benchmark leak, not SRE skill. Note it when it happens and decide whether to block it.
- **Changing the judge, limits, profile or SREGym commit** between versions.
- **Cross-run memory** that carries facts from one problem to another.

## Additions from the research pass

Items the evidence turned up that were not in the first draft.

| ID | Change | Targets | Cost | Risk |
|---|---|---|---|---|
| B13 | Read-only diagnosis: during diagnosis only allow commands that do not change the cluster | F10, F8 | S, – | Blocks a harmless probe that happens to write |
| B14 | Observability as short shell commands on the PATH (`prom`, `logs`, `traces`, `alerts`, `deps`) wrapping SREGym's Prometheus, Loki and Jaeger with filtered output | F2, F6 | M, ↑ small | Raw trace JSON is huge; the wrapper must aggregate |
| G12 | Minimum-evidence gate: reject a diagnosis that names a resource the transcript never inspected, or a run with no commands at all | F8, F7 | S, – | Rejects a correct inference |
| G13 | Persistent-or-transient check: before anchoring on an anomaly, look again a little later | F6, F8 | S, ↑ time | Slower diagnosis |
| G14 | Harness-run health check after mitigation (pods not ready, crash loops, firing alerts), reported to the model without it asking | F11 | S, – | Health looks fine while the cause remains |
| E12 | Tell the model that the benchmark's own telemetry plumbing is out of scope | F2 | S, – | Borderline: it is knowledge about the benchmark, not about SRE. Decide deliberately whether this is allowed |

## Evidence

Collected by a research subagent on 2026-11-16; the full notes with a source link on every figure are in [improvements-evidence.md](improvements-evidence.md). I have not re-checked each figure against its source, so open the link before quoting one. "Transfer" is a judgment, not a measurement.

| Finding | Reported effect | Source | Catalog items |
|---|---|---|---|
| Pre-digested cluster context beats raw kubectl, same model and agent | Sonnet 5 on the SREGym-Lite leaderboard: 61.8% end-to-end at 990K tokens with Chiron, 45.1% at 3.37M without | sregym.com leaderboard | F-1 to F-4, B14 |
| A "what changed recently" view is unusually strong on this benchmark | Radar: 86% vs 60% correct within two minutes on 50 SREGym faults (vendor's own figure). Faults are injected minutes after deploy, which favours it | Radar repo and benchmark page | F-3 |
| Check, undo and retry after mitigation | Stratus on AIOpsLab: 69.2% with it, 15.4% with no retry, 23.1% with retry but no undo | Stratus paper | G7, G8, G9, G14 |
| A correct diagnosis is most of mitigation | Mitigation succeeds 0.84 to 0.89 of the time after a correct diagnosis, 0.22 to 0.62 after a wrong one | SREGym paper | D6, and everything that raises diagnosis |
| Bounded output beats full output | SWE-agent: 18.0% with a 100-line window, 12.7% showing the whole file | SWE-agent paper | C1 to C5 |
| Hiding old observations halves cost and is roughly neutral on accuracy | Gemini 2.5 Flash 32.8% to 35.6% at 56% lower cost; the same model with thinking fell 40.4% to 36.4%. LLM summarisation was no better than plain hiding | "The complexity trap" (arXiv 2508.21433) | D1, D2, C10 |
| Purpose-built tools can beat shell-only, but not always | SWE-agent interface 18.0% vs 11.0% shell-only; yet bash-only mini-swe-agent is competitive with strong models | SWE-agent paper, mini-swe-agent | B4, B5 |
| Agents rarely use telemetry unless it is a first-class tool | Custom tools were 15 to 17% of Stratus's calls; Claude Code and Codex used telemetry via curl for 2 to 3% | SREGym paper | B6, B14 |
| Procedure guidance helps root-cause analysis | SOP-guided agent 64.01% vs 35.50% for plain ReAct | Flow-of-Action (WWW 2025) | E1, J1 |
| Anchoring on the first anomaly is the dominant failure | Diagnosis dropped about 10 points for every agent when noise was added | SREGym paper | G2, G11, G13, D3 |
| Self-critique without new evidence can make things worse | Intrinsic self-correction degraded performance | Huang et al. (arXiv 2310.01798) | G5 and G6 must re-check the system, not re-read the answer |
| Reasoning effort is a real lever with a timeout risk | Terminal-Bench: 53.9% at maximum effort everywhere (timeouts), 66.5% with high effort only for planning and verifying | LangChain deep-agents post | H1 |
| Loop detection is standard practice | OpenHands flags the same action and result four times, or the same error three times | OpenHands docs | G3 |
| The judge grades three things | Origin component, the mechanism with the concrete wrong value, and scope; pass at 0.70. Several causes score as the minimum | SREGym judge checklist | E4, G5 |
| Small models start low | Kimi K2.5 under Stratus: 27.4% end-to-end vs 54.8% for Sonnet 4.6 | SREGym paper | Expect low v0 numbers; favour work the harness can do deterministically |
| Run-to-run variance is large | The same scenario diagnosed in 1, 6 or 8 of 10 runs | ITBench | Repeats before believing any change |

**Where the answer template stops being legitimate.** Asking for "component, what is wrong with it and the wrong value, why it causes the symptoms, everything affected" (E4) is shaping the answer. Listing fault types or the fields a benchmark fault tends to change is leaking the rubric; another SREGym entrant retired a prompt for exactly that.

**What the evidence does not cover.** No one has published isolated SREGym results for notes or todo tools, runbooks, loop detection or budget prompts. There are no flash-model results on SREGym at all. Those are the gaps this exercise can fill.

## Revised order, given the evidence

1. **Reliability:** A1 to A4, A9, A10.
2. **Bound the output:** C1 to C5, E8.
3. **Pre-digested context:** F-2 and F-3 first, then F-1, F-5.
4. **Answer what the judge grades:** E3, E4, G12.
5. **Close the mitigation loop:** B13, G14, G7, then G9 and G8.
6. **Stay on track:** G3, D3, G13.
7. **Cut cost:** D1 in blocks, K1.
8. **Telemetry as first-class commands:** B14.
9. **Spend more per run:** H1, G5, H4, and only then H2 or D7.

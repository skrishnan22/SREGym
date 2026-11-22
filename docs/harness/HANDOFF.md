# Handoff: start of Phase 4 (design v0)

Written 2026-11-22 at the end of the session that did Phases 1 to 3. Read this first, then [NOTES.md](NOTES.md) (what was measured), then the Phase 4 section of [execution-plan.md](execution-plan.md).

## The exercise in one paragraph

Build a minimal agent harness in TypeScript from scratch (`ts-sre`), score it on SREGym-Lite (17 problems) with cheap flash models on OpenCode Go, then improve it one change at a time and measure each change. The point is learning harness design, not the leaderboard. Design: [superpowers/specs/2026-11-14-sre-harness-design.md](superpowers/specs/2026-11-14-sre-harness-design.md). Ideas menu: [improvements-catalog.md](improvements-catalog.md).

## Working with this user

- **They decide agent design; Claude lays out options and trade-offs, then builds or reviews.** Do not pick the six v0 decisions for them.
- They learn by doing. Walk through things in small steps, and after doing work, explain each step with the exact commands that ran.
- They push back on claims that sound implausible (they asked to see the raw transcript). Show evidence from files rather than summaries.
- They are cost-aware. Stop the VM at the end of every session.

## Where everything is

| What | Where |
|---|---|
| Fork | `github.com/skrishnan22/SREGym`, branch `harness`, cloned at `~/development/SREGym` (origin over SSH, `upstream` read-only) |
| Pinned SREGym commit | `b723f54`, never pull upstream (see [PINNED.md](PINNED.md)) |
| Harness docs | `docs/harness/` (this folder). `results/` is gitignored by SREGym, so tracked notes live here |
| VM | EC2 spot `c7a.2xlarge`, `i-09080670e6656f536`, us-east-1, **stopped**. AWS CLI profile `sregym` (IAM user `sregym-cli`) |
| VM helper | `scripts/harness/vm.sh start|stop|status|allow-my-ip`. `start` rewrites the `sregym-vm` entry in `~/.ssh/config` (the IP changes each start). SSH key `~/.ssh/sregym-vm` |
| On the VM | `~/SREGym` (clone of `harness`, pull-only over HTTPS), `.env` (Go key, mode 600), kind cluster `kind` with 4 nodes, `go-session-proxy` systemd service on port 8788, run scripts and logs in `~/runs/` |
| Key backup | `~/go-direct.env` on the VM: the original direct-to-Go `.env`. Outside the repo on purpose |
| First runs | On the VM under `~/SREGym/results/1122_1403` (autosubmit) and `1122_1416` (mini-sre). The mini-sre run is also copied to the Mac at `results/1122_1416/`, with the diagnosis calls written out verbatim in `results/readable/diagnosis-calls.txt` |

## Resuming

```bash
cd ~/development/SREGym
scripts/harness/vm.sh start
ssh sregym-vm
```

```bash
cd ~/SREGym && git pull
set -a; . ./.env; set +a
kubectl get nodes
```

SREGym does **not** load `.env` itself; every `main.py` command needs the `set -a` line first. If SSH times out, the user's IP probably changed: `scripts/harness/vm.sh allow-my-ip`.

## What Phases 1 to 3 established

All details and numbers are in [NOTES.md](NOTES.md).

- **OpenCode Go requires an `x-opencode-session` header** and returns HTTP 400 `MissingSessionID` without it. SREGym's judge and mini-sre never send it, so both `AGENT_API_BASE` and `JUDGE_API_BASE` point at the proxy, `http://127.0.0.1:8788` (`scripts/harness/go-session-proxy.ts`). The proxy adds the header only when absent, so `ts-sre` should send its own session ID per attempt. No `--allow-agent-endpoint` is needed; SREGym builds the allow-list from `AGENT_API_BASE`.
- **Model IDs** on Go: `glm-5.3-flash`, `mimo-v2.6-flash`, `gpt-6-luna`, passed to SREGym as `openai/<id>`. Every Go response carries `usage.opencode` (token breakdown, `allowance`); log it.
- **A run takes about 9 minutes**, not the 25 to 40 the plan guessed: about 4 minutes of fixed deploy and cleanup once images are cached, plus agent time. A 51-run dev sweep is roughly 8 hours on one VM. The budget section of the execution plan has not been updated for this yet.
- **The judge's floor**: "yes" scores 0.33, an empty answer 0.0, pass is 0.70.
- **autosubmit** on `network_policy_block`: both stages fail as expected; that problem's mitigation oracle cannot be fooled by an untouched cluster.
- **The first mini-sre run is the key input to Phase 4.** GLM-5.3-Flash failed diagnosis because in one 62,000-character reply it wrote 41 bash blocks *and invented their outputs*, a whole fictional incident (Postgres, deleted MongoDB, submissions and conductor replies). mini-sre has no stop sequence and a 65,536-token reply limit, rejected the reply as a format error but left it in history, and the model then believed its own fiction and submitted an empty diagnosis. In mitigation, with a clean context, the same model found and deleted the real NetworkPolicy in 27 real commands and verified the fix. Diagnosis was lost to protocol (failure F1), not to skill. The reply shows repeated `reasoning</think>answer` segments: GLM was generating turn after turn of its own training format without ever reaching the end-of-turn a structured tool call would give it.

## Phase 4: what to do

Run the design session from the execution plan: six decisions (briefing, action format, observation, memory, stopping, stage handoff). For each, present options with trade-offs and evidence; the user chooses. Write the choices, a reason for each, and a one-sentence predicted failure for each into `docs/harness/decisions/v0.md`.

Points already raised with the user that bear on the decisions:

- **Action format** is now the sharpest decision. Text bash block with a stop sequence keeps v0 comparable to mini-sre (the plan's check that v0 and mini-sre score within noise of each other). Native tool calling avoids the failure above but breaks that comparison. One option discussed: text format plus stop sequence for v0, native tool calling as the first improvement.
- **Reliability items probably belong in v0, not in experiment slots**, and the mini-sre run is evidence for it: stop at the first complete action, cap `max_tokens` (a few thousand), never keep text after the first action in history, strip leaked `</think>`, a format error message that says nothing ran, submission as a harness function that refuses an empty diagnosis (catalog A1 to A4, A9, A10, B11, G12).
- **History caching works**: 92% of input tokens were cached on Go, so an append-only history with a stable prefix pays (K1, D5).
- The user agreed v0 should still be "the simplest defensible answer" to each decision, so later versions have something to improve on.

## Discussed but not yet written into the plan

The user wanted these left for later ("we can get to optimization later"). Do not apply them without asking.

- **Experiment budget.** About 5 to 6 full improvement turns fit the budget, and with 17 problems and 3 repeats only changes of about 12 points or more are detectable. Remedies discussed: screen each idea with 1 repeat and confirm only promising ones; repeat only problems that flip between pass and fail; use the judge's continuous score and process metrics (did the agent inspect the faulty resource, and when) as less noisy measures; test prompt and output-shaping ideas offline by replaying saved transcripts (L3, L4); diagnosis-only sweeps for diagnosis-targeted changes.
- **Sweep time.** Parallel VMs (the spot quota request for 24 vCPUs is pending; 8 is granted), SREGym's experimental Docker-in-Docker mode with parallel problems (`docker/dind/README.md`, not yet read), and a shorter `--agent-timeout` decided once from baseline data and then frozen.
- **A stronger-model run** of v0 and of the final version, to separate harness limits from model limits.
- **OpenRouter** is a fallback only ($13 of credit). A sweep runs on one provider from start to finish, and a version is compared only against a baseline on the same provider. Pin the backend with `provider.order` and `allow_fallbacks: false`.

## Loose ends

- `~/development/sre-harness/` still exists; its docs were copied into `docs/harness/`. The plan says to delete it; ask before deleting.
- The spot quota increase to 24 vCPUs is still pending with AWS.
- The execution plan's Phase 1 to 3 checkboxes are not ticked; NOTES.md is the record of what was done.
- The default AWS CLI profile on the Mac has an invalid key; it is unrelated and was left alone.

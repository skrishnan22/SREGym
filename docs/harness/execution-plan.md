# Execution plan

How the SRE harness exercise runs from today to a final scored harness. The design it implements is in [superpowers/specs/2026-11-14-sre-harness-design.md](superpowers/specs/2026-11-14-sre-harness-design.md). Code-level tasks for the plumbing are in [superpowers/plans/2026-11-14-sre-harness-v0.md](superpowers/plans/2026-11-14-sre-harness-v0.md); where the two disagree, this document wins.

## Who does what

| Area | Owner |
|---|---|
| Agent design: briefing, action format, observations, memory, stopping, stage handoff, every later improvement | **You decide.** Claude lays out options and trade-offs, then implements or reviews. |
| Plumbing: conductor client, shell runner, model client, transcript, Python shim, sweep and summary scripts | **Claude builds**, you review. |
| Accounts and money: GitHub fork, OpenCode Go subscription and key, AWS instance | **You**, because they need your logins. |
| Running sweeps and reading scores | Claude runs; both read. |
| Reading failed transcripts and choosing the next change | **Together.** This is where most of the learning is. |

## Facts confirmed from SREGym's code

Read from commit `148dded` (2026-11-15); details and file paths are in [learning chapter 3](learning/03-sregym-and-evaluation.md). They change a few things the v0 plan assumed.

| Fact | Consequence |
|---|---|
| `--n-attempts N` repeats every problem N times with a full redeploy; it never stops at the first pass. `--resume` re-runs attempts that are not `complete`. | The sweep script uses `--n-attempts 3` and `--resume` and needs no repeat loop of its own. |
| Results land in `results/<MMDD_HHMM>/<agent>_ALL_results.csv`, with per-problem and per-attempt CSVs beneath. Columns include `problem_id`, `attempt`, `Diagnosis.success`, `Mitigation.success`, `TTL` (time to diagnosis), `TTM`, `run_status`, `timed_out`, `deploy_failed`. | The summariser reads these columns. |
| There is no token column. A custom agent's tokens are recorded nowhere unless it logs them. | Our transcript and results file are the only source for tokens; the summariser joins them to the CSV. |
| The agent is never told the problem ID. It gets only an opaque `SREGYM_ARTIFACT_ID`. | Our files are named by artifact ID; the sweep maps them to problems by the folder SREGym puts them in. |
| A run that hits the time limit is marked `incomplete`, not failed. | Our summary counts a timeout as an agent failure. Only deploy failures and API outages are excluded. |
| `/workspace` is not mounted on `main.py` runs. | Commands run from the logs directory. |
| Conductor endpoints: `GET /status`, `GET /get_app`, `POST /submit`, and an MCP `submit` tool. | As assumed. |
| SREGym runs MCP servers with tools for kubectl (including rollback), Prometheus (`get_metrics`, `get_alerts`), Jaeger (`get_services`, `get_operations`, `get_traces`, `get_dependency_graph`) and Loki (`get_logs`, `get_labels`, `get_label_values`). | These are available as a later improvement (catalog B6); v0 does not use them. |
| `autosubmit` investigates nothing: it submits "yes" for diagnosis and an empty mitigation. | It is a null baseline. Any problem whose mitigation passes under `autosubmit` is graded as fixed without a fix, and should be flagged. |

## Phases at a glance

| # | Phase | Ends when |
|---|---|---|
| 0 | Get up to speed | You can answer the self-check questions in the learning guide |
| 1 | Accounts and repository | Fork cloned, Go key exists, AWS ready |
| 2 | VM and cluster | Four kind nodes `Ready` on the VM |
| 3 | Prove the pipeline | `mini-sre` completes one problem with Luna judging |
| 4 | Design v0 | Six decisions written down in `docs/decisions/v0.md` |
| 5 | Build v0 | `ts-sre` completes one problem on the VM |
| 6 | Measurement tooling | Sweep and summary work; test set frozen |
| 7 | Baseline | v0 and `mini-sre` rows in `results/results.md` |
| 8 | Improvement loop | Repeats until budget or ideas run out |
| 9 | Wrap-up | Ablations, final test score, write-up |

---

## Phase 0: Get up to speed

Read the learning guide in [learning/](learning/README.md) in order.

- [ ] Chapter 1, harness engineering. This is the one that matters most for the design sessions.
- [ ] Chapter 2, SRE and Kubernetes. Do at least three of its exercises. A one-node kind cluster with a single small app fits on the 16 GB Mac; the full SREGym stack does not.
- [ ] Chapter 3, SREGym internals and evaluation method.
- [ ] Read one real agent transcript end to end before designing anything. The first `mini-sre` run in Phase 3 provides one.

You do not need to finish Phase 0 before Phases 1 to 3 start; they need accounts and waiting, not knowledge.

## Phase 1: Accounts and repository

- [ ] **Fork** `SREGym/SREGym` on GitHub. Clone with submodules to `/Users/skrishnan/development/SREGym`, create branch `harness`.
- [ ] **Move the docs.** Everything under `sre-harness/docs/` goes to `SREGym/docs/harness/` (kept apart from SREGym's own `docs/`). Delete `sre-harness/`.
- [ ] **Pin.** Record the upstream commit in `results/PINNED.md` with the judge, models, limits and profile. Do not pull upstream again during the exercise; a changed benchmark breaks comparisons.
- [ ] **OpenCode Go.** Subscribe, create a personal API key in the Console. In Settings, check which regions are allowed; `glm-5.3-flash` and `mimo-v2.6-flash` need no change.
- [ ] **AWS.** Confirm the region, a key pair, and that the account's vCPU quota allows an 8 vCPU instance (new accounts are sometimes capped lower; a quota request can take a day).

## Phase 2: VM and cluster

Instance: Ubuntu 24.04 x86_64, `c7a.2xlarge` (8 vCPU, 16 GB, the SREGym-Lite minimum), 100 GB gp3 disk, inbound SSH from your IP only. Move up to a 32 GB type only if pods get evicted.

Costs to know (from memory; confirm in the AWS console): the instance bills per second while running, and the disk bills all month even when the instance is stopped, a few dollars a month at 100 GB. **Stop** the instance between sessions; **terminate** it only at the end.

- [ ] Launch, add a `sregym-vm` entry to `~/.ssh/config`.
- [ ] Install Docker, kind, kubectl, Helm 4 or newer, uv 0.11.8 or newer, Python 3.12, Node 22. Take each install command from that tool's own install page.
- [ ] Raise the inotify limits and persist them (from `kind/README.md`):

```bash
echo "fs.inotify.max_user_instances=1024" | sudo tee /etc/sysctl.d/99-sregym-kind.conf
echo "fs.inotify.max_user_watches=1048576" | sudo tee -a /etc/sysctl.d/99-sregym-kind.conf
sudo sysctl --system
```

- [ ] Clone the fork with submodules, check out `harness`, run `uv sync`.
- [ ] Create the cluster and confirm four nodes:

```bash
bash kind/setup_kind_cluster.sh && kubectl get nodes
```

- [ ] Put the Go key in an untracked `.env` on the VM: `AGENT_API_KEY`, `JUDGE_API_KEY`, and both `AGENT_API_BASE` and `JUDGE_API_BASE` set to `https://opencode.ai/inference/go/openai/v1`.

## Phase 3: Prove the pipeline

No code of ours yet. If this phase fails, nothing later can be trusted.

- [ ] **Probe Go** with `curl` to `/chat/completions`: `glm-5.3-flash`, `mimo-v2.6-flash`, `gpt-6-luna`, each with `x-opencode-session` and a named `User-Agent`; then once without the session header. Record the results in `results/NOTES.md`.
- [ ] **Setup check:**

```bash
uv run main.py --agent mini-sre --model openai/glm-5.3-flash --judge-model openai/gpt-6-luna --problem network_policy_block --check-setup
```

- [ ] **One real run:** the same command without `--check-setup`, with `--force-build`.
- [ ] **If Go rejects the judge or `mini-sre`** for lacking the session header: add a small forwarding proxy on the VM that inserts it (specified in the v0 plan, Task 3 Step 5).
- [ ] **Record** in `results/NOTES.md`: wall time of the run split into deploy, agent and teardown; where the results CSV and logs landed; tokens used.
- [ ] **Read the transcript together.** This is the first look at what a flash model does with this task.

**Gate:** one problem completes with a judge verdict. Wall time per run is known, so the budget can be projected.

## Phase 4: Design v0

One working session. For each decision Claude presents the options with trade-offs and the evidence from the learning guide and the [improvements catalog](improvements-catalog.md); you choose. v0 should be the simplest defensible answer to each, so that later versions have something to improve on.

| # | Decision | The question | Simplest answer (strawman) |
|---|---|---|---|
| 1 | Briefing | What is the model told before it starts? | App name, namespace, SREGym's description, how to submit. No method advice. |
| 2 | Action format | How does the model ask for something to happen? | One fenced bash block per reply. |
| 3 | Observation | What comes back, and how much? | Exit code and raw output, cut only by a 50,000-character guard. |
| 4 | Memory | What is in the context each turn? | The whole conversation, resent every call. |
| 5 | Stopping | How does it know when to submit? What if the budget runs low? | 80 commands per stage; a budget line after each command; a wrap-up message at the limit. |
| 6 | Stage handoff | What carries from diagnosis into mitigation? | The same conversation continues. |

- [ ] Write the choices and the reason for each in `docs/harness/decisions/v0.md`.
- [ ] For each choice, write one sentence predicting how it will fail. Phase 8 checks these predictions against transcripts.

## Phase 5: Build v0

- [ ] **Plumbing (Claude):** Tasks 4, 5, 7 and the transcript half of Task 8 in the v0 plan: config, conductor client, shell runner, model client, transcript. Test-first, on the Mac, against fake conductor and model servers.
- [ ] **Agent (your design):** `prompt.ts` and `loop.ts`, built from `decisions/v0.md`. Either you write them and Claude reviews, or Claude writes them and walks you through the code; choose at the start of the phase. Tasks 6 and 8 of the v0 plan are a strawman for the strawman answers above and change if your decisions differ.
- [ ] **Entry point, shim, registration (Claude):** Task 9.
- [ ] **First real run** of `ts-sre` on `network_policy_block` on the VM.
- [ ] **Transcript reader (Claude):** `scripts/show.ts <run-folder>` renders a transcript as readable markdown: each step's reasoning, command, output (shortened), tokens and time. You will read a lot of transcripts; this makes it bearable.

**Gate:** `ts-sre` finishes both stages on one problem, and its transcript reads sensibly.

## Phase 6: Measurement tooling

- [ ] Problem sets in `results/sets/`: `dev.txt` (17 Lite), `test.txt` (15 held out), `subset.txt` (5 dev problems for quick checks).
- [ ] `scripts/sweep.sh <agent> <model> <set> <label> [repeats]` and `scripts/summarize.ts <label>` (Task 10, simplified by `--n-attempts` and `--resume` as noted above).
- [ ] `scripts/compare.ts <labelA> <labelB>`: per-problem table of pass counts for both versions, problems that flipped, and a paired bootstrap interval on the difference. Not in the v0 plan; added here.
- [ ] **Null baseline and test-set freeze:** run all 32 problems (17 dev, 15 test) once with `--agent autosubmit`. This costs no model calls beyond the judge. From the results:
  - swap in reserves for any test problem with `deploy_failed`, then commit `test.txt` and never change it again;
  - record the null scores as the first row of `results/results.md`;
  - list any problem whose mitigation passes with no fix applied. Those inflate every agent's mitigation score equally, so they are reported separately.

## Phase 7: Baseline

- [ ] **Budget gate.** Runs needed: `mini-sre` dev 51, v0 dev on two models 102, v0 test on two models 90, total 243. Multiply by measured minutes per run and the hourly price. If above $30: use a spot instance, cut the `mini-sre` reference to one repeat, and run test on `glm-5.3-flash` only.
- [ ] Journal entry for v0, written before the runs.
- [ ] Tag `v0`. Sweep `mini-sre` on dev, then `ts-sre` on dev for both models, 3 repeats each.
- [ ] **Plumbing check:** no crashed runs, every run has a transcript and a termination reason, and any gap to `mini-sre` is explained by transcripts.
- [ ] **Judge audit:** hand-check 20 diagnosis verdicts (10 pass, 10 fail). More than 3 wrong means stop and rethink the judge.
- [ ] Sweep v0 on test. Read scores only.

**Gate:** baseline rows exist and are believed.

## Phase 8: The improvement loop

One turn of the loop is one harness version. Repeat until the budget is spent or dev stops moving.

1. **Read failures.** Open every failed dev run from the last version with `show.ts`. For each, write one line: where it went wrong and why.
2. **Classify.** Tag each failure with a category from the failure taxonomy in the improvements catalog (for example: never looked in the right place, saw the evidence and missed it, right diagnosis but wrong fix, ran out of budget, format errors). Count per category.
3. **Choose one change.** Take the largest category and pick the cheapest catalog item that targets it. Design it together: options, trade-offs, your call.
4. **Journal.** Before running: the change, the failure category it targets, which problems you expect to flip, and what would make you revert it.
5. **Implement** as one commit series changing one idea.
6. **Quick check.** `sweep.sh ... subset` (5 problems, diagnosis only, 1 repeat). This catches breakage, not improvement.
7. **Full dev sweep,** 3 repeats, primary model. Run the second model too if the budget allows; otherwise at milestones only.
8. **Compare** with `compare.ts`, then decide. With 17 problems and 3 repeats, a difference under about 12 points is inside run-to-run noise, and a true 10-point gain shows up as statistically significant only about one time in five ([chapter 3, B4](learning/03-sregym-and-evaluation.md)). So significance cannot be the bar. Use dev as a screen:
   - **Keep** if the score is up, no problem that used to pass reliably now fails, and the transcripts show the change doing what the journal said it would.
   - **Keep on cost alone** if the score is flat and tokens or time are clearly down.
   - **Confirm** a kept change with 5 more repeats on only the flaky problems (the ones that pass in some repeats and fail in others); problems that always pass or always fail add nothing.
   - **Revert** otherwise, and record why.
   
   The consequence for what to try: prefer changes with a clear mechanism and a large expected effect. A 2-point tweak cannot be measured here.
9. **Tag** the kept version (`v1`, `v2`, ...) and add its row.

Milestones: run the test set at v0, roughly halfway, and at the end. If dev has climbed and test has not, stop adding and look for what was fitted to the dev problems.

Rules that hold throughout: one idea per version; no problem-specific hints in prompts; test transcripts stay unread; judge, profile, limits and SREGym commit do not change.

## Phase 9: Wrap-up

- [ ] **Ablations.** From the final version remove each kept improvement in turn; one dev sweep each. Improvements that no longer matter get removed.
- [ ] **Final test sweep,** both models, 3 repeats.
- [ ] **Transfer check (optional):** `--suite sregym-lite-ia`.
- [ ] **Write-up:** the results table, a chart of score and tokens per version, what each change did, which predictions from Phase 4 were wrong, and what you would do differently.
- [ ] Terminate the VM and delete its disk.

---

## Budget

| Item | Unit | Notes |
|---|---|---|
| One run | 1 problem × 1 repeat | Wall time measured in Phase 3 |
| Dev sweep, one model | 51 runs | 17 × 3 |
| Test sweep, one model | 45 runs | 15 × 3 |
| Quick check | 5 runs | diagnosis only, shorter |
| One improvement turn, primary model only | about 56 runs | quick check + dev sweep |

At a guessed 25 to 40 minutes per run and roughly $0.40 an hour on demand, a dev sweep on one model costs about $8 to $14. After a trimmed baseline, $100 covers on the order of four to six improvement turns on demand, and about three times that on spot. Both figures are estimates until Phase 3 measures real run time.

OpenCode Go limits are per model and per window (20% of the monthly allowance per 5 hours, 50% per week). A dev sweep is roughly 2,000 requests for the agent; `glm-5.3-flash` allows about 6,320 per 5 hours and Luna as judge about 4,230. Sweeps on different agent models draw on different allowances.

## Risks and what to do about each

| Risk | Sign | Response |
|---|---|---|
| Go rejects requests without a session header | Judge or `mini-sre` gets 4xx in Phase 3 | Header-adding proxy on the VM |
| 16 GB instance is too small | Pods evicted or stuck `Pending` | Move to a 32 GB type |
| Some held-out problems do not run on kind | Deploy or injection fails under `autosubmit` | Swap in reserves before freezing |
| Flash models cannot hold the reply format | Many `repeated_format_error` endings in v0 | That is the first improvement to consider, not a plumbing bug |
| Run-to-run noise swamps the changes | Repeat spread wider than version differences | More repeats on fewer versions; rely on paired comparison |
| Judge is unreliable | Audit finds more than 3 of 20 wrong | Try a stronger judge on the same transcripts and compare verdicts |
| Go allowance runs out mid-sweep | 429s; runs marked `infra` | Sweep resumes after the window; the script re-runs `infra` runs |
| Budget runs short | Projection at a gate exceeds what is left | Spot instances, one agent model, fewer test milestones |
| Fitting to the dev set | Dev rises, test flat | Stop, ablate, look for changes that only help named problems |

# SRE harness learning exercise: design

Date: 2026-11-14. Status: awaiting approval.

## Intent

Learn agent-harness design by doing it: write a minimal agent loop from scratch, score it on the SREGym benchmark with cheap models, then add one improvement at a time and measure what each one buys.

The output that matters is the understanding and a results table that shows which harness changes moved the score. A leaderboard submission is not the goal.

## Goals

- A from-scratch agent loop in TypeScript that runs as a SREGym agent.
- A repeatable way to score a harness version: one command, one row in a results table.
- A sequence of harness versions, each differing from the last by one idea, each scored on the same problems, models and judge.
- Transcripts kept for every run, so the next improvement is chosen by reading failures.

## Non-goals

- Beating the leaderboard, or submitting to it.
- The full 90-problem suite. SREGym-Lite (17 problems) only.
- Supporting many model providers. One endpoint: OpenCode Go.
- A general-purpose agent framework. The code serves this exercise.

## Anti-goals

- Bundling several changes into one version. If two things change, the score can't be attributed.
- Changing the judge, the problem set or the deployment profile between versions.
- Tuning to individual Lite problems (for example, hints about a specific fault). That measures memorisation of 17 problems, not harness quality.
- Building on an existing agent (mini-sre, OpenCode, Stratus). Their design decisions are what this exercise is meant to teach.

## Decisions made with the user

| Decision | Choice |
|---|---|
| Benchmark | SREGym-Lite, `full` profile |
| Harness | Own agent loop, written from scratch |
| Language | TypeScript |
| Model access | Hosted only, through an OpenCode Go subscription |
| Judge | GPT 6 Luna, fixed for every run |
| Agent models | Flash-tier models |
| Where it runs | A rented Linux VM. The user's 16 GB MacBook Air cannot hold the cluster. AWS EC2 with $100 of credits is the working assumption. |

## Approaches considered

1. **Own loop from scratch (picked).** Every design decision is written and measured by the user. Costs about a day of plumbing before the first score.
2. **Fork `clients/mini_sre` and iterate.** Fastest first score, but inherits its prompt, limits and action format.
3. **Use OpenCode as the harness and tune prompts and config.** Go works natively, but the loop internals stay hidden.

The user picked 1, in TypeScript. `mini-sre` stays in the picture only as a baseline to compare against.

## How SREGym runs an agent (from the repo, 2026-11-14)

- An agent is an entry in `agents.yaml`: `name`, `kickoff_command`, `kickoff_workdir`, `kickoff_env`, `install_script`, `agent_version`. Existing drivers are Python modules under `clients/<name>/driver.py`.
- The agent runs inside a Docker container built from the local checkout (`--force-build` rebuilds it). Network is filtered: the model endpoint and SREGym's own services are reachable, nothing else. `--allow-agent-endpoint` adds a destination.
- The driver talks to a "conductor" at `http://$API_HOSTNAME:$API_PORT`: `GET /get_app` for application info, `GET /status` for the current stage and `agent_remaining_seconds`, and a `/submit` endpoint for answers.
- Environment the driver receives includes `AGENT_MODEL_ID`, `AGENT_API_BASE`, `AGENT_API_KEY`, `AGENT_REASONING_EFFORT`, `AGENT_LOGS_DIR`.
- Each problem has two stages, diagnosis then mitigation, sharing one time limit (`--agent-timeout`, 1800 s by default). `--stages diagnosis` runs the first only.
- SREGym writes a results CSV named after the agent, and `trajectory.json` per run.
- `mini-sre` reference limits: 80 commands per stage, 60 s per command, diagnosis may use two thirds of the time.

## Design

### Repository layout (my call)

One repo: a fork of SREGym, with the agent in `clients/ts_sre/`. The agent image is built from the checkout, so living inside the fork avoids a second packaging step. Harness versions are git tags (`v0`, `v1`, ...).

```
clients/ts_sre/
  driver.py          # thin shim: start the Node process, pass env through, map exit codes
  agent/             # the TypeScript agent
    src/
      main.ts        # stage loop: wait for stage, run it, move on
      loop.ts        # one stage: call model, run action, feed result back
      model.ts       # OpenCode Go client (OpenAI-compatible chat completions)
      conductor.ts   # /get_app, /status, /submit
      shell.ts       # run a command with a timeout, capture output
      prompt.ts      # all prompt text in one place
      transcript.ts  # JSONL log of every model call and command
      config.ts      # limits and settings read from env
agents.yaml          # one added entry: ts-sre (no install script: the agent image already has Node 22 and copies clients/)
results/
  results.md         # one row per (version, model) sweep
  runs/              # transcripts copied out per sweep
scripts/sweep.sh     # run a sweep and append the row
```

The shim stays as small as possible. All behaviour lives in TypeScript.

### v0: the minimal loop

- The model gets a system prompt, the task text from the conductor, and the rule that each reply contains exactly one bash command.
- The agent runs the command in a fresh shell, and sends back exit code and output.
- This repeats until the model submits through the conductor, or a limit is hit: commands per stage, per-command timeout, stage time read from `/status`.
- The full conversation is resent on every call. No tools beyond bash, no planning, no investigation advice in the prompt. Command output is passed through unshaped, except for a guard that cuts a single output at 50,000 characters so one command cannot destroy the context.
- Same limits as `mini-sre` (80 commands, 60 s per command, two-thirds time share), so the two are comparable.

**Check before improving anything:** v0 and `mini-sre` on the same model should score within noise of each other. If they don't, the plumbing is wrong.

### Model client

- OpenAI-compatible chat completions against the OpenCode Go endpoint, key from `AGENT_API_KEY`.
- Go asks custom clients to send their own user agent and a stable `x-opencode-session` header per conversation. One session ID per problem attempt.
- Record token usage from every response, including Go's `opencode.allowance` figure.
- Retry transient failures with backoff. Two consecutive failures end the stage.

### Models

| Role | Model | Why |
|---|---|---|
| Agent A | GLM-5.3-Flash | Main workhorse; about 6,320 requests per 5 hours on Go |
| Agent B | MiMo-V2.6-Flash (my call) | Cheapest on Go, about 30,100 requests per 5 hours; shows whether a change helps flash models in general |
| Judge | GPT 6 Luna | Fixed; never grades its own runs |

A Lite sweep is roughly 17 problems × 40 calls ≈ 700 requests (my estimate), inside both agents' 5-hour windows.

### Measurement

#### Dev and test sets

- **Dev set: the 17 SREGym-Lite problems.** Transcripts are read freely and the harness is tuned against them.
- **Test set: 15 held-out problems from outside Lite** (list below). Run only at milestones: v0, a midpoint, and the final version. Test transcripts are never read while the harness is still changing; only the scores are looked at. Dev rising while test stays flat means overfitting.
- **Optional transfer check at the end:** `--suite sregym-lite-ia`, the Lite faults ported to three other applications.

Test problems, chosen by hand on 2026-11-14 from the current registry. Selection rules: uses one of the three Lite applications, is a Kubernetes- or application-level fault, and is not the same fault class as any Lite problem (no "same fault, different app" siblings). Excluded: TrainTicket, hardware, kubelet and node-level faults, operator faults, and the GitLab, Stripe, Frappe, Saleor and Slack applications.

| Application | Problems |
|---|---|
| Hotel reservation | `misconfig_app_hotel_res`, `revoke_auth_mongodb-1`, `configmap_drift_hotel_reservation`, `expired_tls_hotel_reservation`, `priority_preemption_cascade_hotel_reservation`, `sidecar_port_conflict_hotel_reservation` |
| Social network | `scale_pod_zero_social_net`, `taint_no_toleration_social_network`, `liveness_probe_too_aggressive_social_network`, `init_container_dependency_hang_social_network` |
| Astronomy shop | `astronomy_shop_cart_service_failure`, `astronomy_shop_ad_service_high_cpu`, `postgres_lock_contention_product_catalog`, `service_port_conflict_astronomy_shop`, `integer_overflow_primary_key_astronomy_shop` |

Reserves, in order, if any of the 15 fails to deploy on kind: `stale_hostaliases_dns_poisoning_astronomy_shop`, `psa_restricted_blocks_recreation_hotel_reservation`, `wrong_bin_usage`, `auth_miss_mongodb`, `resource_request_too_small`.

Kind compatibility is not confirmed. The registry blocks only one problem on emulated clusters (`node_clock_drift_hotel_reservation`), and the Lite doc says only that TrainTicket, hardware and "other hard to run" faults were left out. Each test problem must be run once on the VM with the `autosubmit` agent (no model calls) to confirm it deploys and injects its fault. Swap in reserves for failures, then freeze the list before v0 is scored.

#### Sweeps and rows

- One sweep = one harness version × one agent model × one problem set, both stages.
- Full dev sweeps run 3 times (`--n-attempts` or three sweeps); the row reports mean and spread. Test sweeps also run 3 times.
- Each row: version, model, set, diagnosis %, mitigation %, end-to-end %, mean tokens, mean time, and a count of how stages ended (submitted, hit command cap, hit time limit, format errors, model failure). Cost sits next to accuracy.
- Versions are compared problem by problem (which flipped, in which direction), not only by average. With 17 problems one problem is 5.9 points, so a single flip is not evidence.
- For quick iteration between sweeps: a fixed 5-problem dev subset, single run, `--stages diagnosis`. Subset numbers guide work; only full sweeps go in the results table.

#### Experiment discipline

- **Hypothesis first.** Each version gets one line in `results/journal.md` before it runs: what changed and what is expected.
- **Best-of-many is discounted.** If several variants are tried on dev and the best kept, its lead is partly luck; the test set is the correction.
- **Ablation at the end.** Remove each improvement from the final version, one at a time, and re-score on dev.
- **Judge audit, once.** Hand-check about 20 of Luna's diagnosis verdicts against the transcripts before trusting small differences.
- **Infrastructure failures are not agent failures.** A failed deploy or an API outage is re-run, not scored.
- **Everything else is pinned** and recorded with each row: SREGym commit, model IDs, temperature, limits, judge model, profile.

### Improvement ladder (proposal, order not fixed)

After each sweep, read the failed transcripts and pick the next change from what went wrong. Likely candidates:

1. Native tool calling in place of parsing a bash block from text.
2. Output handling: truncate or summarise long command output.
3. Context management: stop resending everything once the conversation is long.
4. Domain prompt: a short SRE method (observe, hypothesise, test, fix, verify).
5. Structured tools: purpose-built kubectl, logs and metrics tools, or SREGym's MCP tools.
6. A scratchpad of hypotheses and findings carried between steps.
7. Verify before submit: re-check the system after a mitigation.

Each becomes one tagged version and one or more rows.

### Infrastructure

- One Linux VM, 8 vCPU and 32 GB (on EC2, an `m7i.2xlarge`-class instance), Ubuntu, with Docker, kind, kubectl, Helm, uv and Node.
- SREGym, the kind cluster and the agent container all run on the VM. Code is written on the Mac and pulled on the VM.
- The VM is stopped when not sweeping. Disk persists, so images stay cached.
- Budget, from memory and to be checked against current pricing: on-demand is around $0.40 per hour, so $100 is about 250 hours. One pass over 17 problems is at most 17 × (30 min agent + deploy time), so somewhere between 4 and 11 hours, or about $2 to $5. With 3 repeats, two agent models, and three test milestones, the credits cover roughly 4 to 6 fully scored versions on on-demand pricing. Spot instances would stretch that about threefold; dropping to one agent model for intermediate versions would double it. The SREGym Lite doc names `c7a.2xlarge` (8 vCPU, 16 GB) as the minimum, which is cheaper than a 32 GB instance.

## Constraints

- OpenCode Go limits are per model: 20% of the monthly allowance per 5 hours, 50% per week.
- Go expects coding-agent-like traffic with a session header and a named user agent.
- The agent container is hardened and network-filtered; anything the agent needs must be in the image at build time.
- AWS credits: $100 total.

## To verify first (before any harness work)

1. The exact OpenCode Go base URL and model IDs for GLM-5.3-Flash, MiMo-V2.6-Flash and GPT 6 Luna.
2. That SREGym's judge accepts Go through `JUDGE_API_BASE` and `JUDGE_API_KEY`, and that the network filter lets the agent reach Go (else `--allow-agent-endpoint`).
3. That the AWS credits cover EC2.
4. That `mini-sre` completes one Lite problem end to end on the VM with GLM-5.3-Flash. This proves cluster, judge and endpoint before any of our code exists.
5. How Node gets into the agent image (what `install-opencode.sh` does), and how the model submits: the exact `/submit` request shape.

## Left to the builder

- TypeScript tooling (runtime, bundling, test runner).
- Exact prompt wording for v0.
- The shape of `sweep.sh` and the results row format.
- Which 5 problems form the quick-iteration subset (pick a spread of difficulty from `docs/SREGym-Lite.md`).
- VM provisioning steps (manual console setup is fine; no infrastructure-as-code needed).

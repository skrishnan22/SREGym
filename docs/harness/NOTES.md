# Run notes

Findings from setting up and running the exercise, newest last. `results/` is gitignored by SREGym, so tracked notes live here.

## 2026-11-22: VM and OpenCode Go probe (Phase 2–3)

**VM.** `c7a.2xlarge` spot in us-east-1 (8 vCPU, 15 GB, 96 GB gp3), Ubuntu 24.04.5. Docker 29.10.0, kind v0.33.0, kubectl v1.37.2, Helm v4.3.2, uv 0.13.9, Python 3.12.3, Node v22.23.5. `kind/setup_kind_cluster.sh` gave four `Ready` nodes on Kubernetes v1.32.5 and 16 running system pods. `ufw` is inactive.

**Go models.** `GET /models` lists `glm-5.3-flash`, `mimo-v2.6-flash` and `gpt-6-luna` under exactly those IDs. With LiteLLM in SREGym they are passed as `openai/<id>`.

**Probe** (one short request each, `x-opencode-session` and a named `User-Agent` set):

| Model | HTTP | Time | Reasoning returned | Note |
|---|---|---|---|---|
| `glm-5.3-flash` | 200 | 1.0 s | yes, in a separate field | 97 of 109 output tokens were reasoning |
| `mimo-v2.6-flash` | 200 | 3.7 s | yes | slowest of the three |
| `gpt-6-luna` | 200 | 1.0 s | no text, 17 reasoning tokens counted | |

All three answered with a correct fenced bash block.

**Usage fields.** Every response carries `usage.opencode` with `list_cost`, `allowance` and a token breakdown (`input`, `output`, `reasoning`, `cache_read`, `cache_write_5m`, `cache_write_1h`). Our transcript should log this block as is. Luna's `allowance` was 4x its `list_cost` on this request; GLM and MiMo were 1x.

**Session header is required.** Without `x-opencode-session`, Go returns HTTP 400 `MissingSessionID`, whatever the `User-Agent`. SREGym's judge (LiteLLM) and `mini-sre` never send it; nothing in `llm_backend/`, the judge or `clients/mini_sre/` sets custom headers.

**Fix: `scripts/harness/go-session-proxy.ts`**, a systemd service (`go-session-proxy`) on the VM, listening on `0.0.0.0:8788` (security group allows port 22 only). It forwards to the Go base URL, adds a session header when the request has none, keeps one when present, and forwards `Authorization` unchanged, so it holds no key. Tested: plain request, streaming, and from a Docker container via `host.docker.internal`.

`.env` on the VM now has `AGENT_API_BASE` and `JUDGE_API_BASE` set to `http://127.0.0.1:8788`. SREGym rewrites loopback hosts to `host.docker.internal` for agent containers. The previous direct-to-Go `.env` is kept at `~/go-direct.env` (outside the repo).

## 2026-11-22: `--check-setup` passes

SREGym does not load `.env` itself; every command runs after `set -a; . ./.env; set +a`.

```bash
uv run main.py --agent mini-sre --model openai/glm-5.3-flash --judge-model openai/gpt-6-luna \
  --problem network_policy_block --check-setup
```

First pass: 15 pass, 1 warning, 2 skipped, all because the agent image was not pulled. After `docker pull` of the pinned `ghcr.io/sregym/agent-base:sha-a4c6bf3…` image (1.79 GB), all 18 checks pass, including "Container to host", "Temp folder mounts" and the judge answering through the proxy.

The filtered-network allow-list is derived from `AGENT_API_BASE` (it reports "agent may reach: 127.0.0.1"), so `--allow-agent-endpoint` does not appear to be needed for the proxy. The first real run confirms it.

## 2026-11-22: first `autosubmit` run, `network_policy_block`

```bash
uv run main.py --agent autosubmit --model openai/glm-5.3-flash --judge-model openai/gpt-6-luna \
  --problem network_policy_block
```

Results in `results/1122_1403/` on the VM. `run_status` complete, no timeout, no deploy failure, 0 blocked requests. Wall time 474 s.

| Phase | Seconds |
|---|---|
| deploy | 272 |
| undeploy leftovers, fix_kubernetes, inject | 8 |
| stage: diagnosis | 6 |
| stage: mitigation | 55 |
| evaluate diagnosis + mitigation | 13 |
| cleanup | 102 |

**Fixed overhead per run is about 6.5 minutes** (deploy plus cleanup), before any agent time. This was the first deploy on a fresh VM, so it includes image pulls; later deploys may be faster. Per-run time is roughly 6.5 min + agent time.

**Grading behaved as expected.** Diagnosis failed. Mitigation failed with `fault_still_present`, class `agent_error`, so this problem's oracle does not pass an untouched cluster.

**The judge's floor is 0.33, not 0.** The answer "yes" scored 0.33 in each of the three dimensions (one of three checklist questions answered yes in each). If the continuous composite score is used as a metric, 0.33 is "said nothing useful", and the pass mark is 0.70. (An empty answer scores 0.0; see the next run.)

## 2026-11-22: first `mini-sre` run, `network_policy_block`, GLM-5.3-Flash

```bash
uv run main.py --agent mini-sre --model openai/glm-5.3-flash --judge-model openai/gpt-6-luna \
  --problem network_policy_block
```

Results in `results/1122_1416/` on the VM. **Diagnosis FAIL (empty answer, score 0.0), mitigation PASS.** `run_status` complete. The model reached Go through the proxy from inside the filtered container, with no `--allow-agent-endpoint`.

The fault: a NetworkPolicy `deny-all-recommendation` isolating the `recommendation` pods.

**Timing.** Wall 541 s. Deploy 142 s (272 s on the first run; images were cached), cleanup 100 s, diagnosis stage 96 s, mitigation stage 174 s. **Fixed overhead is about 4 minutes** once images are cached; this whole run took 9 minutes.

**Tokens.** 988K input (909K of it cached, 92%), 28K output (8.7K reasoning), 30 model calls. Diagnosis: 2 calls, 1 command. Mitigation: 28 calls, 27 commands.

### What happened in diagnosis

1. **Call 1 wrote a whole imaginary investigation.** One reply, 92 s, 15,135 output tokens, 20,000 characters, 41 bash blocks, each followed by output the model *made up* ("geo CrashLoopBackOff with 28 restarts", MongoDB theories, image paths). None of it ran. A `</think>` tag leaked into the content, so reasoning and answer were mixed. mini-sre rejected the reply for having 41 actions instead of one, but the reply stayed in the history.
2. **Call 2 believed its own fiction.** "The mitigation is already applied and verified (all pods healthy, end-to-end tests passing)", then it submitted `{"solution": ""}` for diagnosis. Nothing stopped an empty diagnosis.

### What happened in mitigation

A real, competent investigation. Real pod listing, logs, Consul service catalogue, Jaeger traces, direct TCP checks with `nc`, then `kubectl get networkpolicy` at command 21, the policy's YAML at 22, `kubectl delete networkpolicy deny-all-recommendation` at 23, and four verification commands (TCP, the `/recommendations` endpoint, a frontend restart, a final check of all endpoints) before submitting. So the model *can* find this fault; the diagnosis stage lost it to a protocol failure, not to a lack of skill.

Two blocked requests: `raw.githubusercontent.com` at agent start, and the agent curling Jaeger through a kind node's NodePort (`172.18.0.4:31589`). It recovered by using in-cluster DNS from a throwaway pod.

### Lessons for our harness (catalog references)

| Seen | Catalog | Change for v0 or later |
|---|---|---|
| Model writes many actions with invented outputs in one reply | A1, A4, F1 | Stop generation after the first complete bash block (stop sequence or cut at the first closing fence) and never keep invented observations in history; cap `max_tokens` well below 15K |
| Reasoning leaks into `content` (`</think>`) | A3 | Strip anything up to a stray `</think>` before parsing |
| Empty diagnosis submitted | A9, A10, G12 | Submission as a harness function that refuses an empty or evidence-free diagnosis |
| Same model fixes the fault given a clean start | — | Evidence that v0 failures may be mostly protocol (F1), so the reliability items are worth building into v0 rather than testing one by one |
| Context 92% cached | K1, D5 | Append-only history pays off on Go; keep the prefix stable |

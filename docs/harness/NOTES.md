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

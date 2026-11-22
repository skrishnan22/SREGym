# Chapter 3: How SREGym Runs and Grades an Agent, and How to Run Trustworthy Experiments on It

After reading this chapter you will be able to trace one SREGym problem from deploy to graded result, wire a custom TypeScript agent into that flow, and know which output fields to trust. You will also be able to decide, with 17 dev problems and noisy LLM runs, whether a change to your agent is a real improvement or luck.

**Source snapshot.** Part A comes from a read of `github.com/SREGym/SREGym` at commit `148dded` (2026-11-15). Every claim cites the repo-relative file it came from. Where the code is ambiguous I say so; where I could not find something I write "not found". The repo moves quickly, so re-check anything load-bearing. As in earlier chapters, this one names no problem's root cause or fix.

---

# Part A: How SREGym runs and grades one problem

## A1. Life of one problem in `main.py`

`main.py` is the CLI and the driver. A driver thread deploys problems and launches the agent while the conductor's HTTP API serves on the main thread (`main.py`, `_run_benchmark`).

**One-time setup.** `_configure_model_environment` turns `--model` into `AGENT_MODEL_ID`, `--judge-model` (or `--model`) into `JUDGE_MODEL_ID`, and `--reasoning-effort` into `AGENT_REASONING_EFFORT`. `API_PORT` defaults to 8000 and `MCP_SERVER_PORT` to 9954. The agent image is checked (or rebuilt with `--force-build`), the agent's install script runs once, and a preflight runs for built-in agents only (`run_preflight_check` has a hard-coded module map, so a custom name is skipped). A judge preflight call runs before the first problem if an active stage uses the LLM judge (`main.py`; `sregym/conductor/conductor.py`, `_preflight_active_oracles`).

**Per problem, per attempt** (`main.py`, `driver_loop`):

1. `claim_results_dir()` creates `results/<MMDD_HHMM>/` once per invocation. A phase ledger `phases_attempt<N>.jsonl` is bound.
2. **Deploy.** `conductor.start_problem()` runs `fix_kubernetes`, undeploys leftovers, deploys the app, then sleeps the problem's `baseline_duration_s` (default 0 in `sregym/conductor/problems/base.py`; `--baseline` overrides) (`conductor.py`, `start_problem`). On an exception `main.py` retries up to 3 deploys with cleanup between. After 3 failures the attempt is recorded `deploy_failed` and **all remaining attempts of that problem are skipped**.
3. **Fault injection.** `_advance_to_next_stage(0)` runs the optional `before_fault_injection` hook, snapshots the healthy cluster for the mitigation oracle, calls `problem.inject_fault()`, then sleeps `propagation_duration_s` (default 0; `--propagation` overrides). The stage becomes `diagnosis` and submissions are accepted (`conductor.py`, `_inject_fault`, `_advance_to_next_stage`).
4. **Agent launch.** `RunArtifacts.create` makes an opaque ID `anon_<32 hex>` and a staging directory (`sregym/run_artifacts.py`). The launcher starts the container with `AGENT_LOGS_DIR` pointing at it. Only after launch does the driver set the deadline `now + agent_timeout` (`main.py`).
5. **Wait loop.** Once a second the driver checks the deadline, whether the agent process exited, and whether the stage is `done`.
6. **Grading.** `POST /submit` is accepted and evaluated on a background thread (`conductor.submit` then `_submit_evaluate_and_advance`). Results go to `conductor.results["Diagnosis"]`, `["Mitigation"]`, `TTL`, `TTM`.
7. **Teardown.** After the last stage, `_finish_problem` sets `tearing_down`, recovers the fault, undeploys the app, and sets `done` (`conductor.py`).
8. **Publish.** The driver waits up to 60 s for the agent to exit (`AGENT_REAP_GRACE_SECONDS`), stops the container, writes the CSV row, restores the real problem ID into artifact paths, writes `fault-spec.json`, converts the log to `trajectory.json`, and rewrites the CSVs (`main.py`, `run_artifacts.py`, `sregym/traces/postprocess.py`).

### `--n-attempts` repeats every time; it does not retry until pass

`--n-attempts N` runs all N attempts of every problem regardless of outcome. The code builds `attempts_to_run = [1..N]` minus attempts already complete in a `--resume` CSV and loops over all of them; nothing exits early on a pass (`main.py`, `driver_loop`). Attempts run sequentially per problem (all of A, then all of B), each with a full redeploy. Consequences:

- Repeats of one problem run back to back, so slow infrastructure drift is correlated within a problem. When comparing two configs, interleave or randomize run order instead of running all of A then all of B.
- A deploy failure on attempt 1 cancels attempts 2 and 3 for that problem. Check `deploy_failed` before computing means.

### CLI flags

| Flag | Default | Exact effect | Source |
|---|---|---|---|
| `--problem ID` | none | Run one problem. Mutually exclusive with `--suite`. Unknown ID exits 1. | `main.py` |
| `--suite NAME` | none | Named set. Choices: `sregym-lite` (17 problems), `sregym-lite-ia` (17). With neither flag the registry's default selection runs (not traced). | `main.py`, `sregym/conductor/problem_sets.py` |
| `--agent` | `stratus` | Name looked up in `agents.yaml`; missing exits 1. | `main.py`, `sregym/agent_registry.py` |
| `--model` | `gpt-5` | LiteLLM string. Sets `AGENT_MODEL_ID` and is also the judge model unless `--judge-model` is set. | `main.py` |
| `--judge-model` | `--model` | Sets `JUDGE_MODEL_ID`. | `main.py` |
| `--stages` | all supported | `diagnosis`, `mitigation`, in order. Naming a stage with no oracle is an error. | `main.py`, `conductor.py` |
| `--n-attempts` | 1 | See above. Must be >= 1. | `main.py` |
| `--resume CSV` | none | Reuses "complete" rows and skips them. Incomplete attempts, timeouts included, are rerun. | `main.py`, `sregym/results/resume.py` |
| `--agent-timeout` | 1800 | Seconds for the whole agent phase (both stages), from agent launch. | `main.py`, `README.md` |
| `--profile` | `full` | `svelte` removes components and "changes what an agent can observe, so its results are not comparable with `full`". | `main.py`, `README.md` |
| `--force-build` | off | Rebuild the agent image instead of only checking it exists. | `main.py`, `sregym/agent_launcher.py` |
| `--internet-access` | `filtered` | `filtered`: only the model provider and local SREGym services. `open`: unrestricted. | `main.py`, `README.md` |
| `--allow-agent-endpoint URL` | none | Repeatable. Adds one endpoint to the filtered allow-list; no effect with `open`. | `main.py`, `docs/network-access.md` |
| `--check-setup` | off | Checks tools, Docker, cluster, network policy, and credentials, prints fixes, exits without running. `--check-setup-offline` skips the live judge request. | `main.py`, `sregym/setup_check.py` |

Also comparability-relevant: `--judge-backend`, `--reasoning-effort`, `--container-hardening`, `--noise`, `--baseline`, `--propagation` (`main.py`). Record them all in your journal.

## A2. The conductor HTTP API

FastAPI on `$API_BIND_HOST:$API_PORT` (default `0.0.0.0:8000`) (`sregym/conductor/conductor_api.py`). The repo defines exactly these routes, and I found no others (FastAPI's `/docs` and `/openapi.json` are framework defaults):

| Route | Purpose |
|---|---|
| `GET /status` | Stage and time remaining |
| `GET /get_app` | Application description |
| `POST /submit` | Submit an answer for a stage |
| MCP over SSE at `/submit_mcp/sse` (`/submit_mcp/messages/`) | One tool, `submit(ans, stage=None)`, same code path as `POST /submit` |

**`GET /status`** returns `{"stage": str, "agent_remaining_seconds": float}`. The banner in `run_api` lists `setup | diagnosis | mitigation | tearing_down | done`. The code also sets `"aborted"` when a stuck evaluator is abandoned (`conductor.abandon_submission_work`) and `stage` is `None` before the first problem. `agent_remaining_seconds` is `max(0, deadline - now)` once the driver has set the deadline, the configured timeout before that, and omitted if neither exists. HTTP 400 if no problem started.

**`GET /get_app`** returns `{"app_name", "namespace", "namespaces", "descriptions", "stages"}`. `stages` lists the configured stage names, so an agent can detect mitigation-only problems.

**`POST /submit`** takes `{"solution": "<string>", "stage": "diagnosis" | "mitigation" | null}`. Success is HTTP 200 with `{"status": "200", "message": "Submission received", "stage": "<accepted stage>"}`. Three behaviors shape agent design:

- **The response is not a grade.** The conductor accepts and then evaluates in the background ("Kicks off evaluation in the background and returns immediately", `conductor.submit`). The agent never learns whether it passed, so it must self-verify before submitting.
- **Send `stage` explicitly.** If omitted, the conductor infers it: current stage if `mitigation`; otherwise `diagnosis`, except an empty string arriving during diagnosis grading counts as early mitigation (`conductor.register_submission_request`).
- **The call can block.** If the requested stage is not yet current, it polls up to 300 s (`_SUBMISSION_WAIT_SECONDS`) then returns 503. Set client timeouts above 300 s; the bundled clients use 310 s (`clients/autosubmit/autosubmit_agent.py`).

Errors are `{"detail": "..."}`: 400 (no problem, unknown stage, grading exception), 409 (stage passed, attempt closed, evaluation in progress, still in `setup`), 503 (stage never became available).

**Stage machine.** Agent stages are `diagnosis` then `mitigation` (`ALL_STAGES` in `conductor.py`; `SUBMISSION_STAGE_ORDER` in `sregym/conductor/submission.py`). State flows `setup` → `diagnosis` → `mitigation` → `tearing_down` → `done`. A stage exists only if the problem attaches the matching oracle (`_build_stage_sequence`).

**Time limit.** One budget covers both stages. When `time.monotonic()` passes `agent_deadline_monotonic`, the driver kills the agent after a 60 s grace, sets `timed_out` and `agent_timeout_seconds`, waits up to 300 s for an already-accepted evaluation, and records the attempt `incomplete` with reason `agent_timeout` if a stage has no result (`main.py`). The clock starts at agent launch, so container startup counts, and grading time is not paused. Agents read the remainder from `GET /status`; mini-sre does so after every command (`clients/mini_sre/driver.py`).

## A3. How an agent is registered and launched

`agents.yaml` (or the file in `$SREGYM_AGENT_REGISTRY`) lists agents. Fields (`AgentRegistration` in `sregym/agent_registry.py`):

| Field | Default | Meaning |
|---|---|---|
| `name` | required | The `--agent` value; also names results directories and files |
| `kickoff_command` | none | Shell command run in the container |
| `kickoff_workdir` | none | Used only on the non-container path (`agent_launcher.py`, `Popen(cwd=...)`); in a container the working directory is `/logs` |
| `kickoff_env` | `{}` | Extra environment for the agent |
| `install_script` | none | Script from `docker/agents/install-scripts/` run first |
| `agent_version` | none | Passed to the script as `AGENT_VERSION` |
| `container_isolation` | `true` | `false` runs on the host and is refused in filtered mode (`main.py`) |
| `cluster_access` | `true` | `false` withholds kubeconfig and egress to the K8s proxy and MCP server; needs filtered mode |
| `hooks` | none | `module:attribute` with `before_fault_injection` / `after_fault_injection` |

The template to copy is `mini-sre`: `python -m clients.mini_sre.driver` with `kickoff_env` for `MINI_SRE_HARD_CAP` and `MINI_SRE_DIAGNOSIS_SHARE` (`agents.yaml`).

**Launch.** `AgentLauncher._start_containerized` composes `[install_script] && <kickoff_command> 2>&1 | tee /logs/driver.log`, records `/logs/install.rc` and `/logs/driver.rc`, and runs `docker run` (`agent_launcher.py`; `sregym/service/container_runner.py`, `build_composite_command`).

**Image.** `docker/agents/Dockerfile`: Ubuntu 24.04, Node 22, Python 3.12 in `/opt/venv`, `kubectl`, the pip packages in `docker/agents/requirements-container.txt`, and `clients/`, `logger/`, `llm_backend/`, parts of `sregym/`, and the install scripts under `/opt/sregym`. `PYTHONPATH=/opt/sregym`, `WORKDIR /logs`, `ENTRYPOINT ["/bin/bash","-c"]`. The default image is a pinned GHCR digest without your code (`container_runner.py`, `DEFAULT_AGENT_IMAGE`); `--force-build` builds `sregym-agent-base:latest` from your checkout. The mini-sre README says so directly (`clients/mini_sre/README.md`).

**For a TypeScript agent.** Node 22 is in the image. In filtered mode install scripts run once on an open network before evaluation (`ContainerRunner.prepare_agent_tools`); afterwards `npm install` and `apt-get` fail (network filter, dropped capabilities). So bake your agent in: put it under `clients/`, build it in the Dockerfile or an install script, and use a small Python `kickoff_command` that execs it. I found no documented path for third-party TypeScript agents; this is the mechanism the code supports.

**Environment the agent receives** (`container_runner.py`, `_build_env_vars`, `_build_base_docker_args`; `agent_launcher.py`):

| Variable | Value |
|---|---|
| `AGENT_MODEL_ID`, `AGENT_REASONING_EFFORT` | From `--model`, `--reasoning-effort` |
| `AGENT_API_BASE`, `AGENT_API_KEY`, provider keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, ...) | Forwarded from your host when non-empty (`API_KEY_VARS`); loopback hosts rewritten to `host.docker.internal` |
| `AGENT_LOGS_DIR` | `/logs` |
| `SREGYM_ARTIFACT_ID` | Opaque `anon_<hex>` |
| `API_HOSTNAME`, `API_PORT` | Conductor address; `API_HOSTNAME` is `host.docker.internal` in filtered mode |
| `MCP_SERVER_PORT`, `MCP_SERVER_URL` | SREGym MCP server |
| `KUBECONFIG` | `/root/.kube/config` when cluster access is on |
| `AGENT_INTERNET_ACCESS`, `HTTP_PROXY`/`HTTPS_PROXY`, CA-bundle vars | Filtered-mode proxy settings (`sregym/service/docker_egress.py`) |
| `kickoff_env` entries | From `agents.yaml` |

**The problem ID is not passed to the agent.** `SREGYM_PROBLEM_ID` is removed from the agent environment (`agent_launcher.py`); the agent gets only `SREGYM_ARTIFACT_ID` (`clients/harness/problem_id.py`). Finalization scans the agent's log directory and rejects the run if the real problem ID appears in any file or path (`run_artifacts.py`, `_find_token_hit`). `JUDGE_MODEL_ID`, `JUDGE_API_BASE`, and `JUDGE_API_KEY` are stripped from the agent environment (`container_runner.py`).

**Mounts** (`_build_base_docker_args`):

- `/logs`: read-write; the host staging directory. Whatever your agent writes here is published under `results/.../run_<N>/`.
- `/root/.kube/config`: read-only; a filtered kubeconfig for SREGym's K8s API proxy, which hides chaos and load-generator namespaces (`main.py`, `start_k8s_proxy`). Only with `cluster_access`.
- `/opt/sregym/SREGym-applications/{socialNetwork,hotelReservation}/wrk2`: read-only. `/opt/agent-tools`: read-only volume when an install script was prepared. `~/.aws` read-only, only when AWS credentials are selected.
- `/workspace`: the runner supports it, but `_start_containerized` sets `workspace_path = None`, so **a `main.py` run mounts no `/workspace`** (`agent_launcher.py`). The README still mentions it. Treat `/logs` as your only writable output.

**Network and hardening.** In filtered mode an egress proxy container is the only route out. The allow-list is `host.docker.internal:$API_PORT`; with `cluster_access`, the K8s proxy port 16443 and the MCP port; the model provider endpoint derived from `--model` (for example `api.anthropic.com` for `claude*`); and any `--allow-agent-endpoint` (`container_runner.py`, `_configured_egress_rules`; `sregym/service/provider_endpoints.py`). Blocked requests are counted in `blocked_requests` and saved to `internet_audit.json`. Containers run with `--cpus=4.0 --memory=8g`, `--cap-drop=ALL --cap-add=DAC_OVERRIDE`, and `--security-opt=no-new-privileges` (`HARDENING_FLAGS`; `--container-hardening off` drops the last two).

## A4. Grading

### Diagnosis: an LLM judge against a stored root cause

93 files in `sregym/conductor/problems/` import `LLMAsAJudgeOracle` (grep count). An exact-match `DiagnosisOracle` base also exists (`sregym/conductor/oracles/diagnosis_oracle.py`); I did not audit which problems use it.

- **Ground truth.** `LLMAsAJudgeOracle(problem=self, expected=self.root_cause)`, where `root_cause` is `[fault_spec] component=<..>; namespace=<..> || <description>` built by `Problem.build_structured_root_cause` (`problems/base.py`).
- **What the judge sees.** Only that string, the agent's submitted text, and a checklist; not the trajectory (`oracles/llm_as_a_judge/judge.py`, `_build_user_message`).
- **Prompt and checklist.** System prompt: `DiagnosisJudge._SYSTEM_PROMPT_TEMPLATE` in `judge.py`. Checklist: `rca_checklists.yaml` v3.0, three dimensions of three yes/no questions: D1 Fault Localization (weight 0.33), D2 Fault Characterization (0.33), D3 Scope Precision (0.34).
- **Scoring.** Each dimension is `yes/3`; composite is the weighted sum; verdict `TRUE` if composite >= 0.70. A dimension at 0 caps the composite at 0.67, so it cannot pass. D1 = 1, D2 = 0.67, D3 = 0.67 scores 0.779 and passes; one flipped D3 answer (D3 = 0.33) scores 0.663 and fails. One yes/no answer can flip the verdict.
- **Returns.** A dict with `success`, `accuracy` (0 to 100), `judgment`, `reasoning`, `composite_score`, `dimensions`, `checklist` (per-question answer, evidence, confidence) (`llm_as_a_judge_oracle.py`). Multiple root causes are graded separately and all must pass.
- **Unscored is not zero.** If the backend fails or the reply cannot be parsed, the result is `success=None` with `unscored_reason` and the raw reply kept, and the attempt becomes incomplete (`judge.py`; `Conductor.finalize_attempt_status`).
- **Configuration.** Temperature 0.0, `max_tokens` 16384, up to three calls with a corrective prompt on parse failure (`judge.py`). Model from `--judge-model` (else `--model`). Endpoint and key from `JUDGE_API_BASE` and `JUDGE_API_KEY`, which default to the `AGENT_*` values only when `--judge-model` is not given (`main.py`, `_configure_model_environment`; `llm_backend/init_backend.py`). The judge runs in the host process. **Pin `--judge-model`**, or changing `--model` silently changes your grader.

### Mitigation: programmatic, per-problem, no LLM

`_evaluate_mitigation` calls `problem.mitigation_oracle.evaluate()` with no arguments, so the agent's submission text is ignored (`conductor.py`). Each problem attaches an oracle (`sregym/conductor/oracles/`). The default `MitigationOracle` (referenced by 68 problem files per a comment in `mitigation.py`) waits up to 60 s for rollouts to settle, then fails if a baseline Deployment is missing or scaled down, no pods exist, a pod or container is unhealthy, or a required Service, PVC, StatefulSet, or referenced ConfigMap is missing. The baseline is captured before injection so "scale to 0" and "delete it" do not pass. Specialized oracles go further; the network-policy oracle checks rollout, ready endpoints, and reachability (`network_policy_oracle.py`). The mitigation-only prompt says mitigation is judged on end-user requests succeeding "for a sustained period after you submit" (`clients/harness/stages.py`).

Failed verdicts carry `reason` and `failure_class`: `agent_error`, `environment_error`, `harness_error`, or `ambiguous` (`oracles/failure.py`). Its docstring: "flaky infrastructure depresses scores in a way indistinguishable from model incapability". Only `agent_error` "should count against a model's score"; `environment_error` attempts "should be excluded from scoring". See B8.

**When each runs.** Diagnosis is graded when `/submit` is accepted in the `diagnosis` stage, mitigation in the `mitigation` stage. A stage the agent never submits gets no result and the attempt is `incomplete`. Status is `complete` only if every configured stage has a result and none is unscored (`finalize_attempt_status`).

## A5. Outputs

Paths are relative to where you ran `main.py`.

```
results/<MMDD_HHMM>/                        one per invocation (_2, _3 on a clash)
  <agent>_ALL_results.csv                   every row of the invocation
  <agent>/<problem_id>/
    <problem_id>_<agent>_results.csv        all attempts of that problem
    phases_attempt<N>.jsonl                 timing ledger
    run_<N>/
      <problem_id>_results.csv              this attempt's one row
      trajectory.json                       ATIF, only if the agent has an adapter
      fault-spec.json                       problem_id, namespace, root_cause, fault_injected_at
      internet_audit.json, judge_responses.json, driver.log, driver.rc, install.log
      ...plus whatever your agent wrote to /logs
results/traces.db                           SQLite store of ingested trajectories
```

(`main.py`: `claim_results_dir`, `_problem_result_paths`, `_write_fault_spec`; `run_artifacts.py`; `sregym/traces/store.py`.) CSV columns are sorted alphabetically.

**Columns.** There is no fixed schema. A row is the attempt snapshot with each stage's result dict flattened as `<Stage>.<key>` (`main.py`). In the code:

| Group | Columns |
|---|---|
| Identity | `problem_id`, `attempt`, `deployment_profile`, `judge_backend`, `deploy_attempts` |
| Diagnosis | `Diagnosis.success`, `.accuracy`, `.judgment`, `.reasoning`, `.composite_score`, `.dimensions`, `.checklist`, `.submission`, `.unscored_reason`, `.error`, `.oracles` |
| Mitigation | `Mitigation.success`, `.reason`, `.failure_class`, `.detail`, `.error` |
| Timing | `TTL` (diagnosis), `TTM` (mitigation), `phase.<name>.duration_s`, `phase.<name>.outcome`, `phase.suspended_s` |
| Status | `run_status`, `incomplete_reason`, `incomplete_stage`, `missing_stages`, `unscored_stages`, `timed_out`, `agent_timeout_seconds`, `agent_return_code`, `deploy_failed`, `hook_failed`, `cleanup_failed`, `cleanup_error`, `cleanup_timed_out` |
| Network | `internet_access`, `blocked_requests`, `internet_audit_error` |

(`conductor.py`: `_submit_evaluate_and_advance`, `record_incomplete_attempt`; `sregym/phases.py`: `results_columns`; the oracle files above.) Oracles may add keys; treat the list as a minimum. The diagnosis timing column is `TTL`, not "TTD" (`timing_key = "TTL" if stage_name == "diagnosis" else "TTM"`). Both are measured from a clock reset at agent start and set after the oracle returns, so they include grading time and TTM is cumulative from agent start, diagnosis included.

**Tokens are not in the results CSV.** I searched `main.py`, `sregym/`, and `llm_backend/` and found no token column. Usage reaches `trajectory.json` (`final_metrics`) and `results/traces.db` (`total_prompt_tokens`, `total_completion_tokens`, `total_cached_tokens`, `total_cost_usd`) (`store.py`). Prompt tokens include cache reads and writes; completion tokens include reasoning (`atif_converter/README.md`, `clients/harness/token_usage.py`). **Only agents with an ATIF adapter get a trajectory:** `convert_run` returns `None` unless the agent name is in `SUPPORTED_AGENTS` (`claudecode`, `codex`, `copilot`, `gemini`, `mini-sre`, `opencode`, `stratus`) (`sregym/traces/convert.py`). A custom agent gets no `trajectory.json` and no token rows. Log your own usage JSON to `AGENT_LOGS_DIR`.

**`sregym/results/report.py`** builds a Markdown difficulty report for one problem from one CSV: per attempt, diagnosis, mitigation, and overall (both must pass), then pass rates over complete attempts and a label: Saturated (all passed), Unsolved (none), Not saturated, or Inconclusive (an attempt incomplete). It says incomplete attempts "are not counted as model failures". It screens problems; it does not compare agents.

## A6. The MCP server SREGym provides

`mcp_server/sregym_mcp_server.py` is a Starlette app with five SSE mounts plus `/healthz`, run in-cluster and reached through a port-forward at `MCP_SERVER_URL` (default port 9954; `sregym/service/mcp_server.py`).

| Mount | Tools | Source |
|---|---|---|
| `/kubectl` | `exec_kubectl_cmd_safely(cmd)`, `rollback_command()`, `get_previous_rollbackable_cmd()` | `mcp_server/kubectl_mcp_tools.py` |
| `/prometheus` | `get_metrics(query)`, `get_alerts()` | `prometheus_server.py` |
| `/jaeger` | `get_services()`, `get_operations(service)`, `get_traces(service, last_n_minutes)`, `get_dependency_graph(last_n_minutes=30)` | `jaeger_server.py` |
| `/loki` | `get_logs(query, last_n_minutes=15)`, `get_labels()`, `get_label_values(label)` | `loki_server.py` |
| `/submit` | `submit(ans, stage=None)`, which POSTs to the conductor's `/submit` | `submit_server.py` |

**Connecting.** Each mount serves SSE at `<base>/<mount>/sse`. Stratus builds `http://$API_HOSTNAME:$MCP_SERVER_PORT/{prometheus,jaeger,kubectl}/sse` and `http://$API_HOSTNAME:$API_PORT/submit_mcp/sse` (`clients/stratus/configs/langgraph_tool_configs.py`). The kubectl tool is session-scoped through a `sregym_ssid` header (`clients/demo/driver.py`). It needs `cluster_access`. MCP is optional: mini-sre uses only bash and curl against `/status`, `/get_app`, `/submit` (`clients/mini_sre/README.md`), and agents can run `kubectl` directly with the filtered kubeconfig.

## A7. The bundled reference agents

- **`clients/mini_sre`** (`mini-sre`). A minimal bash loop: one bash block per model reply, run in a fresh shell, exit code and output returned. The system prompt is adapted from mini-swe-agent; the task text is SREGym's shared instruction (`clients/codex/driver.py`, `build_instruction`) plus five general working rules. It is budget-aware: it reads `agent_remaining_seconds` after each command, caps 80 commands per stage, gives diagnosis two thirds of the time, and warns the model at 15 commands or 5 minutes left. It writes a transcript, a results JSON with token use, and per-step files (`clients/mini_sre/README.md`, `mini.py`, `driver.py`). It is the closest design to yours and the best first read.
- **`clients/stratus`**. A LangGraph-style ReAct system with separate diagnosis, mitigation, and rollback agents on a shared `BaseAgent`. Each step is a thinking step then an action step; after `max_step: 20` it is forced to submit. Mitigation retries (`retry_mode: validate`, up to 10) using "weak oracles" (alerts, cluster state, workload) and a deterministic rollback agent that reverses executed commands (`stratus_agent/README.md`, `configs/mitigation_agent_config.yaml`, `stratus_agent/driver/driver.py`). It uses the MCP server.
- **`clients/demo`**. Not an LLM agent. It replays commands from `kubectl_cmds.txt` through the kubectl and submit MCP tools, one per trigger file (`/tmp/next`, `/tmp/skip`, `/tmp/quit`). For demonstrations and exercising the submit protocol (`clients/demo/driver.py`).
- **`clients/autosubmit`**. A null baseline. Every 60 s it calls `GET /status`; in `diagnosis` it POSTs `{"stage": "diagnosis", "solution": "yes"}`; in `mitigation` it POSTs `{"stage": "mitigation", "solution": ""}`; at `done` it exits. It investigates and fixes nothing (`clients/autosubmit/autosubmit_agent.py`). The file does not state a purpose. My reading, as inference: it exercises deploy, grading, and teardown with no model cost and sets a floor, so any problem it passes tells you about that problem's oracle.

## A8. Leaderboard metrics

The repo does not define Diag %, Mit %, E2E %, TTD, TTM, or tokens (I searched `README.md`, `docs/`, `sregym/`). The only definitions I found are on `https://sregym.com/leaderboard` (fetched 2026-11-16):

| Metric | Page's definition | Closest repo field |
|---|---|---|
| Diag. (%) | "Diagnosis success rate" | `Diagnosis.success` |
| Mit. (%) | "Mitigation success rate" | `Mitigation.success` |
| E2E (%) | "End-to-end (both diagnosis and mitigation correct)", ranked "requiring both ... on the same run" | both true on one attempt; the rule in `report.py` |
| TTD (s) | "Time-to-diagnose" | probably `TTL` (not stated) |
| TTM (s) | "Time-to-mitigate" | probably `TTM`, cumulative (not stated) |
| Tokens | "Mean token usage per run" | not found; likely trajectory `final_metrics` |

The cohort is labeled "SREGym-Lite-1004 · 17 faults". Many percentages are multiples of 1/51 (96.1, 98.0, 94.1, 90.2) or 1/34 (97.1, 88.2), which suggests 3 or 2 runs per fault. That is my inference; the page states neither the run count, the denominator, nor how incomplete attempts are treated. To compare fairly, use the same 17 problems, `--profile full`, E2E per attempt, and the mean over attempts.

---

# Part B: Evaluation methodology

The setup: 17 dev problems, 15 held-out test problems, 3 repeats per problem, and an LLM judge on one stage. That is 51 dev attempts per config. Treat dev as a screening instrument, not a precision one.

## B1. Dev/test split and contamination

- **Dev** is what you may read fully: transcripts, judge reasoning, `fault-spec.json`. **Test** is run to confirm; you do not read it.
- **Contamination** is any path from test information into the agent: editing the prompt, tools, or heuristics after reading a test transcript or judge output; adding a rule because a test problem needed it; choosing dev problems to study based on test failures; running test after every change (adaptive reuse makes it a second dev set); letting an LLM propose edits while it sees test traces; using test IDs or fault families in few-shot examples.
- **Dev overfitting is the likelier failure.** With 17 problems and dozens of experiments you will tune to dev quirks. *AI Agents That Matter* names inadequate holdouts as a main cause of fragile, overfit agents (Kapoor et al., arXiv:2407.01502).
- **Pretraining exposure.** SREGym is public and its problem files hold root-cause text. Be suspicious of high scores and check transcripts for conclusions that skip investigation.
- **Run test as a release gate**: at most once per candidate you would ship, with every look logged. Report dev and test separately; a large dev-to-test gap means overfitting. Freeze model, prompt, tools, `--judge-model`, flags, and agent code hash first.

## B2. Run-to-run variance and repeats

Agents vary in sampling, tool timing, and cluster state. Anthropic's agent-eval guidance: each task has its own success rate, and "a task that passed on one eval run might fail on the next" (*Demystifying evals for AI agents*).

- Per-problem pass rates are mostly extreme: some problems always pass, some never do. Only the flaky middle carries information about a change, and only it adds noise.
- Report per config: mean E2E over attempts (never best-of), the 17-row table of pass counts (0 to 3), and a spread from the bootstrap in B3. A naive standard error over 51 attempts overstates your sample, because attempts within a problem are correlated and the effective n is closer to the flaky-problem count (Anthropic's recommendation #2 is to cluster standard errors; Miller, arXiv:2411.00640).
- Three repeats is the floor. B4 shows how little each extra repeat buys.
- Pass@k (any of k succeeds) hides unreliability. Use mean per-attempt pass rate as the headline and pass^k (all k succeed) if reliability matters.

## B3. Paired comparison, sign test, bootstrap

Compare configs per problem on the same 17 problems so difficulty cancels. This is Anthropic's recommendation #4, "Analyze paired differences" (Miller, arXiv:2411.00640). Their CLT formulas assume many independent questions; at n = 17 use the exact and resampling methods below and treat the output as rough.

1. **Sign test** on problems whose mean changed, ties dropped, exact two-sided binomial at 0.5. McNemar's test is the paired-binary analogue; the unit here must be the problem, not the attempt, since attempts within a problem are not independent (Dror et al., ACL 2018, on choosing significance tests in NLP).
2. **Two-stage paired bootstrap.** Resample problems with replacement (same index for A and B), then resample repeats inside each chosen problem separately per config. The interval reflects problem sampling and run noise.

```ts
// compare.ts. runs[problem][repeat] = 1 (E2E pass) | 0. Same problem order for A and B.
export type Runs = number[][];
const mean = (xs: number[]) => xs.reduce((s, x) => s + x, 0) / xs.length;

export function rng(seed: number): () => number {          // mulberry32: reproducible CIs
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const pick = (xs: number[], r: () => number) => xs[Math.floor(r() * xs.length)];

export function pairedBootstrapCI(a: Runs, b: Runs, reps = 10_000, seed = 1, alpha = 0.05) {
  const n = a.length, r = rng(seed), diffs: number[] = [];
  for (let t = 0; t < reps; t++) {
    let d = 0;
    for (let i = 0; i < n; i++) {
      const p = Math.floor(r() * n);                        // same problem for A and B: paired
      d += mean(b[p].map(() => pick(b[p], r))) - mean(a[p].map(() => pick(a[p], r)));
    }
    diffs.push(d / n);
  }
  diffs.sort((x, y) => x - y);
  return {
    point: mean(b.map(mean)) - mean(a.map(mean)),
    lo: diffs[Math.floor((alpha / 2) * reps)],
    hi: diffs[Math.ceil((1 - alpha / 2) * reps) - 1],
  };
}

export function signTest(a: Runs, b: Runs) {               // exact two-sided, ties dropped
  let wins = 0, losses = 0;
  a.forEach((ra, i) => { const d = mean(b[i]) - mean(ra); if (d > 0) wins++; else if (d < 0) losses++; });
  const n = wins + losses, k = Math.min(wins, losses);
  let tail = 0, c = 1;
  for (let j = 0; j <= k; j++) { if (j > 0) c = (c * (n - j + 1)) / j; tail += c; }
  return { wins, losses, ties: a.length - n, p: Math.min(1, (2 * tail) / 2 ** n) };
}
```

I ran this on a worked example. Config A's passes per problem (of 3): `[3,3,3,3,3,2,2,2,1,1,1,0,0,0,0,0,0]`, 24/51 = 47.1%. Config B: `[3,3,3,3,3,3,2,2,2,2,1,1,0,0,0,0,0]`, 28/51 = 54.9%. B is 7.8 points better with 4 wins, 0 losses, 13 ties. Sign test p = 0.125. The bootstrap 95% CI on the difference is about [-3.9, +21.6] points. A clean 4-0 sweep is not enough.

Exact sign-test p-values for planning:

| Wins - losses | 4-0 | 5-0 | 6-0 | 7-1 | 8-1 | 9-2 | 8-2 |
|---|---|---|---|---|---|---|---|
| p (two-sided) | 0.125 | 0.063 | 0.031 | 0.070 | 0.039 | 0.065 | 0.109 |

## B4. How big must an improvement be at n = 17, k = 3?

Take a plausible shape: 5 problems always pass, 5 never pass, 7 are flaky at p = 0.5. Only flaky problems add run noise.

- One flaky problem's mean of 3 repeats: variance p(1-p)/3 = 0.25/3 = 0.0833.
- Seven of them: 7 × 0.0833 = 0.583. Variance of the 17-problem mean: 0.583 / 17² = 0.00202. Standard error 0.0449, i.e. 4.5 points.
- Difference of two configs with independent runs on the same problems: 4.5 × √2 = 6.4 points.
- 95% half-width: 1.96 × 6.4 = **12.5 points**, which is 6.4 extra passes out of 51, or about 2 problems.

An observed gain under about 12 points is inside the noise at 95%. A seeded simulation of a bimodal mix (35% near-always-pass, 30% near-never, 35% spread over 0.2 to 0.8) gave an A-vs-A noise SD of 6.1 points and a 95% band of ±11.9, close to the hand number. Extra repeats help only by the square root of k:

| Repeats k | 3 | 5 | 10 |
|---|---|---|---|
| 95% half-width (hand model) | 12.5 pts | 9.6 pts | 6.8 pts |

In the simulation (fresh random 17-problem set each trial, B better by a uniform logit shift, k = 3, 400 trials per row):

| True gain | ~0 | ~5 pts | ~10 pts | ~15 pts | ~20 pts |
|---|---|---|---|---|---|
| Bootstrap CI excludes 0 | 1% | 5% | 20% | 46% | 74% |
| Sign test p < 0.05 | 2% | 6% | 17% | 37% | 62% |

With 17 problems and 3 repeats, a true 10-point gain is detected about one time in five. "No significant change" says little. Both tests are conservative under the null, and the price is power. So:

- Use dev as a screen. Keep a change if its point estimate is positive, it caused no large per-problem regressions, and you have a mechanism. Then confirm kept changes with more repeats on the flaky problems only (the always-pass and never-pass problems add nothing).
- Make big, mechanism-driven changes. A 2-point tweak cannot be measured here.
- The test set (n = 15) scales this by about √(17/15) = 1.06, so about ±13 points. Use it to check that the dev gain did not vanish, not to rank small variants.

## B5. Multiple comparisons and best-of-many

If you try m variants and keep the best, the winner's dev score is biased upward even when every variant is a no-op. With a difference SD of σ = 6.05 points, the simulated expected maximum of m null differences is:

| m variants | 2 | 5 | 10 | 20 |
|---|---|---|---|---|
| Expected best "gain" | 0.57σ = 3.4 pts | 1.16σ = 7.0 | 1.54σ = 9.3 | 1.87σ = 11.3 |

The best of 10 do-nothing variants shows about +9 points on average. That is the winner's curse. Defenses:

- Count every config you evaluate; the journal (B10) logs them.
- Re-run the winner with fresh seeds and judge only the new runs. The selection bias lives in the old ones.
- Write the prediction before the run. A pre-stated hypothesis is one comparison, not a scan.
- Tighten the bar with m (Bonferroni: alpha/m is crude but honest).
- Spend the test set once, on the final candidate.

HAL's point applies too: standardize the harness and audit logs, because gains often come from things you did not intend (Kapoor et al., arXiv:2510.11977).

## B6. Ablations

An ablation removes one component from your best config and re-measures. Given B4, ablations at n = 17 detect only large components.

- Remove one thing at a time from the full config, rather than adding to a bare one, and hold model, judge, `--agent-timeout`, step caps, and flags fixed.
- Decide the keep/drop rule beforehand, for example "drop it if removal costs under 5 points and saves 20% cost". Within a 12-point noise band you are mostly reading cost.
- Report `Diagnosis.success` and `Mitigation.success` separately. A component that helps mitigation and hurts diagnosis can net to zero in E2E.
- Include the floor: `autosubmit` (A7) or a no-tools prompt. An ablation that lands on the floor was essential; one within noise of the full config was not carrying weight.

## B7. LLM-judge reliability and how to audit it

The diagnosis judge compares a short text to a stored root-cause string (A4). Risks: judge variance, a threshold single answers can cross (0.779 vs 0.663 above), self-preference when `--judge-model` defaults to the agent's model, and sensitivity to how much detail your agent writes.

1. **Pin `--judge-model`** and record it. Check `judge_backend` and `Diagnosis.reasoning`.
2. **Collect evidence offline.** `Diagnosis.submission` (CSV) is the agent's text, and `fault-spec.json` holds `root_cause` (`main.py`, `_write_fault_spec`). With those you can re-judge any attempt with any model without redeploying.
3. **Self-consistency.** Re-judge 30 to 50 stored submissions three times each and report the fraction of verdicts that flip. Temperature 0.0 is set in code (`judge.py`), but that alone does not guarantee identical outputs across calls or providers (general API behavior; not tested here).
4. **Human agreement.** Label 30 submissions yourself, correct or not against the root cause, before seeing the judge's verdict. Compute agreement and Cohen's kappa, then read the disagreements: they show whether the judge is too strict on mechanism detail or too lenient on scope.
5. **Cross-judge.** Re-judge with a stronger or different-vendor model. If the ranking of your configs changes, the judge drove the result.
6. **Near-threshold cases.** List attempts with composite 0.66 to 0.78; one question decides them. Count how many of your wins come from there.
7. **Unscored attempts.** An empty `Diagnosis.success` with `Diagnosis.unscored_reason` is a judge failure, not an agent failure.

Mitigation is programmatic, so its noise is environmental (B8), not linguistic.

## B8. Separating infrastructure failures from agent failures

Counting an infrastructure failure against your agent adds noise; discarding agent failures inflates scores. Use the fields SREGym writes:

| Signal (column) | Class | Treat as |
|---|---|---|
| `deploy_failed`, `deploy_attempts > 1` | infra | Exclude and rerun; a failure also cancels later attempts of that problem (A1) |
| `cleanup_failed`, `cleanup_timed_out`, `hook_failed` | infra | Exclude; the campaign may abort |
| `Diagnosis.unscored_reason`, `run_status = incomplete` with `unscored_stage_results` | judge infra | Exclude; re-judge via B7 step 2 |
| `Mitigation.failure_class = environment_error` or `harness_error` | infra | Exclude (per `oracles/failure.py`) |
| `Mitigation.failure_class = ambiguous` | unknown | Count as failure but inspect; many on one problem means a weak oracle |
| `Mitigation.failure_class = agent_error` | agent | Count as failure |
| `timed_out = True` | agent | Count as failure, although SREGym marks it `incomplete` (my recommendation: speed is part of the task) |
| `agent_return_code` nonzero; `incomplete_reason = agent_exited_before_all_stages_completed` | likely agent | Read `driver.log`. A crash from your bug is yours; a crash from blocked egress is infra |
| `blocked_requests > 0` | maybe infra | Inspect `internet_audit.json`; a blocked tool endpoint is a config bug |
| `phase.deploy.duration_s`, `phase.baseline`, `phase.propagation` | context | Large outliers suggest a sick cluster |

(Columns from `main.py`, `conductor.py`, `oracles/failure.py`, `sregym/phases.py`.)

- Write the exclusion rule as a function of these columns before the run, so it cannot be tuned to outcomes. Report the excluded count per config; a config with more exclusions is not on equal footing.
- **`--resume` is retry-until-pass if misused.** It reruns every attempt that is not `complete`, timeouts included (`sregym/results/resume.py`). Rerunning agent failures but keeping successes biases scores upward. Use it for infra failures only, and control what reruns by editing the CSV or using `--problem`.
- Run `autosubmit` after any infrastructure change (new cluster, node, kind upgrade, image). If grading, teardown, or results writing broke, you see it without model cost.

## B9. Cost and accuracy

A config that gains 3 points for 3x the tokens may not be a gain. *AI Agents That Matter* argues for optimizing accuracy and cost jointly and reporting the Pareto frontier (arXiv:2407.01502). Per config, report:

- E2E, Diag, and Mit % with the bootstrap interval.
- **Tokens and dollars per attempt**, failed attempts included, using SREGym's definitions (input includes cache reads and writes; output includes reasoning; `clients/harness/token_usage.py`) and a dated price table.
- **Cost per solved problem**: total spend divided by E2E passes.
- Mean `TTL` and `TTM`, and the share of attempts using over 80% of `--agent-timeout`.
- Judge cost separately. With a pinned judge it is equal across configs.

A custom agent gets no `trajectory.json` (A5), so write one JSON per attempt into `AGENT_LOGS_DIR` with per-call input, output, cached, and reasoning tokens. A plot of cost against E2E for every kept config beats a table of best scores.

## B10. Experiment journal template

One entry per experiment, in one version-controlled file. Write hypothesis and prediction before the run.

```markdown
## EXP-NNN  <short title>            date: YYYY-MM-DD   agent commit: <hash>

**Hypothesis.** <Mechanism: why this should help, and on which kind of problem.>
**Change.** <Exactly what differs from baseline. One thing. Link the diff.>
**Baseline.** <Config ID / results dir; same model, judge, flags.>
**Fixed settings.** model=<> judge-model=<> reasoning-effort=<> agent-timeout=<>
                    profile=full internet-access=<> n-attempts=<> split=dev
**Prediction (before running).** <Direction and size, e.g. "+10 pts E2E, mostly
                    mitigation; cost +15%". What would falsify it.>
**Look count.** <Configs evaluated on dev so far; test looks.>

**Result.**
- E2E A -> B: __% -> __%   diff __ pts   95% CI [__, __]   sign test __-__ p=__
- Diag / Mit separately: __ / __
- Per-problem pass counts A vs B: <17-row table, changed rows marked>
- Excluded (infra): <count, reason codes>   timed_out: <count>
- Tokens/attempt: __  $/attempt: __  $/solved: __  mean TTL/TTM: __ / __
- Judge audit: <near-threshold count, unscored count>

**Decision.** keep / drop / rerun with more repeats / check mechanism.
**Why.** <One paragraph, including what the numbers cannot tell you.>
**Follow-ups.** <Next hypothesis. Do not start it before this entry is closed.>
```

---

## Sources

- Miller, E. "Adding Error Bars to Evals: A Statistical Approach to Language Model Evaluations." arXiv:2411.00640 (https://arxiv.org/abs/2411.00640). Anthropic's summary, "A statistical approach to model evaluations" (2024-11-19), lists five recommendations: central limit theorem, cluster standard errors, reduce within-question variance, analyze paired differences, power analysis (https://www.anthropic.com/research/statistical-approach-to-model-evals).
- Anthropic Engineering, "Demystifying evals for AI agents": trials, non-determinism, pass@k and pass^k (https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents).
- Kapoor, Stroebl, Siegel, Nadgir, Narayanan. "AI Agents That Matter." arXiv:2407.01502 (https://arxiv.org/abs/2407.01502): cost-controlled evaluation, holdout sets, reproducibility.
- Kapoor et al. "Holistic Agent Leaderboard: The Missing Infrastructure for AI Agent Evaluation." arXiv:2510.11977 (https://arxiv.org/abs/2510.11977): standardized harness, LLM-aided log inspection.
- Dror, Baumer, Shlomov, Reichart. "The Hitchhiker's Guide to Testing Statistical Significance in Natural Language Processing." ACL 2018 (https://aclanthology.org/P18-1128/).
- SREGym paper, arXiv:2605.07161 (https://arxiv.org/abs/2605.07161); I read only the abstract page and rely on nothing in it. Leaderboard: https://sregym.com/leaderboard (fetched 2026-11-16).
- B3 to B5 numbers come from the TypeScript above plus a seeded simulation I ran (17 problems, 3 repeats, 400 trials per power row, 20,000 for the noise floor). Rerun it on your own problem profile; the flaky-problem fraction dominates.

# SRE Harness v0 and Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A from-scratch TypeScript agent loop (`ts-sre`) that runs as a SREGym agent, plus the sweep tooling and baseline scores needed to start improving it one change at a time.

**Architecture:** A fork of SREGym holds the agent in `clients/ts_sre/`. A few lines of Python start a Node process; all behaviour is TypeScript run directly by Node 22's type stripping, with no runtime npm dependencies and no build step. The agent talks to SREGym's conductor over HTTP and to OpenCode Go over OpenAI-compatible chat completions.

**Tech Stack:** TypeScript on Node 22 (`node --experimental-strip-types`, `node:test`, built-in `fetch`), Python 3.12 shim, bash, SREGym on kind, AWS EC2, OpenCode Go.

**Spec:** `docs/superpowers/specs/2026-11-14-sre-harness-design.md`

**Scope:** This plan ends with v0 tagged and scored. The improvement ladder is not planned here: each later version is chosen from the failed dev transcripts of the one before.

## Global Constraints

- Node 22 type stripping only: erasable TypeScript syntax (no `enum`, no parameter properties, no namespaces), relative imports written with the `.ts` extension, `"type": "module"`.
- Zero runtime npm dependencies in `clients/ts_sre/agent`. `typescript` and `@types/node` are dev-only, for `tsc --noEmit`.
- Agent name in SREGym: `ts-sre`. Module path: `clients.ts_sre.driver`.
- Go base URL: `https://opencode.ai/inference/go/openai/v1`. The agent posts to `<base>/chat/completions`.
- Model strings passed to SREGym: `openai/glm-5.3-flash`, `openai/mimo-v2.6-flash`; judge `openai/gpt-6-luna`. The agent strips everything up to the last `/` before calling Go.
- Every Go request carries `User-Agent: ts-sre/<version>` and `x-opencode-session: ses_<uuid>`, one session ID per problem attempt.
- v0 limits, same as `mini-sre`: 80 commands per stage, 60 s per command, diagnosis may use 0.667 of the attempt time, 3 wrap-up replies, attempt time 1800 s when `/status` does not report it.
- Deployment profile `full`. Judge fixed. SREGym upstream commit pinned and recorded.
- Prompts contain no hint about any specific problem, application fault or Kubernetes object.
- Test-set transcripts are never opened while the harness is still changing. Only scores are read.
- API keys live in an untracked `.env` on the VM. Never committed, never printed in logs or transcripts.
- One harness change per version tag.

## Review Focus

Conditions the spec implies that are most likely to break a run. Each has a test in the task named.

1. **The model replies with zero or several bash blocks, or with empty content.** Expected: a format-error message, and the stage ends after 3 in a row. (Task 6, Task 8)
2. **A command prints megabytes** (`kubectl logs` on a busy pod). Expected: the agent does not crash or exhaust memory; output past the safety cap is cut with a note. (Task 5, Task 6)
3. **A command hangs or waits for input** (`kubectl exec -it`, `watch`). Expected: killed at the timeout with its whole process group, and the model is told. (Task 5)
4. **Go returns 429 because the 5-hour allowance is spent.** Expected: the run exits as an infrastructure failure (exit 1) so the sweep re-runs it, and it is not scored as an agent failure. (Task 7, Task 8, Task 10)
5. **The deadline passes or the conductor changes stage while a model call or command is in flight.** Expected: the stage ends cleanly with the right termination reason; mitigation still gets its turn. (Task 8, Task 9)

## File Structure

```
clients/ts_sre/
  __init__.py
  driver.py                  # shim: exec node, pass env, return its exit code
  agent/
    package.json             # "type": "module", test and typecheck scripts
    tsconfig.json
    src/
      config.ts              # env -> Config
      conductor.ts           # /get_app, /status, waitForStage
      shell.ts               # runCommand with timeout and process-group kill
      prompt.ts              # all prompt text, action parsing, observation formatting
      model.ts               # Go chat-completions client, retries, usage
      transcript.ts          # JSONL log
      loop.ts                # runStage: one stage of the agent loop
      main.ts                # stage sequencing, results file, exit code
    test/
      *.test.ts              # one per src file, plus e2e.test.ts
      fakes.ts               # fake conductor and fake model HTTP servers
agents.yaml                  # add the ts-sre entry
scripts/
  sweep.sh                   # run a problem set N times for one agent and model
  summarize.ts               # results -> row in results/results.md + per-problem matrix
results/
  PINNED.md                  # upstream commit, model IDs, limits, judge, profile
  NOTES.md                   # facts found during setup (CSV columns, flag semantics)
  journal.md                 # one hypothesis line per version, written before it runs
  results.md                 # one row per (version, model, set)
  sets/dev.txt test.txt subset.txt
  runs/<label>/              # transcripts and per_problem.csv per sweep
```

---

### Task 1: Repository

**Files:**
- Create: `results/PINNED.md`, `results/NOTES.md`, `results/journal.md`, `results/results.md`
- Move: `docs/superpowers/` from `/Users/skrishnan/development/sre-harness/` into the fork

**Interfaces:**
- Produces: the fork checked out at `/Users/skrishnan/development/SREGym`, branch `harness`.

- [ ] **Step 1: Fork and clone.** The user forks `SREGym/SREGym` on GitHub (their account). Then:

```bash
git clone --recurse-submodules git@github.com:<user>/SREGym.git /Users/skrishnan/development/SREGym
cd /Users/skrishnan/development/SREGym && git checkout -b harness
```

- [ ] **Step 2: Move the design and plan in.** Copy `sre-harness/docs/superpowers/` to `SREGym/docs/superpowers/`, then delete the now-empty `sre-harness/` folder.

- [ ] **Step 3: Record the pin.** Write `results/PINNED.md` with: upstream commit (`git rev-parse HEAD` before any change), profile `full`, judge `openai/gpt-6-luna`, agent models, the v0 limits from Global Constraints, temperature "provider default (not set)".

- [ ] **Step 4: Check local Node.** Run: `node --version`. Expected: `v22.18` or newer (type stripping without warnings). If older, install Node 22 LTS.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers results && git commit -m "chore: add harness design, plan and results scaffolding"
```

---

### Task 2: VM and cluster

Needs the user's hands: AWS console and SSH key.

**Files:**
- Modify: `results/NOTES.md`

**Interfaces:**
- Produces: a VM reachable as `ssh sregym-vm`, with the fork cloned at `~/SREGym` and a ready kind cluster.

- [ ] **Step 1: Launch the instance.** Ubuntu 24.04, x86_64, 8 vCPU, 200 GB gp3 disk, SSH only from the user's IP. Start with `c7a.2xlarge` (16 GB, the Lite doc's minimum); move to a 32 GB type only if `--check-setup` or pod evictions say so. Add a `sregym-vm` host entry to `~/.ssh/config`.

- [ ] **Step 2: Install requirements.** Docker, kind, kubectl, Helm >= 4.0, uv >= 0.11.8, Python >= 3.12, Node 22. Set the inotify limits from `kind/README.md` and persist them.

- [ ] **Step 3: Clone and sync.**

```bash
git clone --recurse-submodules git@github.com:<user>/SREGym.git ~/SREGym && cd ~/SREGym && git checkout harness && uv sync
```

- [ ] **Step 4: Create the cluster.** Run: `bash kind/setup_kind_cluster.sh && kubectl get nodes`. Expected: four nodes `Ready`.

- [ ] **Step 5: Record instance type, AMI and hourly price in `results/NOTES.md`; commit.**

---

### Task 3: Endpoint, judge and baseline proof

No harness code yet. This proves the cluster, Go and the judge with SREGym's own `mini-sre` agent.

**Files:**
- Create on the VM only: `~/SREGym/.env` (untracked)
- Modify: `results/NOTES.md`

**Interfaces:**
- Produces, written into `results/NOTES.md`: whether Go accepts requests without `x-opencode-session`; the path and column names of SREGym's results CSV; where per-run logs and `trajectory.json` land; what `--n-attempts` means (repeat every time, or retry until pass); the env var that carries the problem ID into the agent container.

- [ ] **Step 1: Keys.** The user subscribes to OpenCode Go and creates a personal API key in the Console. They put it in `~/SREGym/.env` on the VM as `AGENT_API_KEY` and `JUDGE_API_KEY`, with `AGENT_API_BASE` and `JUDGE_API_BASE` both set to the Go base URL. Confirm `.env` is git-ignored.

- [ ] **Step 2: Probe Go directly.** Four `curl` calls to `<base>/chat/completions` with a one-line prompt: `glm-5.3-flash`, `mimo-v2.6-flash` and `gpt-6-luna` with the session and user-agent headers, then `glm-5.3-flash` without the session header. Expected: the first three return 200 with a `usage` block. Record the status of the fourth, and the exact location of the allowance figure in the response body.

- [ ] **Step 3: Setup check.** Run:

```bash
uv run main.py --agent mini-sre --model openai/glm-5.3-flash --judge-model openai/gpt-6-luna --problem network_policy_block --check-setup
```

Expected: exit 0. Apply each printed fix otherwise. If the agent cannot reach Go under the network filter, add `--allow-agent-endpoint https://opencode.ai` to every command from here on and note it.

- [ ] **Step 4: One real run.** Same command without `--check-setup`, with `--force-build`. Expected: both stages complete and a results CSV row with a judge verdict.

- [ ] **Step 5: If Step 2 or Step 4 shows Go rejecting requests that lack the session header** (SREGym's LiteLLM judge and `mini-sre` do not send it): write `scripts/go-session-proxy.ts`, a Node HTTP server on port 8788 that forwards every request to the Go base URL adding `x-opencode-session: ses_<one uuid per process>` and `User-Agent: sregym-judge/1.0`, streaming the response back. Point `JUDGE_API_BASE` (and `AGENT_API_BASE` for `mini-sre` runs only) at `http://host.docker.internal:8788`, bind it with authentication or a firewall rule as the SREGym README advises, and re-run Step 4. Skip this step if nothing was rejected.

- [ ] **Step 6: Record the findings listed under Produces. Commit `results/NOTES.md`.**

---

### Task 4: Config and conductor client

**Files:**
- Create: `clients/ts_sre/agent/package.json`, `tsconfig.json`, `src/config.ts`, `src/conductor.ts`, `test/fakes.ts`, `test/config.test.ts`, `test/conductor.test.ts`

**Interfaces:**
- Produces:

```ts
// config.ts
export interface Config {
  conductorUrl: string; model: string; apiBase: string; apiKey: string; logsDir: string;
  problemId: string; hardCap: number; commandTimeoutS: number; attemptS: number;
  diagnosisShare: number; wrapUpCalls: number; maxTokens: number;
  temperature: number | undefined; reasoningEffort: string | undefined;
}
export function loadConfig(env: Record<string, string | undefined>): Config;

// conductor.ts
export type Stage = "diagnosis" | "mitigation";
export interface AppInfo { app_name: string; namespace: string; descriptions: string; stages?: string[] }
export interface Status { stage: string | null; agentRemainingSeconds: number | null }
export class Conductor {
  constructor(baseUrl: string);
  getApp(): Promise<AppInfo>;                 // retries 6 times, 5 s apart
  status(): Promise<Status | null>;           // null when the conductor does not answer
  waitForStage(targets: Stage[], timeoutS: number): Promise<Stage>;  // polls every 2 s, throws on timeout
}

// test/fakes.ts
export function startFakeConductor(script: { app: AppInfo; stages: string[] }): Promise<{ url: string; submissions: string[]; setStage(s: string): void; close(): Promise<void> }>;
```

Env mapping for `loadConfig`: `API_HOSTNAME` (default `localhost`), `API_PORT` (`8000`), `AGENT_MODEL_ID` (required; strip through the last `/`), `AGENT_API_BASE` (required), `AGENT_API_KEY` (required), `AGENT_LOGS_DIR` (`./logs/ts-sre`), the problem-ID variable found in Task 3 (default `unknown`), `AGENT_REASONING_EFFORT`, `TS_SRE_HARD_CAP` (80), `TS_SRE_COMMAND_TIMEOUT` (60), `TS_SRE_ATTEMPT_S` (1800), `TS_SRE_DIAGNOSIS_SHARE` (0.667), `TS_SRE_WRAP_UP_CALLS` (3), `TS_SRE_MAX_TOKENS` (8192), `TS_SRE_TEMPERATURE` (unset).

The fake conductor serves `GET /get_app`, `GET /status` (`{"stage": ..., "agent_remaining_seconds": ...}`) and `POST /submit`, which records the `solution`, replies `{"message": "Submission received", "stage": "<stage>"}` and advances to the next scripted stage.

- [ ] **Step 1: Scaffolding.** `package.json` with `"type": "module"`, scripts `test` = `node --experimental-strip-types --test test/*.test.ts` and `typecheck` = `tsc --noEmit`; `tsconfig.json` with `strict`, `noEmit`, `allowImportingTsExtensions`, `erasableSyntaxOnly`, `module` and `moduleResolution` `nodenext`.

- [ ] **Step 2: Write failing tests.**

```ts
test("loadConfig applies defaults and strips the provider prefix", () => {
  const c = loadConfig({ AGENT_MODEL_ID: "openai/glm-5.3-flash", AGENT_API_BASE: "https://x/v1", AGENT_API_KEY: "k" });
  assert.equal(c.model, "glm-5.3-flash");
  assert.equal(c.conductorUrl, "http://localhost:8000");
  assert.deepEqual([c.hardCap, c.commandTimeoutS, c.attemptS, c.wrapUpCalls], [80, 60, 1800, 3]);
  assert.equal(c.temperature, undefined);
});
test("loadConfig throws naming the missing variable", () => {
  assert.throws(() => loadConfig({ AGENT_API_BASE: "x", AGENT_API_KEY: "k" }), /AGENT_MODEL_ID/);
});
test("status maps agent_remaining_seconds and returns null when unreachable", async () => { /* fake conductor, then a closed port */ });
test("waitForStage resolves when the stage appears and rejects on timeout", async () => { /* setStage after 100 ms; timeout 0.2 s case */ });
```

- [ ] **Step 3: Run.** `npm test` in `clients/ts_sre/agent`. Expected: FAIL, modules not found.
- [ ] **Step 4: Implement `config.ts`, `conductor.ts`, `fakes.ts`.** Poll and retry intervals are constructor options so tests run in milliseconds.
- [ ] **Step 5: Run.** `npm test && npm run typecheck`. Expected: PASS.
- [ ] **Step 6: Commit.** `feat(ts-sre): config and conductor client`

---

### Task 5: Shell runner

**Files:**
- Create: `src/shell.ts`, `test/shell.test.ts`

**Interfaces:**
- Produces:

```ts
export interface CommandResult { exitCode: number; stdout: string; stderr: string; timedOut: boolean; durationS: number; truncated: boolean }
export function runCommand(command: string, timeoutS: number, cwd: string): Promise<CommandResult>;
export const CAPTURE_LIMIT_BYTES = 1_000_000;
```

Runs `bash -c <command>` in a fresh shell, its own process group, stdin closed. On timeout the whole group gets SIGKILL and `exitCode` is 124. Each stream stops being stored after `CAPTURE_LIMIT_BYTES` (the process keeps running and is drained), and `truncated` is set.

- [ ] **Step 1: Write failing tests.**

```ts
test("captures stdout, stderr and exit code", async () => {
  const r = await runCommand("echo out; echo err >&2; exit 3", 5, ".");
  assert.deepEqual([r.exitCode, r.stdout, r.stderr, r.timedOut], [3, "out\n", "err\n", false]);
});
test("kills a hanging command and its children at the timeout", async () => {
  const r = await runCommand("sleep 30 & sleep 30", 0.3, ".");
  assert.equal(r.timedOut, true); assert.equal(r.exitCode, 124); assert.ok(r.durationS < 2);
});
test("a command waiting on stdin ends instead of hanging", async () => {
  const r = await runCommand("cat", 2, "."); assert.equal(r.timedOut, false);
});
test("output past the capture limit is dropped without failing", async () => {
  const r = await runCommand("head -c 5000000 /dev/zero | tr '\\0' 'a'", 10, ".");
  assert.equal(r.truncated, true); assert.ok(r.stdout.length <= CAPTURE_LIMIT_BYTES);
});
test("state does not persist between commands", async () => {
  await runCommand("cd /tmp && export X=1", 5, ".");
  const r = await runCommand("echo ${X:-unset}", 5, "."); assert.equal(r.stdout, "unset\n");
});
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** with `node:child_process` `spawn`, `detached: true`, `process.kill(-pid, "SIGKILL")`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(ts-sre): shell runner`

---

### Task 6: Prompt text and parsing

**Files:**
- Create: `src/prompt.ts`, `test/prompt.test.ts`

**Interfaces:**
- Consumes: `AppInfo`, `Stage` from Task 4.
- Produces:

```ts
export const MAX_CONSECUTIVE_FORMAT_ERRORS = 3;
export const OBSERVATION_LIMIT_CHARS = 50_000;
export function systemText(): string;
export function taskText(app: AppInfo, conductorUrl: string): string;
export function parseAction(content: string): { command: string | null; count: number };
export function observationText(exitCode: number, output: string): string;
export function timeoutText(command: string, output: string): string;
export function formatErrorText(count: number): string;
export function budgetLine(used: number, cap: number, secondsLeft: number): string;
export function wrapUpText(reason: string): string;
export function isAcceptedSubmission(output: string, stage: Stage): boolean;
```

Decisions:
- `systemText`: the reply must contain exactly one fenced `bash` block holding one command (chains with `&&` or `||` allowed), preceded by a short reasoning paragraph. Written in our own words.
- `taskText`: application name, namespace, the conductor's `descriptions`, that the environment is automated with no one to ask, the two stages and how each is graded, and how to submit. Submission is the same contract SREGym gives its other agents: diagnosis is `POST <conductorUrl>/submit` with JSON `{"solution": "<natural-language description>"}`; mitigation is the same request with `{"solution": ""}` after the fix is applied, and is mandatory. Ends with one line: every command runs in a new shell, so directory and environment changes do not persist. When `app.stages` is `["mitigation"]`, only the mitigation half is described.
- No investigation advice in v0. That is a ladder item.
- `parseAction` matches fenced blocks tagged `bash`; `command` is non-null only when `count === 1`.
- `observationText`: `<returncode>N</returncode>` then the output inside `<output>` tags. v0 does not shape output for the model, but output longer than `OBSERVATION_LIMIT_CHARS` keeps its first 50,000 characters followed by `[N more characters not shown]`. This is a guard against a single command destroying the context, not the output-handling improvement from the ladder; `PINNED.md` records it.
- `budgetLine`: `command <used> of <cap>, about <minutes> minutes left in this stage`.
- `isAcceptedSubmission`: true when the output contains `"message": "Submission received"` and `"stage": "<stage>"`, whitespace-tolerant.

- [ ] **Step 1: Write failing tests.**

```ts
test("parseAction returns the single command", () => {
  assert.deepEqual(parseAction("why\n\n```bash\nkubectl get pods -n x\n```\n"), { command: "kubectl get pods -n x", count: 1 });
});
test("parseAction rejects zero and multiple blocks, and empty content", () => {
  assert.deepEqual(parseAction("no code here"), { command: null, count: 0 });
  assert.deepEqual(parseAction("```bash\na\n```\n```bash\nb\n```"), { command: null, count: 2 });
  assert.deepEqual(parseAction(""), { command: null, count: 0 });
});
test("parseAction ignores blocks in other languages", () => {
  assert.equal(parseAction("```yaml\na: 1\n```\n```bash\nls\n```").command, "ls");
});
test("observationText cuts output past the limit and says how much", () => {
  const t = observationText(0, "a".repeat(OBSERVATION_LIMIT_CHARS + 123));
  assert.match(t, /\[123 more characters not shown\]/); assert.ok(t.length < OBSERVATION_LIMIT_CHARS + 300);
});
test("isAcceptedSubmission needs both the message and the matching stage", () => {
  const ok = '{"message": "Submission received", "stage": "diagnosis"}';
  assert.equal(isAcceptedSubmission(ok, "diagnosis"), true);
  assert.equal(isAcceptedSubmission(ok, "mitigation"), false);
  assert.equal(isAcceptedSubmission('{"detail": "error"}', "diagnosis"), false);
});
test("taskText names the submit endpoint and contains no kubectl resource hints", () => {
  const t = taskText({ app_name: "hotel", namespace: "hr", descriptions: "d" }, "http://c:8000");
  assert.match(t, /http:\/\/c:8000\/submit/); assert.match(t, /"solution": ""/);
});
test("taskText for a mitigation-only run does not describe diagnosis submission", () => { /* stages: ["mitigation"] */ });
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(ts-sre): prompt text and action parsing`

---

### Task 7: Model client

**Files:**
- Create: `src/model.ts`, `test/model.test.ts`; extend `test/fakes.ts`

**Interfaces:**
- Consumes: `Config`.
- Produces:

```ts
export interface ChatMessage { role: "system" | "user" | "assistant"; content: string }
export interface Usage { inputTokens: number; outputTokens: number; cachedTokens: number; allowance: number | null }
export type ModelError = { kind: "rate_limited" | "http" | "network" | "empty"; detail: string };
export interface Reply { content: string; finishReason: string | null; usage: Usage; latencyS: number; error: ModelError | null }
export class ModelClient {
  constructor(cfg: Config, sessionId: string, opts?: { fetchImpl?: typeof fetch; sleep?: (ms: number) => Promise<void> });
  complete(messages: ChatMessage[]): Promise<Reply>;
}
export function newSessionId(): string;          // "ses_" + crypto.randomUUID()
export function addUsage(a: Usage, b: Usage): Usage;

// test/fakes.ts
export function startFakeModel(replies: Array<string | { status: number }>): Promise<{ url: string; requests: Array<{ headers: Record<string, string>; body: any }>; close(): Promise<void> }>;
```

Decisions:
- Request body: `model`, `messages`, `max_tokens`, plus `temperature` and `reasoning_effort` only when set. Non-streaming.
- Retry on network errors, 429 and 5xx: 3 attempts in total, waiting 5 s then 15 s. After the last attempt a 429 gives `kind: "rate_limited"`; other failures give `"http"` or `"network"`. A 4xx other than 429 is not retried.
- A 200 whose content is empty or whitespace gives `kind: "empty"`.
- `cachedTokens` from `usage.prompt_tokens_details.cached_tokens` (0 when absent). `allowance` from the location recorded in Task 3 (`null` when absent).
- The API key appears in the `Authorization` header only; error details never include request headers.

- [ ] **Step 1: Write failing tests.**

```ts
test("sends the session header, a named user agent and the bare model id", async () => {
  /* one reply; assert requests[0].headers["x-opencode-session"] matches /^ses_/, user-agent matches /^ts-sre\//,
     authorization === "Bearer k", body.model === "glm-5.3-flash", body.temperature === undefined */
});
test("the same session id is sent on every call", async () => { /* two completes, headers equal */ });
test("retries a 500 then succeeds", async () => { /* replies [{status:500}, "ok"]; content === "ok"; 2 requests */ });
test("a 429 on every attempt returns rate_limited after 3 requests", async () => { /* error.kind === "rate_limited" */ });
test("a 401 is not retried", async () => { /* 1 request; error.kind === "http" */ });
test("empty content is an error", async () => { /* reply ""; error.kind === "empty" */ });
test("usage is read and summed", async () => { /* prompt 100, cached 80, completion 20 -> Usage; addUsage adds fields */ });
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(ts-sre): OpenCode Go model client`

---

### Task 8: Transcript and the stage loop

**Files:**
- Create: `src/transcript.ts`, `src/loop.ts`, `test/loop.test.ts`

**Interfaces:**
- Consumes: `ChatMessage`, `Reply`, `Usage`, `addUsage` (Task 7); `CommandResult` (Task 5); `Status`, `Stage` (Task 4); everything in `prompt.ts` (Task 6); `Config`.
- Produces:

```ts
// transcript.ts
export class Transcript { constructor(path: string); write(record: Record<string, unknown>): void; close(): void }
// each line: {"ts": ISO string, ...record}; parent directories are created

// loop.ts
export type Termination =
  | "submitted" | "stage_changed" | "hard_cap_no_submission" | "deadline_no_submission"
  | "repeated_format_error" | "model_failure" | "rate_limited";
export interface StageOutcome { stage: Stage; termination: Termination; commandsUsed: number; modelCalls: number; usage: Usage; wallSeconds: number }
export interface StageDeps {
  complete(messages: ChatMessage[]): Promise<Reply>;
  status(): Promise<Status | null>;
  run(command: string, timeoutS: number, cwd: string): Promise<CommandResult>;
  transcript: { write(record: Record<string, unknown>): void };
  now(): number;                      // seconds, monotonic
  sleep(ms: number): Promise<void>;
}
export interface StageOptions { stage: Stage; cfg: Config; workDir: string; runEndsAt: number; stageEndsAt: number | null }
export function runStage(deps: StageDeps, messages: ChatMessage[], opts: StageOptions): Promise<StageOutcome>;
```

`runStage` appends to `messages` in place, so mitigation continues the diagnosis conversation. Behaviour, in order, on each turn:

1. If time is up (`min(stageEndsAt, runEndsAt)`) or `commandsUsed >= hardCap`: send `wrapUpText` once, then allow `wrapUpCalls` more replies; after that return `deadline_no_submission` or `hard_cap_no_submission`.
2. Call the model. `rate_limited` returns `rate_limited` at once. Any other error: wait 30 s and retry; two in a row return `model_failure`.
3. Parse. Not exactly one block: send `formatErrorText`; `MAX_CONSECUTIVE_FORMAT_ERRORS` in a row return `repeated_format_error`.
4. Run the command, then read `/status` once. If it reports `agent_remaining_seconds`, recompute `runEndsAt`.
5. Send `observationText` or `timeoutText`, followed by `budgetLine`.
6. If the command's output `isAcceptedSubmission` for this stage, return `submitted`. If `/status` reports a different stage, return `stage_changed`.

Transcript records: `{type: "model_call", stage, call, latencyS, usage, finishReason, content, command, error}` and `{type: "command", stage, index, command, exitCode, durationS, timedOut, truncated, stdout, stderr}`, plus `{type: "wrap_up", stage, reason}`.

- [ ] **Step 1: Write failing tests.** All use scripted `complete`, `run` and `status` functions and a fake clock; no network or processes.

```ts
test("runs commands until the conductor accepts a submission", async () => {
  /* replies: ls block, then curl-submit block; run returns accepted JSON for the second.
     outcome.termination === "submitted"; commandsUsed === 2; modelCalls === 2;
     messages ends with [..., assistant, user(observation)] and grew by 4 */
});
test("returns stage_changed when status moves on without an accepted reply", async () => {});
test("three format errors in a row end the stage; one good reply resets the count", async () => {});
test("at the command cap the model is told once and gets 3 more replies", async () => {
  /* hardCap 2: after 2 commands a wrap-up message appears exactly once, 3 further model calls, then hard_cap_no_submission */
});
test("when the clock passes stageEndsAt during a command, the next turn wraps up with deadline_no_submission", async () => {});
test("a submission during wrap-up still counts", async () => {});
test("rate_limited ends the stage immediately without waiting", async () => {});
test("two consecutive model errors return model_failure; one error then success continues", async () => {});
test("agent_remaining_seconds from status replaces runEndsAt", async () => { /* status reports 5 s left; stage ends by deadline */ });
test("a timed-out command sends the timeout message and counts as a command", async () => {});
test("usage is summed across calls", async () => {});
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement `transcript.ts` and `loop.ts`.**
- [ ] **Step 4: Run.** `npm test && npm run typecheck`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(ts-sre): stage loop and transcript`

---

### Task 9: Entry point, shim and registration

**Files:**
- Create: `src/main.ts`, `test/e2e.test.ts`, `clients/ts_sre/__init__.py`, `clients/ts_sre/driver.py`
- Modify: `agents.yaml`

**Interfaces:**
- Consumes: everything above.
- Produces:

```ts
export function exitCodeFor(outcomes: StageOutcome[]): 0 | 1 | 2 | 4;
export function main(env: Record<string, string | undefined>): Promise<number>;
```

Decisions:
- Exit codes: `0` every stage run ended `submitted` or `stage_changed`; `1` infrastructure (conductor unreachable, config error, any `rate_limited`); `2` any `model_failure`; `4` otherwise (a stage ended without a submission). `1` wins over `2` wins over `4`.
- Sequence: `waitForStage(["diagnosis", "mitigation"], 300)`, `getApp`, read `/status` for the time left (fall back to `attemptS`), build `[system, task]`. If the first stage is diagnosis, run it with `stageEndsAt = start + diagnosisShare * (runEndsAt - start)`; then, if the conductor reaches mitigation within 300 s, run mitigation with `stageEndsAt = null` on the same messages. A diagnosis that ended without a submission still proceeds to mitigation if the conductor gets there.
- Files written in `logsDir`: `ts_sre_transcript.jsonl`, and `ts_sre_results_<problemId>_<YYYYMMDD_HHMMSS>.json` holding `{problemId, model, harnessVersion, sessionId, exitCode, stages: StageOutcome[]}`. `harnessVersion` comes from `agent/package.json`.
- Commands run with `workDir` = `/workspace` if it exists, else the logs directory.
- `driver.py`: runs `node --experimental-strip-types /opt/sregym/clients/ts_sre/agent/src/main.ts` (path resolved relative to the file), inheriting the environment and stdio, and exits with the child's code. Nothing else.
- `agents.yaml` entry:

```yaml
  - name: ts-sre
    kickoff_command: python -m clients.ts_sre.driver
    kickoff_workdir: .
    kickoff_env: null
    install_script: null
    agent_version: null
```

- [ ] **Step 1: Write failing tests.**

```ts
test("exitCodeFor ranks infrastructure over model failure over no submission", () => {
  /* [submitted, stage_changed] -> 0; [submitted, hard_cap_no_submission] -> 4;
     [model_failure, deadline_no_submission] -> 2; [rate_limited, model_failure] -> 1 */
});
test("end to end: diagnoses, then mitigates, against fake conductor and fake model", async () => {
  /* fake conductor stages ["diagnosis", "mitigation", "done"]; fake model replies with two curl-submit blocks
     whose commands really run against the fake conductor. Assert: main resolves 0;
     conductor.submissions has 2 entries and the second is ""; the results JSON exists with 2 stages;
     the transcript has model_call and command records; the API key appears in no file under logsDir */
});
test("end to end: a mitigation-only problem runs one stage", async () => {});
test("end to end: an unreachable conductor exits 1", async () => {});
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement `main.ts`, `driver.py`, the `agents.yaml` entry.**
- [ ] **Step 4: Run.** `npm test && npm run typecheck`. Expected: PASS.
- [ ] **Step 5: Run on the VM.** Push, pull on the VM, then:

```bash
uv run main.py --agent ts-sre --model openai/glm-5.3-flash --judge-model openai/gpt-6-luna --problem network_policy_block --force-build
```

Expected: the node process starts inside the container without a type-stripping error, both stages run, a results CSV row exists, and `ts_sre_transcript.jsonl` is in the run's log folder. If the image's Node rejects the flag or the syntax, record its version in `NOTES.md` and fix before going on.

- [ ] **Step 6: Commit.** `feat(ts-sre): entry point, python shim and agent registration`

---

### Task 10: Problem sets and sweep tooling

**Files:**
- Create: `results/sets/dev.txt`, `results/sets/test.txt`, `results/sets/subset.txt`, `scripts/sweep.sh`, `scripts/summarize.ts`, `scripts/summarize.test.ts`

**Interfaces:**
- Consumes: results CSV columns, log locations and `--n-attempts` semantics from `results/NOTES.md` (Task 3); `ts_sre_results_*.json` (Task 9).
- Produces:

```
scripts/sweep.sh <agent> <model-id> <dev|test|subset> <label> [repeats=3]
  -> results/runs/<label>/rep<N>/<problem>/   copied CSV row, results JSON, transcript
node --experimental-strip-types scripts/summarize.ts <label>
  -> results/runs/<label>/per_problem.csv    problem, rep, diagnosis, mitigation, tokens, seconds, termination
  -> appends one row to results/results.md
```

```ts
export interface RunRecord { problem: string; rep: number; diagnosis: boolean | null; mitigation: boolean | null; tokens: number; seconds: number; termination: string; infra: boolean }
export function summarize(records: RunRecord[]): { n: number; diagnosisPct: number; mitigationPct: number; e2ePct: number; perRep: number[]; meanTokens: number; meanSeconds: number; terminations: Record<string, number> };
```

Decisions:
- `dev.txt`: the 17 Lite IDs from `docs/SREGym-Lite.md`. `test.txt`: the 15 from the spec. `subset.txt`: `network_policy_block`, `env_variable_shadowing_astronomy_shop`, `service_dns_resolution_failure_social_network`, `kafka_poison_pill_hol_block`, `finalizer_deadlock_controller_hotel_reservation`.
- `sweep.sh` loops repeats outside and problems inside, one `uv run main.py --problem <id>` per run, always with `--judge-model openai/gpt-6-luna` and the default profile. `subset` adds `--stages diagnosis` and defaults to 1 repeat. It sources `.env`, refuses to run with a dirty git tree, and writes the git tag or commit into `results/runs/<label>/meta.json` with the model, set and start time.
- A run whose agent exit code is `1`, or whose deploy failed, is marked `infra` and re-run once at the end of the sweep. Runs still `infra` after that are excluded from percentages and listed in the row.
- `results.md` columns: date, version, model, set, n, diagnosis % (mean and min-max over repeats), mitigation %, end-to-end %, mean tokens, mean seconds, terminations, excluded, label.
- Percentages are over problems within a repeat, then averaged over repeats; `perRep` holds each repeat's end-to-end %.

- [ ] **Step 1: Write failing tests for `summarize`.**

```ts
test("percentages are per repeat, then averaged", () => {
  /* 2 problems x 2 reps; rep1 both e2e pass, rep2 one passes -> e2ePct 75, perRep [100, 50] */
});
test("infra records are excluded from n and percentages", () => {});
test("a diagnosis-only run counts e2e as null, not as failure", () => { /* mitigation null -> e2ePct NaN reported as n/a */ });
test("termination counts are tallied", () => {});
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement `summarize.ts` and `sweep.sh`.**
- [ ] **Step 4: Run.** Tests PASS; `bash -n scripts/sweep.sh` exits 0.
- [ ] **Step 5: Smoke test on the VM.** `scripts/sweep.sh ts-sre glm-5.3-flash subset smoke 1` then `summarize.ts smoke`. Expected: 5 run folders, a `per_problem.csv` with 5 rows, one new row in `results.md`. Delete the smoke row afterwards.
- [ ] **Step 6: Freeze the test set.** Run each of the 15 test problems once with `--agent autosubmit`. For any that fails to deploy or inject its fault, swap in the next reserve from the spec and repeat. Commit the final `test.txt` with a note in `NOTES.md` listing swaps. From here on `test.txt` does not change.
- [ ] **Step 7: Commit.** `feat: problem sets, sweep script and summariser`

---

### Task 11: Baselines and v0

**Files:**
- Modify: `results/journal.md`, `results/results.md`, `results/NOTES.md`

- [ ] **Step 1: Journal first.** Write the v0 entry in `journal.md` before running: what v0 is, and the expectation that it scores at or somewhat below `mini-sre` on the same model, since it has no investigation advice and a looser output limit.

- [ ] **Step 2: Tag.** Set `version` in `agent/package.json` to `0.0.0`, commit, `git tag v0`, push the tag, pull on the VM.

- [ ] **Step 2b: Budget gate.** The full baseline below is 243 runs (51 `mini-sre`, 102 v0 dev, 90 v0 test). Take the mean wall time per run from the Task 9 and Task 10 runs (deploy plus agent plus teardown), multiply by 243 and by the hourly price in `NOTES.md`. If the projection is above $30, cut in this order and tell the user: switch the instance to spot; run the `mini-sre` reference with 1 repeat; run the test set on `glm-5.3-flash` only. Record the projection and the choice in `NOTES.md`.

- [ ] **Step 3: `mini-sre` reference, dev set.** `scripts/sweep.sh mini-sre glm-5.3-flash dev mini-glm-dev 3`, then summarise.

- [ ] **Step 4: v0, dev set, both models.** `scripts/sweep.sh ts-sre glm-5.3-flash dev v0-glm-dev 3` and `scripts/sweep.sh ts-sre mimo-v2.6-flash dev v0-mimo-dev 3`, then summarise each. Sweeps run one at a time; the cluster is shared. Stop the VM between sweeps.

- [ ] **Step 5: Plumbing check.** Compare `v0-glm-dev` with `mini-glm-dev` problem by problem. Pass: every v0 run ended with a recorded termination, no run was lost to a crash, and v0's end-to-end % is within one repeat's spread of `mini-sre`, or lower for reasons visible in the transcripts. Fail: any crash, any run with no transcript, or zero accepted submissions. Fix plumbing and re-run before continuing.

- [ ] **Step 6: Judge audit.** Pick 20 diagnosis verdicts from the dev runs (10 passes, 10 fails), read each submission against the problem's known fault, and record agreement in `NOTES.md`. If more than 3 of 20 look wrong, stop and raise it with the user before trusting any comparison.

- [ ] **Step 7: v0, test set.** `scripts/sweep.sh ts-sre glm-5.3-flash test v0-glm-test 3` and the same for `mimo-v2.6-flash`; summarise. Read scores only.

- [ ] **Step 8: Commit results.** `results: v0 and mini-sre baselines`. Record spend so far (VM hours, Go allowance used) in `NOTES.md`.

- [ ] **Step 9: Hand back.** Report the table to the user. The next step is theirs with you: read the failed v0 dev transcripts together and choose the first improvement.

# Harness-level improvements for a minimal SREGym agent: evidence catalogue

Compiled 2026-11-16. Target setting: a TypeScript loop of one model call, one bash command per reply, output fed back; SREGym (diagnose, then mitigate, about 1800 s for both); flash-tier open models over an OpenAI-compatible API.

Notes on sources. "Repo" means the SREGym repository at https://github.com/SREGym/SREGym (shallow clone of `main`, read 2026-11-16). File paths are relative to it. Vendor benchmark numbers are flagged as vendor-reported. Transfer ratings are my judgment, not measured.

---

## 0. What the top SREGym entries do

**Leaderboard (SREGym-Lite, 17 faults), https://sregym.com/leaderboard.** Top five by E2E: Radar + Claude Code (Opus 5.5 medium) 100% E2E, TTD 36.6 s, TTM 65.9 s, 554K tokens; Chiron + Claude Code (Opus 5.5 medium) 100%, 57.5 s / 97.1 s, 277K tokens; Devin Oncall (Opus 5.5 high) 100%, 1.24M tokens; CloudThinker (GPT-6 Astra low) 100%, 736K tokens. The most useful row pair is a controlled harness comparison on the same model: **Chiron + Claude Code with Claude Sonnet 5 scores 61.8% E2E at 990K tokens, against plain Claude Code with Sonnet 5 at 45.1% E2E and 3.37M tokens.** That is +16.7 points with 3.4x fewer tokens, from better context alone.

**Radar + Claude Code** (`clients/claudecode_radar/README.md`, `routing.md`; https://github.com/skyhook-io/radar). This is stock Claude Code with kubectl *removed* from the container. Its only path to the cluster is Radar's MCP server, which keeps a live model of the cluster: resources, ownership and topology, a timeline of recent changes with diffs, events, logs, and detected issues. Tools named include `diagnose`, `get_changes`, `list_resources`, `get_resource`, `exec_pod`, `patch_resource`, `apply_resource`, `manage_workload` and `wait_for`. Deletes use a preview-then-confirm token. The only client-added prompt text is a short routing note saying which tool covers exec, change, delete and wait. Radar is restarted for each problem with an empty timeline database. Radar's own benchmark used 50 SREGym faults, the same agent and model, and diagnosis only. It reports 64 s vs 191 s to diagnosis with Radar MCP versus raw kubectl, and 86% vs 60% correct within two minutes (vendor-reported, https://github.com/skyhook-io/radar). Its tool comparison reports Radar at 44/50 correct, 79 s and $0.27 per fault, against kubectl-ai at 41/50, 288 s and $1.67 (https://radarhq.io/benchmark/ai-sre-tools). The biggest gap was on "Ready, but broken" faults, where the evidence sits in a configuration object: Radar got 12/14 and AWS DevOps Agent 5/14. The page itself notes that faults are injected minutes after deployment, which favours tools that correlate recent changes.

**Chiron + Claude Code** (https://chironvision.ai). Chiron is a streaming observability layer that correlates logs, metrics and traces into a compact live model. Agents query it through a context endpoint that returns structured causal state and linked evidence. On its own ORCA-bench, Chiron reports about 154K tokens per incident trial with Sonnet 4.6, against 1.43M in the SREGym paper (vendor-reported). The site has no public design details on prompts or memory.

**CloudThinker** (`clients/cloudthinker/README.md`, `driver.py`). A hosted multi-agent platform ("Anna") reaching the cluster through MCP connections to kubectl, Prometheus, Loki and Jaeger. Design points visible in the client:
- (a) Mitigation **continues the same conversation** as diagnosis, so the agent keeps its own findings.
- (b) A run with zero tool calls is treated as a harness failure, not an answer.
- (c) The published prompt mode `scoped_rca` makes the agent load a generic `root-cause-analysis` skill (competing hypotheses, evidence standards, causal chain) before investigating. The driver comments record that in the same mode, Sonnet runs loaded the skill on their own and Opus runs did not, which is why loading was made mandatory.
- (d) A `scoped_rca_corpus` mode lets the agent scout a corpus of past incident patterns, "then verify any match against live evidence".
- (e) The mitigation prompt asks it to verify that pods are Running and Ready and that the symptom is gone, and states that it is graded on fixing the root cause, not the symptoms.
- (f) A memory arm with seeded observations, skills and memories is logged per run.

The driver also notes that an earlier `guided` prompt, which enumerated the mutated fields, was retired as unpublishable because it reproduced the judge rubric.

**Devin Oncall** (Cognition, launched 2026-10-15). It connects to observability and ticketing tools and can open tested PRs (https://runtimewire.com/article/cognition-devin-oncall-production-incidents, paywalled teaser). I found no public design details.

**Stratus** (`clients/stratus/`; paper https://arxiv.org/html/2506.02009, NeurIPS 2025). This is a state machine of four agents: Detection, Diagnosis, Mitigation and Undo/Rollback. Each round is a "thinking step" that picks a tool and justifies it, followed by an "action step" that emits the call (`stratus_agent/README.md`). Diagnosis gets only read-only kubectl, which is allowlisted, plus Jaeger and Prometheus tools. Steps are capped at 20 per agent. Mitigation runs under `retry_mode: validate`, with up to 10 attempts. After each attempt, weak oracles check the cluster: `ClusterStateOracle` looks for pods not Running or Succeeded, waiting containers and CrashLoopBackOff, and `AlertOracle` looks at firing Prometheus alerts (`weak_oracles/`, `driver/driver.py`). On failure, a rollback agent undoes the recorded kubectl commands from an action stack, and the next attempt gets the oracle results plus a "what worked / what didn't" reflection summary (`configs/llm_summarization_prompt.yaml`).

**mini-sre** (`clients/mini_sre/`). This bundled agent is essentially the harness being built. It is mini-swe-agent's prompt with one bash block per reply and a new subshell per command. Output is capped at 10,000 characters, keeping the first and last 5,000 with an elided count and a warning. Five "how to work" rules are added:
1. State the hypothesis and what the command would tell you.
2. Read the output and say what it rules in and out.
3. Drop an idea after two uninformative commands.
4. Survey before going deep.
5. Stop once the evidence answers the task.

A `<budget>` line after each command reports commands and minutes left, and turns into an urgent "submit now" at 15 commands or 5 minutes left. The harness also sets 80 commands per stage, 60 s per command, a two-thirds time share for diagnosis, 3 wrap-up replies after a limit, and stops after 3 consecutive format errors. I found no published scores. It is the natural baseline to ablate against.

---

## 1. Observation shaping and tool / ACI design

**1.1 Pre-digested cluster state (topology, recent-change timeline, ranked issues) instead of raw kubectl.**
- Evidence:
  - Same model and harness, Sonnet 5 on the SREGym leaderboard: Chiron + Claude Code 61.8% E2E at 990K tokens, against Claude Code alone at 45.1% and 3.37M tokens (https://sregym.com/leaderboard).
  - Radar on 50 SREGym faults: 3x faster diagnosis and 86% vs 60% correct within 2 minutes (vendor, https://github.com/skyhook-io/radar).
  - The SREGym paper reports that Claude Code and Codex pull raw observability streams into context, "which inflates token use without raising end-to-end success", while Stratus preprocesses telemetry and uses far fewer tokens. On the same model, Claude Code used 1.81x Stratus's tokens and Codex at least 2.44x (https://arxiv.org/html/2605.07161).
  - ITBench's SRE agent wraps telemetry in NL2Traces, NL2Metrics, NL2Logs and summarization tools because raw telemetry overflows context (https://arxiv.org/html/2502.05352).
- Transfer: **high**. A weak model gains the most when the harness does the correlation, and the injected-shortly-after-deploy pattern makes a "what changed recently" view especially informative.
- Cost: a medium-to-high build. You can approximate it with bash helper scripts, for example one that summarizes non-Ready pods, recent events sorted by time, and rollout history with spec diffs. Saves tokens.

**1.2 Output truncation with head and tail plus a guidance message.**
- Evidence:
  - In SWE-agent (GPT-4 Turbo, SWE-bench Lite), a 100-line file viewer scored 18.0%. Showing the full file dropped it to 12.7%, and a 30-line window to 14.3%.
  - "Summarized" search scored 18.0%, against 12.0% for iterative search (https://arxiv.org/html/2405.15793).
  - AIOpsLab names "overloaded data consumption" (dumping raw output with `cat`) as a failure cause. Successful runs used metrics and trace APIs sparingly (https://arxiv.org/html/2501.06706).
  - Anthropic reports that Claude Code caps tool responses at 25,000 tokens and that concise response formats used about 1/3 of the tokens (72 vs 206 in their example) (https://www.anthropic.com/engineering/writing-tools-for-agents).
  - mini-sre already keeps 5,000 head and 5,000 tail characters (`clients/mini_sre/mini.py`).
- Transfer: **high**. `kubectl logs`, `describe` and Jaeger JSON are routinely huge.
- Cost: trivial. Tune the limit per command type. Grep-able spill-to-file, as in the mini-swe-agent warning, keeps the data recoverable.

**1.3 Linting / guardrails on actions, by analogy with SWE-agent's edit linter.**
- Evidence: in SWE-agent, edit without linting scored 15.0% against 18.0% with it. After a single failed edit, the eventual edit success rate fell from 90.5% to 57.2%, and cascading failed edits were 23.4% of unresolved runs (https://arxiv.org/html/2405.15793).
- Transfer: **medium**. The analogue here is pre-execution checks: reject `kubectl edit` and `-f`/`--watch`, validate resource names against a cached `kubectl get` listing, and dry-run patches with `--dry-run=server`.
- Cost: low.

**1.4 Actionable error messages and meaningful identifiers.**
- Evidence: Anthropic recommends errors that state specific fixes, and resolving UUIDs to names, which they say reduces hallucination. They give no number (https://www.anthropic.com/engineering/writing-tools-for-agents). AIOpsLab saw GPT-3.5 repeat the same malformed call up to 14 times in a 20-step run (https://arxiv.org/html/2501.06706).
- Transfer: **high** for weak models.
- Cost: low. For example, on "NotFound", append the list of existing names of that kind.

**1.5 A few task-specific tools rather than only bash.**
- Evidence:
  - The SWE-agent ACI beat a shell-only agent: 18.0% vs 11.0%, a 64% relative gain (https://arxiv.org/html/2405.15793).
  - Counter-evidence: mini-swe-agent is bash-only, uses no tool-calling interface, and claims more than 74% on SWE-bench Verified with frontier models (https://github.com/SWE-agent/mini-swe-agent).
  - In the SREGym paper, Stratus's custom API tools made up 15-17% of its calls, while Claude Code and Codex used raw curl for only 2-3% (https://arxiv.org/html/2605.07161). Agents rarely touch telemetry unless it is a first-class tool.
- Transfer: **medium-high**. Keep bash, and add wrapper commands on PATH, such as `prom`, `logs`, `traces`, `alerts` and `deps`, that call the observability backends with concise, filtered output.
- Cost: low-medium.

---

## 2. Context management

**2.1 Observation masking (drop old tool outputs, keep actions).**
- Evidence:
  - On SWE-bench Verified with SWE-agent, masking observations older than 10 turns cut cost by about 50% in most setups.
  - Gemini 2.5 Flash rose from 32.8% to 35.6% with masking, at 56% lower cost. Qwen3-Coder 480B went from 53.4% to 54.8%.
  - Exception: Gemini 2.5 Flash with thinking fell from 40.4% to 36.4%.
  - LLM summarization was no better than masking and made trajectories longer: for Gemini Flash, 52 turns vs 44 with masking (https://arxiv.org/html/2508.21433).
  - In SWE-agent, keeping the last 5 observations scored 18.0% against 15.0% for full history (https://arxiv.org/html/2405.15793).
- Transfer: **high** for token metrics, **medium** for accuracy. SRE runs of 30-80 commands are long enough that masking pays off, but the evidence used to diagnose must survive. Pair it with notes (2.3).
- Cost: trivial. It does break prefix caching at each masking boundary, so mask in blocks.

**2.2 Prompt-cache-friendly, append-only context.**
- Evidence: Manus reports a roughly 100:1 input-to-output token ratio and a 10x price gap between cached and uncached tokens on Sonnet ($0.30 vs $3 per MTok). It recommends a stable prefix, no timestamps at the top, deterministic serialization, and masking rather than removing tools (https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus).
- Transfer: **high** for cost and latency if the provider supports prefix caching. Many OpenAI-compatible hosts of open models do, but check yours. mini-sre appends the budget line to the end of each observation, which is already cache-safe.
- Cost: none.

**2.3 Scratchpad / notes / todo recitation.**
- Evidence:
  - Manus rewrites a `todo.md` to push the plan into recent attention and reduce goal drift on tasks of about 50 tool calls, and keeps errors in context so the model updates its beliefs (no numbers, URL above).
  - Anthropic recommends structured note-taking for long-horizon work (no numbers) (https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents).
  - The SREGym paper documents "failure to revise hypotheses": an agent wrote down the correct Valkey password command as a candidate but stuck with a memory explanation (https://arxiv.org/html/2605.07161).
- Transfer: **medium-high**. A harness-maintained "hypotheses: supported / ruled out" block, re-injected at the end of context, directly targets anchoring.
- Cost: low tokens. There is no measured effect in SRE.

**2.4 Carry diagnosis into mitigation.**
- Evidence: the SREGym paper gives P(mitigation | correct diagnosis) of 0.84-0.89 for the Sonnet agents, against 0.54-0.62 when the diagnosis was wrong. For Kimi K2.5 it was 0.68 vs 0.22 (https://arxiv.org/html/2605.07161). CloudThinker continues the same conversation (`clients/cloudthinker/README.md`).
- Transfer: **high**. Either keep the history, or pass a structured diagnosis forward if you reset context.
- Cost: none.

---

## 3. Prompting, planning and domain knowledge

**3.1 Hypothesis-driven investigation rules and anti-anchoring.**
- Evidence:
  - The SREGym paper's dominant failure is greedy anchoring: all agents treated "the first plausible anomaly" as the target. Under noise, diagnosis dropped for every agent, by 61.5 to 51.5 for Stratus + Sonnet and 72.6 to 62.6 for Claude Code (https://arxiv.org/html/2605.07161).
  - Kim et al. ran 1,675 OpenRCA runs and found the most common pitfalls were "hallucinated data interpretation and incomplete exploration" across all models. Prompt engineering alone did not fix them (https://arxiv.org/abs/2602.09937).
- Transfer: **medium**. Rules help, but the evidence says architecture matters more. Combine them with harness-enforced checks, such as requiring a ruled-out list before submitting.
- Cost: negligible.

**3.2 SOP / runbook / skill retrieval.**
- Evidence:
  - Flow-of-Action (WWW'25): an SOP-guided multi-agent RCA reached 64.01% against ReAct's 35.50% (https://arxiv.org/abs/2502.08224).
  - RCACopilot at Microsoft routes incidents to alert-type handlers that collect diagnostics, and reports RCA accuracy up to 0.766 (https://arxiv.org/abs/2305.15778).
  - CloudThinker's published numbers all use a forced generic RCA skill (`clients/cloudthinker/driver.py`).
- Transfer: **high**. A generic Kubernetes triage checklist, covering changes, selectors and endpoints, env and config/secret refs, NetworkPolicy, quotas and limits, webhooks, finalizers, probes and DNS, maps directly onto SREGym's fault families. Keep it generic to avoid overfitting.
- Cost: about 1-2K prompt tokens, cacheable.

**3.3 Workflow memory / few-shot trajectories.**
- Evidence: Agent Workflow Memory improved success by 24.6% relative on Mind2Web and 51.1% on WebArena, and reduced steps (https://arxiv.org/abs/2409.07429). In SWE-agent, removing the demonstration cost 1.7 points (16.3 vs 18.0) (https://arxiv.org/html/2405.15793). Manus warns that repetitive few-shot context causes mimicry ruts (URL above).
- Transfer: **medium**. One generic worked trajectory is likely to help format adherence in flash models. Trajectories mined from SREGym problems risk benchmark overfitting; HAL warns about holdouts (https://arxiv.org/abs/2407.01502).
- Cost: 2-5K tokens per example.

**3.4 Explicit "think" step before each action.**
- Evidence: Anthropic's think tool on τ-bench airline scored pass^1 0.584 with an optimized prompt, against a 0.332 baseline. The think tool alone scored 0.404, against 0.412 for extended thinking. Retail went from 0.812 to 0.783 baseline. On SWE-bench the gain was 1.6% (https://www.anthropic.com/engineering/claude-think-tool). A December 2025 update recommends extended thinking instead in most cases. Stratus separates its thinking step from its action step.
- Transfer: **medium**. mini-sre already requires a THOUGHT section. Native reasoning in the flash models is probably the better lever (see 6.2).
- Cost: output tokens.

**3.5 Tell the agent the grading criteria.**
- Evidence: SREGym's diagnosis judge scores three equal-weight dimensions, with a pass at a composite of at least 0.70 (`sregym/conductor/oracles/llm_as_a_judge/rca_checklists.yaml`):
  - D1, Fault Localization: names the origin component, not the downstream victims.
  - D2, Fault Characterization: names the mechanism and the concrete mutated value.
  - D3, Scope Precision: no over-attribution, includes all affected components.
  CloudThinker's retired `guided` prompt that mirrored this was judged leakage, but its `scoped` mitigation prompt keeps the upstream wording "addresses the root cause rather than only the symptoms".
- Transfer: **high**. A structured final-answer template asking for kind/name, namespace, the wrong value against the expected value, causal chain and affected components is legitimate output shaping. It likely raises D2 and D3 for terse flash models.
- Cost: none. Stay on the right side of the leakage line by not enumerating fault types.

---

## 4. Verification, retries and safety

**4.1 Post-mitigation verification against weak oracles, with undo and retry.**
- Evidence:
  - Stratus ablation (AIOpsLab, GPT-4o): the full system reached 69.2% mitigation. With no retry it fell to 15.4%, and with naive retry and no undo to 23.1%.
  - Only 2 problems were solved by the first plan, and naive retry from a worsened state added only 1 (https://arxiv.org/html/2506.02009).
  - The SREGym paper attributes Stratus + Sonnet's best mitigation rate (78.5%) to undo-and-retry. Stratus averaged 3.82 attempts when the diagnosis was wrong and 1.88 when it was right (https://arxiv.org/html/2605.07161).
  - With smaller models, Stratus on GPT-4o-mini beat AOL-agent 23.1% vs 7.7%, but took 3,557.9 s and 125.7 steps (https://arxiv.org/html/2506.02009).
- Transfer: **high**. Mitigation is graded on the live cluster's health, and the harness can check pod readiness and firing alerts itself, without the model's help.
- Cost: medium complexity. Record write commands and their inverses, for example by snapshotting the object with `kubectl get -o yaml` before a patch. Each retry costs time, so watch TTM.

**4.2 Pre-submit verification gate for diagnosis.**
- Evidence:
  - LangChain's deepagents went from 52.8% to 66.5% on Terminal-Bench 2.0 with GPT-5.2-Codex fixed, through harness changes alone. These included a pre-completion checklist that forces a verification pass. Only the reasoning-effort settings were isolated individually (https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering).
  - Huang et al. found intrinsic self-correction without external feedback can *degrade* performance (https://arxiv.org/abs/2310.01798). The check therefore needs external evidence: "re-run the command that shows the wrong value", not "re-read your answer".
- Transfer: **medium-high**.
- Cost: 1-3 extra commands.

**4.3 Multiple attempts / repeated sampling and voting.**
- Evidence:
  - Large Language Monkeys raised SWE-bench Lite from 15.9% with 1 sample to 56% coverage with 250 samples (DeepSeek-Coder-V2). Without a verifier, majority voting plateaus (https://arxiv.org/abs/2407.21787).
  - RCAgent applies self-consistency over action trajectories and beats ReAct; the abstract gives no numbers (https://arxiv.org/abs/2310.16340).
  - HAL: simple retry and warming baselines (92.0% and 93.2% on HumanEval) matched or beat LATS (88.0% at $134.50) at about 1/50 of the cost (https://arxiv.org/html/2407.01502).
- Transfer: **low-medium** for a live cluster. You cannot fork the environment, and parallel mitigations collide. For diagnosis, cheap parallel read-only investigations followed by a vote over structured answers (component, mechanism) are feasible within 30 minutes.
- Cost: N times the tokens.

**4.4 Read-only diagnosis phase / command allowlist.**
- Evidence: Stratus restricts diagnosis to an allowlist of read-only kubectl commands (`clients/stratus/configs/diagnosis_agent_config.yaml`). Radar's notes report that a Claude Code auto-mode classifier refused a legitimate fix, so it uses `dontAsk` with an explicit allowlist (`clients/claudecode_radar/README.md`).
- Transfer: **medium**. It prevents a weak model from "fixing" during diagnosis and destroying evidence.
- Cost: trivial.

---

## 5. Orchestration, budget and termination

**5.1 Budget / time awareness injected each turn.**
- Evidence:
  - Liu et al. (Google): giving agents a bigger tool budget does not help without budget awareness, and a "Budget Tracker" plug-in gives "more favorable scaling curves" (https://arxiv.org/abs/2511.17006). The per-benchmark numbers come from aggregators only (see "Could not verify").
  - LangChain used time-budget warnings (no isolated number, URL above).
  - In AIOpsLab, accuracy plateaued as the step limit grew, and GPT-3.5 gained nothing beyond 5 steps (https://arxiv.org/html/2501.06706).
- Transfer: **high**. Unsubmitted stages score zero. mini-sre implements it already.
- Cost: about 20 tokens per turn.

**5.2 Loop / stuck detection.**
- Evidence: OpenHands' StuckDetector flags the same action and observation 4 or more times, the same error 3 times, or alternating ping-pong patterns, and is enabled by default (https://docs.openhands.dev/sdk/guides/agent-stuck-detector). LangChain's LoopDetectionMiddleware injects "reconsider your approach" after N edits to the same file and "can help but is not guaranteed" (URL above). AIOpsLab lists repeated calls and invented APIs as wasted steps (https://arxiv.org/html/2501.06706).
- Transfer: **high**. Flash models loop.
- Cost: trivial. Hash normalized commands and outputs.

**5.3 Diagnosis / mitigation split with separate prompts and budgets.**
- Evidence: Stratus, CloudThinker and mini-sre all stage it. mini-sre gives diagnosis up to two-thirds of the time. In the SREGym paper, agents issued 19-28 reads before their first write (https://arxiv.org/html/2605.07161).
- Transfer: **high**. It is structurally required.
- Cost: none.

**5.4 Sub-agents.**
- Evidence: Anthropic's multi-agent research system beat single-agent Opus 4 by 90.2%. Token usage explains 80% of the variance, and multi-agent setups use about 15x the tokens of chat. It is a poor fit for tightly coupled tasks (https://www.anthropic.com/engineering/multi-agent-research-system). AIOpsLab saw multi-agent "chatter" waste steps (https://arxiv.org/html/2501.06706). Kim et al. found richer inter-agent protocols cut communication failures by up to 15 points (https://arxiv.org/abs/2602.09937).
- Transfer: **low-medium**. A single cluster and sequential causality limit the benefit. The plausible use is a context-isolated "log digger" sub-call that returns a short summary.
- Cost: high tokens.

**5.5 Model routing (cheap explorer, stronger decider).**
- Evidence: Aider's architect/editor split scored 85.0% for o1-preview plus o1-mini or DeepSeek, against 79.7% for o1-preview alone, and 71.4% for o1-mini plus DeepSeek, against 61.1% for o1-mini alone (https://aider.chat/2024/09/26/architect.html). HAL's "escalation" baseline scored 85.0% at $0.27 (https://arxiv.org/html/2407.01502).
- Transfer: **medium**. Use the flash model for reads and a stronger model only for the final diagnosis and the mitigation plan. Results then would not be pure "flash-tier" numbers.
- Cost: a few expensive calls.

---

## 6. Weak-model failure modes and mitigations

**6.1 Format errors / text parsing versus native tool calls.**
- Evidence: mini-swe-agent parses a single fenced bash block and needs no tool-calling API (https://github.com/SWE-agent/mini-swe-agent). Tam et al. find "a significant decline in LLMs reasoning abilities under format restrictions" such as JSON (https://arxiv.org/abs/2408.02442). mini-sre ends a stage after 3 consecutive format errors and gives a corrective template (`clients/mini_sre/mini.py`).
- Transfer: **high**. Measure format-error rate per model and try both modes. Lenient parsing (accept a lone ```sh block, take the last block) is cheap.
- Cost: none.

**6.2 Reasoning effort.**
- Evidence:
  - deepagents scored 53.9% at `xhigh` everywhere (timeouts), 63.6% at `high`, and 66.5% with the "sandwich" of xhigh for planning and verification and high for implementation (LangChain URL).
  - On the SREGym leaderboard, Codex with GPT-6 Astra scored 90.2% E2E at medium (377K tokens) and 96.1% at max (719K). CloudThinker scored 100% at both low and max, but low took TTD 126 s against 310 s.
  - Gemini 2.5 Flash on SWE-bench Verified scored 40.4% with thinking against 32.8% without (https://arxiv.org/html/2508.21433).
- Transfer: **high**. It is one parameter, but there is a real timeout risk at a 30-minute cap.
- Cost: time and tokens.

**6.3 Premature submission / giving up.**
- Evidence: SREGym documents greedy stopping at the first anomaly (paper URL). LangChain saw agents re-read their work, "decide it looked fine", and stop. CloudThinker treats zero-tool-call answers as invalid.
- Mitigations: a minimum-evidence gate (for example, reject a submission that names a resource never inspected in the transcript) and a verification checklist.
- Transfer: **high**.

**6.4 Hallucinated resource names and mechanisms.**
- Evidence: in the SREGym GC-capacity case, an agent submitted a fabricated `tc netem` rule as root cause and mitigated it (paper URL). Kim et al. report hallucinated data interpretation as a top pitfall (URL above).
- Mitigation: the harness cross-checks the names in the final answer against `kubectl get` output.
- Transfer: **high**. Cost: low.

**6.5 Weak base capability.**
- Evidence: Stratus with Kimi K2.5 scored 27.4% E2E against 54.8% with Sonnet 4.6, with TTD 674 s against 114 s (https://arxiv.org/html/2605.07161). ITBench: Llama-3.1-8B diagnosed 0.99% against 13.81% for GPT-4o (https://arxiv.org/html/2502.05352).
- Implication: expect low absolute numbers, and favor deterministic harness work (1.1, 4.1, 6.4) over prompt cleverness.

**6.6 Run-to-run variance.**
- Evidence: ITBench GPT-4o diagnosed the same scenario in 1/10, 6/10 and 8/10 runs depending on the scenario (https://arxiv.org/html/2502.05352).
- Implication: you need repeated attempts per problem (SREGym supports `--n-attempts`) before crediting a one-change improvement.

---

## SREGym-specific observations

- **Observability exposed by the MCP server** (`mcp_server/`):
  - Prometheus: `get_metrics(query)` (PromQL) and `get_alerts()` (firing alerts only).
  - Jaeger: `get_services`, `get_operations(service)`, `get_traces(service, last_n_minutes)` (20 traces, raw JSON as a string) and `get_dependency_graph(last_n_minutes=30)`.
  - Loki: `get_logs(LogQL, last_n_minutes=15)` (100 entries, formatted), `get_labels` and `get_label_values`.
  - kubectl: `exec_kubectl_cmd_safely`, `rollback_command` and `get_previous_rollbackable_cmd`, which give a server-side action stack and undo.
  - `submit(ans, stage)`.
  - Raw `get_traces` output is unsummarized. A wrapper that aggregates error spans and latency per service would matter for a flash model.
- **The task text says** "You can query metrics and traces through the available observability tools". A bash-only agent must reach these by curl or MCP. Exposing them as short CLI wrappers is the cheapest way to raise telemetry use above the 2-3% the paper measured for Claude Code and Codex.
- **Known distractor:** the harness rewrites `jaeger*` Services into ExternalName aliases for `otel-collector` in every namespace and orphans a jaeger pod. That creates a "service with no matching pods" pattern regardless of the fault (comments in `clients/cloudthinker/driver.py`). A generic note that harness telemetry plumbing is out of scope removes a false lead.
- **Diagnosis is judged by an LLM** against D1/D2/D3, with a pass at 0.70. **The judge defaults to the agent's own model** unless you set `--judge-model` (README). With a flash agent model, set a strong judge explicitly for comparable numbers. Multi-cause incidents score as the minimum across causes (`llm_as_a_judge_oracle.py`), so name every independent cause.
- **Mitigation oracles are problem-specific** (`sregym/conductor/oracles/*`) and check root-cause repair, not just symptoms. Restarting pods, which Stratus exploited on ITBench, will not pass misconfiguration faults (https://arxiv.org/html/2506.02009).
- **Hard categories** are hardware/OS faults (no agent above 0.22 diagnosis), metastable faults (quota plus trigger, never both identified) and compound faults (paper URL). A checklist item on "constraints that produce no errors (quotas, limits, GOGC), node and kernel (dmesg)" targets known blind spots.
- **SREGym-Lite** is 17 problems on kind (8 vCPU / 16 GB) and is the leaderboard cohort (`docs/SREGym-Lite.md`). Its fault list leans on config objects: env shadowing, selectors, NetworkPolicy, webhooks, finalizers, PVCs, namespace limits, secret rotation, ports, DNS. That favors a recent-change diff and spec-inspection tooling (1.1).
- **Noise injectors** add transient pod crashes and resource stress concurrently (paper appendix). Consider a harness hint to check whether an anomaly is persistent or transient before anchoring on it.
- **mini-sre is the in-repo baseline** with exactly this architecture, so implement changes against it for apples-to-apples ablations.

---

## Could not verify

- Any public design write-up for Devin Oncall, or Cognition's SREGym post itself (the RuntimeWire article is paywalled).
- Chiron's agent-side design: its prompts, memory, and how it integrates with Claude Code. Only the product page was found.
- CloudThinker's internal multi-agent design beyond the client driver; I found no cloudthinker.io write-up.
- The Stratus and mini-sre leaderboard rows. The leaderboard page I fetched listed 26 entries and no Stratus or mini-sre row, though they may appear in another cohort or view.
- BATS / Budget Tracker per-benchmark numbers (for example HLE-Search 27.0% vs 20.5% for ReAct), which I saw only on aggregator sites, not in the arXiv abstract.
- Terminal-Bench harness-gap figures, such as Opus 4.6 at 58.0% in Claude Code against 74.7% in Terminus-KIRA. These came from secondary blogs (https://qepo17.pages.dev/til/2026-04-02-terminal-bench-harness-gap), not the paper (arXiv 2601.11868).
- OpenRCA RCA-agent internals (controller plus code executor). The headline 11.34% for RCA-agent with Claude 3.5, against 5.37% for prompting with oracle telemetry, came from search snippets of https://proceedings.iclr.cc/paper_files/paper/2025/file/d29b8d53678015079e1d245c023e49d2-Paper-Conference.pdf; the PDF text could not be extracted.
- The MAST per-mode frequencies, such as step repetition and premature termination (https://arxiv.org/abs/2503.13657, abstract only).
- Isolated effect sizes for scratchpad/todo tools, tool-result clearing, or runbook retrieval specifically on SREGym. I found none published.
- Whether the target flash models' OpenAI-compatible hosts support prefix caching, and their native tool-calling reliability.

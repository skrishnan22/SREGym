# Harness Engineering Fundamentals

After reading this chapter you will know the parts of an agent harness, the vocabulary practitioners use for them, and the main trade-offs at each design point. You should be able to write a minimal v0 loop for SREGym and pick a sensible order in which to test improvements one at a time.

---

## 1. What a harness is and why it matters

A **language model** takes a sequence of messages and returns text, possibly with structured tool calls. An **agent** is a model that runs in a loop: it chooses actions, sees what they did, and decides what to do next. The **harness** (also called the **scaffold**) is all the code around the model that makes this happen: the loop, the system prompt, the tool definitions, the way command output is formatted and fed back, the handling of a growing transcript, the rules for stopping, and the code that deals with errors. **Harness engineering** means designing and tuning that code. The term caught on in early 2026, partly through an OpenAI post on building software with Codex agents ([InfoQ summary](https://www.infoq.com/news/2026/02/openai-harness-engineering-codex); the original was not fetchable for this chapter).

The harness matters because the same model scores very differently under different harnesses:

- **Terminal-Bench 2.0.** The [Terminal-Bench paper](https://arxiv.org/html/2601.11868v1) (89 command-line tasks) ran several models under several agents. GPT-5 scored 49.6% in Codex CLI and 33.9% in mini-swe-agent. Gemini 2.5 Pro scored 32.6% in the paper's own Terminus 2 agent and 15.7% in OpenHands. The paper also concludes that model choice usually matters more than the scaffold. Both statements are true: the harness moves scores by a lot, and a better model moves them by more.
- **LangChain deepagents.** LangChain [raised its agent from 52.8% to 66.5%](https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering) on Terminal-Bench 2.0 by changing only the harness, with the model fixed at gpt-5.2-codex. The changes were a self-verification step, a pre-completion checklist, injecting environment context at startup, time-budget warnings, loop detection, and varying reasoning effort by phase.
- **Edit formats.** Can Bölük [changed only the file-edit tool](https://stencil.so/blog/the-harness-problem) on a 180-task code-editing benchmark and measured 16 models. His format, which tags each line with a short hash, beat a patch format for 14 of the 16, adding about 15 points on average. Grok Code Fast 1 went from 6.7% to 68.3%. The weakest models gained the most.
- **SWE-agent ablations.** The [SWE-agent paper](https://arxiv.org/abs/2405.15793) took parts of its interface away one at a time (GPT-4 Turbo, SWE-bench Lite, full system 18.0%). Removing the edit command dropped it to 10.3%. Showing whole files instead of 100-line windows dropped it to 12.7%.

For your project this means a harness change can matter as much as moving up a model tier, and the effect is largest for cheap models. It also means results don't transfer automatically: a change that helps one model can hurt another, and a change tuned on one benchmark can fail to generalise.

---

## 2. Anatomy of the agent loop

The loop has five parts:

| Part | What it is |
|---|---|
| **Messages** | The transcript the model sees: a system prompt, the task, then alternating model replies and observations. |
| **Model call** | One request to the chat-completions endpoint with the current messages (and tool definitions, if you use native tools). |
| **Action** | What the harness pulls out of the reply: a shell command, a tool call, or a "submit" signal. |
| **Observation** | The result of running the action (stdout, stderr, exit code, or an error), formatted and appended as the next message. |
| **Termination** | The rule that ends the loop: the model submits, a step or time budget runs out, or an unrecoverable error happens. |

This is the **ReAct** pattern ([Yao et al., 2022](https://arxiv.org/abs/2210.03629)): reasoning and acting alternate, and each observation informs the next step. A minimal TypeScript version:

```ts
type Msg = { role: "system" | "user" | "assistant"; content: string };

async function runAgent(task: string, maxSteps = 40): Promise<string> {
  const messages: Msg[] = [
    { role: "system", content: SYSTEM_PROMPT },
    { role: "user", content: task },
  ];
  for (let step = 0; step < maxSteps; step++) {
    const reply = await chat(messages);                 // POST /v1/chat/completions
    messages.push({ role: "assistant", content: reply });

    const cmd = reply.match(/```bash\n([\s\S]*?)```/)?.[1]?.trim();
    if (!cmd) {                                          // malformed reply
      messages.push({ role: "user", content: "Reply with exactly one ```bash block." });
      continue;
    }
    if (cmd === "submit") return reply;                  // model chose to stop

    const { stdout, exitCode } = await exec(cmd, { timeoutMs: 60_000 });
    messages.push({
      role: "user",
      content: `exit_code=${exitCode}\n${headTail(stdout, 10_000)}`,
    });
  }
  return "STEP_LIMIT";                                   // budget ran out
}
```

Every later section changes one of these lines. The regex is your action format (§3). `exec` and `headTail` are your tool interface and output shaping (§4). The growing `messages` array is your context problem (§5). `SYSTEM_PROMPT` is §6. `maxSteps` and the timeout are §8. `chat` needs retries (§9).

Two properties of this sketch are worth keeping. First, the history only grows by appending, so what you log is exactly what the model saw. [mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent) makes this a design goal because it makes debugging easier. Second, each command runs in a fresh process (mini-swe-agent uses `subprocess.run`, not a persistent shell), which makes sandboxing simple: swap in `docker exec` or `kubectl exec`. The cost is that `cd` and `export` don't carry over between steps, so the prompt has to say so.

---

## 3. Action formats

The **action format** is how the model expresses what it wants to do. There are four main options.

| Format | How it works | Strengths | Weaknesses |
|---|---|---|---|
| **Free-text command block** | The model writes prose plus a fenced code block; the harness extracts it with a regex. Used by mini-swe-agent v1. | Works with any model and endpoint. Easy to read. Format errors are visible and you can correct them with a message. | You write the parser. Models may emit zero or several blocks. Code fences inside the command can confuse the regex. |
| **Native tool / function calling** | You send JSON Schema tool definitions; the server returns structured `tool_calls`; you reply with `role: "tool"` messages. | Arguments arrive structured. No regex. Supports **parallel tool calls** (several calls in one reply). | Depends on the server parsing the model's native tool syntax correctly, which often goes wrong with open models (§10). Failures can be silent. |
| **Purpose-built tools** | A small set of task-specific tools (for example `get_pod_logs(namespace, pod, tail)`), either as native tools or as text commands. | Easier for weak models. Lets you shape outputs and block mistakes (§4). | More code. Each tool reflects your guess about what the task needs. Too many tools confuse the model. |
| **Code as action** | The model writes a Python (or TypeScript) snippet that is executed; the result is the observation. CodeAct ([Wang et al., ICML 2024](https://arxiv.org/abs/2402.01030)). | Loops, conditionals and combining tools in one step. CodeAct reported up to 20% higher success than JSON or text actions across 17 models. | Needs a code sandbox. Runtime errors become a new failure mode. Gains depend on the model's coding skill. |

Bash already gives you a lot of code-as-action for free: a shell command can pipe, loop and filter. Terminal-Bench's neutral agent, Terminus 2, uses [only a headless terminal](https://arxiv.org/html/2601.11868v1) for this reason.

**Considerations for cheap models.**

- **Format errors.** Whatever format you choose, some replies won't parse. You need a recovery path: reply with a short error that restates the expected format, as mini-swe-agent does with its `format_error_template` ([config](https://raw.githubusercontent.com/SWE-agent/mini-swe-agent/main/src/minisweagent/config/default.yaml)), and count these errors as a metric.
- **Schema adherence.** Native tool calling is only as reliable as the provider's parser for that model. The [Berkeley Function Calling Leaderboard](https://gorilla.cs.berkeley.edu/leaderboard.html) evaluates models in both native ("FC") and prompt-based modes. Check your model there, and also test your actual endpoint, because the same model can behave very differently behind different providers (§10).
- **Parallel tool calls.** Several actions per reply means fewer round trips, but also commands running in an order the model didn't think through, and observations that are harder to attribute. One action per turn is the safer default for v0.
- **Practice has moved toward native calls.** mini-swe-agent v2 made a single native `bash` tool [the default](https://mini-swe-agent.com/latest/advanced/v2_migration/) and kept text parsing as an opt-in legacy mode. For a flash-tier open model through a third-party endpoint, measure both. This is a good early A/B test.

---

## 4. Tool design and the agent-computer interface

SWE-agent introduced the term **agent-computer interface (ACI)**: the commands, output formats and feedback an agent uses to operate a computer. The paper's argument is that models are a new kind of user and need interfaces designed for them, the way people benefit from IDEs ([paper](https://arxiv.org/abs/2405.15793)). Anthropic gives similar advice: put as much effort into the ACI as into a human UI, and the team [reported spending more time on tools than on the overall prompt](https://www.anthropic.com/engineering/building-effective-agents) for their SWE-bench agent.

What makes a tool easy for a model to use:

1. **Few tools, little overlap.** Anthropic's [tool-writing guide](https://www.anthropic.com/engineering/writing-tools-for-agents) recommends a few high-impact tools over wrappers for every API endpoint, and combining multi-step operations into one call (a `search_logs` tool instead of `read_logs`). Overlapping tools make the model hesitate between them.
2. **Clear names and parameters.** Group tools by prefix (`k8s_get_pods`, `prom_query`), and use specific parameter names (`namespace`, not `ns`; `user_id`, not `user`).
3. **Make mistakes hard (poka-yoke).** Anthropic's SWE-bench agent kept getting relative paths wrong after changing directory, and requiring absolute paths [fixed it](https://www.anthropic.com/engineering/building-effective-agents). SWE-agent runs a linter on every edit and rejects edits that break syntax. Removing that check cost 3 points ([ablation](https://arxiv.org/html/2405.15793)).
4. **Shape the output.** Large outputs fill the context and bury the useful part. SWE-agent shows files 100 lines at a time and returns at most 50 search results; above that it asks for a narrower query. mini-swe-agent returns the first and last 5,000 characters of any output over 10,000 characters, with a warning saying how much was cut. Claude Code caps tool responses at [25,000 tokens by default](https://www.anthropic.com/engineering/writing-tools-for-agents). For SRE work this matters a lot: `kubectl logs` without `--tail`, or `kubectl get events -A` on a busy cluster, can produce a huge output in one step.
5. **Say something even when there's no output.** SWE-agent returns "Your command ran successfully and did not produce any output" for silent commands, so the model doesn't think the command failed or hung.
6. **Write error messages as guidance.** An error is a prompt. "Error: namespace `prod` not found. Namespaces: default, kube-system, hotel-reservation" leads to a correct retry; a bare stack trace leads to guessing. Anthropic recommends [specific, actionable errors](https://www.anthropic.com/engineering/writing-tools-for-agents) over error codes and tracebacks.
7. **Prefer readable identifiers.** Names over UUIDs where possible. Anthropic reports that natural-language identifiers reduced hallucinated IDs.

A common real failure: in Terminal-Bench, the most frequent command-level error was calling a program that is not installed or not on `PATH` (24.1% of sampled failures, [paper](https://arxiv.org/html/2601.11868v1)). Telling the agent at startup which tools exist (what LangChain calls injecting local context) prevents a lot of wasted steps.

---

## 5. Context management

The **context window** is the maximum number of tokens the model can take in one call. An agent transcript grows with every step, and long transcripts cause problems well before they hit that limit:

- **Context rot.** Chroma tested 18 models and found performance gets [less reliable as input length grows](https://www.trychroma.com/research/context-rot), even on simple retrieval tasks, and irrelevant but similar-looking content (distractors) makes it worse. Old log dumps are exactly that kind of distractor.
- **Lost in the middle.** Models use information at the start and end of a long input better than information in the middle ([Liu et al., 2023](https://arxiv.org/abs/2307.03172)).
- **Cost and latency.** Every step resends the whole transcript. Manus reports an average input-to-output ratio of about 100:1 in its agent ([Manus](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus)), so input tokens are your main cost.

Anthropic calls managing this **context engineering**: choosing the smallest set of high-signal tokens that makes a good outcome likely ([post](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)). The main techniques, from least to most intrusive:

| Technique | What it does | Trade-off |
|---|---|---|
| **Output truncation** | Cap each observation (head/tail elision: keep the start and end, drop the middle). | Cheap and predictable. Can drop the one line that mattered; say how much was cut so the model can re-query with `grep` or `--tail`. |
| **Observation collapsing / tool-result clearing** | Replace old observations with a one-line placeholder, keeping the model's own messages. SWE-agent collapses everything except the last 5 observations; keeping full history instead cost 3 points in its ablation. | Keeps the reasoning trail. Lost details must be fetched again. |
| **Summarisation / compaction** | When near a token threshold, have a model summarise the transcript so far and continue from the summary. Terminus 2 and Claude Code both do this. | Can lose important facts. Costs an extra call. Rewrites history (see caching below). |
| **Scratchpad / notes** | The agent keeps a file such as `NOTES.md` or a todo list outside the context and re-reads it. Manus calls rewriting a todo list "recitation": it keeps goals near the end of the context, where attention is strongest. | Uses steps. Weak models may not keep notes reliably unless the harness requires it. |
| **Sub-agents** | Hand a narrow question to a fresh agent with a clean context; it returns a short summary (Anthropic cites [roughly 1,000-2,000 tokens](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)). | Keeps the main context clean, but the sub-agent lacks the main agent's context (§7). |

**Prompt caching** constrains all of these. Providers can reuse the processed state of a prompt **prefix** that matches an earlier request exactly, which makes repeated input cheaper and faster. OpenAI's docs say a hit requires the [entire rendered prefix to match](https://developers.openai.com/api/docs/guides/prompt-caching), recommend putting static content first and appending rather than rewriting, and note that summarisation, compaction or truncation can reset reuse. Manus cites a 10x price difference between cached and uncached input on Claude Sonnet and warns against putting a timestamp at the start of the system prompt. In practice:

- Keep the system prompt and tool definitions byte-identical across steps. Serialise JSON with stable key order.
- Prefer append-only history. If you must edit history, do it rarely and in large chunks (compact once at a threshold, not a little every turn), so you lose the cache occasionally rather than on every call.
- Don't add and remove tools mid-run; that changes the prefix.
- Check whether your provider caches at all for your model, and log `cached_tokens` from the usage field. Many open-model endpoints differ here, so measure.

Manus also recommends keeping failed actions and their errors in the context, because seeing them stops the model from repeating them. Be careful about deleting "noise" that is actually evidence.

---

## 6. Prompt design for agents

There are two places to put instructions:

- **System prompt.** Stable across tasks: role, environment facts (what's installed, that each command runs in a fresh shell), action format, how to submit, and general method. Stable content also caches well.
- **Task message.** Per-task: the problem statement, plus any per-task facts (namespace, which stage: diagnosis or mitigation). SREGym runs [up to two stages per problem](https://github.com/SREGym/SREGym), diagnosis then mitigation, so this is where the stage-specific instruction goes.

**How much procedure to prescribe.** Anthropic recommends the ["right altitude"](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents): between rigid if-else rules and vague advice that assumes the model knows what you mean. Start minimal and add instructions in response to failures you've seen in transcripts. Use a few varied, representative examples rather than a long list of edge cases. Some procedure clearly helps: LangChain's biggest single fix was telling the agent to plan, build, verify against the spec, and fix, because its most common failure was re-reading its own work, deciding it looked fine, and stopping. Cheap models usually benefit from more explicit procedure than frontier models, but each added rule is something they can misread.

**Over-fitting to the benchmark.** Every prompt change you test on SREGym risks tuning to those 90 problems. Signs of this: rules that mention specific services or faults, or "check X first" rules that came from one failing problem. Anthropic recommends [held-out test sets](https://www.anthropic.com/engineering/writing-tools-for-agents) when tuning tools. A critique of automated harness tuning on Terminal-Bench found that evolved harnesses [generalised poorly to held-out tasks](https://aiweekly.co/alerts/study-agent-harness-evolution-doesnt-beat-test-time-scaling) (secondary report; primary paper not checked). For this project: split off a held-out subset (for example, keep part of SREGym outside SREGym-Lite's 17 problems untouched until the end), write rules about SRE method rather than specific faults, and be suspicious of any change that fixes exactly the problem you were looking at.

Watch also for **few-shot lock-in**: if the transcript is full of similar action-observation pairs, the model copies the pattern even when it no longer fits ([Manus](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus)).

---

## 7. Control flow beyond the single loop

Anthropic separates **workflows** (models and tools run along fixed code paths) from **agents** (the model directs its own process), and lists the common patterns: prompt chaining, routing, parallelisation, orchestrator-workers and evaluator-optimizer ([Building effective agents](https://www.anthropic.com/engineering/building-effective-agents)). Its main advice is to use the simplest design that works and add complexity only when it's needed. The options you'll most likely consider:

| Addition | What it is | When it helps | When it burns tokens |
|---|---|---|---|
| **Explicit planning** | Have the model write a plan before acting, or keep a todo list. | Long tasks where the agent loses track of the goal. | Short tasks; plans that are never revisited. |
| **Reflection / self-critique** | Ask the model to critique its own answer and revise. Reflexion ([Shinn et al., 2023](https://arxiv.org/abs/2303.11366)) stores reflections between attempts. | When there's **external** feedback (a failed test, an error, a metric that didn't recover). | Without external feedback, models are poor at correcting their own reasoning and [sometimes get worse](https://arxiv.org/abs/2310.01798). |
| **Verify before submitting** | Intercept the first "submit" and require a check: re-read the task, run a command that confirms the claim (for mitigation: are pods healthy, does the error rate drop?). | Very often. This was the core of LangChain's gains. Premature completion is a common failure ([Anthropic, long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)). | When the check is just "are you sure?" with no new evidence. |
| **Retries / best-of-N** | Run the task several times and pick an answer by vote or verifier. | When runs vary a lot and you have a good selector. | Multiplies cost. Without a reliable selector, it's just extra runs. |
| **Orchestrator-worker / multi-agent** | A lead agent splits the work and gives parts to sub-agents. | Broad, parallel exploration. Anthropic's research system beat a single agent by 90.2% on its internal eval. | That system used [about 15x the tokens of chat](https://www.anthropic.com/engineering/multi-agent-research-system), and token use alone explained 80% of variance on BrowseComp. Anthropic says tightly coupled tasks are a poor fit. Cognition argues for [single-threaded agents](https://cognition.com/blog/dont-build-multi-agents) because parallel agents make conflicting implicit decisions. |

A useful test: does the addition bring in **new information** (a check against the system, a fresh context with a narrow question) or just **more tokens** (another opinion from the same model on the same evidence)? The first kind tends to help; the second mostly costs money. When comparing, track tokens and steps per problem alongside score, because many improvements turn out to be "spent more compute".

LangChain's results also show a related setting: reasoning effort. Running at the highest effort everywhere scored 53.9% because of timeouts; high effort scored 63.6%; high effort for planning and verification with less for implementation scored 66.5% ([post](https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering)).

---

## 8. Budgets and stopping

An agent without budgets eventually loops forever or runs out of money. Common controls:

- **Step cap.** Maximum model calls per run. Set it from data: look at how many steps successful runs take and allow some headroom.
- **Wall-clock limit.** Benchmarks usually enforce one (each Terminal-Bench task [has a time limit](https://arxiv.org/html/2601.11868v1)). Your own limit should end the run cleanly before the benchmark kills it.
- **Per-command timeout.** Separate from the run limit. Kill the command and return a clear observation ("timed out after 60s; use `--tail`, `timeout`, or run in background").
- **Token or cost cap.** Stops runaway context growth on a bad run.
- **Wrap-up nudges.** At, say, 80% of the budget, add a message: "N steps left. Verify your current hypothesis and submit." LangChain found time-budget warnings useful.
- **Forced submission.** When the budget runs out, make one final call asking for the best answer now, instead of ending with nothing. On a benchmark, a partly correct diagnosis can still score.
- **Loop detection.** Spot repeated identical commands or repeated edits to the same resource, and add a message asking the model to change approach. LangChain does this per file.

Record *why* each run ended (submitted, step cap, timeout, error). That reason, broken down by problem, is one of the most useful numbers you'll have.

---

## 9. Reliability plumbing

Benchmark runs are long and involve many API calls, so rare failures happen regularly. Plumbing to build early:

- **API retries.** Retry on 429 (rate limit), 5xx and network errors with exponential backoff and jitter, and respect `Retry-After`. Don't retry 400s blindly; they usually mean your request is malformed (for example, missing `reasoning_content`, see §10).
- **Rate limits and concurrency.** Running many problems in parallel against one key will hit limits. Use a concurrency limiter and log retry counts, so slowdowns aren't mistaken for agent behaviour.
- **Malformed replies.** Empty content, cut-off output (`finish_reason: "length"`), tool calls with invalid JSON, calls to tools that don't exist. Treat each as an observation that tells the model what went wrong, cap consecutive format errors, and count them. mini-swe-agent's format error template handles the `length` case by asking for a shorter reply.
- **Hung commands.** `kubectl logs -f`, `top`, interactive prompts and pagers never return. Use hard timeouts, set `PAGER=cat`, and warn about streaming flags in the prompt.
- **Non-determinism.** Even at temperature 0, results vary from run to run (batching and provider-side differences). A one-problem score change from one run is mostly noise. Run each configuration several times on the same problems and report mean and spread. SREGym also uses an LLM judge ([repo](https://github.com/SREGym/SREGym)), which adds its own variance; keep the judge model fixed across experiments.
- **Full logging.** Save every request and response with token counts, latency and cached tokens. Transcripts are where you find the next improvement.

---

## 10. Realities of cheap and open models

**Tool-call adherence depends on the serving stack.** An open model writes tool calls in its own syntax, and the server has to parse that into OpenAI-style `tool_calls`. vLLM's investigation of Kimi K2 found that template and parser mismatches caused most failures: [218 successful calls on vLLM vs 1,286 on Moonshot's API](https://vllm.ai/blog/Kimi-K2-Accuracy) before fixes. The model also sometimes called tools that weren't declared. LiveKit points out that [the same model can work behind one endpoint and fail behind another](https://livekit.com/blog/your-model-isnt-bad-at-tool-calling) depending on whether the provider set up the right parsers. Before blaming the model, send a single request with one tool attached and check what comes back.

**Reasoning tokens need specific handling.** Many cheap models produce separate "thinking" text (often as a `reasoning_content` field). The rules for sending it back differ by provider:

- DeepSeek: without tools, sending it back is ignored. With tools, it [must be passed back](https://api-docs.deepseek.com/guides/thinking_mode) in later requests; leaving it out returns a 400 error.
- OpenAI's gpt-oss (harmony format): [drop earlier chain-of-thought](https://developers.openai.com/cookbook/articles/openai-harmony) after a final answer, but keep it across tool calls.
- Reasoning models also need both a reasoning parser and a tool parser on the server (LiveKit, above).

So the harness has to handle a third field besides `content` and `tool_calls`, per provider. Reasoning tokens also count against output limits and add latency, so measure the reasoning-effort setting rather than assuming more is better.

**Effective context is smaller than the advertised maximum.** A 128k-token window doesn't mean good performance at 100k. Context rot applies to all models, and one practitioner reported a Qwen model's tool-call format [drifting after about 65k tokens](https://allanchan339.github.io/bug-fixes/2026/04/13/Qwen35-tool-calling.html) (single anecdote). Expect to compact earlier with cheap models.

**Sensitivity to format.** Weaker models are more affected by prompt wording, example formatting and tool-description details. BFCL tests format sensitivity for prompt-mode models for this reason. The hashline result (§1) is an extreme case: the weakest models gained most from a friendlier interface. Expect more format errors, more early submissions and more loops than a frontier model would show, and design the plumbing in §8 and §9 for that.

**Benchmark spread is large.** Terminal-Bench reports command error rates from 9.2% to 26.7% across models, with an open model (GPT-OSS-120B) at the high end ([paper](https://arxiv.org/html/2601.11868v1)). SREGym's authors report [differences of up to 40%](https://arxiv.org/abs/2605.07161) in end-to-end results across failure types. Look at results per problem, not just the overall score.

---

## 11. Glossary

| Term | Meaning |
|---|---|
| **Harness / scaffold** | All code around the model: loop, prompts, tools, observation formatting, context handling, stopping, error handling. |
| **Agent loop** | Repeated cycle of model call, action, observation, until termination. |
| **ReAct** | Pattern of interleaving reasoning and actions with environment feedback. |
| **Action format** | How the model expresses an action: text block, native tool call, or code. |
| **Tool / function calling** | API feature where the model returns structured calls against JSON Schema definitions. |
| **Parallel tool calls** | Several tool calls in one model reply. |
| **ACI** | Agent-computer interface: the tools and feedback an agent uses, designed for models. |
| **Observation** | Formatted result of an action, fed back to the model. |
| **Context window** | Maximum tokens per model call. |
| **Context rot** | Performance drop as input grows, even well within the window. |
| **Head/tail elision** | Keeping the start and end of a long output and dropping the middle. |
| **Compaction** | Summarising the transcript to free context and continuing from the summary. |
| **Prompt caching** | Provider reuse of an identical prompt prefix, cutting cost and latency. |
| **Sub-agent** | A separate agent run with a clean context, given a narrow task, returning a summary. |
| **Orchestrator-worker** | A lead model that splits work and hands parts to workers. |
| **Reasoning tokens** | Separate "thinking" output from reasoning models, with provider-specific handling. |
| **Step cap / budget** | Limit on model calls, time, tokens or cost per run. |
| **pass@1** | Fraction of tasks solved in a single attempt. |
| **Held-out set** | Tasks kept out of tuning, used to check that improvements generalise. |

---

## 12. Read next

1. **Anthropic, [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents).** The workflow-vs-agent distinction, the standard patterns, and the advice to start simple and invest in the ACI.
2. **Anthropic, [Writing effective tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents).** Practical rules for tool count, naming, output size, error messages and evaluating tools.
3. **Anthropic, [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents).** Context rot, "right altitude" prompts, compaction, notes and sub-agents.
4. **Yang et al., [SWE-agent](https://arxiv.org/abs/2405.15793).** Where the ACI idea comes from; read the ablation table to see how much each interface choice is worth.
5. **[mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent) and its [default config](https://raw.githubusercontent.com/SWE-agent/mini-swe-agent/main/src/minisweagent/config/default.yaml).** A roughly 100-line reference loop; copy its observation, format-error and submit templates for v0.
6. **Wang et al., [CodeAct](https://arxiv.org/abs/2402.01030).** The case for code as the action format.
7. **Merrill et al., [Terminal-Bench](https://arxiv.org/html/2601.11868v1).** Same-model, different-harness comparisons, the minimal Terminus 2 agent, and a command-level error taxonomy.
8. **LangChain, [Improving Deep Agents with harness engineering](https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering).** A worked example of trace-driven, harness-only improvement with the specific changes listed.
9. **Can Bölük, [The harness problem](https://stencil.so/blog/the-harness-problem).** Evidence that one tool's format can matter more than the model tier, especially for weak models.
10. **Manus, [Context engineering lessons](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus).** Cache-friendly history, recitation, and keeping errors in context.
11. **Cognition, [Don't build multi-agents](https://cognition.com/blog/dont-build-multi-agents), alongside Anthropic's [multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system).** The two sides of the multi-agent argument, with cost numbers.
12. **vLLM, [Debugging Kimi K2's tool calling](https://vllm.ai/blog/Kimi-K2-Accuracy).** How open-model tool calling fails in the serving layer and how to diagnose it.

---

## Self-check questions

1. **Why can the same model score very differently on two harnesses, and why might your improvements not transfer to another model?** Interface, feedback and context choices decide whether the model's ability turns into correct actions. Cheap models are most sensitive, and a change can help one model's quirks while hurting another's.
2. **What are the five parts of the agent loop, and which line of your v0 is each?** Messages, model call, action extraction, observation, termination: the `messages` array, `chat()`, the regex or tool-call parse, `exec` plus formatting, and the submit check and step cap.
3. **When would you choose text command blocks over native tool calls for a flash-tier open model?** When the provider's tool-call parsing for that model is unreliable or untested. Text blocks are visible and recoverable; native calls fail silently when the parser is wrong. Measure both.
4. **`kubectl logs` returns 3 MB. What should the agent see?** A capped, head/tail-elided observation with a note on how much was cut and how to narrow the query (`--tail`, `--since`, `grep`). Better still, a default limit in the tool.
5. **Why does prompt caching discourage editing earlier messages every turn, and what do you do instead?** A cache hit needs an exact prefix match, so any edit invalidates everything after it. Append-only history, a stable system prompt and tools, and occasional threshold-based compaction.
6. **Which control-flow addition is most likely to help first, and why?** Verifying before submission against the live system, because it brings in new external evidence. Self-critique with no new evidence often doesn't help.
7. **How will you tell whether a change helped?** Several runs per configuration on a fixed problem set, comparing mean and spread, along with tokens, steps, end reasons and format-error counts, then confirming on a held-out subset.
8. **Your model's provider returns `reasoning_content`. What do you check?** Whether that provider requires it to be sent back during tool use (DeepSeek does, and returns 400 without it) or dropped (gpt-oss after a final answer), and whether it counts toward your output and cost limits.

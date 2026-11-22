# Learning guide

Three chapters, about 17,000 words in all. Read them in order; chapter 1 is the one the design sessions lean on most.

| # | Chapter | Read it to be able to | Length |
|---|---|---|---|
| 1 | [Harness engineering fundamentals](01-harness-engineering.md) | Name the parts of an agent loop, the options for each, and their trade-offs for cheap models | about 5,000 words |
| 2 | [SRE and Kubernetes primer](02-sre-kubernetes-primer.md) | Follow what the agent is doing in a transcript and judge whether a competent engineer would have done the same | about 5,700 words |
| 3 | [SREGym internals and evaluation](03-sregym-and-evaluation.md) | Explain exactly how a run is launched and graded, and decide whether a score change is real | about 6,500 words |

## Suggested path

1. **Chapter 1, sections 1 to 5.** Stop and answer the self-check questions at the end of the chapter before going on.
2. **Chapter 3, part A.** How one run works end to end, from the code.
3. **Chapter 2, sections 1 to 4,** then do three of its exercises on a small local kind cluster.
4. **Read one real transcript** from the first `mini-sre` run (execution plan, Phase 3) with chapters 1 and 2 open.
5. **Chapter 1, sections 6 to 10,** now that you have seen a real run.
6. **Chapter 3, part B,** before the first sweep. Section B4 is the one that changes how you read results: with 17 problems and 3 repeats, differences under about 12 points are noise.
7. **Chapter 2, sections 6 to 9,** as reference while reading failures.

## You are ready to design v0 when you can answer these

- What are the five parts of the agent loop, and which line of a minimal loop does each design decision change?
- Why might a free-text bash block work better than native tool calls for a cheap model, and when would the reverse hold?
- What goes wrong when a transcript gets long, well before the context limit, and what are three ways to deal with it?
- Why does prompt caching push you toward append-only history?
- What does SREGym's diagnosis judge look at, and what does it never see?
- How is mitigation graded, and why does restarting pods not pass most problems?
- What is the difference between a root cause and a symptom in a "service has no endpoints" incident?
- If v1 scores 6 points above v0 on the dev set, what do you conclude?

## A caution on answers

Chapter 2 describes fault classes for the benchmark problems, not their root causes or fixes. Keep it that way: do not read the problem source files for answers, and never put anything problem-specific into the agent's prompt. The moment you do, the dev score stops meaning anything.

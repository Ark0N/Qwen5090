# What makes an agent harness good?

*Research notes, 2026-08-30. Five harnesses — Claude Code, OpenAI Codex CLI,
DeepSeek Harness (dsh), pi, OpenCode — read from primary sources: the binaries
and packages installed on this machine and the system prompts extracted from
them, the five teams' own engineering writing, the public leaderboards and
papers, and this repo's own four-harness Terminal-Bench study
([HARNESS-BENCHMARKS.md](HARNESS-BENCHMARKS.md)). Research only; nothing here
changes the product. Every number carries a source; anything that could not be
verified says so.*

## The short answer

A harness is "everything in an AI agent except the model itself"
([Böckeler, martinfowler.com](https://martinfowler.com/articles/harness-engineering.html)):
the program that turns a chat model into an agent. It decides what the model
sees (system prompt, tool schemas, tool results, project instructions), what
it can do (the tool set, the sandbox, the approval policy), when a turn ends,
how a conversation survives a full context window (compaction), and how the
whole thing is driven (TUI, headless, SDK). Anthropic's own definition: "the
agentic harness around Claude: it provides the tools, context management, and
execution environment that turn a language model into a capable coding agent"
([docs](https://code.claude.com/docs/en/how-claude-code-works)). Every one of
those is a design choice, and the five make them differently.

What the evidence says:

1. **The harness is worth a model generation.** On the same weights, harness
   choice moves Terminal-Bench 2.1 by 3–8 points and SWE-bench by 8–15;
   between frontier *models* under one fixed harness the spread is 1–5. A
   controlled 3×3 study found harness-induced variance **7.8×** the
   model-induced variance and model rankings flipping in 6 of 9 comparisons
   ([Zhang et al. 2026](https://arxiv.org/html/2605.23950)). For weaker or
   open models the harness delta reaches 30–60 points, because mechanical
   failures — edit format, tool-call parsing — hide what the model can do.
   Measured here: 3/12 → 7/12 on one model, every point of it plumbing.
2. **The best harness for a model is the one it was trained with.** Claude
   Code beats the generic Terminus 2 on Claude weights by 2.8–3.4 points;
   Codex CLI beats it on GPT-5.5 by 5.1; DeepSeek's headline 82.7 was
   measured in its own harness. Each vendor now trains the model on its
   harness's edit format and prompt shape. The exception proves the rule:
   Terminus 2 beats Google's own Gemini CLI on Gemini 3 Pro by 8.1 —
   co-design is not automatic.
3. **Less is more, until it isn't.** pi ships four tools and a prompt under
   1,000 tokens; DeepSeek's 82.7 used a *two-tool* preset (persistent bash +
   a string-replace editor); Vercel went from 18 tools to 1 and from 80% to
   100% on its eval. Rich tool sets earn their keep only with strong models
   and fast prefill — on a slow local server a 25-tool preamble is the single
   biggest cost of every cold turn (828 s vs 196 s, measured here).
4. **The harnesses that feel better handle the boring failure modes.**
   Reasoning tokens eating the output budget, a background server killed with
   the turn's process group, a model narrating instead of calling a tool,
   `reasoning_effort` values a template rejects, a tool result that blows the
   context. Each cost a task in this repo's study, on every harness, and none
   was about the model. The single largest published harness gain — +13.7
   points with no model change — came from exactly this kind of work
   ([LangChain](https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering)).
5. **Prompt-cache discipline is now a first-class design axis.** Claude Code
   treats cache hit rate "like uptime" and has flags that exist only for it;
   dsh documents the KV-cache effect of every plugin; pi disables cache
   writes for one-off compaction requests; Codex moved compaction to the
   server. Locally this is the difference between a 1.8 s first turn and a
   14-minute one, and one changing request header cost llama.cpp users ~90%
   of their throughput.

The rest is the evidence.

## 1. What a harness actually decides

Strip any of the five down and the core is the same loop — Thorsten Ball's
"an LLM, a loop, and enough tokens" in under 400 lines
([Amp](https://ampcode.com/notes/how-to-build-an-agent)), mini-SWE-agent's ~100
lines with `subprocess.run` per action
([repo](https://github.com/SWE-agent/mini-swe-agent/)):

```
messages = [system, project-instructions, user]
loop:
    response = model(messages, tools)
    if response has no tool calls: return   # end of turn
    for call in response.tool_calls:
        messages += execute(call)           # tool result
```

Everything that distinguishes them lives in the choices around that loop:

| decision | what it covers | why it matters |
|---|---|---|
| **tool set** | which tools exist, their schemas, their descriptions | schemas are re-sent every request; a weak model calls the wrong tool or the right one wrongly |
| **edit mechanism** | string-replace, unified diff (`apply_patch`), whole-file write, line-numbered view+insert | the single most error-prone tool call; each format fails differently |
| **system prompt** | identity, guidelines, examples, formatting rules, size | a fixed per-request cost; the model's default behaviour |
| **project instructions** | `CLAUDE.md` / `AGENTS.md` discovery, nesting, precedence, budget | how the user steers without re-typing |
| **tool results** | truncation, line numbers, exit-code markers, pruning of old results | what the model reads most; what it cannot see it cannot fix |
| **end of turn** | no-tool-call = done, or a goal/continuation driver keeps it going | the "narrates its next step and stops" failure |
| **context management** | compaction trigger, what is kept, who summarises, cache behaviour | long tasks die here |
| **safety** | approval prompts, permission rules, OS sandbox, plan/read-only mode | whether you can leave it alone |
| **concurrency** | subagents (fresh vs forked), background jobs, orchestration scripts | parallelism and context isolation vs. coordination cost |
| **persistence** | session log format, resume/fork/branch, memory across sessions | whether yesterday's work is reachable |
| **surface** | TUI, web, IDE, headless/print, JSON stream, RPC, SDK | headless mode is what benchmarks and automation use |
| **model freedom** | one vendor, or any OpenAI-compatible endpoint, with per-server quirks | local models live or die on the `compat` layer |

Two 2026 papers formalise the same list: Zhang et al.'s seven mandatory
disclosure layers (Execution, Tool, Context, Scheduling, Observability,
Verification, Governance — [2605.23950](https://arxiv.org/html/2605.23950)) and
Guo et al.'s survey (Observation, Context, Control, Action, State,
Verification — [2606.20683](https://arxiv.org/abs/2606.20683)).

## 2. The five, side by side

Versions are what is installed on this box on 2026-08-30. Star counts are from
the same day.

| | **Claude Code** 2.1.251 | **Codex CLI** 0.147.0 | **DeepSeek Harness** 0.1.1-rc.2 | **pi** 0.84.3 | **OpenCode** 1.3.0 installed (1.18.25 current) |
|---|---|---|---|---|---|
| vendor / licence | Anthropic; proprietary (source leaked 2026-03-31) | OpenAI; Apache-2.0 | DeepSeek; MIT; 204.6k stars, 17 days old | Mario Zechner / Earendil; MIT core "forever"; 99.4k stars | Anomaly (ex-SST); MIT; 202.6k stars, ~8M MAU |
| implementation | TypeScript on Bun, React/Ink; ~512K lines | Rust, single static musl binary | TypeScript, ~250 `cordis` plugin packages, pnpm; ~450–500K lines | TypeScript, 4 packages (`pi-ai`, `pi-agent-core`, `pi-tui`, `pi-coding-agent`); ~118K lines cited for OpenCode as comparison | TypeScript on Bun (2.0 moves server to Node), OpenTUI (Zig + SolidJS); ~118K lines |
| models | Claude only; subscriptions Claude-Code-only since 2026-04-04; 3rd-party via `ANTHROPIC_BASE_URL` + a bridge | OpenAI + `model_providers` (any OpenAI-compatible; `--oss` for LM Studio/Ollama); OAuth allowed in 3rd-party harnesses | any, via `pi-ai` routes in `settings.yaml`; second native adapter for DeepSeek's API | ~35 providers incl. Claude/ChatGPT/Copilot subscriptions and a llama.cpp router | 75+ via Models.dev / Vercel AI SDK; Zen (at-cost) and Go ($10 open-weight) gateways |
| built-in tools | ~30, many *deferred* — name only in context, schema fetched via `ToolSearch` | shell, `apply_patch`, `update_plan`, MCP, browser/computer use, image gen, sub-agents | 20 tool packages / 25 tools in the Web preset; **2** in the `minimal` preset | **4**: read, write, edit, bash (+ optional powershell/grep/find/ls) | read/edit/write/apply_patch/bash/glob/grep/lsp/skill/todowrite/webfetch/websearch/question/task |
| edit mechanism | `Edit` = exact string replace, refuses unless the file was `Read` first | `apply_patch` unified-diff envelope, model trained on it; prompt says do *not* re-read after patching | `str_replace_editor` (view/create/str_replace/insert, 1-based line views) | `edit` = string replace, batched edits accepted | string replace; `apply_patch` when running GPT models |
| system prompt | "500+ fragments conditionally injected"; ~4,200 tokens core in Anthropic's simulator, 30–50K measured with tool defs; static/dynamic boundary for caching | ~4K words: AGENTS.md spec, preamble rules, plan guidance, validation policy per approval mode, final-answer style guide, `{{ personality }}` slot | assembled from ordered sections: `-100` identity (one sentence), `0` persona, `100–199` tool guidance; canonical `toolOrder` for cache determinism | ~15 lines + one-liner per tool + project context + skills + cwd; < 1,000 tokens with tools | **one per model family** — `anthropic.txt`, `codex.txt`, `gpt.txt`, `gemini.txt`, `kimi.txt`, `beast.txt`, `default.txt` — chosen by substring-matching the model id |
| project instructions | `CLAUDE.md` hierarchy (keep < 200 lines), `.claude/` rules/skills/agents, auto-memory dir | `AGENTS.md` (spec in the prompt: directory-scoped, deeper wins, direct instructions win; 32 KiB cap; `AGENTS.override.md`) | `AGENTS.md` **and** `CLAUDE.md` (byte-identical siblings collapse), nested discovery on file *touch*, byte-budgeted, `<system-reminder>` framing | `AGENTS.md`/`CLAUDE.md` in `<project_context>`; `AGENTS.override.md` | `AGENTS.md` walked upward, `CLAUDE.md` fallback |
| permissions / sandbox | 6 modes; **auto** = a separate classifier request per non-read-only call, default on Pro/Max/Team since 2026-08-14; allow/deny rules; hooks; OS sandbox (Seatbelt / bubblewrap+socat) | **OS sandbox is the primary mechanism** ("opt-out, not opt-in"): Seatbelt / bubblewrap+Landlock+seccomp, network off by default, shell tool only; approval policy untrusted / on-request / never; optional **Guardian** LLM reviewer for out-of-policy calls; `codex sandbox <cmd>` | approval policy + sandbox mode as plugins; read-only / workspace-write / danger-full-access; bwrap+Landlock, Seatbelt, Windows restricted token; **fails closed** if confinement is missing; plan mode is "soft guidance" | **none** — "run in a container, or build your own confirmation flow"; project trust gates loading of local extensions | allow/ask/deny per tool with glob patterns; `doom_loop` guard; `.env` read-blocked; no OS sandbox |
| plan / todo | plan mode (read-only, plan file), `AskUserQuestion`; task tools **hidden by default on Fable 5 / Sonnet 5 / Opus 4.8+** "for context preservation" | `update_plan` with high/low-quality plan examples; "never end with only a plan" | plan mode (`/plan`, `exit_plan_mode` needs explicit approval), todo tool | **none** ("to-dos confuse models — use a TODO.md") | plan agent (read-only `<system-reminder>`), `todowrite` |
| long-horizon driver | ralph-loop plugin, `/goal`, `--max-budget-usd`, background sessions | **goals** (SQLite `thread_goals`: active / paused / blocked / usage_limited / budget_limited / complete) | **goal domain** + round driver (≤ 256 rounds, event-sourced); `ralph` tool: fresh child per round, workspace is the only memory | none built in | none built in |
| compaction | 3 tiers (micro / auto / full); older tool outputs cleared first; circuit breaker after 3 failures; docs admit early instructions get lost | **remote compaction v2** — `POST /v1/responses/compact` returns an encrypted item; plaintext local summariser for other providers | `tool-result-pruner` (model-free head/tail) + `compaction-basic` (summary via a stream that *replays the prefix to hit the KV cache*) | summary at `contextWindow − 16,384`, keep last 20K tokens; tool results cut to 2,000 chars in the summary input; **disables cache writes** for the summary request; branch summaries | summary when ≥ 20K freeable, keeps newest 40K, hides old messages rather than deleting |
| subagents | `Agent` (fresh or `fork` sharing the parent's prompt cache, default since 2.1.232), worktree/cloud isolation, teams (~7× tokens), `Workflow` scripts | `multi_agent` stable; `thread_spawn_edges` in the state DB; app-server for orchestration | providers `spawn` / `fork` / `acp` / **Claude Code** / **Codex**; foreground or background job; `workflow` = model-written JS orchestration; `ralph` | none ("spawn pi in tmux, or write an extension"); `pi-subagents` is a community package | `task` with `general` / `explore` / `scout` and custom agents |
| memory across sessions | auto-memory dir per project + `MEMORY.md` index; idle-time consolidation in the leaked source | **memories** (SQLite: per-thread `raw_memory` + `rollout_summary` → phase-2 distillation; flag off by default) | `$DSH_HOME/AGENTS.md`; schedule tool survives restarts | none | none |
| sessions | JSONL, resume/fork, `--teleport`, cloud sessions | rollouts + SQLite thread history/queue; resume/fork/archive | **append-only event log** is the source of truth; messages *derived*, never stored; replay/fork; logs double as test fixtures | **tree-structured** JSONL (`id`/`parentId`), `/tree` branching, `/fork`, `/clone` | SQLite; `/share` links |
| surfaces | TUI, `-p`/`stream-json`, SDK, IDE, desktop, web, remote control, cloud | TUI, `exec`, `review`, `app-server` (IDE/desktop protocol), MCP server, cloud | Web UI, `--profile headless "job"`, TUI profile, ACP, Python SDK over JSON-RPC | interactive, `-p`/JSON, RPC (JSONL stdin/stdout), SDK | TUI (client/server, OpenAPI on :4096), `run`, web, Electron, IDE, ACP, SDK |
| extensibility | hooks (~25 events, 5 handler types), skills, plugins, MCP (deferred), custom agents | hooks, skills, plugins, MCP, feature flags | *everything is a plugin*; profiles = bundles + `cordis.patch.yml` layers; the model can define plugins into the live process (`cordis_define/run`) | TypeScript extensions (can block/modify tool calls, filter context), skills, prompt templates, themes, packages; **no MCP by design** — the community's top package re-adds it | plugins with hooks, MCP, custom agents/commands |
| effort / thinking | `--effort low…max`; cache keyed by effort | reasoning effort via config; "reasoning sandwich" recommended | `reasoningEfforts` map per route; effort is a **text prefix** in DeepSeek's own template | `/thinking off…max`, per-provider budget fields | per-model config |

Sources for the table: `claude --help`, `codex --help` / `codex features list`,
the `~/.dsh-runtime` and `pi-coding-agent` packages, the OpenCode binary's
embedded prompt files, plus the vendor docs cited in §3.

## 3. What each one does that the others do not

### 3.1 Claude Code — the maximalist, and the one with the most machinery around safety

- **The biggest tool set, kept out of the prompt until needed.** Around
  thirty tools, but a large share are *deferred*: only the name is in
  context and `ToolSearch` fetches the schema on demand. That is one answer
  to "rich tool set vs. prompt size" — pay for a schema when it is used.
  It only works on Anthropic's own endpoint, though: behind a custom
  `ANTHROPIC_BASE_URL` tool search is disabled and every MCP schema lands in
  the cached prefix ([prompt caching docs](https://code.claude.com/docs/en/prompt-caching)).
- **Permissions are a product, not a flag.** Six modes, per-tool patterns
  (`Bash(git *)`), ~25 hook events that can veto or rewrite any call, an OS
  sandbox, and **auto mode**: a separate classifier request per call that
  is not plainly read-only, now the default on Pro/Max/Team
  ([blog](https://claude.com/blog/auto-mode-default-in-claude-code)). The
  study behind it is the best evidence anywhere that humans are the weaker
  gate: 1,053 testers approved 97% of prompts and caught 13.6% of injected
  dangerous commands against the classifier's 89%; the classifier's own
  miss rate on real over-eager actions is 17%
  ([engineering post](https://www.anthropic.com/engineering/claude-code-auto-mode)).
  The docs draw the line cleanly: "an instruction in CLAUDE.md is a request,
  not a guarantee. A PreToolUse hook that blocks the edit is enforcement"
  ([features](https://code.claude.com/docs/en/features-overview)).
- **Cache-first request layout, engineered and instrumented.** The leaked
  source has a `SYSTEM_PROMPT_DYNAMIC_BOUNDARY` splitting a globally
  cacheable front half from a session-specific back half, 14 tracked
  cache-break vectors, and `DANGEROUS_uncachedSystemPromptSection` markers
  ([engineerscodex](https://read.engineerscodex.com/p/diving-into-claude-codes-source-code));
  reminders are *appended* as `<system-reminder>` rather than rewriting
  history; fork subagents reuse the parent's cache; and Anthropic says it
  treats cache hit rate "like uptime" with SEVs on drops
  ([prompt caching is everything](https://claude.com/blog/lessons-from-building-claude-code-prompt-caching-is-everything)).
  `--exclude-dynamic-system-prompt-sections` exists only to improve
  cross-user cache reuse. The March 2026 token-burn episode (4–10× reports
  around 2.1.76–2.1.88, one analysis blaming a per-request attestation
  header breaking the prefix — single source, unconfirmed) shows what
  happens when this breaks.
- **Concurrency is the deepest of the five**: `Agent` (fresh or `fork`, in a
  worktree or in the cloud, depth 3, 20 concurrent), named teammates with
  mailboxes, `Workflow` scripts that fan out and pipeline agents
  ([a harness for every task](https://claude.com/blog/a-harness-for-every-task-dynamic-workflows-in-claude-code)),
  background sessions, scheduled wake-ups. Anthropic's own research-agent
  numbers explain both the appeal and the bill: orchestrator-workers beat a
  single Opus 4 by 90.2%, at ~15× the tokens
  ([multi-agent post](https://www.anthropic.com/engineering/multi-agent-research-system)).
- **It is retiring its own scaffolding for newer models.** Task/todo tools
  are hidden by default on Fable 5 / Sonnet 5 / Opus 4.8+ "for context
  preservation" ([tools reference](https://code.claude.com/docs/en/tools-reference)),
  and the Claude 5 system prompt was cut ~80% — the same direction pi argued
  from the start.
- **Measured as a harness**: on Claude weights it is worth +6–7 points over
  Terminus 2 on TB 2.1 (Opus 4.6: 70.1 vs 63.8; Sonnet 4.6: 58.5 vs 51.5 —
  [tbench 2.1 news](https://www.tbench.ai/news/terminal-bench-2-1)) and holds
  #1 with Fable 5 at 83.8 ±1.2 ([Snorkel](https://snorkel.ai/leaderboard/terminal-bench-2-1/)).
  It is not the best harness for Claude on every task, though: Cursor's CLI
  extracts ~4 more points from Opus 4.7 on Endor Labs' suite
  ([Endor](https://www.endorlabs.com/learn/claude-opus-4-7-sets-new-records-in-the-endor-labs-agent-security-league)).
- **The costs.** ~33K tokens sent before the prompt is read (HN, 706
  points — [thread](https://news.ycombinator.com/item?id=48883275)); 3–4× the
  tokens of Codex on the same task in two independent comparisons; every
  non-fork subagent re-sends the ~30K prompt; cache invalidated by a model,
  effort, MCP or upgrade change; compaction admits "instructions from early
  in the conversation can get lost". Locally it is the most reasoning-hungry
  of the four (180–240 s/task vs 70–90 for pi), *collapses* below `xhigh`
  (3/8 at medium), needed a 900 s cap where 500 s sufficed elsewhere, and is
  Claude-only in practice — the bridge in this repo has to rewrite
  `reasoning_effort`, disable thinking for the small-cap `fast` alias,
  strip `tool_choice` for server-side tools, and route the auto-mode
  classifier to a non-thinking alias ([CLAUDE-CODE.md](CLAUDE-CODE.md)).
  Since 2026-04-04 subscriptions cannot be used from any other harness.

### 3.2 Codex CLI — the disciplined one: sandbox first, patch-based edits, a prompt that reads like a style guide

Read from the 0.147.0 binary's embedded prompt and `codex features list`,
and from OpenAI's own account of the loop
([Unrolling the Codex agent loop](https://openai.com/index/unrolling-the-codex-agent-loop/)).

- **The loop is stateless and cache-first by design.** Codex deliberately
  does *not* use the Responses API's `previous_response_id` — "primarily to
  keep requests fully stateless and to support Zero Data Retention" — and
  is built around prefix caching: "When we get cache hits, sampling the
  model is linear rather than quadratic." So static content goes first and
  any mid-conversation change to tools, model, sandbox or cwd is *appended*
  as a new message rather than edited into an earlier one. The same rule
  Claude Code and dsh arrived at, stated as a first principle.
- **An OS sandbox is the default safety mechanism, not a dialog** —
  "sandboxing is opt-out, not opt-in". Seatbelt on macOS, bubblewrap +
  Landlock + seccomp on Linux (network syscalls denied), restricted tokens
  on Windows; `.git` and `.codex` are carved out read-only inside writable
  roots; `codex sandbox` runs *any* command under it. Two honest limits:
  reads are never restricted, and the sandbox "applies only to the
  Codex-provided `shell` tool… those provided from MCP servers are not
  sandboxed". Approval policy (untrusted / on-request / never) layers on
  top, and since v0.115 out-of-policy calls can be routed to a **Guardian**
  LLM reviewer subagent instead of a human — Codex's answer to Claude Code's
  auto-mode classifier, with a V2 in August. The prompt changes its own
  behaviour by mode: under `never`, "proactively run tests, lint and do
  whatever you need"; under interactive modes, "hold off on running tests or
  lint commands until the user is ready". Anthropic's containment post makes
  the same argument from its telemetry — users approve ~93% of prompts, an
  OS sandbox cut them 84%, "design for containment at the environment layer
  first" ([How we contain Claude](https://www.anthropic.com/engineering/how-we-contain-claude)).
- **`apply_patch` is a trained tool, and the prompt trusts it**: "Do not
  waste tokens by re-reading files after calling `apply_patch` on them. The
  tool call will fail if it didn't work." OpenAI's guide says the model "has
  been trained to excel at this diff format"
  ([Codex prompting guide](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide)).
  Compare Claude Code's `Edit`, which refuses to run unless the file was
  `Read` first. Two opposite answers to stale edits, each right for its
  model — and the format is *wrong* for other models: `apply_patch` fails
  46–51% of the time on Grok 4 Fast and GLM-4.7
  ([Stencil](https://stencil.so/blog/the-harness-problem)).
- **The prompt is a behaviour spec.** AGENTS.md scoping rules (directory
  tree, deeper wins, direct instructions win); *preamble messages* of 8–12
  words before grouped tool calls; `update_plan` with explicit high- vs
  low-quality plan examples; "Ambition vs. precision" (creative on
  greenfield, "surgical precision" in an existing codebase); a final-answer
  guide down to "no blank line before the first bullet"; a
  `{{ personality }}` slot (personality is a feature flag).
- **Long-horizon state lives in SQLite**, the most structured of the five.
  `/goal` (v0.128, 2026-04-30) records one objective per thread with
  statuses `active / paused / blocked / usage_limited / budget_limited /
  complete` and a token budget; continuation is a prompt injected at the
  end of each turn, one-shot, and suppressed if the continuation turn made
  zero tool calls — so a model that only narrates stops the loop rather
  than spinning it ([Willison](https://simonwillison.net/2026/Apr/30/codex-goals/)).
  `memories` (flag off by default) is a two-stage pipeline: threads idle
  ≥ 6 h are summarised by a small model into `raw_memory` /
  `rollout_summary` rows, then a global consolidation produces a
  `memory_summary.md` injected under a ~5,000-token budget — with a
  maintainer's warning that at launch "the rate limits would consume all
  your tokens" ([discussion](https://github.com/openai/codex/discussions/12567)).
  `thread_spawn_edges` records multi-agent parentage; a queue holds
  steering messages.
- **Compaction is remote** (`remote_compaction_v2`, stable and on):
  `POST /v1/responses/compact` returns an *encrypted* compaction item the
  harness cannot read, with a plaintext local summariser for other
  providers. The harness gives up control of summarisation in exchange for
  one the model was trained to survive — GPT-5.1-Codex-Max was "natively
  trained to operate across multiple context windows" via compaction, and
  OpenAI's ARC-AGI-3 result (13.3% → 38.3%, 6× fewer output tokens, from
  retained reasoning + compaction alone —
  [post](https://openai.com/index/how-two-settings-tripled-our-arc-agi-3-scores/))
  is the argument. It has had its own failure mode: a v0.112 "compaction
  death spiral" at `xhigh`, since fixed.
- **OpenAI runs a 1M-line codebase this way.** Its harness-engineering
  post (3 → 7 engineers, five months from late Aug 2025, ~1,500 PRs, zero
  hand-written lines; an `AGENTS.md` kept to ~100 lines as "a map, not a
  1,000-page instruction manual" pointing into `docs/`; Codex-written
  linters that emit remediation text into the agent's context; structural
  tests; a doc-gardening agent and recurring "garbage collection" PRs —
  [openai.com](https://openai.com/index/harness-engineering/), primary
  returned 403; read via [InfoQ](https://www.infoq.com/news/2026/02/openai-harness-engineering-codex/))
  is the most concrete account of harness design as an engineering
  discipline rather than a prompt. Its two lines worth keeping: "From the
  agent's point of view, anything it can't access in-context while running
  effectively doesn't exist", and "When something failed, the fix was
  almost never 'try harder'." It also carries its own caveat — it "should
  not be assumed to generalize without similar investment".
- **One core behind a versioned protocol.** The `app-server` (JSON-RPC over
  stdio; thread/turn/item primitives; Go, Python, TypeScript, Swift,
  Kotlin bindings) exists so VS Code, the desktop app, cloud and partners
  drive the same loop "without re-implementing it"; the CLI itself is
  being refactored onto it and `codex mcp-server` was deprecated for it on
  2026-08-24 ([Unlocking the Codex harness](https://openai.com/index/unlocking-the-codex-harness/)).
  `AGENTS.md` itself became a Linux Foundation open standard with 60,000+
  projects ([agents.md](https://agents.md/)); Codex caps the chain at
  32 KiB.
- **Feature flags are the roadmap**: `code_mode` (the model writes code
  that calls tools instead of emitting tool calls), `deferred_executor`,
  `rollout_budget`, `request_permissions_tool`, `guardianv2`,
  `realtime_conversation`, `concurrent_reasoning_summaries` — all "under
  development" in this build. Hooks, skills, plugins, multi-agent and
  browser/computer use are stable, which dates the "no hooks, no skills"
  criticism in some 2026 comparisons.
- **Measured as a harness**: #2 on TB 2.1 with GPT-5.5 at 83.1 ±1.1, +5.1
  over Terminus 2 on the same model, and it led the 2.0 → 2.1 table with
  GPT-5.3-Codex at 79.1. On cost, two comparisons put it at a quarter of
  Claude Code's tokens for the same task (1.5M vs 6.2M, $15 vs $155 —
  [Particula](https://particula.tech/blog/codex-vs-claude-code-cli-agent-comparison);
  3–4× — [Firecrawl](https://www.firecrawl.dev/blog/best-ai-coding-agents)).
  Practitioners' shorthand: "Claude Code feels faster in the loop, Codex goes
  deeper"; "it just does it. No pausing on the first file to confirm
  scope"; the counter-claims are that it "loses coherence by step three or
  four" on long chains ([jock.pl](https://thoughts.jock.pl/p/ai-coding-harness-agents-2026)),
  that it "will install packages without asking, edit adjacent files you
  didn't mention", and that reasoning was discarded between user turns
  until "retained reasoning" became a setting in August — opinion and
  changelog, not measurement.
- **Not part of the local study**: it speaks the Responses API only (Chat
  Completions was removed in early 2026), which a Chat-Completions-only
  local server cannot answer, its encrypted compaction is OpenAI-only, and
  its edit format is the one other models fail on. `--oss` covers Ollama
  and LM Studio.

### 3.3 DeepSeek Harness — the composable one: every capability is a plugin with a documented token cost

Read from `~/.dsh-runtime` (0.1.1-rc.2, ~60 `@deepseek-ai/dsh-*` packages
in the CLI's dependency list; ~250 in the monorepo), the repo's own
integration ([DEEPSEEK-HARNESS.md](DEEPSEEK-HARNESS.md)) and the public
sources. Released 2026-08-13, 204.6k stars in 17 days
([repo](https://github.com/deepseek-ai/deepseek-harness)).

- **There is no core.** "The `dsh` command is the product launcher for
  profiles: ordered stacks of plugin-bundle patch layers under the user's own
  overrides." The agent loop, the LLM adapter, the tool registry,
  compaction, plan mode, AGENTS.md loading and the system prompt itself are
  each a plugin, and the user configures by patching the composition tree
  (`- id: tool-web` / `disabled: true`). The `minimal` preset this repo runs
  headless is exactly that: sixteen plugins disabled and the persona
  replaced by one sentence
  ([dsh-minimal.cordis.patch.yml](dsh-minimal.cordis.patch.yml)). The kernel,
  Cordis, is not DeepSeek's — it is the Koishi ecosystem's plugin framework,
  source-vendored with 18 local patches, and formalised in a PKU + DeepSeek
  paper as "revertible effects and reactive coeffects"
  ([arXiv 2608.25512](https://arxiv.org/abs/2608.25512)) — a DI container
  with destructor propagation plus an event bus.
- **The log, not the loop, is the source of truth.** The repo's invariant is
  "Model-visible ⟺ logged": messages are *derived* from an append-only
  event log and never stored, the loop asserts byte-equality between the
  outgoing request and the derived history on every dispatch, and session
  logs double as replay-test fixtures
  ([AGENTS.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/AGENTS.md)).
  A maintainer drew the contrast with pi directly: pi "keeps the agent loop
  central"; here "there is no privileged loop. The session is an append-only
  event log" ([discussion #1023](https://github.com/deepseek-ai/deepseek-harness/discussions/1023)).
- **Every plugin README has a "Model Experience" section with "Token
  effect" and "KV Cache effect".** The system-prompt plugin documents that
  identity is "a fixed per-request cost", that schemas "repeat on every
  request", that reordering "changes cache shape but not semantic content" —
  and enforces a canonical `toolOrder` so registration order (a plugin-load
  artifact) cannot perturb the prefix. No other harness documents cache
  behaviour per feature.
- **The system prompt is assembled, not written**: order bands (`-100`
  harness identity — one sentence, "You are an AI agent powered by DeepSeek
  Harness." — `0` deployment persona, `100–199` tool guidance), strict
  `{{variable}}` interpolation that "fails loud" on an unknown reference,
  an agent-scoped persona that shadows the global one.
- **Project instructions are Claude Code's pattern, generalised.** It reads
  `AGENTS.md` *and* `CLAUDE.md`, collapses byte-identical siblings, budgets
  bytes (drops broader files before truncating the most specific), discovers
  nested files on successful `read`/`write`/`edit` touches rather than on
  shell `cd` ("parsing arbitrary shell syntax would be unreliable"), injects
  them as `<system-reminder>` user messages, and stays append-only so the
  reusable prefix survives.
- **Compaction is two plugins**: a model-free *tool-result pruner* (head +
  marker + tail above 8,192 chars, the full event kept in the log) and a
  summariser that "replays the conversation prefix to reuse the provider's
  KV cache".
- **Long-horizon work has three separate mechanisms**: a *goal* (one per
  session, event-sourced, ≤ 256 rounds, `blocked` carries a reason code), the
  *goal-round driver* that keeps re-waking the agent, and the `ralph` tool —
  a sequence of *fresh* child agents that see only the immutable objective,
  the previous child's structured hand-off, and the workspace ("the
  workspace is long-term memory; parent conversation and prior child
  sessions are not seeded").
- **Rival harnesses are subagent providers.** Alongside `spawn`, `fork` and
  ACP, the subagent seam can mount **Claude Code** and **Codex** as
  children — "real Codex or Claude Code children side by side". The model
  can also extend the harness from inside it (`cordis_define / run /
  stop`, honest that the sandbox "is not a security boundary") and write a
  JavaScript orchestration script (`workflow`) — the same idea as Claude
  Code's `Workflow` tool, shipped by both in the same month.
- **The published benchmark is a two-tool harness.** V4-Flash-0731's 82.7
  on TB 2.1 was "measured using the minimal mode of DeepSeek Harness" — bash
  + `str_replace_editor` — at max effort, temperature 1.0, top_p 0.95
  ([model card](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-0731)),
  and it reproduces: Antigma's independent harness got 82.7 ± 1.79 over 445
  trials ([orcarouter](https://www.orcarouter.ai/blog/deepseek-v4-flash-arc-verified)),
  Artificial Analysis 79% under Terminus 2. **No DeepSeek statement that the
  model was trained *with* the harness exists** — the card says *measured
  with*; the co-training claim is third-party only.
- **Measured here**: the most effort-robust harness (7–8/8 at every
  effort), the best single result of the study (8/12 at `medium`, cheaper
  than `xhigh`), a third of Claude Code's wall time at `low`. Its one
  harness-attributable loss was a process-lifecycle choice — the bash
  executor signals the whole *process group* at turn end, so a background
  server the agent correctly started was dead before the tests ran. In
  Composio's five-harness run of V4-Pro-0813 it scored 20/30 (pi 21, Claude
  Code 19, OpenCode 19) at the lowest cost per success, $0.028
  ([Composio](https://x.com/composio/status/2090069401923989882)).
- **Its costs**: every version is `rc` or `alpha` and the author promises
  "compatibility-breaking changes"; `npm install` cannot finish (pnpm only);
  a default route to DeepSeek's hosted API that fails with
  `MISSING_CREDENTIAL` until `agent-default-model` is set; ~170K lines of
  internal docs against a six-page user guide; a Web UI that binds loopback
  only; 25 tools whose schemas cost 828 s of prefill on a slow llama.cpp
  server against 1.76 s on NInfer — the same preamble, the difference
  entirely prefill speed. Its native DSML tool format leaks as raw text on
  vLLM/SGLang ([HF #209](https://huggingface.co/deepseek-ai/DeepSeek-V4-Pro/discussions/209),
  [vllm #41240](https://github.com/vllm-project/vllm/issues/41240)),
  OpenCode declined to support it ([#24566](https://github.com/anomalyco/opencode/issues/24566)),
  and this repo measured the same drift on the 2-bit build (0% on Hermes,
  100% on the native template).

### 3.4 pi — the minimalist: four tools, a fifteen-line prompt, and a list of things it refuses to build

Read from `@earendil-works/pi-coding-agent` 0.84.3 and Mario Zechner's own
writing ([founding essay, 2025-11-30](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/)).

- **The whole system prompt fits on one screen**: "You are an expert coding
  assistant operating inside pi, a coding agent harness…", a one-line
  snippet per tool, two or three guidelines, pointers to pi's docs *only for
  questions about pi*, then `<project_context>` files, skills, and the cwd.
  Under 1,000 tokens with tool definitions. Why it works, in his words: "all
  the frontier models have been RL-trained up the wazoo, so they inherently
  understand what a coding agent is."
- **The Philosophy section is a list of refusals**, each with a reason.
  *No MCP* — Playwright's MCP costs 13.7K tokens, a CLI README 225
  ([post](https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/)).
  *No sub-agents* — "a black box within a black box." *No permission
  popups* — "you're playing whack-a-mole with attack vectors"; containerise.
  *No plan mode* — "write it to a file." *No built-in to-dos* — "They
  confuse models more than they help. They add state that the model has to
  track and update." *No background bash* — use tmux. The governing rule:
  "If I don't need it, it won't be built." The motive was Claude Code
  itself: "a spaceship with 80% of functionality I have no use for", whose
  "system prompt and tools also change on every release, which breaks my
  workflows and changes model behavior" — he built `cchistory` to diff them
  ([post](https://mariozechner.at/posts/2025-08-03-cchistory/)).
- **The community disagrees with the defaults, and the extension API lets
  it**: 5,358 packages, and the most-downloaded is `pi-mcp-adapter` at
  732K/month — MCP re-added on top — followed by web access, then subagent,
  plan-mode and permission packages ([pi.dev/packages](https://pi.dev/packages)).
  Both readings are right: the defaults are too spare for many, and the
  extension seam (block/modify tool calls, filter context, custom
  compaction) is strong enough to carry the features.
- **Sessions are a tree.** `/tree` branching, `/fork`, `/clone`, branch
  summaries when switching; compaction at `contextWindow − 16,384` keeping
  the last 20K tokens; compaction requests "disable prompt-cache writes
  because these one-off prompts are unlikely to be reused".
- **The provider layer is the product.** `pi-ai` — four wire protocols, a
  `compat` block per endpoint (`supportsDeveloperRole`, `maxTokensField`,
  `supportsReasoningEffort`, thinking-budget fields for vLLM/SGLang/llama.cpp)
  — is what DeepSeek built dsh's adapter on (`@earendil-works/pi-ai ^0.84.2`
  in [dsh's package.json](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/llm/llm-pi-ai/package.json))
  and what OpenClaw embeds; 4.4M weekly npm downloads. Zechner's critique of
  the alternative: other harnesses "rely on libraries like the Vercel AI SDK,
  which doesn't play nice with self-hosted models."
- **Measured**: the strongest independent evidence for the minimal thesis is
  Databricks on a multi-million-line codebase — "Pi sent about 3x less
  context per turn… the cost per task differed significantly (more than 2x
  in some cases), while quality remained the same"
  ([Databricks](https://www.databricks.com/blog/benchmarking-coding-agents-databricks-multi-million-line-codebase));
  Composio on DeepSeek V4 Flash: pi 20/30 at $0.028 per success vs Claude
  Code 16/30 at $0.195 ([Composio](https://composio.dev/content/pi-agent-vs-claude-code)).
  Locally: 7/12 out of the box with no tuning, the lightest install, the
  fastest agent time, and the only harness whose losses were all the
  model's. It *wants* effort (4/8 at `low`, 7/8 at `xhigh`): with no todo
  list, plan tool or continuation driver, the model's reasoning is the only
  structure. Not on any official leaderboard.
- **Its costs** are the refusals' flip side: "full YOLO mode" unless you add
  a gate; it "doesn't automatically finish tasks the way Claude Code does";
  extensions "execute arbitrary code"; and since 2026-04-04 Claude
  subscriptions cannot be used through it (OpenAI "blessed pi", in his
  phrase, for ChatGPT ones). Composio's summary of the mood: "almost
  everyone who reviews both, including the biggest Pi fans, still runs
  Claude Code as their daily driver." Business: joined Earendil (Armin
  Ronacher, Colin Hanna; Accel/Balderton) 2026-04-08, core "MIT, forever"
  ([post](https://mariozechner.at/posts/2026-04-08-ive-sold-out/)).

### 3.5 OpenCode — the pragmatist: a prompt per model family, a client/server split, and the harness that survived losing Anthropic

Read from the installed 1.3.0 binary (prompt files extracted) and the public
sources; current release 1.18.25, 202.6k stars, ~8M MAU
([Pragmatic Engineer](https://newsletter.pragmaticengineer.com/p/opencode)).

- **It ships a system prompt per model family and picks one by substring
  on the model id.** `anthropic.txt` is a Claude Code descendant ("You are
  an interactive CLI tool that helps users with software engineering
  tasks…", TodoWrite "VERY frequently", parallel tool calls); `codex.txt` is
  a Codex descendant ("Try to use apply_patch for single file edits",
  "Never ask permission questions like 'Should I proceed?'", the same
  final-answer style guide); `gemini.txt` is Gemini CLI's "Core Mandates";
  `beast.txt` is the GPT-4.1 "Beast Mode" prompt; `kimi.txt`, `gpt.txt`,
  and a terse `default.txt` for everything else — which is where DeepSeek,
  Qwen and GLM land, an unmeasured bias against exactly the models its
  users run locally ([prompt dir](https://github.com/anomalyco/opencode/tree/dev/packages/opencode/src/session/prompt)).
  This is the clearest statement in any harness that **the prompt a model
  was trained against is part of the model** — and Dax Raad's view that
  the harness barely matters otherwise: "OpenCode and Claude Code function
  nearly identically under the hood"; "The AI is not better. It's just the
  experience around it is better."
- **Client/server with an OpenAPI surface**: `opencode serve` on :4096,
  SSE events, a `/tui` endpoint; TUI, web, Electron desktop, IDE
  extensions, ACP and the SDK are all clients, and `opencode run --format
  json` is what every community benchmark drives. The cost of that
  surface: CVE-2026-22812 (CVSS 8.8), an unauthenticated server with
  permissive CORS that let any website run shell commands, fixed in 1.0.216
  ([advisory](https://github.com/advisories/GHSA-vxw4-wv6m-9hhh)).
- **Deterministic feedback via LSP diagnostics** after edits, 30+ servers
  auto-installed — the harness feeding the compiler's verdict back rather
  than trusting the model's; the docs are honest that servers "get out of
  sync, use significant memory" ([LSP docs](https://opencode.ai/docs/lsp/)).
- **Permissions without a sandbox**: allow/ask/deny per tool with glob
  patterns (last rule wins), per-agent overrides, `.env` read-blocked, a
  `doom_loop` guard for repeated identical calls
  ([docs](https://opencode.ai/docs/permissions/)).
- **Compaction hides rather than deletes**: fires only when ≥ 20K tokens
  can be freed, keeps the newest 40K, never prunes skill results.
- **Zen exists because open-model tool calling is a deployment problem.**
  "Every single day it would be somebody saying 'the LLM is randomly
  stopping in the middle'… depending on the provider, they could be really
  bad… especially with all the tool calling stuff"
  ([Baseten interview](https://www.baseten.co/blog/building-ai-agents-open-code-and-open-source-a-conversation-with-dax/)).
  Curating *where* a model runs is a harness decision too.
- **Measured**: not on any official leaderboard. Same-model community runs
  show correctness parity and the slowest wall-clock: on 5 TB tasks × 3
  with GPT-5.5 it tied pi and Codex at 12/15 while taking 423 s per solve
  against 172–210, and used the fewest tokens
  ([openbench](https://github.com/minghinmatthewlam/openbench/blob/main/RESULTS.md));
  Builder.io with Sonnet 4.5 in both: 16m20s vs Claude Code's 9m09s, but 94
  tests written vs 73 ([Builder.io](https://www.builder.io/blog/opencode-vs-claude-code)).
  Thoroughness over velocity, and it cuts both ways.
- **The Anthropic story is the reason it exists and its biggest wound.**
  Founded as "an open source version of Claude Code… really flexible for
  any model because that's where open source has an advantage"; on
  2026-01-09 Anthropic began rejecting subscription OAuth outside Claude Code
  ("tightened our safeguards against spoofing the Claude Code harness"),
  a legal request removed the bundled auth plugin on 03-19 (548
  thumbs-down on [PR #18186](https://github.com/anomalyco/opencode/pull/18186)),
  full enforcement 04-04 citing "outsized strain" from harnesses missing
  prompt-cache hits; OpenAI enabled Codex OAuth in OpenCode the next day.
  It grew from 650K to ~8M MAU through it. Other costs: "often uses 1GB of
  RAM or more. For a TUI" (Codex's Rust TUI: ~80 MB), 10 releases in 18 days
  with regressions Dax concedes "probably shouldn't have shipped".

## 4. How much does the harness matter?

### 4.1 Measured on this machine

[`tbench/REPORT.md`](../../tbench/REPORT.md) and
[HARNESS-BENCHMARKS.md](HARNESS-BENCHMARKS.md): one model (Qwen3.8-27B NVFP4 on
NInfer), four harnesses, a fixed 12-task Terminal-Bench subset, the only
variable the harness.

| harness | out of the box | after fixing its own bottleneck | best effort | agent time / task |
|---|:---:|:---:|:---:|---|
| pi | **7/12** | 7/12 | xhigh | ~70–90 s |
| DeepSeek Harness | 6/12 | 7/12 → **8/12 at `medium`** | medium (7–8 at every level) | ~120–130 s |
| Claude Code (via bridge) | 4/12 | 7/12 | xhigh (3/8 at medium) | ~180–240 s |
| terminus (TB reference) | 3/12 | 6/12 → 7/8 at `low` | **low** | ~40 s |

- **Every recovered task was plumbing.** dsh: process-group kill of a
  background server. Claude Code: its own 16,384 output-token cap tripped
  by reasoning, and one session that ended on `end_turn` after the model
  *narrated* its next tool call instead of making it. terminus: freeform
  command batches it could not parse — underneath, `completion_tokens:
  8192` spent entirely on `reasoning_content` with zero `content`. pi: one
  flaky download.
- **The bridge was not the cost** (~0.15 s/call, 133/133 200s, zero
  retries) — but it silently dropped `reasoning_effort` for every
  LiteLLM-routed harness until `allowed_openai_params` was set. Two
  harnesses had been benchmarked at the template's default effort by
  accident; proven by sending an illegal value and getting 200 instead of
  the documented 400.
- **The optimal effort is a property of the harness, not the model.** dsh
  flat, terminus inverted (low best), pi and Claude Code monotonic. "More
  thinking" made dsh *worse* on one task at xhigh. LangChain found the same
  shape at the frontier: a "reasoning sandwich" (high plan, medium
  implement, high verify) beat uniform xhigh 63.6 vs 53.9, and HAL's 21,730
  rollouts found higher effort equal-or-worse in 21 of 36 combinations
  ([HAL](https://arxiv.org/html/2510.11977)).
- **Three tasks fail on every harness at every effort** — the model's
  ceiling, and no harness moves it. A fourth "ceiling" task was a scoring
  bug: `is_resolved: null` (parse error) counted as `false`. Count missing
  data separately. Noise is ±1–2 tasks on 12; single-task gaps are not
  results.

Two further local measurements that bear on harness design:

- **Tool-schema cost is prefill cost.** dsh's 25-tool preamble is ~7,757
  tokens: 828.8 s cold on llama.cpp (weights in system RAM) vs 1.76 s on
  NInfer (6,019 tok/s), and 41 ms on the next turn with prefix reuse. The
  same harness is unusable or free depending on the server — why the
  `minimal` preset exists and why DeepSeek's own number was measured with
  it.
- **The tool-call *format* is a harness × server contract.** On llama.cpp
  the stock DeepSeek template rendered *no tools at all*; a Hermes-style
  template worked until the 2-bit model slipped out of Hermes syntax
  mid-task (0% on one task, twice); the native DSML template with
  llama.cpp's dedicated parser + grammar scored 100%. A harness that emits
  OpenAI `tools` is only as reliable as the server's parser for that model.

### 4.2 Same model, different harness — the public record

| benchmark | model held fixed | harness A → B | delta | source |
|---|---|---|---|---|
| SWE-bench Verified (100-task, 3×3 factorial) | GLM-5.1 / GPT-5.4 / Kimi K2.6 | minimal → full harness | +13.0 / +8.5 / +8.5; harness variance 7.8× model variance; rankings flip 6/9 | [Zhang et al.](https://arxiv.org/html/2605.23950) |
| SWE-bench Verified | GPT-5; Kimi K2 Thinking | scaffold switch | up to 11; up to 15 — "the single biggest impact" | [Epoch AI](https://epoch.ai/gradient-updates/why-benchmarking-is-hard) |
| SWE-bench Verified Mini | Sonnet 4.5; GPT-5 | across scaffolds | 68 → 34; 46 → 12 | [HAL](https://arxiv.org/html/2510.11977) |
| SWE-bench Pro | Opus 4.5 | SEAL scaffold → Claude Code | 45.9 → 55.4, while six frontier models under SEAL span 4.9 | [Zhang et al.](https://arxiv.org/html/2605.23950) |
| SWE-bench Verified | Opus 4.5 | bash-only mini-SWE-agent → Live-SWE-agent → Anthropic internal | 76.8 → 79.2 → 80.9 | [Willison](https://simonwillison.net/2026/Feb/19/swe-bench/) |
| Terminal-Bench 2.1 | Fable 5 / GPT-5.5 / Opus 4.7 | Terminus 2 → vendor harness | +3.4 / +5.1 / +2.8 | [Snorkel](https://snorkel.ai/leaderboard/terminal-bench-2-1/) |
| Terminal-Bench 2.1 | Gemini 3 Pro | Gemini CLI → Terminus 2 | **+8.1** — the generic harness beat the vendor's | same |
| Terminal-Bench 2.0 | gpt-5.2-codex | deepagents-cli before → after harness work | 52.8 → 66.5 (**+13.7**, no model change) | [LangChain](https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering) |
| Terminal-Bench 1.0 | Opus 4.1; GPT-5 | Claude Code → Droid; Codex → Droid | 43.2 → 58.8; 42.8 → 52.5 | [Factory](https://factory.ai/news/terminal-bench) |
| SWE-bench Pro | GPT-5.4 | OpenAI-reported → Blitzy's harness | 57.7 → 66.5 (+8.8), independently audited | [Quesma](https://quesma.com/blog/verifying-blitzy-swe-bench-pro/) |
| internal text-to-SQL eval | Opus 4.5 | 18 tools → 1 bash tool + filesystem | 80% → 100%, 37% fewer tokens, 3.5× faster | [Vercel](https://vercel.com/blog/we-removed-80-percent-of-our-agents-tools) |
| 180-task edit benchmark, 16 models | each | `apply_patch` → hash-anchored edit tool | avg **+15**; Grok Code Fast 1 6.7 → 68.3 | [Stencil](https://stencil.so/blog/the-harness-problem) |
| Aider benchmark | GPT-4 Turbo | search/replace → unified diff | 20% → 61% | [Aider](https://aider.chat/2023/12/21/unified-diffs.html) |
| ARC-AGI-3 | GPT-5.6 Sol | default → retained reasoning + compaction | 13.3% → 38.3%, 6× fewer output tokens | [OpenAI](https://openai.com/index/how-two-settings-tripled-our-arc-agi-3-scores/) |
| SWE-bench (2024) | GPT-4 | raw bash → SWE-agent ACI | ~2×; linting-on-edit alone +3.0 | [SWE-agent](https://arxiv.org/abs/2405.15793) |

And the reverse — same harness, different frontier models — is a much
narrower band: under Terminus 2 the top three (GPT-5.6 Sol, Opus 5, Grok 4.6)
sit within 1.1 points ([Artificial Analysis](https://artificialanalysis.ai/evaluations/terminalbench-v2-1));
under bash-only mini-SWE-agent the top four are within 1.2. DeepSWE's 113
tasks under one harness put Opus 5 at 74% for $11.84/task and GLM-5.3 at 69%
for $3.99 ([DeepSWE](https://deepswe.datacurve.ai/)) — a 5-point gap for 3× the
money.

Two caveats. The factorial study is a 100-task subset and Terminal-Bench CIs
are ±1.1–1.7, so single-digit deltas between two frontier harnesses are
near noise. And for strong models the *edit-format* effect specifically is
"roughly neutral" in one replication ([nwyin](https://nwyin.com/blogs/hashline-vs-replace-edit-bench.html))
— the format matters most where the model is weakest, which is exactly the
local-model case.

### 4.3 Terminal-Bench 2.1 today

Agent + model pairs with confidence intervals (Snorkel's mirror of tbench.ai;
tbench's own page renders client-side and could not be scraped):

| # | agent | model | score | own model? |
|---|---|---|---|---|
| 1 | Claude Code | Fable 5 | 83.8 ± 1.2 | own |
| 2 | Codex CLI | GPT-5.5 | 83.1 ± 1.1 | own |
| 3 | Terminus 2 | Fable 5 | 80.4 ± 1.2 | — |
| 4 | Cursor CLI | Grok 4.5 | 79.3 ± 1.5 | — |
| 5 | Claude Code | Opus 4.8 | 78.9 ± 1.3 | own |
| 6 | Codex CLI | GPT-5.6 Terra | 78.4 ± 1.3 | own |
| 7 | Terminus 2 | GPT-5.5 | 78.0 ± 1.2 | — |
| 8 | mini-SWE-agent | Muse Spark 1.1 | 76.2 ± 1.2 | — |
| 11 | Terminus 2 | Gemini 3 Pro | 73.9 ± 1.3 | — |
| 14 | Gemini CLI | Gemini 3 Pro | 65.8 ± 1.4 | own |
| 17 | Claude Code | GLM 5.1 | 58.7 ± 1.2 | — |

Vendor-reported model-level scores run higher and are not comparable
(different harness per row): GPT-5.6 Sol 88.8, Kimi K3 88.3 (Kimi Code),
GLM-5.3 88.2, DeepSeek V4 Pro 0813 87.9, Qwen3.8 Max 86.6, Fable 5 84.3,
DeepSeek V4-Flash-0731 82.7 (dsh minimal), Qwen3.8-27B 73.0
([llm-stats](https://llm-stats.com/benchmarks/terminal-bench-2.1)). **Not on
any 2.1 mirror**: OpenCode, pi, Droid, Warp, or dsh as a tbench submission.

## 5. The design dimensions, and what the evidence says

**Tool set: few, precise, trained-on.** Vercel's 18 → 1 (80 → 100%); pi's
four; dsh's two-tool benchmark preset; Droid crediting "strictly limiting the
tool repertoire"; Anthropic's "more tools don't always lead to better
outcomes" ([writing tools](https://www.anthropic.com/engineering/writing-tools-for-agents)).
The counter-evidence — SWE-agent's structured interface doubling GPT-4 — dates
from before models were RL-trained on tool use; Zechner's "RL-trained up the
wazoo" is the current premise, and Claude Code hiding its task tools on newer
models is Anthropic agreeing.

**Edit mechanics: the harness's most consequential single choice for a
weak model.** 3× on Aider for GPT-4, +15 average and +61.6 maximum across 16
models on Stencil's suite, `apply_patch` failing half the time on non-OpenAI
models, and roughly neutral at the frontier. Whichever format, the harness
must make failure *visible*: Codex's "the tool call will fail if it didn't
work", Claude Code's read-before-edit, SWE-agent's lint-on-edit (+3).

**System prompt: smaller, stable, and shaped for the model.** All 18 models
in Chroma's study degrade monotonically with input length
([context rot](https://www.trychroma.com/research/context-rot)). Developer-written
AGENTS.md files add +4% at up to +19% cost; LLM-generated ones *subtract* 3%
at +20% cost ([ETH](https://arxiv.org/html/2602.11988v1)) — "Bloated CLAUDE.md
files cause Claude to ignore your actual instructions" is Anthropic's own
line. OpenCode's per-family prompts and Cline's 10%-size local prompt are
the two practical responses; Claude Code's `--bare
--exclude-dynamic-system-prompt-sections` is what Unsloth tells local users to
run ([Unsloth](https://unsloth.ai/docs/basics/claude-code)).

**Prefix stability: treat cache hit rate as an SLO.** Static first, no
timestamps in the prefix, never reorder tools ([Claude Code](https://claude.com/blog/lessons-from-building-claude-code-prompt-caching-is-everything));
dsh's canonical `toolOrder`; pi's no-cache-write on one-offs. The failure
mode is measured: Claude Code's attribution header broke llama.cpp's prefix
cache and forced a full re-prefill of tens of thousands of tokens every turn;
`CLAUDE_CODE_ATTRIBUTION_HEADER=0` restored it
([Aleksandrov](https://www.mykolaaleksandrov.dev/posts/2026/06/claude-code-llamacpp-prompt-cache-fix/)).
Anthropic's stated reason for cutting off third-party harnesses was the
same thing from the other side: "outsized strain" from harnesses missing
cache hits.

**Compaction: retain state, but pin the constraints.** Summarising rather
than truncating tripled OpenAI's ARC score; but on AppWorld full context
scores 85.7% against the best summariser's 71.4%, FIFO truncation *matches*
summarisation at small budgets, and the first post-compaction step is
measurably more error-prone ([TRACE](https://arxiv.org/html/2608.06503v1));
compaction drops in-context constraints from 0% to 30% violation across
seven models unless they are pinned at ~47 tokens each
([Governance Decay](https://arxiv.org/html/2606.22528v2)). Hence Anthropic's
three techniques — compaction, structured note-taking, sub-agents with clean
windows ([context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents))
— and the alternative both dsh (`ralph`) and Anthropic's long-running-agent
post converge on: fresh contexts with state in files and git.

**Safety: contain at the environment layer, steer at the model layer.**
The 93%-approve / 84%-fewer-prompts numbers above; Codex and dsh at the
kernel; Claude Code's classifier *plus* a sandbox *plus* deterministic hooks;
pi's "run in a container". The rejected option is prompts as guardrails —
which compaction erodes.

**Subagents: one stateful loop, stateless narrow workers for breadth.**
+90% on research at 15× tokens (Anthropic) against Cognition's "share full
traces; actions carry implicit decisions"
([Don't build multi-agents](https://cognition.com/blog/dont-build-multi-agents))
and a 2026 finding that single agents match multi-agent systems at equal
reasoning budgets ([2604.02460](https://arxiv.org/abs/2604.02460)). Every
harness's 2026 design converged on the same shape: fork for shared context,
spawn for isolation, return a condensed result.

**Verification is the loop's exit condition, not a step.** LangChain's +13.7
came from a pre-completion checklist and doom-loop detection; Anthropic:
"Claude stops when the work looks done", and rules-based feedback ("which
rules failed and why") is "the best form"; Codex: "never end with only a
plan"; OpenCode feeds LSP diagnostics back. The narrate-and-stop failure this
repo hit on Claude Code is this dimension.

**Model–harness co-training: real, +2.8 to +5.1 points, and not
automatic.** OpenAI trained on `apply_patch`; Claude 3.5 Sonnet was
fine-tuned on the text-editor tool; DeepSeek V4 emits DSML natively and
implements `reasoning_effort` as a text prefix; Qwen Code is a Gemini CLI
fork with parser adaptations; Kimi K3's 88.3 is in Kimi Code. Gemini CLI
losing to Terminus 2 by 8.1 on Google's own model is the reminder that the
harness still has to be good.

**Skills over MCP dumps.** Curated skills +16.6 points average, ≤ 3 modules
beating exhaustive bundles, "smaller models with Skills can match larger
models without them" ([SkillsBench](https://arxiv.org/abs/2602.12670));
code-execution over MCP cut 150K tokens to 2K
([Anthropic](https://www.anthropic.com/engineering/advanced-tool-use)). All
five load skill descriptions at start and bodies on demand; the
agentskills.io format is the one thing they agree on.

**Cost is a first-order outcome.** Claude Code at 3–4× Codex's tokens for
the same task; pi at a third of Claude Code's context per turn at equal
quality; DeepSWE's frontier at $4–$22 per task for a five-point spread; the
Scaffold Effect paper finding harness choice moves tokens-per-solved-task
by 40× while pass rates differ 2–8 points ([2607.22585](https://arxiv.org/html/2607.22585)).
Good harnesses cut tokens *and* raise scores (Vercel, OpenAI's ARC run);
the expensive configuration was on the Pareto frontier in 1 of HAL's 9
benchmarks.

## 6. What makes one better than another — a verdict per use

- **Frontier Claude, money no object, work you cannot babysit** — Claude
  Code. Its own model, +6–7 over a generic harness, the deepest safety
  stack, and the only one whose autonomy is backed by a published
  false-negative rate.
- **Frontier GPT, cost-sensitive, or you want the sandbox to be the safety
  model** — Codex CLI. A quarter of the tokens for the same task, kernel
  containment by default, an edit tool the model was trained on.
- **Any model, especially an open or local one, and you want to read the
  whole prompt** — pi. Under 1,000 tokens, the best `compat` layer for
  OpenAI-compatible servers, tree sessions; add the gate and the plan file
  yourself.
- **A local model you will run headless, in benchmarks, or from another
  program** — dsh. Native OpenAI, a two-tool preset, effort-robust, a
  replayable log, cheapest per success in the one five-way comparison, the
  best single score in this repo's study. Accept that it is pre-release and
  its docs are written for agents, not people.
- **Many providers, a server other things can drive, or a team switching
  models by the week** — OpenCode. Provider freedom by contract, per-family
  prompts, LSP feedback, the widest set of clients. Accept the slowest
  wall-clock, the RAM, and the churn.
- **For this project's 5090 specifically**, the measured answer stands:
  dsh at `medium` for headless work, Claude Code at `xhigh` through the
  bridge if the client matters more than the wall time, and pi if you want
  the lightest thing that reaches the model's ceiling. Whichever harness,
  the tool-schema preamble must fit the server's prefill speed, the
  `reasoning_effort` map must match the template, and `max_tokens` must
  leave room for the reasoning.

What none of them has solved: compaction without losing constraints;
proving a task is done without the model's say-so; and the same harness
being right for both a frontier model and a 4-bit 27B — every one of the
five is tuned for one end of that range, and the settings that make it work
at the other end (`--bare`, `minimal`, `default.txt`, a 10% prompt) are
all a way of turning it into pi.

## 7. Open questions nobody has measured

- **Plan mode as such.** No controlled study; the nearest is LangChain's
  checklist and the effort-sandwich result.
- **Streaming and latency across harnesses.** Anecdotes only ("it
  flickers"); no measurement.
- **Whether DeepSeek trained V4-Flash *with* dsh.** The card says *measured
  with*; the co-training claim is third-party.
- **dsh vs pi token usage.** One source says dsh uses ~10× pi's tokens,
  another ~10× fewer; neither primary was reachable.
- **OpenCode, pi or dsh on the official Terminal-Bench leaderboard.** None
  is listed; every number for them is a community run.
- **Codex's memories and goals in practice.** Both are in the state
  database of the installed build; `memories` is flagged off; no published
  evaluation of either.

## 8. Sources

**Primary, on this machine (2026-08-30).** `claude --help` (2.1.251);
`codex --help`, `codex features list`, the prompt embedded in
`@openai/codex-linux-x64` 0.147.0, `~/.codex/*.sqlite` schemas;
`~/.dsh-runtime/node_modules/@deepseek-ai/*` READMEs (0.1.1-rc.2 / rc.8);
`@earendil-works/pi-coding-agent` 0.84.3 (`dist/core/system-prompt.js`,
README, `docs/compaction.md`, CHANGELOG); prompt files extracted from
`~/.opencode/bin/opencode` 1.3.0; this repo's `tbench/REPORT.md`,
`app/docs/HARNESS-BENCHMARKS.md`, `app/docs/DEEPSEEK-HARNESS.md`,
`app/docs/dsh-minimal.cordis.patch.yml`, `CLAUDE.md`.

**Vendor writing.** Anthropic: [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents),
[Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents),
[Writing tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents),
[Multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system),
[Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents),
[Building agents with the Agent SDK](https://claude.com/blog/building-agents-with-the-claude-agent-sdk),
[A harness for every task](https://claude.com/blog/a-harness-for-every-task-dynamic-workflows-in-claude-code),
[Auto mode](https://www.anthropic.com/engineering/claude-code-auto-mode),
[How we contain Claude](https://www.anthropic.com/engineering/how-we-contain-claude),
[Prompt caching is everything](https://claude.com/blog/lessons-from-building-claude-code-prompt-caching-is-everything),
[Best practices](https://code.claude.com/docs/en/best-practices). OpenAI:
[Unrolling the Codex agent loop](https://openai.com/index/unrolling-the-codex-agent-loop/),
[Unlocking the Codex harness](https://openai.com/index/unlocking-the-codex-harness/),
[Codex as a platform](https://developers.openai.com/blog/codex-as-a-platform),
[Harness engineering](https://openai.com/index/harness-engineering/),
[Codex prompting guide](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide),
[Two settings tripled ARC-AGI-3](https://openai.com/index/how-two-settings-tripled-our-arc-agi-3-scores/),
[sandboxing docs](https://learn.chatgpt.com/docs/sandboxing),
[config reference](https://learn.chatgpt.com/docs/config-file/config-reference).
DeepSeek: [harness page](https://deepseek.com/harness/en/),
[repo](https://github.com/deepseek-ai/deepseek-harness),
[V4-Flash-0731 card](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-0731),
[Cordis paper](https://arxiv.org/abs/2608.25512). pi:
[founding essay](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/),
[no-MCP post](https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/),
[cchistory](https://mariozechner.at/posts/2025-08-03-cchistory/),
[docs](https://pi.dev/docs/latest/), [I've sold out](https://mariozechner.at/posts/2026-04-08-ive-sold-out/).
OpenCode: [docs](https://opencode.ai/docs/), [Dax at Baseten](https://www.baseten.co/blog/building-ai-agents-open-code-and-open-source-a-conversation-with-dax/),
[Pragmatic Engineer](https://newsletter.pragmaticengineer.com/p/opencode).

**Leaks and code reads.** Claude Code source map (2.1.88):
[Varonis](https://www.varonis.com/blog/claude-code-leak),
[wavespeed](https://wavespeed.ai/blog/posts/claude-code-architecture-leaked-source-deep-dive/),
[engineerscodex](https://read.engineerscodex.com/p/diving-into-claude-codes-source-code),
[Crosley](https://blakecrosley.com/blog/claude-code-source-leak);
[Piebald's prompt tracker](https://github.com/Piebald-AI/claude-code-system-prompts).
dsh: [developersdigest first look](https://www.developersdigest.tech/blog/deepseek-harness-dsh-first-look),
[BASHCAT dependency audit](https://hackmd.io/@BASHCAT/ByB4Fv6UGl),
[justin3go review](https://justin3go.com/en/posts/2026/08/15-deepseek-harness-review).

**Benchmarks and papers.** [Terminal-Bench 2.1 announcement](https://www.tbench.ai/news/terminal-bench-2-1),
[Snorkel TB 2.1 mirror](https://snorkel.ai/leaderboard/terminal-bench-2-1/),
[Artificial Analysis](https://artificialanalysis.ai/evaluations/terminalbench-v2-1),
[llm-stats](https://llm-stats.com/benchmarks/terminal-bench-2.1),
[Zhang et al., harness disclosure](https://arxiv.org/html/2605.23950),
[HAL](https://arxiv.org/html/2510.11977), [Epoch AI](https://epoch.ai/gradient-updates/why-benchmarking-is-hard),
[SWE-agent ACI](https://arxiv.org/abs/2405.15793), [mini-SWE-agent](https://github.com/SWE-agent/mini-swe-agent/),
[The Scaffold Effect](https://arxiv.org/html/2607.22585), [Guo et al. survey](https://arxiv.org/abs/2606.20683),
[TRACE](https://arxiv.org/html/2608.06503v1), [Governance Decay](https://arxiv.org/html/2606.22528v2),
[AGENTS.md study](https://arxiv.org/html/2602.11988v1), [SkillsBench](https://arxiv.org/abs/2602.12670),
[Chroma context rot](https://www.trychroma.com/research/context-rot),
[single vs multi-agent at equal budget](https://arxiv.org/abs/2604.02460),
[DeepSWE](https://deepswe.datacurve.ai/), [Endor Labs](https://www.endorlabs.com/learn/claude-opus-4-7-sets-new-records-in-the-endor-labs-agent-security-league),
[Antigma reproduction of 82.7](https://www.orcarouter.ai/blog/deepseek-v4-flash-arc-verified).

**Harness-engineering write-ups.** [LangChain](https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering),
[Vercel](https://vercel.com/blog/we-removed-80-percent-of-our-agents-tools),
[Stencil](https://stencil.so/blog/the-harness-problem),
[Factory](https://factory.ai/news/terminal-bench),
[Cognition](https://cognition.com/blog/dont-build-multi-agents),
[HumanLayer](https://www.humanlayer.dev/blog/skill-issue-harness-engineering-for-coding-agents),
[Thorsten Ball](https://ampcode.com/notes/how-to-build-an-agent),
[Geoffrey Huntley](https://ghuntley.com/agent/),
[Aider unified diffs](https://aider.chat/2023/12/21/unified-diffs.html).

**Comparisons.** [Databricks](https://www.databricks.com/blog/benchmarking-coding-agents-databricks-multi-million-line-codebase),
[Composio pi vs Claude Code](https://composio.dev/content/pi-agent-vs-claude-code),
[Composio five harnesses](https://x.com/composio/status/2090069401923989882),
[openbench](https://github.com/minghinmatthewlam/openbench/blob/main/RESULTS.md),
[Builder.io](https://www.builder.io/blog/opencode-vs-claude-code),
[Particula](https://particula.tech/blog/codex-vs-claude-code-cli-agent-comparison),
[Firecrawl](https://www.firecrawl.dev/blog/best-ai-coding-agents),
[HN: 33k tokens before the prompt](https://news.ycombinator.com/item?id=48883275),
[HN: dsh launch](https://news.ycombinator.com/item?id=49285244),
[HN: pi essay](https://news.ycombinator.com/item?id=46844822),
[Unsloth on Claude Code locally](https://unsloth.ai/docs/basics/claude-code),
[llama.cpp prefix-cache fix](https://www.mykolaaleksandrov.dev/posts/2026/06/claude-code-llamacpp-prompt-cache-fix/).

---

[← Back to the README](../../README.md) ·
[Harness benchmarks](HARNESS-BENCHMARKS.md) ·
[DeepSeek Harness](DEEPSEEK-HARNESS.md) ·
[Claude Code](CLAUDE-CODE.md)

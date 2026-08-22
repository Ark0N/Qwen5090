# Performance notes — RTX 5090

## What to expect

Single-stream chat on one RTX 5090 (numbers vary with driver/vLLM version):

| Setup | Decode speed |
|---|---|
| NVFP4 + MTP (default) | ~80–100 tok/s |
| NVFP4, MTP off (`-NoMtp`) | ~60–80 tok/s |
| BF16 reference (doesn't fit on one 5090) | ~1.5× slower than NVFP4 |

Measure your own machine with the server running: `bash app/scripts/benchmark.sh`
from WSL (add `TOKENS=1024` for a longer run).

## Where the VRAM goes (32 GB card)

- **Weights:** ~22 GB (NVFP4, 4-bit weights + FP8 lm_head)
- **KV cache:** FP8, and Qwen3.8's hybrid attention (linear attention on 48 of
  64 layers) keeps it small — that's why long contexts fit at all. The precision
  is chosen to match the window: fp8 up to 128K (~171,000 tokens of capacity),
  and 4-bit (`turboquant_4bit_nc`) above that, which is what makes the native
  262K window fit — 9.1 GiB of fp8 cache would not, against the ~6.3 GiB free
- **Long context costs the MTP speed-up**: a TurboQuant KV cache and speculative
  decoding together corrupt this model's output (empty replies, or `: : : :`
  until the token limit, all behind an HTTP 200), so serve.sh turns MTP off
  whenever it picks a 4-bit cache. 262K runs ~49 tok/s; the default 131072 keeps
  fp8 + MTP and runs ~80 tok/s. Pick the window you actually need
- **Repeated prompts are nearly free above 128K**: the 4-bit path turns on
  prefix caching, so a request that shares its opening tokens with an earlier
  one skips re-reading them. Measured on a 32,422-token prefix: 3.80 s cold,
  then 0.31 s and 0.27 s. That is the difference between usable and painful for
  Claude Code and other agents, which resend one long system prompt every turn.
  It costs ~15,000 tokens of KV capacity and one 60 s recompile the first time
  it is enabled; `PREFIX_CACHE=0` (or `-PrefixCache:$false`) opts out
- **Headroom:** `GPU_UTIL=0.90` leaves ~3 GB for the Windows desktop, which
  shares the GPU under WSL. Above 128K the server uses `0.85` instead: the 4-bit
  cache would otherwise be sized ~1.7x larger than the window can ever use, and
  a ~3 GB margin is thin enough that a desktop VRAM spike between vLLM's
  profiling pass and its allocation pass aborts the start with a CUDA OOM
  *after* it has already reported the cache as fitting

Rule of thumb: OOM at startup → drop `-Ctx` first, then `-GpuUtil`. If it OOMs
having just printed `Available KV cache memory: N GiB`, the profiling was fine
and something else on the GPU grew — close the browser and retry before
changing any setting.

## The DeepSeek V4-Flash path (llama.cpp, 2026-08-22)

A different backend with a different bottleneck. The Qwen numbers above are a
model that fits in VRAM; this one is 150B parameters with its experts in system
RAM, and **where the experts live decides everything**.

Measured on the same 32 GB machine, same weights, same 64K window:

| | `--cpu-moe` (all 43 layers on CPU) | `-NCpuMoe 30` (~13 layers in VRAM) |
|---|---|---|
| first request after a start | 47 s, and **repeated on every request** | 33 s, **once** |
| warm request | nothing stayed warm | 2.4 s |
| generation | 4.5 tok/s | 13.6–20.9 tok/s |
| prefill | 46 tok/s marginal, 47 s fixed | prefix reused (`cache_n` 129 of 149) |

The difference is whether the working set fits. With every expert on the CPU,
58 GiB cycles through a page cache too small to hold it, so the re-read repeats
forever and ~19 GB of VRAM sits idle. `-NCpuMoe 30` pins a slice of them and
the cost is paid once per server start. **Set it.** It is the single largest
lever on this path, worth more than context size, quant tier or thinking level.

Raw prefill against `--cpu-moe`, thinking off, for the shape of the curve:

    412 tokens     51.7 s     8.0 tok/s
  2,417 tokens    109.0 s    22.2 tok/s
  4,823 tokens    149.1 s    32.3 tok/s      -> 47.4 s fixed + 46 tok/s marginal

### What an agent turn actually costs

One `dsh --profile headless` task, end to end, against a freshly started server:

    step 1   828.8 s   model reads the prompt, calls the `read` tool
    step 2    18.0 s   model answers from the tool result
    total    846.8 s   turn completed, answer correct

Step 2 is 46× cheaper than step 1 because `--cache-reuse` kept the prefix. So
the cost of an agent session is **one expensive first step, then cheap ones** -
and since the system prompt and tool schemas are identical across tasks, a
warm server should carry that cache from one task into the next.

What makes step 1 expensive is not the question, it is the preamble: dsh
declares **25 tools** plus a ~1,000-token system prompt, and every one of those
JSON schemas is prefilled.

The harness's `minimal` preset - bash and `str_replace_editor` alone - exists
precisely for this, and is also the configuration DeepSeek's published
Terminal-Bench figure was measured with. `deepseek-harness.sh minimal`
composes it. Same task, same workspace, same server:

| | 25 tools | minimal (2 tools) |
|---|---|---|
| step 1 | 828.8 s | **195.8 s** |
| step 2 | 18.0 s | 15.0 s |
| total | 846.8 s | **210.9 s** |

**4x, for deleting tool definitions the task never needed.** The answer was
correct both times; with `read` gone the model reached for
`str_replace_editor` with `command: view` instead, which is the preset working
as designed rather than degrading. Cutting the preamble is the second lever on
this path, after `-NCpuMoe`.

### The prompt cache is worth ~15x, and costs no accuracy

`--cache-reuse` is on by default, and it earns its place twice over. Identical
tool-enabled request, four runs each way, `cache_prompt` toggled per request so
nothing else changed:

| | latency | tool calls |
|---|---|---|
| cache on | 63.1 s cold, then **3.9–6.0 s** | 4/4 |
| cache off | 19.1–26.2 s | 4/4 |

Two things worth reading off that table. The first request of a session pays
for the whole preamble and there is no way around it; every one after it is an
order of magnitude cheaper. And a reused prefix answered exactly as reliably as
a freshly computed one — the cache is a speed feature with no accuracy cost, so
leave it on.

Note the cold request is *slower* than an uncached one: it computes the prefix
and writes it. That is a one-time cost per server start, paid back within two
requests.

## Levers, in order of impact

1. **MTP (on by default).** Multi-token prediction drafts 3 tokens per step
   and verifies them in one pass — a large single-stream win at negligible
   cost. Disable with `-NoMtp` only if outputs look corrupted after an
   upstream vLLM change.
2. **Context length.** `-Ctx` above 131072 switches the KV cache to 4-bit,
   which costs speed twice over: decode drops from ~80 to ~49 tok/s (MTP has
   to be turned off with it), and long prompts prefill far slower — see the
   next lever. That is why 131072 is the default; go higher only when you
   actually need the room.
3. **Thinking mode.** Reasoning tokens are generated tokens: `-Effort xhigh`
   answers harder questions but takes proportionally longer. Use
   `chat.ps1 -NoThink` for snappy chat. The levels are `low`, `medium` and
   `xhigh` — this model's chat template rejects `high` with an HTTP 400.
   Reasoning tokens also count against the reply limit, so a small
   `max_tokens` with thinking on can return an empty answer.
4. **Long prompts above ~128K cost far more than long chats.** Measured at
   262144 with the 4-bit KV cache, needle-in-a-haystack, thinking off:

   | Prompt | Prefill | Wall | Answer |
   |---|---|---|---|
   | 5,585 tokens | ~11,100 tok/s | 0.5 s | correct |
   | 22,210 tokens | ~11,300 tok/s | 2.0 s | correct |
   | 90,800 tokens | ~370 tok/s | 245 s | correct |

   Retrieval stays exact at every length — it is purely a speed cliff, in
   the TurboQuant KV store and the GDN linear-attention core during chunked
   prefill. While it grinds the GPU reads 100% busy at ~128 W and the server
   logs nothing, so it looks like a freeze. Growing *into* a long context by
   chatting is fine; pasting 100K tokens in at once is a multi-minute wait.
5. **Background VRAM users.** A game or browser eating 4 GB forces a lower
   `GPU_UTIL`. Check with `nvidia-smi` in Windows before blaming vLLM.
6. **Batch throughput.** Serving several clients? Aggregate tok/s scales well
   beyond single-stream numbers; nothing to configure, vLLM batches
   continuously.

## First start is slow — that's normal

Model load from NVMe plus CUDA graph capture takes a minute or two. Subsequent
requests are fast; keep the server running in its own terminal.

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
  whenever it picks a 4-bit cache. 262K runs ~49 tok/s; 131072 keeps fp8 + MTP
  and runs ~80 tok/s. Pick the window you actually need
- **Headroom:** `GPU_UTIL=0.90` leaves ~3 GB for the Windows desktop, which
  shares the GPU under WSL. Enough to run — but not enough for the display
  driver to recover if it resets, which is how the test machine bluescreened
  (see
  [TROUBLESHOOTING](TROUBLESHOOTING.md#bluescreen-0x116-video_tdr_error)).
  `0.80` roughly halves the KV budget, so it has to be paired with
  `-Ctx 131072` — and that pair restores fp8 + MTP, making it the faster
  setup as well as the safer one

Rule of thumb: OOM at startup → drop `-Ctx` first, then `-GpuUtil`.

## Levers, in order of impact

1. **MTP (on by default).** Multi-token prediction drafts 3 tokens per step
   and verifies them in one pass — a large single-stream win at negligible
   cost. Disable with `-NoMtp` only if outputs look corrupted after an
   upstream vLLM change.
2. **Context length.** `-Ctx` above 131072 switches the KV cache to 4-bit,
   which costs speed twice over: decode drops from ~80 to ~49 tok/s (MTP has
   to be turned off with it), and long prompts prefill far slower — see the
   next lever. 131072 is the sweet spot; go higher only when you need the room.
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

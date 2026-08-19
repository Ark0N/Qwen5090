# Performance notes — RTX 5090

## What to expect

Single-stream chat on one RTX 5090 (numbers vary with driver/vLLM version):

| Setup | Decode speed |
|---|---|
| NVFP4 + MTP (default) | ~80–100 tok/s |
| NVFP4, MTP off (`-NoMtp`) | ~60–80 tok/s |
| BF16 reference (doesn't fit on one 5090) | ~1.5× slower than NVFP4 |

Measure your own machine with the server running: `bash scripts/benchmark.sh`
from WSL (add `TOKENS=1024` for a longer run).

## Where the VRAM goes (32 GB card)

- **Weights:** ~17 GB (NVFP4, 4-bit weights + FP8 lm_head)
- **KV cache:** FP8, and Qwen3.8's hybrid attention (linear attention on 48 of
  64 layers) keeps it small — that's why 128K–262K context fits at all
- **Headroom:** `GPU_UTIL=0.90` leaves ~3 GB for the Windows desktop, which
  shares the GPU under WSL

Rule of thumb: OOM at startup → drop `-Ctx` first, then `-GpuUtil`.

## Levers, in order of impact

1. **MTP (on by default).** Multi-token prediction drafts 3 tokens per step
   and verifies them in one pass — a large single-stream win at negligible
   cost. Disable with `-NoMtp` only if outputs look corrupted after an
   upstream vLLM change.
2. **Context length.** Bigger `-Ctx` costs VRAM, not speed — until vLLM starts
   preempting because the KV cache is tight. If logs show preemption warnings,
   lower `-Ctx`.
3. **Thinking mode.** Reasoning tokens are generated tokens: `-Effort high`
   answers harder questions but takes proportionally longer. Use
   `chat.ps1 -NoThink` for snappy chat.
4. **Background VRAM users.** A game or browser eating 4 GB forces a lower
   `GPU_UTIL`. Check with `nvidia-smi` in Windows before blaming vLLM.
5. **Batch throughput.** Serving several clients? Aggregate tok/s scales well
   beyond single-stream numbers; nothing to configure, vLLM batches
   continuously.

## First start is slow — that's normal

Model load from NVMe plus CUDA graph capture takes a minute or two. Subsequent
requests are fast; keep the server running in its own terminal.

#!/usr/bin/env bash
# Quick single-stream throughput check against a running server.
# Usage (from WSL):  bash scripts/benchmark.sh          # or PORT=8080 TOKENS=1024 ...
# Counts streamed chunks (~1 token each), so treat the number as a close estimate.
set -euo pipefail

VENV="${QWEN5090_VENV:-$HOME/.qwen5090/venv}"

PORT="${PORT:-8000}" TOKENS="${TOKENS:-512}" "$VENV/bin/python" - <<'PY'
import os
import time
from openai import OpenAI

port, tokens = os.environ["PORT"], int(os.environ["TOKENS"])
client = OpenAI(base_url=f"http://localhost:{port}/v1", api_key="local")
model = client.models.list().data[0].id

t0 = time.perf_counter()
first = None
n = 0
for chunk in client.chat.completions.create(
    model=model, stream=True, max_tokens=tokens,
    messages=[{"role": "user", "content": "Write a detailed essay about the history of GPUs."}],
    extra_body={"chat_template_kwargs": {"enable_thinking": False}},
):
    if chunk.choices and chunk.choices[0].delta.content:
        n += 1
        if first is None:
            first = time.perf_counter() - t0
total = time.perf_counter() - t0
decode = n / (total - first) if first is not None and total > first else float("nan")
print(f"\nmodel: {model}")
print(f"time to first token: {first:.2f}s | tokens: {n} | decode: {decode:.1f} tok/s | total: {total:.1f}s")
PY

#!/usr/bin/env bash
# Backport upstream vLLM PR #40914 into the installed vLLM, which makes MTP
# speculative decoding safe on the 4-bit TurboQuant KV cache path.
#
#   bash patch-mtp.sh status     # is it applied?
#   bash patch-mtp.sh apply      # apply it (keeps a .pre40914.bak)
#   bash patch-mtp.sh revert     # restore the backup
#
# WHY THIS EXISTS
# serve.sh forces MTP off whenever CTX > 131072, because that switches the KV
# cache to turboquant_4bit_nc and stock vLLM 0.27.1 garbles output with the two
# combined: it captures the MTP verify step as a context-free first-chunk
# flash_attn FULL cudagraph (the capture dummy batch has seq_len == query_len),
# so the replayed graph never reads the KV cache and generation collapses into
# repetition loops while still answering HTTP 200 (upstream issue #40880).
#
# PR #40914 routes uniform K+1 spec-verify batches through the decode kernel
# with all-GPU synthetic args, which fixes it at the source. Once applied,
# serve.sh will keep MTP on at any context if you also pass
# QWEN5090_MTP_TQ_PATCHED=1 - it checks for this patch's marker in the file, so
# an env var alone can never re-enable the broken combination.
#
# Measured on an RTX 5090 (32 GB) at CTX=262144, MAX_SEQS=1, GPU_UTIL=0.93:
#   MTP off (stock)   52.6 tok/s
#   MTP-3 (patched)  139.3 tok/s   2.65x, 15/15 on the garble battery
#
# This edits a file inside the venv, so it must be re-applied after any
# reinstall of vLLM. It refuses to patch a layout it does not recognise rather
# than corrupting the file - if that happens, check whether #40914 has landed
# upstream before serving MTP on this path.
set -euo pipefail

VENV="${QWEN5090_VENV:-$HOME/.qwen5090/venv}"
MARKER="spec-verify routing (backport of PR #40914)"

TQ_FILE="$(ls "$VENV"/lib/python3*/site-packages/vllm/v1/attention/backends/turboquant_attn.py 2>/dev/null | head -1 || true)"
if [[ -z "$TQ_FILE" ]]; then
  echo "turboquant_attn.py not found under $VENV" >&2
  echo "(is vLLM installed? run scripts/setup-wsl.sh first)" >&2
  exit 1
fi
BAK="$TQ_FILE.pre40914.bak"

case "${1:-status}" in
  status)
    if grep -q "$MARKER" "$TQ_FILE"; then
      echo "APPLIED   $TQ_FILE"
      echo "          serve.sh will keep MTP on if QWEN5090_MTP_TQ_PATCHED=1 is set."
    else
      echo "NOT APPLIED   $TQ_FILE"
      echo "              MTP stays off above CTX=131072 (correct for stock vLLM)."
    fi
    ;;

  apply)
    if grep -q "$MARKER" "$TQ_FILE"; then
      echo "already applied - nothing to do"; exit 0
    fi
    cp "$TQ_FILE" "$BAK"
    "$VENV/bin/python" - "$TQ_FILE" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
ANCHOR = """        num_decodes = attn_metadata.num_decodes
        num_decode_tokens = attn_metadata.num_decode_tokens

        if not attn_metadata.is_prefill:"""
PATCH = """        num_decodes = attn_metadata.num_decodes
        num_decode_tokens = attn_metadata.num_decode_tokens

        # --- Spec-decode K+1 spec-verify routing (backport of PR #40914) ---
        # MTP verify produces uniform q_len=K+1 batches with prior cached KV.
        # FULL cudagraph capture feeds a dummy batch with seq_len == q_len, so
        # _prefill_attention would capture the first-chunk flash_attn branch
        # (cu_seqlens_k == cu_seqlens_q) - the replayed graph never reads the
        # KV cache and output degenerates into repetition loops (vllm#40880).
        # Route these batches through the decode kernel with all-GPU synth
        # args instead (same synth_seq_lens trick as the continuation path;
        # no CPU-side per-request branching, so capture/replay stay valid).
        _k1 = attn_metadata.max_query_len
        if (
            attn_metadata.is_prefill
            and num_decodes == 0
            and 1 < _k1 <= 16
            and attn_metadata.max_seq_len > _k1
            and N > 0
            and (N % _k1) == 0
            and attn_metadata.query_start_loc is not None
            and attn_metadata.query_start_loc.shape[0] == N // _k1 + 1
        ):
            _b = N // _k1
            _offs = torch.arange(_k1, device=device, dtype=attn_metadata.seq_lens.dtype)
            _synth_seq_lens = (
                attn_metadata.seq_lens[:_b, None] - _k1 + 1 + _offs[None, :]
            ).reshape(-1)
            _synth_bt = attn_metadata.block_table[:_b].repeat_interleave(_k1, dim=0)
            _synth_meta = TurboQuantMetadata(
                seq_lens=_synth_seq_lens,
                slot_mapping=attn_metadata.slot_mapping,
                block_table=_synth_bt,
                query_start_loc=attn_metadata.query_start_loc,
                num_actual_tokens=N,
                max_query_len=1,
                max_seq_len=attn_metadata.max_seq_len,
                is_prefill=False,
            )
            attn_out = self._decode_attention(
                q, kv_cache, _synth_meta, Pi, centroids, PiT, layer
            )
            if output.ndim == 3:
                output[:N] = attn_out.to(output.dtype)
            else:
                output[:N] = attn_out.reshape(N, -1).to(output.dtype)
            return output

        if not attn_metadata.is_prefill:"""
if src.count(ANCHOR) != 1:
    sys.exit("anchor not found - the installed vLLM no longer matches the 0.27.1 "
             "layout. Check whether PR #40914 has merged upstream before serving "
             "MTP on this path (stock MTP x TurboQuant garbles output).")
open(path, "w").write(src.replace(ANCHOR, PATCH))
PY
    "$VENV/bin/python" -c "import ast,sys; ast.parse(open('$TQ_FILE').read())"
    echo "applied   $TQ_FILE"
    echo "backup    $BAK"
    echo
    echo "Now serve with MTP on at the full window:"
    echo "  CTX=262144 MTP=1 QWEN5090_MTP_TQ_PATCHED=1 MAX_SEQS=1 GPU_UTIL=0.93 \\"
    echo "    bash app/scripts/serve.sh"
    ;;

  revert)
    if [[ ! -f "$BAK" ]]; then
      echo "no backup at $BAK - nothing to revert" >&2; exit 1
    fi
    cp "$BAK" "$TQ_FILE"
    echo "reverted  $TQ_FILE"
    echo "MTP is now forced off above CTX=131072 again, as it should be on stock vLLM."
    ;;

  *)
    echo "usage: bash patch-mtp.sh [status|apply|revert]" >&2; exit 2
    ;;
esac

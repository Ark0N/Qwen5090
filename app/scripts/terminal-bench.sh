#!/usr/bin/env bash
# Run Terminal-Bench 2.1 against a model served on the 5090, through the
# DeepSeek Harness.
#
#   bash terminal-bench.sh subset          # the pinned 15-task slice
#   bash terminal-bench.sh full            # all 89 tasks
#   bash terminal-bench.sh oracle          # no model: proves the pipeline works
#   bash terminal-bench.sh view            # browse the last run's trajectories
#
# Terminal-Bench 2.1 runs through Harbor, and Harbor runs every task in its own
# Docker container - so Docker has to be here, with the compose v2 CLI plugin.
#
# The number to beat is DeepSeek's own 82.7, measured on the full-precision
# V4-Flash-0731 through the API with the harness's minimal preset at the max
# thinking tier. Artificial Analysis got 79 on the same model with a different
# scaffold. Two things therefore have to be said about any number this prints:
# which checkpoint produced it, and that a quantized local build is not the
# model those figures describe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Where the model is, and what it is called there. Discovery fills MODEL in if
# it is not set, so the usual invocation names neither.
QWEN_URL="${QWEN_URL:-http://localhost:8000}"
MODEL="${MODEL:-}"
# The chat template decides which of these is legal: the Qwen builds take low,
# medium and xhigh and answer 400 to anything else; DeepSeek V4 has high and
# max. Left unset, it is chosen from the served model id below.
EFFORT="${EFFORT:-}"
CTX="${CTX:-131072}"
MAX_TOKENS="${MAX_TOKENS:-32768}"
# Harbor concurrency. One local server serves one request at a time in any
# useful sense, so more than a couple of concurrent trials just queues.
CONCURRENCY="${CONCURRENCY:-2}"
ATTEMPTS="${ATTEMPTS:-1}"
JOBS_DIR="${JOBS_DIR:-$HOME/.qwen5090/terminal-bench}"
DATASET="${DATASET:-terminal-bench/terminal-bench-2-1}"
AGENT_PATH="${AGENT_PATH:-app.scripts.tb_dsh_agent:DeepSeekHarness}"
MINIMAL="${MINIMAL:-true}"

# A deterministic slice of the 89, one in every six by name - the first fifteen
# alphabetically would be all b- and c- tasks. Pinned rather than computed so
# two runs a week apart compare.
SUBSET=(
  adaptive-rejection-sampler
  caffe-cifar-10
  compile-compcert
  db-wal-recovery
  feal-differential-cryptanalysis
  fix-ocaml-gc
  hf-model-inference
  log-summary-date-ranges
  model-extraction-relu-logits
  openssl-selfsigned-cert
  polyglot-rust-c
  pytorch-model-recovery
  regex-log
  sparql-university
  tune-mjcf
)

say()  { printf '>> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v harbor >/dev/null 2>&1 || die "harbor is not installed:  uv tool install harbor"
docker compose version >/dev/null 2>&1 || die "Harbor needs the Docker compose v2 CLI plugin.
       Without root:  mkdir -p ~/.docker/cli-plugins && curl -sSL -o ~/.docker/cli-plugins/docker-compose \\
         https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 && \\
         chmod +x ~/.docker/cli-plugins/docker-compose"

# The host the agent has to reach, for Harbor's agent-phase firewall. Without
# this every request from inside a task container is refused.
AGENT_HOST=$(printf '%s' "$QWEN_URL" | sed -E 's#^[a-z]+://##; s#[:/].*$##')

discover() {
  local json
  json=$(curl -sf -m 10 "$QWEN_URL/v1/models" 2>/dev/null || true)
  [[ -n "$json" ]] || die "no server answering at $QWEN_URL

Start one on the 5090 first, and if it is on another machine point this at it:
    QWEN_URL=http://<5090-ip>:8000 bash terminal-bench.sh subset"
  [[ -n "$MODEL" ]] || MODEL=$(printf '%s' "$json" | python3 -c '
import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')
  [[ -n "$MODEL" ]] || die "could not read a model id from $QWEN_URL/v1/models"
  if [[ -z "$EFFORT" ]]; then
    case "$MODEL" in
      *[Dd]eep[Ss]eek*) EFFORT=max ;;   # V4's own top tier
      *)                EFFORT=xhigh ;; # the Qwen template's default; "high" 400s
    esac
  fi
}

run_job() {
  local name="$1"; shift
  discover
  say "dataset  : $DATASET"
  say "model    : $MODEL @ $QWEN_URL (effort=$EFFORT, ctx=$CTX)"
  say "agent    : $AGENT_PATH (minimal=$MINIMAL)"
  say "results  : $JOBS_DIR"
  mkdir -p "$JOBS_DIR"
  # Run from the repo root so the agent import path resolves.
  cd "$REPO_ROOT"
  PYTHONPATH="$REPO_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
  harbor run \
    -d "$DATASET" \
    -a "$AGENT_PATH" \
    -m "$MODEL" \
    --ak "base_url=$QWEN_URL/v1" \
    --ak "effort=$EFFORT" \
    --ak "minimal=$MINIMAL" \
    --ak "context_window=$CTX" \
    --ak "max_tokens=$MAX_TOKENS" \
    --allow-agent-host "$AGENT_HOST" \
    --job-name "$name" \
    --jobs-dir "$JOBS_DIR" \
    -n "$CONCURRENCY" \
    -k "$ATTEMPTS" \
    -y \
    "$@"
}

summarize() {
  local latest
  latest=$(ls -dt "$JOBS_DIR"/*/ 2>/dev/null | head -1 || true)
  [[ -n "$latest" ]] || return 0
  python3 - "$latest/result.json" <<'PY' || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
s = d.get("stats", {})
print()
print(f"  trials    : {d.get('n_total_trials')}  "
      f"completed {s.get('n_completed_trials')}  errored {s.get('n_errored_trials')}")
for name, ev in (s.get("evals") or {}).items():
    for metric in ev.get("metrics") or []:
        mean = metric.get("mean")
        if mean is not None:
            print(f"  accuracy  : {mean * 100:.1f}%   ({ev.get('n_trials')} trials, "
                  f"{ev.get('n_errors')} errors)")
    if ev.get("exception_stats"):
        print(f"  exceptions: {ev['exception_stats']}")
print()
print("  Reference: 82.7 is DeepSeek's own figure for the full-precision")
print("  V4-Flash-0731 through the API; Artificial Analysis measured 79 on the")
print("  same model with a different scaffold. A quantized local build is not")
print("  that model - say which checkpoint produced this number.")
PY
}

cmd="${1:-subset}"
if (( $# > 0 )); then shift; fi

case "$cmd" in
  subset)
    args=()
    # Task ids reach harbor dataset-prefixed. A bare `-i openssl-selfsigned-cert`
    # is `ValueError: No tasks matched the filter(s)` on harbor 0.22.0, which
    # kills the whole subset loop; it wants `-i terminal-bench/openssl-...`.
    # Taken off $DATASET rather than hardcoded, so overriding the dataset
    # carries the prefix with it.
    for t in "${SUBSET[@]}"; do args+=(-i "${DATASET%%/*}/$t"); done
    run_job "subset-$(date +%Y%m%d-%H%M%S)" "${args[@]}" "$@"
    summarize ;;
  full)
    run_job "full-$(date +%Y%m%d-%H%M%S)" "$@"
    summarize ;;
  oracle)
    # No model and no agent of ours: the task's own solution is applied, so
    # anything below 100% is a broken pipeline rather than a weak model.
    say "oracle run - proves Docker, the dataset and the verifier work here"
    mkdir -p "$JOBS_DIR"
    harbor run -d "$DATASET" -a oracle -l "${1:-3}" -n "$CONCURRENCY" -y --jobs-dir "$JOBS_DIR"
    summarize ;;
  view)
    harbor view "$JOBS_DIR" ;;
  tasks)
    printf '%s\n' "${SUBSET[@]}" ;;
  -h|--help|help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$cmd' - try: subset full oracle view tasks" ;;
esac

#!/usr/bin/env bash
# Shared helper, meant to be *sourced*: the two things every backend on this
# box should do to the GPU before it starts serving, and one of them is the
# only reason the crash investigation in CLAUDE.md has any evidence at all.
#
# Extracted from serve.sh when NInfer became the third backend. Telemetry that
# only one of three serving paths records is worse than none: the open question
# on this machine is whether an Xid 79 / 0x116 "GPU has fallen off the bus" is
# a power-delivery transient, and a crash on an unrecorded backend would be a
# ninth incident with nothing to read. Neither function is backend-specific -
# they talk to nvidia-smi, not to a server.
#
#   qwen5090_apply_power_limit          honour GPU_POWER_LIMIT, warn-only
#   qwen5090_start_telemetry <logdir>   sample the card until this shell dies

# GPU power-limit cap. Unset by default, and it must stay that way: silently
# reconfiguring someone's hardware because they double-clicked a launcher is
# not this script's business. Set GPU_POWER_LIMIT=450 to have the serving
# script apply `nvidia-smi -pl` before every start - the standing test for
# whether the crash is a power-delivery transient. Applying it on every start
# rather than once by hand is the point: persistence mode is Disabled on the
# test box, so the cap is lost on every driver unload, i.e. on every reboot -
# exactly when the next soak run would otherwise quietly revert to 600 W and
# waste the test.
#
# Needs root, and never blocks the start: a warning is the entire failure mode,
# because a server that refuses to come up teaches nothing about a crash. The
# limit that actually took effect is in the telemetry file either way - every
# sample carries power.limit - so a warning that gets ignored cannot corrupt
# the record.
qwen5090_apply_power_limit() {
  local limit="${GPU_POWER_LIMIT:-}"
  [[ -n "$limit" ]] || return 0
  command -v nvidia-smi >/dev/null 2>&1 || return 0

  local pl_rc=0
  if [[ "$(id -u)" == "0" ]]; then
    nvidia-smi -pl "$limit" >/dev/null 2>&1 || pl_rc=$?
  elif sudo -n true 2>/dev/null; then
    sudo -n nvidia-smi -pl "$limit" >/dev/null 2>&1 || pl_rc=$?
  else
    pl_rc=126
  fi

  if [[ $pl_rc -eq 0 ]]; then
    echo ">> GPU power limit set to ${limit} W (GPU_POWER_LIMIT)"
  elif [[ $pl_rc -eq 126 ]]; then
    echo ">> WARNING: GPU_POWER_LIMIT=${limit} needs root and sudo asked for a password." >&2
    echo ">>          Run 'sudo nvidia-smi -pl ${limit}' yourself; starting at the current limit." >&2
  else
    echo ">> WARNING: could not set the GPU power limit (nvidia-smi rc=$pl_rc); starting at the current limit." >&2
  fi
  return 0
}

# GPU telemetry. On 2026-08-21 an Xid 79 ("GPU has fallen off the bus") took
# the Linux 5090 down mid-decode and left nothing behind but the driver's own
# obituary - no power, temperature, clock or PCIe history for the seconds
# before it went. Six 0x116 bugchecks on the Windows box had already burned
# five theories for want of exactly that data, so sample it and keep it.
#
# Deliberately named .log rather than .csv: collect-logs.ps1 bundles
# logs/*.log into the bug-report ZIP, and this is the one file such a report
# most needs. It is hardware counters only - no prompts, no completions, so it
# is safe to collect in a way that ~/.qwen5090/debug/payloads-*.jsonl is not.
#
# Call this from the script that is about to `exec` the server, and only from
# there: it watches $$, which exec turns into the server's own PID. Called from
# a subshell it would watch the wrong process and stop sampling immediately.
qwen5090_start_telemetry() {
  local log_dir="${1:?qwen5090_start_telemetry needs a log directory}"
  [[ "${GPU_TELEMETRY:-1}" == "1" ]] || return 0
  command -v nvidia-smi >/dev/null 2>&1 || return 0

  local interval="${GPU_TELEMETRY_INTERVAL:-2}"
  # Declared and assigned separately: `local x=$(cmd)` swallows cmd's exit
  # status, which is the same landmine as a bare assignment under `set -e`.
  local stamp file
  stamp=$(date +%Y%m%d-%H%M%S)
  file="$log_dir/gpu-telemetry-$stamp.log"
  local watch_pid=$$
  (
    # A fallen-off GPU makes nvidia-smi block rather than fail, so every call
    # is bounded - and the failure line is itself the most valuable record in
    # the file, because it timestamps the moment the card stopped answering.
    fields=timestamp,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.mem
    fields=$fields,utilization.gpu,utilization.memory,memory.used
    fields=$fields,pcie.link.gen.current,pcie.link.width.current
    fields=$fields,clocks_event_reasons.hw_slowdown,clocks_event_reasons.sw_power_cap
    echo "# qwen5090 GPU telemetry, every ${interval}s, while PID $watch_pid lives"
    echo "# $fields"
    while kill -0 "$watch_pid" 2>/dev/null; do
      rc=0
      timeout 5 nvidia-smi --query-gpu="$fields" \
        --format=csv,noheader,nounits 2>&1 || rc=$?
      if [[ $rc -ne 0 ]]; then
        echo "$(date '+%Y/%m/%d %H:%M:%S.000'), NVIDIA-SMI FAILED OR TIMED OUT (rc=$rc)"
      fi
      sleep "$interval"
    done
    echo "# server PID $watch_pid gone at $(date '+%Y/%m/%d %H:%M:%S'); telemetry stopped"
  ) >> "$file" 2>&1 &
  echo ">> GPU telemetry -> $file (every ${interval}s; GPU_TELEMETRY=0 disables)"
  return 0
}

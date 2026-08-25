#!/usr/bin/env python3
"""Self-optimization loop for the Qwen5090 stack (dsh harness + ninfer server).

Runs forever, one "round" at a time:

  phase A (harness):  screen untried (persona x effort) combos on the 4-task
                      subset against the live server, then full-run (12 tasks)
                      the top new combo and the incumbent harness.
  phase B (server):   screen untried serving-flag candidates on the subset
                      (swapping the live server between candidates, guarded by
                      a quiet-time check so an active dsh conversation is not
                      killed mid-request), then full-run the best candidate
                      and the incumbent server.
  promote:            the best harness effort is written into the dsh
                      settings (agent-default-model.reasoningEffort); the
                      winning server flags stay on the live server.

State:  state.json          best configs, tried space, history
        server.flags        the flags the live server runs on (loop-managed)
        heartbeat.json      liveness for observers (mtime = last beat)
        logs/rounds/NNN.json per-round detail
        logs/loop.log       human-readable trace

Stop:   touch STOP          (checked between steps and before server swaps)
Status: python3 loop.py status
"""

from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys
import time
import traceback

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)

import bench  # noqa: E402
import tb_agent  # noqa: E402
import tasks as T  # noqa: E402

STATE_FILE = os.path.join(ROOT, "state.json")
FLAGS_FILE = os.path.join(ROOT, "server.flags")
INCUMBENT_FLAGS_FILE = os.path.join(ROOT, "server.flags.incumbent")
HEARTBEAT_FILE = os.path.join(ROOT, "heartbeat.json")
MODE_FILE = os.path.join(ROOT, "mode.json")
LOG_FILE = os.path.join(ROOT, "logs", "loop.log")
ROUNDS_DIR = os.path.join(ROOT, "logs", "rounds")
STOP_FILE = os.path.join(ROOT, "STOP")
LOOP_PID_FILE = os.path.join(ROOT, ".loop.pid")
WATCHDOG_PID_FILE = os.path.join(ROOT, ".watchdog.lock")
REQUEST_LOG = os.path.join(ROOT, "logs", "server-requests.jsonl")

SERVE_CTL = os.path.join(ROOT, "serve_ctl.sh")
DSH_SETTINGS = os.path.expanduser("~/.dsh/settings.yaml")

MODEL = tb_agent.DEFAULT_MODEL
BASE_URL = tb_agent.DEFAULT_BASE_URL

HARNESS_EFFORTS = ["none", "low", "medium", "xhigh"]
HARNESS_PROMPTS = ["minimal", "tb", "structured"]
SCREENING_PER_ROUND = 4
SERVER_PER_ROUND = 2
FULL_RUNS_PER_ROUND = 3

SUBSET_IDS = [t["id"] for t in T.SUBSET]
ALL_IDS = [t["id"] for t in T.ALL]


def log(msg: str) -> None:
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


def stopped() -> bool:
    return os.path.exists(STOP_FILE)


def heartbeat(event: str, **extra) -> None:
    hb = {
        "ts": time.time(),
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "event": event,
    }
    hb.update(extra)
    mode = read_mode()
    if mode:
        hb["mode"] = mode.get("mode")
        hb["candidate"] = mode.get("candidate")
    with open(HEARTBEAT_FILE, "w") as f:
        json.dump(hb, f, indent=2)


# ---------------------------------------------------------- mode protocol
#
# One GPU, one model slot: the harness (the dsh session this loop exists for),
# the benchmark agent and the verifier all share the same server on :8000.
# The system therefore time-slices. mode.json is the contract between the two
# sides: the loop writes it, the harness (and anything driven by the harness)
# reads it before doing heavy work.
#
#   harness          server on best-known flags, probe passed -> heavy work OK
#   candidate-testing server on candidate flags -> keep harness footprint
#                    minimal (short turns, no long subagents; the candidate may
#                    run at a smaller context window and may be unstable)
#   recovering       server down or unhealthy; the loop is repairing it

def set_mode(mode: str, candidate=None, note: str = "", flags_sig: str = None) -> None:
    doc = {
        "mode": mode,
        "candidate": candidate,
        "flags_sig": flags_sig,
        "note": note,
        "since": time.time(),
        "since_str": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    tmp = MODE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2)
    os.replace(tmp, MODE_FILE)
    log(f"mode: {mode}" + (f" (candidate={candidate})" if candidate else "")
        + (f" - {note}" if note else ""))


def read_mode() -> dict:
    try:
        with open(MODE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


PROBE_QUESTION = "What is 17 times 23? Reply with only the number, no words."
PROBE_ANSWER = "391"


def probe_server(effort: str = "low", attempts: int = 3, timeout: int = 90) -> tuple:
    """Deterministic health probe: a short generation that must contain the
    right answer. Catches dead servers (HTTP/transport errors) and degenerate
    output (the MTP-garble failure mode: repetitions or empty content)."""
    last = "unreachable"
    for i in range(attempts):
        # NB: no STOP check in the probe loop. The probe IS the safety verdict
        # (its result sets the mode), so it must always complete and report
        # the truth; STOP merely ends the round, and a probe aborted by STOP
        # once mislabeled a healthy server as "unreachable"/recovering.
        try:
            import urllib.request
            body = json.dumps({
                "model": MODEL,
                "messages": [{"role": "user", "content": PROBE_QUESTION}],
                "max_tokens": 256,
                "reasoning_effort": effort,
                "stream": False,
            }).encode()
            req = urllib.request.Request(
                "http://127.0.0.1:8000/v1/chat/completions",
                data=body, headers={"content-type": "application/json"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                resp = json.loads(r.read().decode())
            msg = resp["choices"][0]["message"]
            content = (msg.get("content") or "").strip()
            finish = resp["choices"][0].get("finish_reason")
            # Strict answer check: this is the primary gate. finish_reason
            # alone is NOT a failure: reasoning tokens bill against
            # max_tokens, so a correct short answer can arrive with
            # finish=length. But a repetition like "391391391..." (the MTP
            # garble mode) must fail, so the content must be almost exactly
            # the answer.
            core = content.rstrip(".! ").strip()
            if not core:
                last = f"empty content (finish={finish})"
            elif core != PROBE_ANSWER and not (core.startswith(PROBE_ANSWER) and len(core) <= 8):
                last = f"wrong/garbled answer: {content[:120]!r} (finish={finish})"
            else:
                return True, f"ok ({content!r}, finish={finish})"
        except Exception as e:
            last = f"{type(e).__name__}: {e}"[:200]
        time.sleep(5)
    return False, last


def load_state() -> dict:
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            return json.load(f)
    return {}


def save_state(state: dict) -> None:
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, STATE_FILE)


def read_flags_file() -> list:
    if not os.path.exists(FLAGS_FILE):
        return []
    with open(FLAGS_FILE) as f:
        return [ln.strip() for ln in f if ln.strip()]


def write_flags_file(flags: list) -> None:
    with open(FLAGS_FILE, "w") as f:
        f.write("\n".join(flags) + "\n")


def live_server_flags() -> list:
    """Command line of the running server, one arg per item (binary stripped,
    same convention as server.flags)."""
    out = subprocess.run(["pgrep", "-f", "ninfer-serve /root/.qwen5090"],
                         capture_output=True, text=True).stdout
    pids = out.split()
    if not pids:
        return []
    pid = pids[0]
    with open(f"/proc/{pid}/cmdline", "rb") as f:
        raw = f.read().decode(errors="replace").split("\0")
    args = [a for a in raw if a]
    if args and os.path.basename(args[0]) == "ninfer-serve":
        args = args[1:]
    return args


def server_up() -> bool:
    try:
        r = subprocess.run(["curl", "-s", "-m", "3", "-o", "/dev/null", "-w", "%{http_code}",
                            "http://127.0.0.1:8000/v1/models"],
                           capture_output=True, text=True, timeout=10)
        return r.stdout.strip() == "200"
    except Exception:
        return False


# ---------------------------------------------------------------- quiet guard

def session_mtime_age() -> float:
    newest = 0.0
    patterns = [
        os.path.expanduser("~/.dsh/sessions/*/*/session.jsonl.zstd"),
        os.path.expanduser("~/.dsh/sessions/*/session.jsonl.zstd"),
    ]
    for pat in patterns:
        for p in glob.glob(pat):
            try:
                newest = max(newest, os.path.getmtime(p))
            except OSError:
                pass
    return time.time() - newest if newest else 1e9


def gpu_util() -> int:
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10).stdout
        return max(int(x) for x in re.findall(r"\d+", out))
    except Exception:
        return 100  # unreadable GPU -> treat as busy


def wait_quiet(max_wait: int = 900, event: str = "waiting") -> bool:
    """Block until the GPU is quiet and no dsh conversation is fresh.

    Quiet means: no harness session file written in the last 60 s AND six GPU
    utilization samples (one per 4 s) all below 10%. Returns False if it never
    became quiet within max_wait (caller must skip the risky step).
    """
    deadline = time.time() + max_wait
    while time.time() < deadline:
        if stopped():
            return False
        age = session_mtime_age()
        if age < 60:
            heartbeat(f"{event}: dsh conversation active (session written {int(age)}s ago)")
            time.sleep(30)
            continue
        busy = False
        for _ in range(6):
            if stopped():
                return False
            if gpu_util() >= 10:
                busy = True
            time.sleep(4)
        if not busy:
            return True
        heartbeat(f"{event}: GPU busy, deferring")
        time.sleep(30)
    return False


# ------------------------------------------------------------- server control

def run_ctl(cmd: str, timeout: int = 300):
    return subprocess.run(["bash", SERVE_CTL, cmd], capture_output=True, text=True,
                          timeout=timeout)


def ensure_request_log_rotated() -> None:
    for p in [REQUEST_LOG, REQUEST_LOG + ".1"]:
        if os.path.exists(p) and os.path.getsize(p) > 50_000_000:
            os.replace(p, p + ".old")
            try:
                os.remove(p + ".old")
            except OSError:
                pass


def swap_server(flags: list, label: str, restore_flags: list = None) -> str:
    """Stop the live server, start it with `flags`, probe it. Roll back on
    failure (to restore_flags, else to the pre-swap flags). Never leaves the
    machine without a serving model: a failed candidate rolls back, and a
    failed rollback keeps retrying the known-good flags until the probe
    passes, with the mode set to `recovering` in the meantime.

    Returns "ok" | "deferred" | "failed".
    """
    current = read_flags_file() or live_server_flags()
    if flags == current:
        log(f"swap({label}): flags unchanged, skipping")
        return "ok"
    log(f"swap({label}): switching server (flags {flags_sig(flags) if flags else 'empty'})")
    if not wait_quiet(event=f"swap {label}"):
        log(f"swap({label}): deferred - GPU/harness still busy after waiting")
        return "deferred"

    fallback = restore_flags or current
    set_mode("candidate-testing", label, "swapping server", flags_sig(flags))
    r = run_ctl("stop", timeout=120)
    log(f"swap({label}): stop rc={r.returncode} {r.stdout.strip()[:120]}")
    write_flags_file(flags)
    r = run_ctl("start", timeout=300)
    if not (r.returncode == 0 and server_up()):
        log(f"swap({label}): FAILED to start (rc={r.returncode}); rolling back")
        # Head of stderr carries the serve_ctl ERROR line + the grepped
        # engine error; the tail is usually just the usage block.
        log(r.stderr[:600])
        _restore_server(fallback, label)
        return "failed"

    ok, detail = probe_server(attempts=3)
    if ok:
        log(f"swap({label}): up and healthy ({detail})")
        return "ok"
    log(f"swap({label}): server up but probe failed ({detail}); rolling back")
    _restore_server(fallback, label)
    return "failed"


def _restore_server(fallback: list, label: str) -> None:
    """Land the server on `fallback` flags, verified by the probe."""
    set_mode("recovering", None, f"candidate {label} failed; restoring")
    prev = read_flags_file()
    if fallback and fallback != prev:
        write_flags_file(fallback)
        run_ctl("stop", timeout=120)
    for attempt in range(50):
        if stopped():
            return
        r = run_ctl("start", timeout=300)
        if r.returncode == 0 and server_up():
            ok, detail = probe_server(attempts=2)
            if ok:
                log(f"_restore_server: healthy on restore flags ({detail}), attempt {attempt + 1}")
                set_mode("harness", None, f"recovered after {label} failure",
                         flags_sig(fallback))
                return
        log(f"_restore_server: attempt {attempt + 1} not healthy; retrying in 30s")
        time.sleep(30)


# ------------------------------------------------------------------- dsh cfg

def dsh_current_effort() -> str:
    try:
        with open(DSH_SETTINGS) as f:
            lines = f.read().splitlines()
        in_block = False
        for ln in lines:
            if ln.startswith("agent-default-model:"):
                in_block = True
                continue
            if in_block and re.match(r"^\S", ln):
                break
            if in_block:
                m = re.match(r"^\s*reasoningEffort:\s*(\S+)", ln)
                if m:
                    return m.group(1)
    except Exception:
        pass
    return "xhigh"


def promote_effort(effort: str) -> None:
    cur = dsh_current_effort()
    if cur == effort:
        return
    if not re.fullmatch(r"none|low|medium|xhigh", effort or ""):
        return
    with open(DSH_SETTINGS) as f:
        lines = f.read().splitlines(keepends=True)
    in_block = False
    changed = False
    for i, ln in enumerate(lines):
        if ln.startswith("agent-default-model:"):
            in_block = True
            continue
        if in_block and re.match(r"^\S", ln):
            in_block = False
        if in_block and re.match(r"^\s*reasoningEffort:", ln):
            lines[i] = f"  reasoningEffort: {effort}\n"
            changed = True
    if not changed:
        log("promote_effort: no agent-default-model.reasoningEffort line found; skipping")
        return
    backup = DSH_SETTINGS + f".bak-{time.strftime('%Y%m%d-%H%M%S')}"
    with open(backup, "w") as f:
        f.writelines(lines)
    # backup first with the OLD content
    with open(DSH_SETTINGS) as f:
        old = f.read()
    with open(backup, "w") as f:
        f.write(old)
    with open(DSH_SETTINGS, "w") as f:
        f.writelines(lines)
    log(f"promoted harness effort {cur} -> {effort} in {DSH_SETTINGS} (backup {os.path.basename(backup)})")


# --------------------------------------------------------------------- bench

def run_bench(cfg: dict, task_sel: str, tag: str, workers: int = 2) -> dict:
    """Run the suite; return the summary dict. Retries the whole suite once on
    >50% server errors (server may have been mid-swap)."""
    for attempt in (1, 2):
        summary = bench_main(cfg, task_sel, tag)
        if summary["n"] > 0 and summary["errors"] > summary["n"] / 2 and attempt == 1:
            log(f"bench({tag}): {summary['errors']}/{summary['n']} server errors - rerunning suite once")
            time.sleep(20)
            continue
        return summary
    return summary


def bench_main(cfg: dict, task_sel: str, tag: str) -> dict:
    runid = time.strftime("%Y%m%d-%H%M%S") + f"-{tag[:24]}"
    base = os.path.join(ROOT, "results", runid)
    os.makedirs(base, exist_ok=True)
    import concurrent.futures

    sel = T.SUBSET if task_sel == "subset" else T.ALL
    results = []
    t0 = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        futs = {
            ex.submit(tb_agent.run_task, t, cfg, os.path.join(base, "work", t["id"])): t
            for t in sel
        }
        for fut in concurrent.futures.as_completed(futs):
            r = fut.result()
            results.append(r)
            with open(os.path.join(base, "results.jsonl"), "a") as f:
                f.write(json.dumps({k: r[k] for k in
                                    ("task", "passed", "wall_s", "iterations", "tool_calls",
                                     "prompt_tokens", "completion_tokens", "error")}) + "\n")
            log(f"  task {r['task']}: {'PASS' if r['passed'] else 'FAIL'} "
                f"({r['wall_s']}s, {r['iterations']} iter, "
                f"{r['prompt_tokens'] + r['completion_tokens']} tok"
                + (f", err={r['error'][:80]}" if r["error"] else "") + ")")
    s = bench.summarize(results, cfg)
    s["runid"] = runid
    s["tag"] = tag
    s["suite"] = task_sel
    s["suite_wall_s"] = round(time.time() - t0, 1)
    with open(os.path.join(base, "summary.json"), "w") as f:
        json.dump(s, f, indent=2)
    return s


# ---------------------------------------------------------------------- grid

def harness_key(prompt: str, effort: str) -> str:
    return f"{prompt}|{effort}"


def harness_grid() -> list:
    """Screening order: fast efforts first, all three personas."""
    grid = []
    for effort in HARNESS_EFFORTS:
        for prompt in HARNESS_PROMPTS:
            grid.append((prompt, effort))
    return grid


def server_base_flags() -> list:
    """STABLE baseline for the candidate grid: the original pre-optimization
    flags, NOT the live flags file. Deriving candidates from the live/best
    flags would make the grid drift after every promotion (a candidate
    labeled 'pc4096' would silently become 'dt4 + pc4096' once dt4 was
    promoted) and break tried_server accounting, because the same label
    then maps to a different flags_sig each round. The search is over fixed
    mutations of the known starting point."""
    incumbent = os.path.join(ROOT, "server.flags.incumbent")
    try:
        with open(incumbent) as f:
            flags = [ln.strip() for ln in f if ln.strip()]
        if flags:
            return flags
    except OSError:
        pass
    return [
        "/root/.qwen5090/ninfer/models/qwen3_8_27b_nvfp4.ninfer",
        "--host", "0.0.0.0", "--port", "8000",
        "--max-context", "252928",
        "--kv-capacity", "auto", "--kv-dtype", "int8",
        "--max-concurrency", "2", "--prefill-chunk", "1024",
        "--spec", "mtp", "--draft-tokens", "3", "--lm-head-draft",
    ]


def _mutate(base: list, pairs: list, adds: list = None, removes: list = None) -> list:
    out = []
    skip = set()
    for rm in removes or []:
        if rm in base:
            i = base.index(rm)
            skip.add(i)
            if i + 1 < len(base) and not base[i + 1].startswith("--"):
                skip.add(i + 1)
    # NB: a `for` loop with a manual `i += 1` does NOT skip the next element
    # (enumerate resets i each iteration) - this must be a while loop,
    # otherwise the replaced flag keeps its old value (e.g.
    # --draft-tokens 4 3).
    i = 0
    while i < len(base):
        f = base[i]
        if i in skip:
            i += 1
            continue
        matched = False
        for name, val in pairs:
            if f == name:
                out.extend([name, val])
                if i + 1 < len(base) and not base[i + 1].startswith("--"):
                    i += 2  # drop the old value
                else:
                    i += 1
                matched = True
                break
        if not matched:
            out.append(f)
            i += 1
    for a in adds or []:
        if a not in out:
            out.append(a)
    return out


def flags_sig(flags: list) -> str:
    return "|".join(flags)


def with_request_log(flags: list) -> list:
    """Every loop-managed server run carries the request log (audit trail).
    Normalize any flag set to that convention. NB: tried_s / server_best /
    live flags must all be compared and stored in this form, or the same
    physical config ends up under two different flags_sig keys (the bug that
    crashed round 5: server_best held the pre-request-log incumbent)."""
    if "--request-log-jsonl" in flags:
        return flags
    return flags + ["--request-log-jsonl", REQUEST_LOG]


def server_candidates(base: list) -> list:
    """(label, flags) candidates derived from the base flag set."""
    cands = []

    def add(label, flags):
        cands.append((label, with_request_log(flags)))

    add("incumbent", base)
    add("dt4", _mutate(base, [("--draft-tokens", "4")]))
    add("dt5", _mutate(base, [("--draft-tokens", "5")]))
    add("pc4096", _mutate(base, [("--prefill-chunk", "4096")]))
    add("conc4", _mutate(base, [("--max-concurrency", "4")]))
    # NOTE: the prefill-chunk 4096 composites (dt4-pc4096 / dt5-pc4096) and
    # conc4-dt5 are deliberately NOT candidates: measured 2026-08-25, this
    # 32 GB card at the 252,928-token int8 window is VRAM-bound at startup -
    # "minimum Engine runtime reservation requires N bytes ... but only
    # 11,245,380,608 bytes are available after weights". The base config
    # (conc 2, dt 3, pc 1024) fits; --prefill-chunk 4096 alone needs 10.66 GB
    # and --max-concurrency 4 alone needs 10.89 GB (both refused to start),
    # and any config that adds draft slots on top only grows the reservation.
    # pc4096 is kept so the loop records the measured failure once.
    add("preserve-thinking", _mutate(base, [], adds=["--preserve-thinking"]))
    add("temp06", _mutate(base, [], adds=["--temperature", "0.6", "--top-p", "0.95"]))
    # bf16 KV needs ~2x the int8 pool, so probe it at a smaller window
    add("ctx98k-bf16", _mutate(base, [("--max-context", "98304"), ("--kv-dtype", "bf16")]))
    return cands


def suite_fingerprint() -> str:
    """Hash of the full task list; a change means full-run scores from the old
    suite are not comparable and must be invalidated."""
    import hashlib
    return hashlib.md5("".join(t["id"] for t in T.ALL).encode()).hexdigest()[:12]


# --------------------------------------------------------------------- score

def better(a: dict, b: dict) -> bool:
    """a beats b: more passes, then fewer tokens, then less wall time."""
    if a["passed"] != b["passed"]:
        return a["passed"] > b["passed"]
    ta = a["total_prompt_tokens"] + a["total_completion_tokens"]
    tb = b["total_prompt_tokens"] + b["total_completion_tokens"]
    if ta != tb:
        return ta < tb
    return a["avg_wall_s"] < b["avg_wall_s"]


# --------------------------------------------------------------------- round

def round_fn(state: dict) -> None:
    state["round"] = state.get("round", 0) + 1
    n = state["round"]
    log(f"===== round {n} start =====")
    heartbeat(f"round {n} start")

    ensure_request_log_rotated()
    if not server_up():
        log("server is down at round start - restoring best-known flags and starting")
        set_mode("recovering", None, "server down at round start")
        best_flags = (state.get("server_best") or {}).get("flags") or read_flags_file()
        r = run_ctl("start", timeout=300) if read_flags_file() else None
        if not (r and r.returncode == 0 and server_up()):
            if best_flags:
                write_flags_file(best_flags)
                r = run_ctl("start", timeout=300)
            if not (r and r.returncode == 0 and server_up()):
                log(f"FATAL: cannot start server: {r.stderr[-500:] if r else 'no flags'}")
                return
        time.sleep(10)
    ok, detail = probe_server(attempts=2)
    if not ok:
        log(f"round start: probe failed ({detail}) - restarting on best-known flags")
        set_mode("recovering", None, f"round start probe failed: {detail[:120]}")
        best_flags = (state.get("server_best") or {}).get("flags") or read_flags_file()
        if best_flags:
            write_flags_file(best_flags)
            run_ctl("stop", timeout=120)
            r = run_ctl("start", timeout=300)
        ok, detail = probe_server(attempts=3)
        if not ok:
            log(f"round {n}: server still unhealthy ({detail}); skipping round, retrying next")
            heartbeat(f"round {n} skipped: server unhealthy", mode="recovering")
            return
    # normalise the mode for the harness: the server is on known-good flags and healthy
    set_mode("harness", None, f"round {n} start", flags_sig(read_flags_file()))

    def harness_cfg(prompt: str, effort: str, **over) -> dict:
        c = {
            "prompt": prompt,
            "effort": effort,
            "max_tokens": state.get("harness_best", {}).get("max_tokens", 16384),
            "max_iterations": state.get("harness_best", {}).get("max_iterations", 30),
            "base_url": BASE_URL,
            "model": MODEL,
        }
        c.update(over)
        return c

    # ---------------- phase A: harness ----------------
    hb = state.setdefault("harness_best", {
        "prompt": "minimal", "effort": dsh_current_effort(),
        "max_tokens": 16384, "max_iterations": 30,
        "subset": 0, "full": None, "tokens": None, "wall": None, "ts": 0,
    })
    tried_h = state.setdefault("tried_harness", {})

    untried = [(p, e) for p, e in harness_grid() if harness_key(p, e) not in tried_h]
    # invalidate full-run scores from a different task suite. NB: tried_s/sb
    # are defined later (phase B) - reference them through state here.
    fp = suite_fingerprint()
    if state.get("suite_fp") != fp:
        log(f"suite fingerprint changed ({state.get('suite_fp')} -> {fp}): "
            f"{len(T.ALL)} tasks - invalidating full-run results from the old suite")
        for rec in tried_h.values():
            for k in ("full", "tokens", "wall"):
                rec.pop(k, None)
        for rec in state.get("tried_server", {}).values():
            for k in ("full", "tokens", "wall"):
                rec.pop(k, None)
        for best in (hb, state.get("server_best") or {}):
            best["full"] = None
            best["tokens"] = None
            best["wall"] = None
        state["suite_fp"] = fp
        save_state(state)
    screened = []
    for prompt, effort in untried[:SCREENING_PER_ROUND]:
        if stopped():
            return
        key = harness_key(prompt, effort)
        log(f"[A] screening harness {key} on subset")
        heartbeat(f"screening harness {key}")
        s = run_bench(harness_cfg(prompt, effort), "subset", f"h-{key}")
        rec = {"subset": s["passed"], "ts": time.time(), "suite_wall_s": s["suite_wall_s"]}
        tried_h[key] = rec
        screened.append((key, s["passed"]))
        save_state(state)
        log(f"[A] {key}: {s['passed']}/{s['n']} in {s['suite_wall_s']}s")

    if screened:
        screened.sort(key=lambda kv: -kv[1])
        top_key, top_score = screened[0]
        p, e = top_key.split("|")
        # full-run: the top new combo + the incumbent harness (dedup)
        fulls = [(p, e)]
        cur = harness_key(hb["prompt"], hb["effort"])
        if cur != top_key:
            fulls.append((hb["prompt"], hb["effort"]))
        for i, (pp, ee) in enumerate(fulls[:FULL_RUNS_PER_ROUND]):
            if stopped():
                return
            key = harness_key(pp, ee)
            log(f"[A] full run harness {key}")
            heartbeat(f"full run harness {key}")
            s = run_bench(harness_cfg(pp, ee), "all", f"hf-{key}")
            tried_h[key]["full"] = s["passed"]
            tried_h[key]["tokens"] = s["total_prompt_tokens"] + s["total_completion_tokens"]
            tried_h[key]["wall"] = s["suite_wall_s"]
            save_state(state)
            log(f"[A] full {key}: {s['passed']}/{s['n']} ({s['suite_wall_s']}s, "
                f"{s['total_prompt_tokens'] + s['total_completion_tokens']} tok)")
            cand = {**hb, "prompt": pp, "effort": ee,
                    "full": s["passed"], "tokens": s["total_prompt_tokens"] + s["total_completion_tokens"],
                    "wall": s["suite_wall_s"], "ts": time.time()}
            ref = {**hb, "full": hb.get("full") or 0,
                   "tokens": hb.get("tokens") or float("inf"), "wall": hb.get("wall") or float("inf")}
            if cand["full"] > ref["full"] or (cand["full"] == ref["full"] and
                                              cand["tokens"] < ref["tokens"]):
                hb.update(cand)
                save_state(state)
                log(f"[A] NEW BEST HARNESS: {pp}|{ee} full={cand['full']}/{s['n']}")
    promote_effort(hb.get("effort"))

    # ---------------- phase B: server ----------------
    sb = state.setdefault("server_best", {
        "label": "incumbent", "flags": read_flags_file() or live_server_flags(),
        "subset": 0, "full": None, "tokens": None, "wall": None, "ts": 0,
    })
    # heal a stale pre-request-log server_best in place (and persist it)
    if sb.get("flags"):
        healed = with_request_log(sb["flags"])
        if healed != sb["flags"]:
            sb["flags"] = healed
            save_state(state)
    tried_s = state.setdefault("tried_server", {})
    base = server_base_flags()
    cands = [(label, flags) for label, flags in server_candidates(base)]
    cands_by_sig = {flags_sig(flags): (label, flags) for label, flags in cands}
    live_sig = flags_sig(read_flags_file())
    untried_s = [(label, flags) for label, flags in cands
                 if flags_sig(flags) not in tried_s and flags_sig(flags) != live_sig]

    screened_s = []
    for label, flags in untried_s[:SERVER_PER_ROUND]:
        if stopped():
            return
        res = swap_server(flags, label, restore_flags=sb.get("flags"))
        if res == "deferred":
            log(f"[B] {label}: swap deferred this round; will retry next round")
            continue
        if res == "failed":
            tried_s[flags_sig(flags)] = {"label": label, "subset": -1,
                                         "ts": time.time(), "note": "candidate failed (swap or probe)"}
            save_state(state)
            continue
        log(f"[B] screening server {label} on subset (harness {harness_key(hb['prompt'], hb['effort'])})")
        heartbeat(f"screening server {label}")
        s = run_bench(harness_cfg(hb["prompt"], hb["effort"]), "subset", f"s-{label}")
        tried_s[flags_sig(flags)] = {"label": label, "subset": s["passed"],
                                     "ts": time.time(), "suite_wall_s": s["suite_wall_s"]}
        screened_s.append((label, flags, s["passed"]))
        save_state(state)
        log(f"[B] {label}: {s['passed']}/{s['n']} in {s['suite_wall_s']}s")

    # ---------------- full runs ----------------
    # Up to FULL_RUNS_PER_ROUND slots, in priority order:
    #   1. the top candidate newly screened THIS round (fresh head-to-head),
    #   2. the current server_best, re-run fresh every round - the
    #      confirmation run: a promotion is only as good as the latest
    #      fresh-vs-fresh comparison (measured variance: suite wall swung
    #      2.3x on one noisy task, ~5% on tokens),
    #   3. the best subset-scored candidate that has NEVER had a full run
    #      (the backlog: without this slot, a candidate screened in an
    #      earlier round that didn't top that round would never be
    #      full-run at all - temp06/dt5/incumbent were stuck exactly there).
    fulls = []
    if screened_s:
        screened_s.sort(key=lambda kv: -kv[2])
        fulls.append((screened_s[0][0], screened_s[0][1]))
    # Normalize the incumbent through the request-log convention BEFORE
    # comparing: a stale pre-request-log server_best would otherwise
    # produce a second full-run under a key that was never screened
    # (KeyError in the tried_s write below).
    incumbent_flags = with_request_log(sb.get("flags") or [])
    if incumbent_flags and all(flags_sig(incumbent_flags) != flags_sig(f)
                               for _, f in fulls):
        fulls.append((sb["label"], incumbent_flags))
    cand_by_label = {label: flags for label, flags in cands}
    seen_sigs = {flags_sig(f) for _, f in fulls}
    backlog = []
    for v in tried_s.values():
        if v.get("subset", -1) < 0 or "full" in v:
            continue  # never screened, or failed, or already full-run
        f = cand_by_label.get(v.get("label"))
        if not f:
            continue  # pruned from the grid
        f = with_request_log(f)
        if flags_sig(f) in seen_sigs:
            continue
        backlog.append((v.get("subset") or 0, v.get("ts") or 0,
                        v.get("label"), f))
    backlog.sort(key=lambda t: (-t[0], t[1]))  # best subset first, oldest first
    for _, _, label, f in backlog:
        fulls.append((label, f))
        seen_sigs.add(flags_sig(f))
    for label, flags in fulls[:FULL_RUNS_PER_ROUND]:
            if stopped():
                return
            res = swap_server(flags, f"full:{label}", restore_flags=sb.get("flags"))
            if res != "ok":
                log(f"[B] full {label}: swap {res}; skipping")
                continue
            log(f"[B] full run server {label}")
            heartbeat(f"full run server {label}")
            s = run_bench(harness_cfg(hb["prompt"], hb["effort"]), "all", f"sf-{label}")
            rec = tried_s.setdefault(flags_sig(flags), {"label": label, "ts": time.time()})
            rec["full"] = s["passed"]
            rec["tokens"] = s["total_prompt_tokens"] + s["total_completion_tokens"]
            rec["wall"] = s["suite_wall_s"]
            # Keep recent full-run history: run-to-run variance (~5% tokens,
            # 2.3x wall on one noisy task) makes single-run tiebreaks
            # marginal - the history is the evidence base for judging
            # whether a promotion held or ping-ponged.
            hist = rec.setdefault("full_history", [])
            hist.append({"ts": time.time(), "full": s["passed"],
                         "tokens": rec["tokens"], "wall": s["suite_wall_s"]})
            del hist[:-5]
            save_state(state)
            log(f"[B] full {label}: {s['passed']}/{s['n']} ({s['suite_wall_s']}s)")
            cand = {"label": label, "flags": flags,
                    "full": s["passed"],
                    "tokens": s["total_prompt_tokens"] + s["total_completion_tokens"],
                    "wall": s["suite_wall_s"], "ts": time.time()}
            # Robust promotion. Measured 2026-08-25 on identical configs:
            # token runs swing 5-31% and suite walls 2.3-3.2x between runs
            # (agent behavior varies: iteration counts, solution paths), so
            # a single-run comparison flips the crown on noise. Rule:
            #   gate: more passes than the incumbent's best-ever full wins
            #         outright (a 15/16 run can never take the crown from a
            #         config that has shown 16/16),
            #   tiebreak: mean tokens over each side's full-run history
            #         (full_history, capped at the last 5 runs).
            hist = rec.get("full_history") or [{"full": s["passed"], "tokens": cand["tokens"]}]
            mean_tok_c = sum(h.get("tokens", float("inf")) for h in hist) / len(hist)
            sb_flags_sig = flags_sig(with_request_log(sb.get("flags") or []))
            sb_hist = (tried_s.get(sb_flags_sig) or {}).get("full_history") or []
            if not sb_hist:
                sb_hist = [{"full": sb.get("full") or 0,
                            "tokens": sb.get("tokens") or float("inf")}]
            sb_best_full = max(h.get("full", 0) for h in sb_hist)
            sb_mean_tok = sum(h.get("tokens", float("inf")) for h in sb_hist) / len(sb_hist)
            if s["passed"] > sb_best_full or (
                    s["passed"] == sb_best_full and s["passed"] > 0
                    and mean_tok_c < sb_mean_tok):
                sb.update(cand)
                sb["mean_tokens"] = mean_tok_c
                save_state(state)
                log(f"[B] NEW BEST SERVER: {label} full={cand['full']}/{s['n']} "
                    f"(mean tokens {mean_tok_c:.0f} vs incumbent {sb_mean_tok:.0f}, "
                    f"n_c={len(hist)} n_s={len(sb_hist)})")
    # end-of-round: land the server on the best-known flags and land the mode
    if sb.get("flags"):
        eol_flags = with_request_log(sb["flags"])
        res = swap_server(eol_flags, f"eol:{sb['label']}", restore_flags=sb.get("flags"))
        if res == "deferred":
            log("eol: swap deferred (harness busy); current server stays, mode stays as-is")
        elif res == "failed":
            log("eol: could not land the best server flags; _restore_server handles recovery")
        ok, detail = probe_server(attempts=2)
        if ok:
            set_mode("harness", None, f"round {n} done; server on {sb['label']}",
                     flags_sig(eol_flags))
        else:
            log(f"eol: probe failed after round ({detail}); mode recovering until next round")
            set_mode("recovering", None, f"round {n} done but probe failed: {detail[:120]}")

    state["history"] = state.get("history", []) + [{
        "round": n, "ts": time.time(),
        "harness": {k: hb.get(k) for k in ("prompt", "effort", "full", "tokens")},
        "server": {k: sb.get(k) for k in ("label", "full", "tokens")},
    }][-50:]
    save_state(state)
    with open(os.path.join(ROUNDS_DIR, f"round-{n:04d}.json"), "w") as f:
        json.dump({
            "round": n,
            "harness_best": hb,
            "server_best": {"label": sb["label"], "full": sb.get("full"),
                            "tokens": sb.get("tokens"), "flags": sb.get("flags")},
            "tried_harness": tried_h,
            "tried_server": tried_s,
        }, f, indent=2)
    log(f"===== round {n} done: harness {harness_key(hb['prompt'], hb['effort'])} "
        f"(full={hb.get('full')}), server {sb['label']} (full={sb.get('full')}) =====")
    heartbeat(f"round {n} done",
              harness=f"{hb['prompt']}|{hb['effort']}", server=sb["label"],
              harness_full=hb.get("full"), server_full=sb.get("full"))


def _claim_loop_lock():
    """Single-instance guard: hold an exclusive flock for the process lifetime.
    If another live loop instance holds it, exit - flock is released by the
    kernel when a holder dies, so there is no stale-lock problem."""
    import fcntl
    lock_path = os.path.join(ROOT, ".loop.lock")
    f = open(lock_path, "a+")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        other = read_pid_file(LOOP_PID_FILE)
        print(f"loop.py: another instance is already running (pid {other or 'unknown'}) - exiting")
        return None
    return f


def read_pid_file(path: str) -> str:
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("status", "mode"):
        try:
            with open(HEARTBEAT_FILE) as f:
                print("heartbeat:", f.read().strip())
        except FileNotFoundError:
            print("heartbeat: (none yet)")
        try:
            state = load_state()
            hb = state.get("harness_best", {})
            sb = state.get("server_best", {})
            print(f"round: {state.get('round', 0)}")
            print(f"best harness: {hb.get('prompt')}|{hb.get('effort')} full={hb.get('full')} "
                  f"tokens={hb.get('tokens')}")
            print(f"best server: {sb.get('label')} full={sb.get('full')} tokens={sb.get('tokens')}")
            print(f"tried harness: {len(state.get('tried_harness', {}))}/12, "
                  f"tried server: {len(state.get('tried_server', {}))}")
        except Exception as e:
            print(f"state: {e}")
        print("server:", "UP" if server_up() else "DOWN")
        return 0

    if len(sys.argv) > 1 and sys.argv[1] == "mode":
        doc = read_mode()
        if not doc:
            print("mode: (no mode.json yet)")
            return 0
        print(json.dumps(doc, indent=2))
        print("server:", "UP" if server_up() else "DOWN")
        age = time.time() - doc.get("since", 0)
        print(f"mode age: {int(age)}s")
        return 0

    # full-run mode: claim the single-instance lock, then record our pid
    lock = _claim_loop_lock()
    if lock is None:
        return 0
    with open(LOOP_PID_FILE, "w") as f:
        f.write(str(os.getpid()) + "\n")

    os.makedirs(ROUNDS_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    # Record the incumbent once.
    if not os.path.exists(INCUMBENT_FLAGS_FILE):
        write_file = open(INCUMBENT_FLAGS_FILE, "w")
        write_file.write("\n".join(live_server_flags()) + "\n")
        write_file.close()
        log(f"recorded incumbent server flags in {os.path.basename(INCUMBENT_FLAGS_FILE)}")
    if not os.path.exists(FLAGS_FILE):
        write_flags_file(read_flags_file() or live_server_flags())
        log("initialized server.flags from the live server")
    if server_up():
        ok, detail = probe_server(attempts=2)
        if ok:
            set_mode("harness", None, "loop start", flags_sig(read_flags_file()))
        else:
            set_mode("recovering", None, f"loop start: probe failed ({detail[:120]})")
    else:
        set_mode("recovering", None, "loop start: server down")
    log("loop started")
    while True:
        if stopped():
            log("STOP file present - exiting cleanly")
            heartbeat("stopped by STOP file")
            return 0
        t0 = time.time()
        try:
            round_fn(load_state())
        except Exception:
            log("round crashed:\n" + traceback.format_exc())
        if stopped():
            log("STOP file present - exiting cleanly")
            heartbeat("stopped by STOP file")
            return 0
        elapsed = time.time() - t0
        pause = max(30, min(300, 1200 - int(elapsed)))
        log(f"round took {int(elapsed)}s; sleeping {pause}s")
        heartbeat(f"between rounds ({pause}s)")
        for _ in range(pause):
            if stopped():
                break
            time.sleep(1)
        if stopped():
            log("STOP file present - exiting cleanly")
            return 0


if __name__ == "__main__":
    raise SystemExit(main())
#!/usr/bin/env python3
"""Benchmark suite runner for the optimization loop.

  python3 bench.py --cfg '{"prompt":"minimal","effort":"low"}' --tasks subset
  python3 bench.py --tasks all --workers 2 --tag smoke

Writes results/<runid>/results.jsonl + summary.json, prints the summary.
Exit code 0 even when tasks fail (the summary carries the scores); exit 2 on
usage errors.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)

import tb_agent  # noqa: E402
import tasks as T  # noqa: E402

DEFAULTS = {
    "base_url": tb_agent.DEFAULT_BASE_URL,
    "model": tb_agent.DEFAULT_MODEL,
    "prompt": "minimal",
    "effort": "none",
    "max_tokens": 16384,
    "max_iterations": 30,
}


def pick(ids: str):
    if ids == "all":
        return T.ALL
    if ids == "subset":
        return T.SUBSET
    want = set(ids.split(","))
    sel = [t for t in T.ALL if t["id"] in want]
    missing = want - {t["id"] for t in sel}
    if missing:
        raise SystemExit(f"unknown tasks: {sorted(missing)}")
    return sel


def summarize(results: list, cfg: dict) -> dict:
    n = len(results)
    passed = sum(1 for r in results if r["passed"])
    walls = [r["wall_s"] for r in results]
    return {
        "n": n,
        "passed": passed,
        "pass_rate": round(passed / n, 4) if n else 0.0,
        "avg_wall_s": round(sum(walls) / n, 1) if n else 0.0,
        "total_prompt_tokens": sum(r["prompt_tokens"] for r in results),
        "total_completion_tokens": sum(r["completion_tokens"] for r in results),
        "errors": sum(1 for r in results if r["error"]),
        "per_task": [
            {
                "task": r["task"],
                "passed": r["passed"],
                "wall_s": r["wall_s"],
                "iterations": r["iterations"],
                "tool_calls": r["tool_calls"],
                "prompt_tokens": r["prompt_tokens"],
                "completion_tokens": r["completion_tokens"],
                "error": r["error"],
            }
            for r in sorted(results, key=lambda r: r["task"])
        ],
        "cfg": {k: cfg.get(k) for k in ("prompt", "effort", "max_tokens", "max_iterations", "model")},
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tasks", default="subset", help="'all', 'subset', or comma-separated ids")
    ap.add_argument("--cfg", default="{}", help="inline JSON harness config (see DEFAULTS)")
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--tag", default="", help="label stored in the summary")
    ap.add_argument("--keep", default="", help="explicit workdir base (default: results/<runid>/work)")
    args = ap.parse_args()

    cfg = {**DEFAULTS, **json.loads(args.cfg)}
    sel = pick(args.tasks)

    runid = time.strftime("%Y%m%d-%H%M%S")
    if args.keep:
        base = os.path.abspath(args.keep)
    else:
        base = os.path.join(ROOT, "results", runid)
    os.makedirs(base, exist_ok=True)

    t0 = time.time()
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {
            ex.submit(tb_agent.run_task, t, cfg, os.path.join(base, "work", t["id"])): t
            for t in sel
        }
        for fut in concurrent.futures.as_completed(futs):
            r = fut.result()
            results.append(r)
            line = {
                "task": r["task"],
                "passed": r["passed"],
                "wall_s": r["wall_s"],
                "tokens": r["prompt_tokens"] + r["completion_tokens"],
                "error": r["error"],
            }
            with open(os.path.join(base, "results.jsonl"), "a") as f:
                f.write(json.dumps(line) + "\n")
            print(json.dumps(line), flush=True)

    summary = summarize(results, cfg)
    summary["runid"] = runid
    summary["tag"] = args.tag
    summary["suite"] = args.tasks
    summary["suite_wall_s"] = round(time.time() - t0, 1)
    with open(os.path.join(base, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps({k: summary[k] for k in
                      ("n", "passed", "pass_rate", "avg_wall_s", "total_prompt_tokens",
                       "total_completion_tokens", "suite_wall_s")}, indent=2), flush=True)
    print(f"results: {base}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
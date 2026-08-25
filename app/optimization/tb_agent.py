#!/usr/bin/env python3
"""Terminal-bench-style agent runner over an OpenAI-compatible endpoint.

Mirrors the repo's tb_dsh_agent.py 'minimal' preset (short persona + persistent
bash + str_replace_editor) so results stay comparable to the published harness
numbers, and it runs anywhere a plain HTTP endpoint exists.

Used directly:
  python3 tb_agent.py --task fix-bug --prompt minimal --effort low

Imported by bench.py / loop.py:  tb_agent.run_task(task, cfg, workdir)
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import select
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))

DEFAULT_BASE_URL = "http://127.0.0.1:8000/v1"
DEFAULT_MODEL = "qwen3.8-27b"
DEFAULT_EFFORT = "none"
DEFAULT_MAX_TOKENS = 16384
DEFAULT_MAX_ITERATIONS = 30
DEFAULT_TIMEOUT_S = 420
SHELL_TIMEOUT_S = 110
OUTPUT_CAP = 16000
CHAT_TIMEOUT_S = 900

PROMPTS = {
    "minimal": "You are a helpful software engineer assistant.",
    "tb": (
        "You are an expert software engineer. Solve the task step by step: "
        "inspect the files, plan, implement, and verify by running commands. "
        "Read command output carefully and fix errors as they appear. When the "
        "task is fully complete and verified, reply with a final message that "
        "does not call any tools."
    ),
    "structured": (
        "You are an expert terminal engineer working in a sandbox directory.\n"
        "Rules:\n"
        "- Inspect before you change: list files and read the relevant ones first.\n"
        "- Run commands in small steps and read their output; a failing command is "
        "information, not failure.\n"
        "- Never assume file contents or exit codes; verify with cat/ls/python3.\n"
        "- Prefer one focused command per tool call; avoid commands that read from "
        "stdin (they block the shell).\n"
        "- Keep a clear final verification step that proves the task is done.\n"
        "- When everything is verified, end with a short final message that does "
        "not call any tools."
    ),
}

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "bash",
            "description": (
                "Run a bash command in the working directory. The same shell "
                "session persists between calls (cwd, environment, exported "
                "variables survive). Returns stdout+stderr (truncated) and the "
                "exit code. Commands are killed after "
                f"{SHELL_TIMEOUT_S} seconds; a blocked or hung command kills the "
                "shell, which is then restarted in the working directory."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "The bash command to run (may span lines)",
                    }
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "str_replace_editor",
            "description": (
                "File editor. Commands: view (show a file with line numbers), "
                "create (write a new file; overwrites), str_replace (replace the "
                "single unique occurrence of old_str with new_str), insert (insert "
                "content after line insert_line; 0 = top of file). Paths are resolved "
                "against the task's root working directory, NOT the bash shell's "
                "current directory - if you cd around in bash, use absolute paths "
                "here or relative-to-root paths."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "enum": ["view", "create", "str_replace", "insert"],
                    },
                    "path": {
                        "type": "string",
                        "description": "File path (relative to the working directory)",
                    },
                    "file_text": {"type": "string", "description": "For create: full file content"},
                    "old_str": {"type": "string", "description": "For str_replace: exact text to find (must be unique)"},
                    "new_str": {"type": "string", "description": "For str_replace: replacement text"},
                    "insert_line": {"type": "number", "description": "For insert: line number after which to insert"},
                    "content": {"type": "string", "description": "For insert: text to insert"},
                },
                "required": ["command", "path"],
            },
        },
    },
]


class ServerError(Exception):
    """The model endpoint stayed unavailable through the retry budget."""


class ShellSession:
    """A persistent bash session fed line-by-line via a Popen pipe."""

    def __init__(self, cwd: str):
        self.cwd = cwd
        self._spawn()

    def _spawn(self) -> None:
        self.p = subprocess.Popen(
            ["bash"],
            cwd=self.cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            start_new_session=True,
        )

    def _kill(self) -> None:
        try:
            os.killpg(os.getpgid(self.p.pid), 9)
        except Exception:
            try:
                self.p.kill()
            except Exception:
                pass
        try:
            self.p.wait(timeout=5)
        except Exception:
            pass
        self._spawn()

    def run(self, command: str, timeout: int = SHELL_TIMEOUT_S):
        """Run command; return (output_tail, exit_code, timed_out)."""
        if self.p.poll() is not None:
            self._spawn()
        tag = f"__TBC_{random.getrandbits(64):016x}__"
        try:
            self.p.stdin.write(command.rstrip("\n") + f"\necho {tag} $?\n")
            self.p.stdin.flush()
        except (BrokenPipeError, OSError):
            self._spawn()
            return "<shell died before the command could be sent; it was restarted>", -1, True

        deadline = time.time() + timeout
        out: list[str] = []
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                self._kill()
                return (
                    f"<command timed out after {timeout}s; the shell was killed and "
                    "restarted - avoid long-running foreground commands>"
                ), -9, True
            r, _, _ = select.select([self.p.stdout], [], [], min(remaining, 1.0))
            if not r:
                if self.p.poll() is not None:
                    tail = self.p.stdout.read()
                    if tail:
                        out.append(tail.rstrip("\n"))
                continue
            line = self.p.stdout.readline()
            if line == "":
                # process exited without emitting the tag
                code = self.p.poll() or 0
                self._spawn()
                return "\n".join(out)[-OUTPUT_CAP:], code, False
            if tag in line:
                m = re.search(re.escape(tag) + r" (\d+)", line)
                code = int(m.group(1)) if m else -1
                return "\n".join(out)[-OUTPUT_CAP:], code, False
            out.append(line.rstrip("\n"))


def _editor(args: dict, workdir: str) -> str:
    cmd = args.get("command")
    rel = args.get("path", "")
    path = os.path.abspath(os.path.join(workdir, rel))
    if not (path == workdir or path.startswith(workdir + os.sep)):
        return "error: path is outside the working directory"
    try:
        if cmd == "view":
            if not os.path.isfile(path):
                return f"error: {rel} not found"
            with open(path, errors="replace") as f:
                lines = f.readlines()
            head = lines[:2000]
            body = "".join(f"{i + 1:6d}  {ln}" for i, ln in enumerate(head))
            more = f"\n... ({len(lines) - len(head)} more lines)" if len(lines) > 2000 else ""
            return f"(file {rel}, {len(lines)} lines)\n{body}{more}"
        if cmd == "create":
            text = args.get("file_text", "")
            if not text.endswith("\n"):
                text += "\n"
            d = os.path.dirname(path)
            if d:
                os.makedirs(d, exist_ok=True)
            with open(path, "w") as f:
                f.write(text)
            return f"created {rel} ({len(text.splitlines())} lines)"
        if cmd == "str_replace":
            if not os.path.isfile(path):
                return f"error: {rel} not found"
            with open(path) as f:
                content = f.read()
            old = args.get("old_str", "")
            new = args.get("new_str", "")
            if not old:
                return "error: old_str must be non-empty"
            n = content.count(old)
            if n == 0:
                return "error: old_str not found in the file"
            if n > 1:
                return f"error: old_str occurs {n} times; it must be unique"
            with open(path, "w") as f:
                f.write(content.replace(old, new, 1))
            return f"replaced 1 occurrence in {rel}"
        if cmd == "insert":
            if not os.path.isfile(path):
                return f"error: {rel} not found"
            with open(path) as f:
                lines = f.readlines()
            at = int(args.get("insert_line", 0))
            ins = [l + "\n" for l in str(args.get("content", "")).split("\n")]
            if ins and ins[-1] == "\n":
                ins = ins[:-1]
            lines[at:at] = ins
            with open(path, "w") as f:
                f.writelines(lines)
            return f"inserted {len(ins)} lines at line {at} in {rel}"
        return f"error: unknown editor command {cmd!r}"
    except Exception as e:  # editor must never take the agent down
        return f"error: {e}"


def chat(base_url: str, model: str, messages: list, effort: str, max_tokens: int,
         timeout: int = CHAT_TIMEOUT_S) -> dict:
    body = {
        "model": model,
        "messages": messages,
        "tools": TOOLS,
        "max_tokens": max_tokens,
        "stream": False,
    }
    if effort:
        body["reasoning_effort"] = effort
    req = urllib.request.Request(
        base_url + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def chat_with_retry(base_url, model, messages, effort, max_tokens) -> dict:
    delays = [5, 15, 30, 60, 120]
    last = None
    for i, d in enumerate(delays + [None]):
        try:
            return chat(base_url, model, messages, effort, max_tokens)
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = e.read().decode(errors="replace")[:300]
            except Exception:
                pass
            last = f"HTTP {e.code}: {detail}"
            if e.code in (429, 500, 502, 503, 504):
                if d is None:
                    break
                time.sleep(d)
                continue
            raise ServerError(last)
        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError) as e:
            last = f"transport: {e}"
            if d is None:
                break
            time.sleep(d)
            continue
    raise ServerError(last or "unknown server error")


def run_task(task: dict, cfg: dict, workdir: str) -> dict:
    """Run one task end to end; return a result dict. Never raises."""
    started = time.time()
    result = {
        "task": task["id"],
        "passed": False,
        "error": None,
        "wall_s": 0.0,
        "iterations": 0,
        "tool_calls": 0,
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "final": "",
    }
    try:
        if os.path.exists(workdir):
            import shutil
            shutil.rmtree(workdir)
        os.makedirs(workdir)
        for rel, content in (task.get("files") or {}).items():
            p = os.path.join(workdir, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(content)
        if task.get("setup_bash"):
            s = subprocess.run(
                ["bash", "-c", task["setup_bash"]],
                cwd=workdir, capture_output=True, text=True, timeout=120,
            )
            if s.returncode != 0:
                result["error"] = f"setup failed: {s.stderr[-500:]}"
                result["wall_s"] = round(time.time() - started, 1)
                return result

        shell = ShellSession(workdir)
        sys_prompt = PROMPTS.get(cfg.get("prompt", "minimal"), PROMPTS["minimal"])
        user = (
            "Task: " + task["instructions"]
            + f"\n\nYou are working in {workdir}. Every file mentioned in the task "
            "lives there unless an absolute path is given. Use the bash and "
            "str_replace_editor tools to complete the task."
        )
        messages = [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": user},
        ]
        max_iter = int(cfg.get("max_iterations", DEFAULT_MAX_ITERATIONS))
        base_url = cfg.get("base_url", DEFAULT_BASE_URL)
        model = cfg.get("model", DEFAULT_MODEL)
        effort = cfg.get("effort", DEFAULT_EFFORT)
        max_tokens = int(cfg.get("max_tokens", DEFAULT_MAX_TOKENS))

        for _ in range(max_iter):
            result["iterations"] += 1
            resp = chat_with_retry(base_url, model, messages, effort, max_tokens)
            msg = resp["choices"][0]["message"]
            usage = resp.get("usage") or {}
            result["prompt_tokens"] += usage.get("prompt_tokens", 0)
            result["completion_tokens"] += usage.get("completion_tokens", 0)
            tcs = msg.get("tool_calls") or []
            assistant = {"role": "assistant", "content": msg.get("content")}
            if tcs:
                assistant["tool_calls"] = [
                    {
                        "id": tc.get("id"),
                        "type": "function",
                        "function": {
                            "name": tc["function"]["name"],
                            "arguments": tc["function"].get("arguments", ""),
                        },
                    }
                    for tc in tcs
                ]
            messages.append(assistant)
            if not tcs:
                result["final"] = (msg.get("content") or "")[-2000:]
                break
            for tc in tcs:
                fn = tc["function"]["name"]
                try:
                    args = json.loads(tc["function"].get("arguments") or "{}")
                except Exception:
                    args = {}
                if fn == "bash":
                    out, code, timed_out = shell.run(str(args.get("command", "")))
                    head = f"$ {str(args.get('command', ''))[:400]}\n"
                    res = head + out + (f"\n[exit code: {code}]" + (" [TIMED OUT]" if timed_out else ""))
                elif fn == "str_replace_editor":
                    res = _editor(args, workdir)
                else:
                    res = f"error: unknown tool {fn!r}"
                result["tool_calls"] += 1
                messages.append(
                    {"role": "tool", "tool_call_id": tc.get("id"), "content": res[:OUTPUT_CAP]}
                )
        else:
            result["final"] = "(iteration limit reached)"

        v = subprocess.run(
            ["bash", "-c", task["verify"]],
            cwd=workdir, capture_output=True, text=True,
            timeout=int(task.get("timeout_s", 120)),
        )
        result["passed"] = v.returncode == 0
        if not result["passed"]:
            result["error"] = (v.stderr or v.stdout or "verify failed")[-500:]
    except ServerError as e:
        result["error"] = f"server: {e}"
    except Exception as e:
        result["error"] = f"agent: {type(e).__name__}: {e}"[:500]
    result["wall_s"] = round(time.time() - started, 1)
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--task", required=True, help="task id from tasks.py")
    ap.add_argument("--prompt", default="minimal", choices=sorted(PROMPTS))
    ap.add_argument("--effort", default=DEFAULT_EFFORT)
    ap.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    ap.add_argument("--max-iterations", type=int, default=DEFAULT_MAX_ITERATIONS)
    ap.add_argument("--base-url", default=DEFAULT_BASE_URL)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--workdir", default=os.path.join(ROOT, "work", "manual"))
    args = ap.parse_args()

    sys.path.insert(0, ROOT)
    import tasks as T

    task = next((t for t in T.ALL if t["id"] == args.task), None)
    if task is None:
        print(f"unknown task {args.task}; known: {', '.join(t['id'] for t in T.ALL)}")
        return 2
    cfg = {
        "prompt": args.prompt,
        "effort": args.effort,
        "max_tokens": args.max_tokens,
        "max_iterations": args.max_iterations,
        "base_url": args.base_url,
        "model": args.model,
    }
    r = run_task(task, cfg, args.workdir)
    print(json.dumps(r, indent=2))
    return 0 if r["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
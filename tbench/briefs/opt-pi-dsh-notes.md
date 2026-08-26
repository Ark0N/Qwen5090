# Optimization notes — pi (harden) + dsh (recover fibonacci-server)

## dsh: fibonacci-server, 0/6 tests → 6/6

The baseline failure was **not** a wrong answer. dsh's own summary was correct
(BigInt fib, 400s on bad input, verified with curl), but at test time nothing
was listening on port 3000:

```
test_server_running FAILED - AssertionError: Server is not running on port 3000
... Connection refused (all 6 tests)
```

**Mechanism, read out of dsh's code rather than guessed.**
`@deepseek-ai/dsh-subprocess-local` signals the *process group*, not the child:

```
1 kill(-pgid          1 process.kill(-pid, sig)      15 SIGKILL   7 SIGTERM
```

A `nohup <cmd> &` from the bash tool stays in that group and dies when the turn
ends. `setsid` gives the child its own session, so the group signal misses it.
Confirmed locally: driving the installed dsh with the same headless profile, the
model happened to choose `setsid nohup`, and the server was still answering
after dsh exited. Whether it reaches for `setsid` was pure luck of the draw —
so the harness now says it.

**Fix: the headless profile's `system-prompt` persona** (`dsh-setup.sh.j2`,
`cordis.patch.yml`). Two paragraphs, both general, no task named. Iterated —
each of the first two attempts traded one test for another:

| run | change | result |
|---|---|---|
| baseline | persona = one sentence | 0/6 — server gone at test time |
| `opt-dsh-1` | + `setsid` rule | 5/6 — server up; `large_number` failed |
| `opt-dsh-2` | + "natural JSON types, implement exactly what was asked" | 5/6 — `large_number` fixed, `negative_number` broke |
| `opt-dsh-3` | second rule reframed as input validation | **6/6, resolved** |

- `large_number`: the model serialized F(100) as a **string** to keep BigInt
  precision. The test does `data["result"] > 1000000` → `TypeError: '>' not
  supported between 'str' and 'int'`. Hence "a number stays a JSON number".
- `negative_number`: "implement exactly what was asked, no unrequested extras"
  over-corrected. The instruction only mandates 400 for *missing* and
  *non-integer*; `-5` is an integer, so the model started returning 200 and the
  test wants 4xx. Reframed as a validation rule ("an argument the endpoint
  cannot meaningfully answer for … is a 4xx, not a 200 carrying a guess"),
  which gets both.

Call this what it is: **prompt-level tuning iterated against observed failure
modes on the target task.** The rules are written generically and are ordinary
API/process guidance, but they were found by reading this task's failures. The
persona is the harness's, not the task's, so it applies unchanged to all 12 —
which is also the regression risk the final run measures.

## pi: install hardening only (no capability change)

pi was already at the 7-task frontier; the single non-model loss was
`write-compressor` → `agent_installation_failed`, and it was pure transport:

```
Downloading .../node-v22.23.2-linux-x64.tar.gz...  57.8%
curl: (56) OpenSSL SSL_read: ... error:0A000119: decryption failed or bad record mac
Binary download failed, trying source.
Downloading .../node-v22.23.2.tar.gz...  34.7%
curl: (56) OpenSSL SSL_read: ...
bash: npm: command not found
/usr/local/bin/pi: line 4: exec: : not found
INSTALL_FAIL_STATUS
```

Changes in `pi-setup.sh.j2`:

- `__pi_retry` helper (bounded, linear backoff, logs each attempt) wrapping
  `apt-get update`, `apt-get install`, the nvm bootstrap, the node install and
  the npm install.
- **`nvm install -b`**. Without it nvm answers a *transport* error by trying to
  build node from source — minutes of CPU for something a retry fixes in
  seconds. `--no-progress` keeps the pane readable.
- nvm's cache is cleared (`.cache/bin`, `.cache/src`) before each node attempt:
  a half-written tarball is never resumed, only re-checksummed and rejected
  ("Provided file to checksum does not exist" in the baseline log).
- `npm install --fetch-retries 5 --fetch-retry-maxtimeout 120000`.
- Explicit guard when `command -v pi` / `command -v node` come back empty —
  that is what produced the nonsense `exec: : not found` line above. It fails
  with a legible message instead of writing a broken shim.
- No distro-package fallback: pi's `engines` is `node >=22.19.0` and Ubuntu
  24.04 ships 18, so the retry *is* the fallback.

Verified: `opt-pi-install-1` (hello-world) resolved on the hardened script.
`~/.pi/agent/models.json` and `pi_agent.py` are unchanged — pi's capability is
untouched on purpose, per the brief.

---

# Effort-sweep knob (TB_EFFORT)

`TB_EFFORT` (`low`|`medium`|`xhigh`, default `xhigh`) is read once at agent
construction in both adapters and validated there, so a bad value fails before
any container starts rather than 400ing on the first request of every task.
`high`/`minimal`/`max`/`none` are refused by name.

| harness | file:line | how it reaches the model |
|---|---|---|
| pi | `pi_agent.py:26-46` (knob), `:55` (resolve), `:84` (use) | CLI flag `--thinking <effort>` → pi maps it through `thinkingLevelMap` → `reasoning_effort` in the request body |
| dsh | `dsh_agent.py:20-40` (knob), `:49` (resolve), `:61-63` (`_get_template_variables`) → `dsh-setup.sh.j2:163` | jinja var `{{ effort }}` → `agent-default-model.reasoningEffort` in the container's `settings.yaml` → `reasoning_effort` in the request body |

**Wire-verified, not inferred.** A recording mock serve on 127.0.0.1:8099
(`scratchpad/mock_serve.py`) captured the actual request bodies:

- pi `--thinking low|medium|xhigh` → `reasoning_effort` `low|medium|xhigh`.
- dsh `reasoningEffort: low|medium|xhigh` → same, on the agent turn.
  dsh also fires a second request with `reasoning_effort: "none"` and
  `max_tokens: 64` — its **session-title helper**, deliberately non-thinking.
  It is not part of the agent loop and is correctly left alone.

`dsh-setup.sh.j2:187` echoes `grep reasoningEffort "$DSH_HOME/settings.yaml"`
after the readiness probe, so the effort a trial actually ran at is recorded in
its own pane capture. pi needs no equivalent - its effort is on the command
line, which `commands.txt` already records verbatim.

Smoke at medium (both resolved, both artifacts confirm medium):

```
knob-dsh-med  hello-world  resolved  ->  pane: "31:  reasoningEffort: medium"
knob-pi-med   hello-world  resolved  ->  commands.txt: "--thinking medium"
```

## Unrelated: cmp-pi-opt scored 0/12 on a serve outage

Recorded here so it is not misread as an install-hardening regression.
`cmp-dsh-opt` ran first and scored 7/12 (fibonacci-server recovered, no
regression). `cmp-pi-opt` ran next and every one of its 12 tasks installed pi
cleanly and then died at the first model request with a bare `Request timed
out.`, failure_mode `unset`. The serve answered `/v1/models` and a full
completion in 0.17 s afterwards, so the window was transient. **cmp-pi-opt
needs re-running before its number means anything.**

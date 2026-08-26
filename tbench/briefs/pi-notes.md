# pi harness adapter — working notes

Status: **WORKING**. `pi-smoke-1` resolved hello-world on the first attempt
(`is_resolved: true`, both parsers passed, agent wall time ~59 s including the
node+npm+pi install).

## The models.json shape (this is what the first attempt got wrong)

Authority is `docs/models.md` inside the npm package, **not** the README's
"Custom Providers" section — that section documents `pi.registerProvider()` for
extensions and uses a different vocabulary. The failing config used dsh's field
names, which pi silently ignores, leaving the provider undefined:

| wrong (dsh vocabulary) | right (pi `models.json`) |
|---|---|
| `baseURL` | `baseUrl` |
| `apiKeyEnv: "QWEN5090_API_KEY"` | `apiKey: "$QWEN5090_API_KEY"` (env interpolation) |
| `displayName` | `name` |
| model `reasoningEfforts` | model `thinkingLevelMap` |

`compat` names carried over unchanged (`supportsDeveloperRole`,
`supportsReasoningEffort`, `maxTokensField`). `reasoning: true` on the model is
required or pi never sends `reasoning_effort` at all.

Verify with `pi --list-models qwen5090` — one line means the provider resolved.

## Reasoning levels the serve actually accepts

Measured directly against `http://<5090-ip>:8000/v1/chat/completions`:

| value | result |
|---|---|
| `none` | 200, no `reasoning_content` (this is how "off" is spelled) |
| `low` / `medium` / `xhigh` | 200 with `reasoning_content` |
| `minimal` / `high` / `max` | 400 `reasoning_effort_not_supported` — "not supported by the loaded chat template" |
| `off` | 400 from the API layer itself (not a valid enum value) |

So the map is `off: "none"`, `low`/`medium`/`xhigh` identity, and
`minimal`/`high`/`max` set to `null` — `null` is pi's "level unsupported, hide
and clamp away". Getting this wrong is a hard 400 mid-task, not a warning.

From the bundle (`openai-completions-*.js`): with no thinking level selected pi
sends `reasoning_effort = thinkingLevelMap.off` **only if it is a string**, so
omitting `off` would send nothing and let the template default to xhigh. `none`
is the honest mapping.

## Adapter choices

- `--thinking xhigh` on the run command, to match dsh's
  `agent-default-model.reasoningEffort: xhigh` — same weights, same effort, so
  the harness comparison is about the harness.
- `PI_CODING_AGENT_DIR=/opt/pi-agent` in `_env` rather than writing to `$HOME`:
  the env file is sourced into the tmux session before the install script, so
  both the install and the run command see it regardless of which user the task
  container runs as.
- `PI_OFFLINE=1` + `PI_SKIP_VERSION_CHECK=1`: pi does update checks and a
  `pi.dev` version request at startup, on every task, out of the container.
- `--` before the instruction (`pi -p ... -- '<instruction>'`). pi's own help
  documents it for prompts beginning with a dash.
- `npm install -g --ignore-scripts`: no postinstall, so no toolchain needed in
  the task image. read/write/edit/bash tools all work without it (verified
  locally and in the container).
- Readiness probe is `pi --list-models qwen5090 | grep -q 'qwen3.8-27b'`, which
  parses models.json and resolves the provider — the exact failure this brief
  started from would now surface as `INSTALL_FAIL_STATUS` instead of a
  mid-task `Unknown provider`.

## Traps

- The setup script is *sourced* into the task's tmux session, so `cd` leaks.
  `$PWD` is saved at the top and restored before the probe; the pane recording
  confirms the agent ran from `/app`.
- `command -v pi` must be captured **before** `/usr/local/bin/pi` is written,
  or the shim execs itself.
- Non-interactive pi (`-p`) never shows a trust prompt and ignores untrusted
  project resources by default (`docs/security.md`), so no `--approve` flag is
  needed in a fresh task directory.
- Smoke was run with `--no-cleanup` on purpose: the default `cleanup` does
  `docker compose down --rmi all` plus `docker buildx prune`, which is shared
  state while the 64-task dsh run is live.

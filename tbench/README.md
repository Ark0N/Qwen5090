# tbench — agent-harness comparison on the 5090

Reproducible [Terminal-Bench](https://www.tbench.ai/) benchmark of four coding-agent
**harnesses**, all driving the same local model (Qwen3.8-27B NVFP4 on this project's
NInfer serve). The point is to isolate the harness: same model, same tasks, same
effort, only the agent runtime changes.

**Read [`REPORT.md`](REPORT.md) for the results and analysis.** The product-facing
summary is [`app/docs/HARNESS-BENCHMARKS.md`](../app/docs/HARNESS-BENCHMARKS.md).
This file is how to run it.

## What's here

| file | what it is |
|---|---|
| `dsh_agent.py` + `dsh-setup.sh.j2` | DeepSeek Harness adapter (installs `dsh` headless in the task container) |
| `pi_agent.py` + `pi-setup.sh.j2` | pi coding-agent adapter |
| `cc_agent.py` + `cc-setup.sh.j2` + `cc_hooks.py` + `litellm-bridge.yaml` | Claude Code adapter, routed through a LiteLLM Anthropic-to-OpenAI bridge |
| `terminus_fix.py` | Terminal-Bench's built-in `terminus` agent, subclassed to stop sending OpenAI structured-output that NInfer rejects |
| `compare.sh` | the driver: runs all four harnesses over the fixed 12-task subset, sequentially |
| `runbook.md` | the exact per-harness commands and flags |
| `REPORT.md` | full results, per-task matrix, optimization findings, verdict |
| `runs/` | raw results (`results.json` + `run_metadata.json` per run; the bulky asciinema casts and per-trial logs are gitignored) |

The four adapters are [Terminal-Bench installed-agents](https://www.tbench.ai/docs):
each ships a Jinja setup script that Terminal-Bench copies into the task container and
sources, then a run command. Two design notes that cost real debugging time, kept in
the code comments:

- The setup script is **sourced** into the task's tmux session, so its `cd` leaks. Each
  script saves and restores `$PWD`, or the agent runs from the install tree instead of
  the task's working directory.
- Each script ends with a **readiness probe** (compose the profile / print `--help`), so
  a broken install fails there and Terminal-Bench reports `agent_installation_failed`,
  rather than surfacing later as a mysterious task failure.

## Prerequisites

- **Docker** running (each task builds a container).
- **Terminal-Bench** on PATH: `uv tool install terminal-bench` (provides `tb`).
- **The model serve reachable** at the base URL baked into the adapters (default
  `http://<5090-ip>:8000/v1`, the NInfer serve). If your serve is elsewhere,
  edit the `baseURL` / `api_base` in `dsh-setup.sh.j2`, `pi-setup.sh.j2`,
  `litellm-bridge.yaml`, and the terminus env below.
- For Claude Code only: the **LiteLLM bridge** running (`compare.sh` starts it).

## Run it

The whole comparison, all four harnesses over the 12-task subset, sequentially so they
never share the single GPU:

```bash
cd tbench
./compare.sh                 # writes runs/cmp-{dsh,terminus,pi,cc}/
```

One harness on one task (fast smoke), e.g. pi on hello-world:

```bash
PYTHONPATH=$PWD PATH="$HOME/.npm-global/bin:$PATH" \
  tb run --dataset terminal-bench-core==0.1.1 \
    --agent-import-path pi_agent:PiAgent \
    -t hello-world --n-concurrent 1 --no-cleanup \
    --run-id smoke --output-path $PWD/runs
```

Terminus is the exception that needs its OpenAI credentials in the environment (the
others set them inside the container):

```bash
OPENAI_API_KEY=sk-qwen5090-local \
OPENAI_API_BASE=http://<5090-ip>:8000/v1 \
OPENAI_BASE_URL=http://<5090-ip>:8000/v1 \
  tb run --dataset terminal-bench-core==0.1.1 \
    --agent-import-path terminus_fix:TerminusQwen --model openai/qwen3.8-27b \
    -t hello-world --n-concurrent 1 --no-cleanup --run-id smoke --output-path $PWD/runs
```

`runbook.md` has the full flag set for each harness. `--no-cleanup` is deliberate
throughout: the default cleanup runs `docker compose down --rmi all`, which would delete
a shared task image out from under a concurrent run.

## Score a run

```bash
# accuracy of one run
find runs/cmp-dsh-opt -mindepth 2 -name results.json \
  -exec jq -r .is_resolved {} \; | grep -c true

# per-task pass/fail
find runs/cmp-dsh-opt -mindepth 2 -name results.json \
  -exec jq -r '[.task_id,(.is_resolved|tostring),.failure_mode]|join("  ")' {} \; | sort
```

`sk-qwen5090-local` throughout is a **placeholder** credential, not a secret: the NInfer
serve is keyless, but the OpenAI clients refuse a route that names no key.

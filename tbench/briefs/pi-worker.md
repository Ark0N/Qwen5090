# Brief: pi harness adapter

Build a Terminal-Bench installed-agent adapter for the pi coding agent, backed by the
qwen5090 serve. Read briefs/CONTEXT.md first.

State so far:
- pi 0.84.3 is installed locally at `~/.npm-global/bin/pi` (npm package
  `@earendil-works/pi-coding-agent`, installed with `--ignore-scripts`). It has
  `-p/--print` non-interactive mode, `--provider`, `--model`, `--mode json`.
- Custom providers are declared in a `models.json` ("Custom Providers" section of the
  package README; details in `models.md` somewhere under
  `~/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent/` — find and READ it).
- First attempt FAILED: `{"providers": {qwen5090: {...}}}` written to
  `~/.pi/agent/models.json` → `Error: Unknown provider "qwen5090"`. Wrong shape or
  wrong location; models.md is the authority. (`~/.pi/agent/` is pi's config dir here.)

Your steps:
1. Read models.md, fix `~/.pi/agent/models.json` (provider `qwen5090`, api
   openai-completions, baseURL http://<5090-ip>:8000/v1, apiKeyEnv QWEN5090_API_KEY,
   model id `qwen3.8-27b`, contextWindow 252928, reasoningEfforts off:none/low/medium/xhigh —
   NO high, the chat template 400s on it). Verify locally until this works:
   `QWEN5090_API_KEY=sk-qwen5090-local pi -p --provider qwen5090 --model qwen3.8-27b "Reply with exactly: PI-OK"`
   (watch out: it may need `--model qwen5090/qwen3.8-27b` or similar pattern syntax).
2. Write `tbench/pi_agent.py` (class PiAgent) + `tbench/pi-setup.sh.j2`, modeled on
   dsh_agent.py/dsh-setup.sh.j2: nvm node 22, then
   `npm install -g --ignore-scripts @earendil-works/pi-coding-agent@0.84.3`, write the
   working models.json into the container root's pi config dir, env QWEN5090_API_KEY.
   Run command shape: `pi -p <quoted instruction>` with the right provider/model flags.
   Check `pi --help` for trust/approval flags a non-interactive run in a fresh dir needs.
3. Smoke until hello-world resolves. Your run-ids: `pi-smoke-1`, `pi-smoke-2`, ...
4. Report per CONTEXT.md. Files you own: tbench/pi_agent.py, tbench/pi-setup.sh.j2,
   ~/.pi/agent/models.json, briefs/pi-notes.md (optional scratch).

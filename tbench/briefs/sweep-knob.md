# Effort-knob task (shared context)

We are running an EFFORT SWEEP: the same harnesses at reasoning efforts low / medium /
xhigh (xhigh already measured in cmp-*-opt). Your adapter currently bakes in xhigh.

Add a single knob: your adapter must read effort from the env var **`TB_EFFORT`**
(values `low`|`medium`|`xhigh`), defaulting to `xhigh` when unset, and pass it wherever
your harness currently hard-codes xhigh. The serve accepts low/medium/xhigh (measured);
do not send `high` (400) or `none`.

Do NOT change anything else, do NOT run a full 12-task sweep (I run those sequentially),
and do NOT touch other harnesses' files. Just:
1. Add the TB_EFFORT knob to your adapter.
2. Smoke-verify at medium on ONE task: run hello-world with `TB_EFFORT=medium` set in
   the launching shell, run-id `knob-<harness>-med`, and confirm it resolves AND that the
   transcript/request actually used medium (check the run's debug/transcript, not just
   pass/fail).
3. Report: the exact file+line you changed, how TB_EFFORT flows to the model, and the
   knob-verify result. Keep it short.

Model serve: http://<5090-ip>:8000/v1, model qwen3.8-27b. Work dir
<repo>/tbench, `PYTHONPATH=$PWD`. `--no-cleanup` always.

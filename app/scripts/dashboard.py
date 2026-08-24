#!/usr/bin/env python3
"""Local web dashboard for the Qwen5090 server: what is loaded, and what the
machine is doing while it serves.

Linux has no GUI. The .ps1 layer - gui.ps1 and its status pills - is Windows
only, so on a native Linux box there has never been anything to look at but the
server's own log and nvidia-smi in another terminal. This is the Linux answer to
those status pills and nothing more: it reads, it never controls. Starting,
stopping and reconfiguring stay with serve.sh, install-service.sh and systemctl,
where the safeguards already live.

Standard library only, deliberately. It has to run on a box where the venv may be
half-rebuilt or the GPU may have fallen off the bus, and a dashboard that needs
its own pip install is one that is unavailable exactly when something is wrong.

  bash app/scripts/dashboard.sh                    # http://127.0.0.1:8600
  DASH_PORT=9000 bash app/scripts/dashboard.sh
  DASH_HOST=0.0.0.0 bash app/scripts/dashboard.sh  # reachable from the LAN
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Four minutes of history at the default 2 s refresh. Enough to see a decode
# run ramp the card and settle, which is the thing worth watching, without
# holding a session's worth of samples in memory.
HISTORY = 120

# Every nvidia-smi call is bounded. A GPU that has fallen off the bus makes
# nvidia-smi *block* rather than fail - the exact failure mode this machine has
# hit eight times - and an unbounded call would hang the dashboard at the one
# moment it is worth looking at. A timeout is reported as its own state.
SMI_TIMEOUT = 5

GPU_FIELDS = [
    "name", "driver_version", "temperature.gpu", "power.draw", "power.limit",
    "clocks.sm", "clocks.mem", "utilization.gpu", "utilization.memory",
    "memory.used", "memory.total", "pcie.link.gen.current",
    "pcie.link.width.current", "clocks_event_reasons.hw_slowdown",
    "clocks_event_reasons.sw_power_cap",
]


def _num(text, cast=float):
    """nvidia-smi prints [N/A] for anything the card will not answer."""
    try:
        return cast(text.strip())
    except (ValueError, AttributeError):
        return None


def _run(cmd, timeout):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def read_gpu():
    if not shutil.which("nvidia-smi"):
        return {"present": False, "reason": "nvidia-smi not installed"}
    query = "--query-gpu=" + ",".join(GPU_FIELDS)
    try:
        proc = _run(["nvidia-smi", query, "--format=csv,noheader,nounits"], SMI_TIMEOUT)
    except subprocess.TimeoutExpired:
        # Worth surfacing loudly rather than as a blank card: this is what an
        # Xid 79 looks like from userspace.
        return {"present": False, "reason": "nvidia-smi timed out - the GPU may have fallen off the bus"}
    if proc.returncode != 0:
        return {"present": False, "reason": (proc.stderr or "nvidia-smi failed").strip()[:200]}

    row = proc.stdout.strip().splitlines()[0].split(", ")
    if len(row) < len(GPU_FIELDS):
        return {"present": False, "reason": "unexpected nvidia-smi output"}

    gpu = {
        "present": True,
        "name": row[0].strip(),
        "driver": row[1].strip(),
        "temp": _num(row[2], int),
        "power": _num(row[3]),
        "power_limit": _num(row[4]),
        "sm_clock": _num(row[5], int),
        "mem_clock": _num(row[6], int),
        "util": _num(row[7], int),
        "mem_util": _num(row[8], int),
        "mem_used": _num(row[9], int),
        "mem_total": _num(row[10], int),
        "pcie_gen": _num(row[11], int),
        "pcie_width": _num(row[12], int),
        "hw_slowdown": row[13].strip() == "Active",
        "sw_power_cap": row[14].strip() == "Active",
        "procs": [],
    }

    # Which processes hold VRAM. On this box that is normally exactly one, and
    # "the server is gone but the memory is not" is a state worth seeing.
    try:
        apps = _run(["nvidia-smi", "--query-compute-apps=pid,process_name,used_memory",
                     "--format=csv,noheader,nounits"], SMI_TIMEOUT)
        if apps.returncode == 0:
            for line in apps.stdout.strip().splitlines():
                parts = line.split(", ")
                if len(parts) >= 3:
                    gpu["procs"].append({
                        "pid": _num(parts[0], int),
                        "name": os.path.basename(parts[1].strip()),
                        "mem": _num(parts[2], int),
                    })
    except subprocess.TimeoutExpired:
        pass
    return gpu


class CpuSampler:
    """Utilisation is a delta between two reads of /proc/stat, so it needs the
    previous one kept. First call reports None rather than a fabricated 0."""

    def __init__(self):
        self.prev = {}

    @staticmethod
    def _read():
        stats = {}
        with open("/proc/stat") as fh:
            for line in fh:
                if not line.startswith("cpu"):
                    break
                parts = line.split()
                if len(parts) < 5:
                    continue
                vals = [int(v) for v in parts[1:]]
                stats[parts[0]] = (sum(vals), vals[3] + (vals[4] if len(vals) > 4 else 0))
        return stats

    def sample(self):
        cur = self._read()
        out = {"cores": os.cpu_count(), "util": None, "per_core": []}
        try:
            out["load"] = list(os.getloadavg())
        except OSError:
            out["load"] = None

        for key, (total, idle) in sorted(cur.items(), key=lambda kv: kv[0]):
            prev = self.prev.get(key)
            pct = None
            if prev:
                dt, di = total - prev[0], idle - prev[1]
                if dt > 0:
                    pct = round(max(0.0, min(100.0, 100.0 * (dt - di) / dt)), 1)
            if key == "cpu":
                out["util"] = pct
            else:
                out["per_core"].append(pct)
        self.prev = cur
        return out


def read_mem():
    want = {"MemTotal", "MemAvailable", "SwapTotal", "SwapFree"}
    vals = {}
    with open("/proc/meminfo") as fh:
        for line in fh:
            key, _, rest = line.partition(":")
            if key in want:
                vals[key] = int(rest.split()[0]) * 1024
    total = vals.get("MemTotal", 0)
    avail = vals.get("MemAvailable", 0)
    swap_total = vals.get("SwapTotal", 0)
    return {
        "total": total,
        "available": avail,
        "used": total - avail,
        "swap_total": swap_total,
        "swap_used": swap_total - vals.get("SwapFree", 0),
    }


def read_server(url):
    """Ask the server what it is serving. owned_by is how the three backends
    identify themselves - vllm, ninfer, llamacpp - so no second round trip is
    needed to tell which one answered."""
    info = {"up": False, "url": url, "model": None, "backend": None,
            "max_model_len": None, "error": None}
    try:
        with urllib.request.urlopen(url + "/v1/models", timeout=2) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as exc:
        info["error"] = "HTTP %s" % exc.code
        return info
    except Exception as exc:                      # noqa: BLE001 - any failure means "down"
        info["error"] = type(exc).__name__
        return info

    entries = payload.get("data") or []
    if not entries:
        info["error"] = "no models listed"
        return info
    first = entries[0]
    info.update({
        "up": True,
        "model": first.get("id"),
        "backend": first.get("owned_by"),
        # Only vLLM publishes this. NInfer does not, which is why the Claude
        # Code bridge has to be told the window by hand - see NINFER.md.
        "max_model_len": first.get("max_model_len"),
    })
    return info


def read_service(unit="qwen5090"):
    if not shutil.which("systemctl"):
        return {"present": False}
    try:
        active = _run(["systemctl", "--user", "is-active", unit], 5).stdout.strip()
        enabled = _run(["systemctl", "--user", "is-enabled", unit], 5).stdout.strip()
    except subprocess.TimeoutExpired:
        return {"present": False}
    # `is-active` is not the test for existence: systemd answers "inactive" for
    # a unit that was never installed, which would put a pill on the page for a
    # service this machine has never had. `is-enabled` says "not-found", and
    # that is the only answer that means absent - "static", "linked", "disabled"
    # and the rest all describe a unit that does exist.
    if enabled == "not-found" or active in ("", "unknown"):
        return {"present": False}
    return {"present": True, "active": active, "enabled": enabled, "unit": unit}


class Sampler:
    """One shared snapshot behind a lock. Several open tabs must not turn into
    several nvidia-smi calls a second."""

    def __init__(self, server_url, min_interval=1.0):
        self.server_url = server_url
        self.min_interval = min_interval
        self.cpu = CpuSampler()
        self.lock = threading.Lock()
        self.snapshot = None
        self.taken = 0.0
        self.history = {"gpu_util": [], "gpu_power": [], "cpu_util": [], "mem_pct": []}

    def _push(self, key, value):
        series = self.history[key]
        series.append(value)
        del series[:-HISTORY]

    def get(self):
        with self.lock:
            now = time.time()
            if self.snapshot and now - self.taken < self.min_interval:
                return self.snapshot

            gpu = read_gpu()
            cpu = self.cpu.sample()
            mem = read_mem()
            snap = {
                "time": now,
                "gpu": gpu,
                "cpu": cpu,
                "mem": mem,
                "server": read_server(self.server_url),
                "service": read_service(),
            }
            self._push("gpu_util", gpu.get("util") if gpu.get("present") else None)
            self._push("gpu_power", gpu.get("power") if gpu.get("present") else None)
            self._push("cpu_util", cpu.get("util"))
            self._push("mem_pct", round(100.0 * mem["used"] / mem["total"], 1) if mem["total"] else None)
            snap["history"] = self.history
            self.snapshot, self.taken = snap, now
            return snap


PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Qwen5090</title>
<style>
  :root {
    --bg:#0e1116; --card:#161b22; --line:#262d37; --text:#e6edf3; --dim:#8b949e;
    --ok:#3fb950; --warn:#d29922; --bad:#f85149; --accent:#58a6ff;
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:14px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif; }
  header { padding:16px 20px; border-bottom:1px solid var(--line); display:flex; flex-wrap:wrap; gap:12px; align-items:center; }
  h1 { font-size:16px; margin:0; font-weight:600; letter-spacing:.2px; }
  .pill { font-size:12px; padding:3px 10px; border-radius:999px; border:1px solid var(--line); color:var(--dim); white-space:nowrap; }
  .pill.up { color:var(--ok); border-color:#1d572c; background:#0f2716; }
  .pill.down { color:var(--bad); border-color:#5c2321; background:#2a1415; }
  .pill.warn { color:var(--warn); border-color:#5c4614; background:#2a2110; }
  main { padding:20px; display:grid; gap:16px; grid-template-columns:repeat(auto-fit,minmax(320px,1fr)); max-width:1400px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:16px; }
  .card h2 { font-size:12px; text-transform:uppercase; letter-spacing:.8px; color:var(--dim); margin:0 0 12px; font-weight:600; }
  .big { font-size:30px; font-weight:600; font-variant-numeric:tabular-nums; }
  .big small { font-size:14px; color:var(--dim); font-weight:400; margin-left:4px; }
  .row { display:flex; justify-content:space-between; gap:12px; padding:5px 0; border-top:1px solid var(--line); font-variant-numeric:tabular-nums; }
  .row:first-of-type { border-top:0; }
  .row span:first-child { color:var(--dim); }
  .bar { height:8px; border-radius:4px; background:#0b0e13; overflow:hidden; margin:8px 0 4px; }
  .bar > i { display:block; height:100%; background:var(--accent); transition:width .3s; }
  .bar > i.hot { background:var(--warn); } .bar > i.crit { background:var(--bad); }
  svg.spark { width:100%; height:44px; display:block; margin-top:10px; }
  .cores { display:grid; grid-template-columns:repeat(auto-fill,minmax(13px,1fr)); gap:3px; margin-top:12px; }
  .cores i { height:20px; border-radius:2px; background:#0b0e13; position:relative; overflow:hidden; }
  .cores i b { position:absolute; bottom:0; left:0; right:0; background:var(--accent); display:block; }
  table { width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums; }
  td { padding:4px 0; border-top:1px solid var(--line); }
  td:last-child { text-align:right; color:var(--dim); }
  .muted { color:var(--dim); }
  footer { padding:0 20px 24px; color:var(--dim); font-size:12px; }
  .err { color:var(--bad); }
</style></head><body>
<header>
  <h1>Qwen5090</h1>
  <span class="pill" id="p-server">connecting</span>
  <span class="pill" id="p-model" hidden></span>
  <span class="pill" id="p-backend" hidden></span>
  <span class="pill" id="p-ctx" hidden></span>
  <span class="pill" id="p-service" hidden></span>
</header>
<main>
  <section class="card">
    <h2>GPU</h2>
    <div id="gpu-body">
      <div class="big"><span id="g-util">--</span><small>% utilisation</small></div>
      <svg class="spark" id="g-spark" preserveAspectRatio="none"></svg>
      <div class="row"><span>Power</span><b id="g-power">--</b></div>
      <div class="row"><span>Temperature</span><b id="g-temp">--</b></div>
      <div class="row"><span>SM clock</span><b id="g-clock">--</b></div>
      <div class="row"><span>PCIe</span><b id="g-pcie">--</b></div>
      <div class="row"><span>Throttling</span><b id="g-throttle">--</b></div>
    </div>
    <p class="err" id="gpu-error" hidden></p>
  </section>

  <section class="card">
    <h2>VRAM</h2>
    <div class="big"><span id="v-used">--</span><small>of <span id="v-total">--</span> GiB</small></div>
    <div class="bar"><i id="v-bar" style="width:0"></i></div>
    <table id="v-procs"></table>
  </section>

  <section class="card">
    <h2>CPU</h2>
    <div class="big"><span id="c-util">--</span><small>%</small></div>
    <svg class="spark" id="c-spark" preserveAspectRatio="none"></svg>
    <div class="row"><span>Load average</span><b id="c-load">--</b></div>
    <div class="row"><span>Cores</span><b id="c-cores">--</b></div>
    <div class="cores" id="c-grid"></div>
  </section>

  <section class="card">
    <h2>Memory</h2>
    <div class="big"><span id="m-used">--</span><small>of <span id="m-total">--</span> GiB</small></div>
    <div class="bar"><i id="m-bar" style="width:0"></i></div>
    <div class="row"><span>Available</span><b id="m-avail">--</b></div>
    <div class="row"><span>Swap</span><b id="m-swap">--</b></div>
  </section>
</main>
<footer id="foot">refreshing every 2 s</footer>

<script>
var GIB = 1073741824;
function gib(bytes) { return (bytes / GIB).toFixed(1); }
function el(id) { return document.getElementById(id); }
function set(id, text) { el(id).textContent = text; }
function pill(id, text, cls) {
  var node = el(id);
  node.hidden = false;
  node.textContent = text;
  node.className = "pill" + (cls ? " " + cls : "");
}

// A polyline over the last N samples, scaled to the series' own peak so a quiet
// stretch still shows shape. Nulls (a sample the GPU refused) break the line.
function spark(id, series, max, colour) {
  var svg = el(id), w = 300, h = 44;
  svg.setAttribute("viewBox", "0 0 " + w + " " + h);
  var top = Math.max(max, 1);
  for (var i = 0; i < series.length; i++) {
    if (series[i] !== null && series[i] > top) top = series[i];
  }
  var pts = [], step = series.length > 1 ? w / (series.length - 1) : w;
  for (var j = 0; j < series.length; j++) {
    if (series[j] === null) { continue; }
    pts.push((j * step).toFixed(1) + "," + (h - (series[j] / top) * (h - 3) - 1.5).toFixed(1));
  }
  svg.innerHTML = pts.length < 2 ? "" :
    '<polyline fill="none" stroke="' + colour + '" stroke-width="1.5" ' +
    'stroke-linejoin="round" points="' + pts.join(" ") + '"/>';
}

function barClass(pct) { return pct >= 92 ? "crit" : pct >= 75 ? "hot" : ""; }

function render(d) {
  var s = d.server;
  if (s.up) {
    pill("p-server", "serving on " + s.url.replace(/^https?:\/\//, ""), "up");
    pill("p-model", s.model || "unknown model");
    if (s.backend) { pill("p-backend", s.backend); }
    pill("p-ctx", s.max_model_len ? (s.max_model_len / 1024).toFixed(0) + "K context"
                                  : "context not published");
  } else {
    pill("p-server", "no server on " + s.url.replace(/^https?:\/\//, "") +
                     (s.error ? " (" + s.error + ")" : ""), "down");
    el("p-model").hidden = true; el("p-backend").hidden = true; el("p-ctx").hidden = true;
  }
  if (d.service.present) {
    pill("p-service", d.service.unit + ": " + d.service.active,
         d.service.active === "active" ? "up" : "warn");
  }

  var g = d.gpu;
  el("gpu-body").hidden = !g.present;
  el("gpu-error").hidden = g.present;
  if (!g.present) {
    el("gpu-error").textContent = g.reason || "no GPU";
  } else {
    set("g-util", g.util === null ? "--" : g.util);
    set("g-power", g.power === null ? "--" :
        g.power.toFixed(0) + " W of " + (g.power_limit === null ? "?" : g.power_limit.toFixed(0)) + " W");
    set("g-temp", g.temp === null ? "--" : g.temp + " C");
    set("g-clock", g.sm_clock === null ? "--" : g.sm_clock + " MHz");
    set("g-pcie", g.pcie_gen === null ? "--" : "gen " + g.pcie_gen + " x" + g.pcie_width);
    var flags = [];
    if (g.hw_slowdown) { flags.push("HW slowdown"); }
    if (g.sw_power_cap) { flags.push("at power cap"); }
    set("g-throttle", flags.length ? flags.join(", ") : "none");
    el("g-throttle").className = flags.length ? "err" : "";
    spark("g-spark", d.history.gpu_power, 100, "#58a6ff");

    var vpct = g.mem_total ? 100 * g.mem_used / g.mem_total : 0;
    set("v-used", (g.mem_used / 1024).toFixed(1));
    set("v-total", (g.mem_total / 1024).toFixed(1));
    el("v-bar").style.width = vpct.toFixed(1) + "%";
    el("v-bar").className = barClass(vpct);
    el("v-procs").innerHTML = g.procs.length
      ? g.procs.map(function (p) {
          return "<tr><td>" + p.name + " <span class=muted>(" + p.pid + ")</span></td><td>" +
                 (p.mem / 1024).toFixed(1) + " GiB</td></tr>";
        }).join("")
      : '<tr><td class="muted">nothing holding VRAM</td><td></td></tr>';
  }

  var c = d.cpu;
  set("c-util", c.util === null ? "--" : c.util.toFixed(0));
  set("c-load", c.load ? c.load.map(function (n) { return n.toFixed(2); }).join("  ") : "--");
  set("c-cores", c.cores);
  spark("c-spark", d.history.cpu_util, 100, "#3fb950");
  el("c-grid").innerHTML = c.per_core.map(function (p) {
    return "<i><b style='height:" + (p === null ? 0 : p) + "%'></b></i>";
  }).join("");

  var m = d.mem, mpct = m.total ? 100 * m.used / m.total : 0;
  set("m-used", gib(m.used));
  set("m-total", gib(m.total));
  el("m-bar").style.width = mpct.toFixed(1) + "%";
  el("m-bar").className = barClass(mpct);
  set("m-avail", gib(m.available) + " GiB");
  set("m-swap", m.swap_total ? gib(m.swap_used) + " of " + gib(m.swap_total) + " GiB" : "none");
}

function tick() {
  fetch("api/stats", { cache: "no-store" })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      render(d);
      el("foot").textContent = "updated " + new Date(d.time * 1000).toLocaleTimeString() +
                               " - refreshing every 2 s";
    })
    .catch(function () { pill("p-server", "dashboard lost its own backend", "down"); });
}
tick();
setInterval(tick, 2000);
</script>
</body></html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "qwen5090-dashboard"
    sampler = None

    def _send(self, code, body, ctype):
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):                              # noqa: N802 - BaseHTTPRequestHandler API
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/":
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif path == "/api/stats":
            self._send(200, json.dumps(self.sampler.get()), "application/json")
        else:
            self._send(404, "not found\n", "text/plain; charset=utf-8")

    def log_message(self, fmt, *args):
        """Silent by default: a 2 s poll would otherwise write a line every two
        seconds forever. DASH_ACCESS_LOG=1 turns it back on."""
        if os.environ.get("DASH_ACCESS_LOG") == "1":
            super().log_message(fmt, *args)


def main():
    parser = argparse.ArgumentParser(description="Qwen5090 status dashboard")
    parser.add_argument("--host", default=os.environ.get("DASH_HOST", "127.0.0.1"),
                        help="bind address; 0.0.0.0 to reach it from the LAN (default 127.0.0.1)")
    parser.add_argument("--port", type=int, default=int(os.environ.get("DASH_PORT", "8600")))
    parser.add_argument("--server-url",
                        default=os.environ.get("QWEN_URL", "http://127.0.0.1:%s" % os.environ.get("PORT", "8000")),
                        help="the inference server to ask what it is serving")
    args = parser.parse_args()

    Handler.sampler = Sampler(args.server_url.rstrip("/"))
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    shown = "127.0.0.1" if args.host in ("0.0.0.0", "::") else args.host
    print(">> dashboard on http://%s:%d" % (shown, args.port))
    if args.host == "0.0.0.0":
        print(">> bound to all interfaces - reachable from the LAN")
    print(">> watching %s" % args.server_url)
    print(">> Ctrl-C to stop")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n>> stopped")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()

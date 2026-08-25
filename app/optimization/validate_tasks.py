#!/usr/bin/env python3
"""Validator audit: prove every task's verify script is sound.

For each task in tasks.py:
  1. build the sandbox (files + setup_bash)
  2. bash -n the verify script (syntax)
  3. extract embedded python heredocs and py_compile them (syntax)
  4. if REFERENCE has a reference answer for the task: write it and
     verify the script PASSES (accepts the right answer)
  5. for the 'fix' tasks: verify the script FAILS on the pristine state
     (rejects the broken starting point)
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tasks as T  # noqa: E402


def build_sandbox(task: dict, root: str) -> str:
    sb = os.path.join(root, task["id"])
    shutil.rmtree(sb, ignore_errors=True)
    os.makedirs(sb)
    for rel, content in (task.get("files") or {}).items():
        p = os.path.join(sb, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(content)
    if task.get("setup_bash"):
        r = subprocess.run(["bash", "-c", task["setup_bash"]], cwd=sb,
                           capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            raise RuntimeError(f"setup failed for {task['id']}: {r.stderr[:300]}")
    return sb


def check_syntax(task: dict) -> list:
    problems = []
    r = subprocess.run(["bash", "-n", "-c", task["verify"]], capture_output=True, text=True)
    if r.returncode != 0:
        problems.append(f"bash -n: {r.stderr.strip()[:200]}")
    for m in re.finditer(r"<<-?\s*'?EOF'?\n(.*?)\nEOF", task["verify"], re.S):
        code = m.group(1)
        r = subprocess.run(["python3", "-c", "import sys;compile(sys.stdin.read(),'<verify>','exec')"],
                           input=code.encode(), capture_output=True)
        if r.returncode != 0:
            problems.append(f"py syntax: {r.stderr.decode()[:200]}")
    return problems


def run_verify(task: dict, sb: str) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "-c", task["verify"]], cwd=sb,
                          capture_output=True, text=True, timeout=120)


# ---------------------------------------------------------------- references

def ref_csv_to_json(sb):
    import csv, json
    rows = list(csv.DictReader(open(os.path.join(sb, "data.csv"))))
    expected = sorted(
        [{"name": r["name"], "city": r["city"], "age": int(r["age"])} for r in rows],
        key=lambda o: (o["name"], o["city"]))
    json.dump(expected, open(os.path.join(sb, "out.json"), "w"))


def ref_ini_gen(sb):
    open(os.path.join(sb, "app.ini"), "w").write(
        "[core]\nport=8080\nworkers=4\ndebug=false\n\n"
        "[logging]\nlevel=INFO\nfile=/var/log/app.log\n\n"
        "[cache]\nttl=300\nbackend=redis\nurl=redis://localhost:6379/1\n")


def ref_word_freq(sb):
    from collections import Counter
    c = Counter()
    for tok in open(os.path.join(sb, "corpus.txt")).read().split():
        w = re.sub(r"[^a-z0-9]+", "", tok.lower())
        if len(w) >= 3:
            c[w] += 1
    top = sorted(c.items(), key=lambda kv: (-kv[1], kv[0]))[:10]
    open(os.path.join(sb, "freq.txt"), "w").write("".join(f"{w} {n}\n" for w, n in top))


def ref_log_stats(sb):
    from collections import defaultdict
    pat = re.compile(r"^(\S+) \S+ \S+ \[[^\]]*\] [^ ]+ [^ ]+ [^ ]+ (\d{3}) (\d+|-)")
    cnt, byt = defaultdict(int), defaultdict(int)
    for line in open(os.path.join(sb, "access.log")):
        m = pat.match(line.rstrip("\n"))
        if not m:
            continue
        ip, status, size = m.group(1), m.group(2), m.group(3)
        if status == "200":
            cnt[ip] += 1
            byt[ip] += 0 if size == "-" else int(size)
    rows = sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0]))
    open(os.path.join(sb, "summary.csv"), "w").write(
        "ip,count,bytes\n" + "".join(f"{ip},{c},{byt[ip]}\n" for ip, c in rows))


def ref_sql_report(sb):
    import csv, sqlite3
    rows = list(csv.DictReader(open(os.path.join(sb, "orders.csv"))))
    con = sqlite3.connect(os.path.join(sb, "sales.db"))
    con.execute("CREATE TABLE orders (id INTEGER, customer TEXT, region TEXT, amount REAL)")
    con.executemany("INSERT INTO orders VALUES (?,?,?,?)",
                    [(int(r["id"]), r["customer"], r["region"], float(r["amount"])) for r in rows])
    con.commit()
    agg = con.execute("SELECT region, SUM(amount) FROM orders GROUP BY region").fetchall()
    top = sorted(agg, key=lambda r: (-r[1], r[0]))[:3]
    open(os.path.join(sb, "report.csv"), "w").write(
        "".join(f"{r[0]},{r[1]:.2f}\n" for r in top))


def ref_render(sb):
    import json
    d = json.load(open(os.path.join(sb, "data.json")))
    open(os.path.join(sb, "output.txt"), "w").write(
        f"Hello {d['name']}!\nDate: {d['date']}\nItems:\n" + "\n".join(d["lines"]) + "\n")


def ref_data_clean(sb):
    rows = []
    for line in open(os.path.join(sb, "raw.tsv"), newline=""):
        line = line.rstrip("\r\n")
        if not line:
            continue
        parts = line.split("\t")
        rows.append((parts[0], parts[1] if len(parts) > 1 else ""))
    seen, kept = set(), []
    for rid, name in rows:
        if rid.lower() in seen:
            continue
        seen.add(rid.lower())
        kept.append((rid, name or "unknown"))
    kept.sort(key=lambda kv: kv[0].lower())
    open(os.path.join(sb, "clean.tsv"), "w").write(
        "".join(f"{rid}\t{name}\n" for rid, name in kept))


def ref_permissions(sb):
    os.chmod(os.path.join(sb, "proj"), 0o755)
    os.chmod(os.path.join(sb, "proj/src"), 0o700)
    os.chmod(os.path.join(sb, "proj/docs"), 0o755)
    os.chmod(os.path.join(sb, "proj/run.sh"), 0o755)
    for f in ("a.py", "b.py"):
        os.chmod(os.path.join(sb, "proj/src", f), 0o644)
    for f in ("x.log", "y.log"):
        os.chmod(os.path.join(sb, "proj/logs", f), 0o600)
    os.symlink("proj", os.path.join(sb, "latest"))


def ref_git_surgery(sb):
    import subprocess
    out = subprocess.run(
        ["git", "log", "--format=%H%s", "main"], cwd=os.path.join(sb, "repo"),
        capture_output=True, text=True).stdout
    target = None
    for line in out.splitlines():
        if line.endswith("Fix bug"):
            target = line[:-len("Fix bug")]
    if not target:
        raise RuntimeError("target commit not found")
    subprocess.run(["git", "branch", "hotfix", target], cwd=os.path.join(sb, "repo"),
                   check=True)


def ref_fix_bug(sb):
    # the two bugs: range_sum off-by-one and apply_discount semantics
    p = os.path.join(sb, "calc.py")
    c = open(p).read()
    c = c.replace("return sum(range(1, n))", "return sum(range(1, n + 1))")
    c = c.replace("return price * pct / 100.0", "return price * (100.0 - pct) / 100.0")
    open(p, "w").write(c)


def ref_refactor(sb):
    base = os.path.join(sb, "utils")
    mathops = open(os.path.join(base, "mathops.py")).read()
    clamp_src = re.search(r"def clamp.*?\n(?=\ndef |\Z)", mathops, re.S).group(0)
    open(os.path.join(base, "mathops.py"), "w").write(
        mathops.replace(clamp_src, "").strip() + "\n")
    with open(os.path.join(base, "textops.py"), "a") as f:
        f.write("\n\n" + clamp_src)
    mainp = os.path.join(sb, "main.py")
    c = open(mainp).read()
    c = c.replace("from utils.mathops import add, clamp\nfrom utils.textops import slug",
                  "from utils.mathops import add\nfrom utils.textops import slug, clamp")
    open(mainp, "w").write(c)


def ref_script_spec(sb):
    open(os.path.join(sb, "stats.py"), "w").write(
        "import json, math, sys\n\n\n"
        "def main():\n"
        "    vals = [o[\"value\"] for o in json.load(open(sys.argv[1]))]\n"
        "    mean = sum(vals) / len(vals)\n"
        "    std = math.sqrt(sum((v - mean) ** 2 for v in vals) / len(vals))\n"
        "    print(f\"{mean:.4f}\")\n"
        "    print(f\"{std:.4f}\")\n\n\n"
        "if __name__ == \"__main__\":\n"
        "    main()\n")


def ref_debug_multi_bug(sb):
    open(os.path.join(sb, "shop/inventory.py"), "w").write(
        "class Inventory:\n"
        "    def __init__(self):\n"
        "        self._stock = {}\n\n"
        "    def add(self, sku, qty):\n"
        "        self._stock[sku] = self._stock.get(sku, 0) + qty\n\n"
        "    def remove(self, sku, qty):\n"
        '        """Remove qty units; stock must never go below zero."""\n'
        "        self._stock[sku] = max(0, self._stock.get(sku, 0) - qty)\n\n"
        "    def stock(self, sku):\n"
        "        return self._stock.get(sku, 0)\n")
    open(os.path.join(sb, "shop/pricing.py"), "w").write(
        "def price_after_discount(base, discount_pct, tax_pct):\n"
        '    """Apply the percentage discount first, then the percentage tax."""\n'
        "    discounted = base * (1 - discount_pct / 100.0)\n"
        "    taxed = discounted * (1 + tax_pct / 100.0)\n"
        "    return round(taxed, 2)\n")
    open(os.path.join(sb, "shop/cart.py"), "w").write(
        "PRICES = {\"widget\": 9.99, \"gadget\": 24.50, \"doohickey\": 4.75}\n\n\n"
        "def total(items):\n"
        '    """Exact total for (sku, qty) pairs, rounded to two decimals at the end."""\n'
        "    total = 0.0\n"
        "    for sku, qty in items:\n"
        "        total += PRICES[sku] * qty\n"
        "    return round(total, 2)\n")


def ref_html_url_dedupe(sb):
    import re
    raw = open(os.path.join(sb, "messy.html")).read()
    urls = re.findall(r"https?://[A-Za-z0-9:/?#=&%._~+-]+", raw)

    def norm(u):
        u = u.split("#", 1)[0]
        if "://" not in u:
            return None
        scheme, rest = u.split("://", 1)
        if "/" not in rest:
            host, pathq = rest, ""
        else:
            host, pathq = rest.split("/", 1)
            pathq = "/" + pathq
        if "?" in pathq:
            path, query = pathq.split("?", 1)
            keep = []
            for p in query.split("&"):
                if not p:
                    continue
                key = p.split("=", 1)[0]
                if key.startswith("utm_") or key == "ref":
                    continue
                keep.append(p)
            pathq = path + ("?" + "&".join(keep) if keep else "")
        out = scheme.lower() + "://" + host.lower() + pathq
        if out.endswith("/") and not out.endswith("://" + host.lower() + "/"):
            out = out[:-1]
        return out

    seen, out = set(), []
    for u in urls:
        n = norm(u)
        if n and n not in seen:
            seen.add(n)
            out.append(n)
    open(os.path.join(sb, "urls.txt"), "w").write("".join(u + "\n" for u in sorted(out)))


def ref_build_makefile(sb):
    open(os.path.join(sb, "Makefile"), "w").write(
        "all: done.txt\n"
        "\n"
        "a.log: raw.txt\n"
        "\tsed 's/foo/bar/g' raw.txt > a.log\n"
        "\techo 'made a.log' >> build.log\n"
        "\n"
        "b.log: a.log\n"
        "\tprintf 'HEADER\\n' > b.log\n"
        "\tcat a.log >> b.log\n"
        "\techo 'made b.log' >> build.log\n"
        "\n"
        "c.log: a.log b.log\n"
        "\tcat a.log b.log > c.log\n"
        "\techo 'made c.log' >> build.log\n"
        "\n"
        "done.txt: c.log\n"
        "\tprintf 'OK\\n' > done.txt\n"
        "\techo 'made ok' >> build.log\n")


def ref_jsonl_recover(sb):
    import json
    recs, valid, dropped = {}, 0, 0
    for line in open(os.path.join(sb, "events.jsonl")):
        line = line.rstrip("\n")
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except Exception:
            dropped += 1
            continue
        if (isinstance(o, dict) and isinstance(o.get("event_id"), int)
                and not isinstance(o.get("event_id"), bool)
                and isinstance(o.get("msg"), str)):
            valid += 1
            if o["event_id"] not in recs:
                recs[o["event_id"]] = o["msg"]
        else:
            dropped += 1
    open(os.path.join(sb, "out.txt"), "w").write(
        "".join(f"{k}|{recs[k]}\n" for k in sorted(recs)))
    open(os.path.join(sb, "stats.txt"), "w").write(
        f"valid={valid}\nduplicates={valid - len(recs)}\ndropped={dropped}\n")


REFERENCE = {
    "csv-to-json": ref_csv_to_json,
    "ini-gen": ref_ini_gen,
    "word-freq": ref_word_freq,
    "log-stats": ref_log_stats,
    "sql-report": ref_sql_report,
    "render-template": ref_render,
    "data-clean": ref_data_clean,
    "permissions": ref_permissions,
    "git-surgery": ref_git_surgery,
    "fix-bug": ref_fix_bug,
    "refactor-modules": ref_refactor,
    "script-spec": ref_script_spec,
    "debug-multi-bug": ref_debug_multi_bug,
    "html-url-dedupe": ref_html_url_dedupe,
    "build-makefile": ref_build_makefile,
    "jsonl-recover": ref_jsonl_recover,
}
# tasks whose pristine state must FAIL verify (the agent has to change something)
MUST_FAIL_PRISTINE = {"fix-bug", "refactor-modules", "script-spec", "debug-multi-bug"}
# tasks where a reference answer is not a complete fix but a plausible one
# (fix-bug / refactor-modules are covered by their own reference impls)


def main() -> int:
    root = tempfile.mkdtemp(prefix="task-audit-")
    failures = 0
    for task in T.ALL:
        tid = task["id"]
        sb = build_sandbox(task, root)

        problems = check_syntax(task)

        # pristine-state expectation
        r0 = run_verify(task, sb)
        expect_fail = tid in MUST_FAIL_PRISTINE
        if expect_fail and r0.returncode == 0:
            problems.append("verify PASSED on pristine state (should fail)")

        # reference answer -> must pass
        if tid in REFERENCE:
            try:
                REFERENCE[tid](sb)
            except Exception as e:
                problems.append(f"reference impl error: {e}")
            else:
                r1 = run_verify(task, sb)
                if r1.returncode != 0:
                    problems.append(
                        f"verify REJECTED the reference answer: "
                        f"{(r1.stderr or r1.stdout).strip()[:300]}")

        if problems:
            failures += 1
            print(f"FAIL  {tid}")
            for p in problems:
                print(f"      - {p}")
        else:
            print(f"ok    {tid}")
    shutil.rmtree(root, ignore_errors=True)
    print(f"\n{len(T.ALL) - failures}/{len(T.ALL)} verifiers sound")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
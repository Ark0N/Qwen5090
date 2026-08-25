"""Local terminal-bench-style task suite.

Each task: {id, title, instructions, timeout_s, files, setup_bash, verify, subset}

- files:      {relpath: content} written into the task sandbox before the agent runs
- setup_bash: deterministic bash run in the sandbox after files are written
- verify:     bash run in the sandbox after the agent runs; exit 0 == pass
- subset:     True for the fast 4-task screening slice

Everything is offline and deterministic: no network, no random numbers in
verification, no timing-sensitive checks.
"""

TASKS = [
    dict(
        id="fix-bug",
        title="Fix the broken calculator module",
        instructions=(
            "The module calc.py is failing its test suite. Run `python3 test_calc.py` "
            "to see the failures. Fix the bugs in calc.py so the whole test suite "
            "passes. Do NOT modify test_calc.py. When you are done, run the tests one "
            "final time and confirm they all pass."
        ),
        timeout_s=420,
        files={
            "calc.py": (
                "def add(a, b):\n"
                "    return a + b\n"
                "\n"
                "\n"
                "def range_sum(n):\n"
                '    """Sum of the integers 1..n inclusive."""\n'
                "    return sum(range(1, n))\n"
                "\n"
                "\n"
                "def split_evenly(total, parts):\n"
                '    """Split total into parts as evenly as possible; the first values get the remainder."""\n'
                "    base, extra = divmod(total, parts)\n"
                "    return [base + (1 if i < extra else 0) for i in range(parts)]\n"
                "\n"
                "\n"
                "def apply_discount(price, pct):\n"
                '    """Return price after applying a percentage discount."""\n'
                "    return price * pct / 100.0\n"
            ),
            "test_calc.py": (
                "import calc\n"
                "\n"
                "\n"
                "def test_add():\n"
                "    assert calc.add(2, 3) == 5\n"
                "    assert calc.add(-1, 1) == 0\n"
                "\n"
                "\n"
                "def test_range_sum():\n"
                "    assert calc.range_sum(1) == 1\n"
                "    assert calc.range_sum(5) == 15\n"
                "    assert calc.range_sum(10) == 55\n"
                "\n"
                "\n"
                "def test_split_evenly():\n"
                "    assert calc.split_evenly(10, 3) == [4, 3, 3]\n"
                "    assert calc.split_evenly(9, 3) == [3, 3, 3]\n"
                "    assert calc.split_evenly(0, 4) == [0, 0, 0, 0]\n"
                "\n"
                "\n"
                "def test_apply_discount():\n"
                "    assert abs(calc.apply_discount(100, 20) - 80.0) < 1e-9\n"
                "    assert abs(calc.apply_discount(50, 0) - 50.0) < 1e-9\n"
                "    assert abs(calc.apply_discount(10, 50) - 5.0) < 1e-9\n"
                "\n"
                "\n"
                "if __name__ == \"__main__\":\n"
                "    test_add(); test_range_sum(); test_split_evenly(); test_apply_discount()\n"
                '    print("ALL TESTS PASSED")\n'
            ),
        },
        verify="python3 test_calc.py",
        subset=True,
    ),

    dict(
        id="csv-to-json",
        title="Convert a CSV file to JSON",
        instructions=(
            "Convert data.csv into a file named out.json. out.json must contain a JSON "
            "array with one object per CSV row. Each object has exactly three keys: "
            '"name" (string), "city" (string; an empty cell becomes "") and "age" '
            "(integer, not string). Sort the array by name ascending, then by city "
            "ascending (plain character-code comparison of the strings). The file must "
            "be valid JSON. No other fields, no extra files required."
        ),
        timeout_s=300,
        files={
            "data.csv": (
                'name,city,age\n'
                '"Smith, John",NYC,34\n'
                'Alice,,29\n'
                '"O\'Brien",Paris,41\n'
                ',Chicago,18\n'
                'Bob,Paris,22\n'
                'Alice,NYC,31\n'
                '"Zed",,45\n'
                'Carol,SF,27\n'
                'Bob,SF,33\n'
                '"Smith, Jane",NYC,38\n'
                'Dave,,50\n'
                'Eve,SF,24\n'
            ),
        },
        verify=(
            "python3 - <<'EOF'\n"
            "import csv, json\n"
            "rows = list(csv.DictReader(open('data.csv')))\n"
            "expected = sorted(\n"
            '    [{"name": r["name"], "city": r["city"], "age": int(r["age"])} for r in rows],\n'
            '    key=lambda o: (o["name"], o["city"]))\n'
            "got = json.load(open('out.json'))\n"
            "assert got == expected, ('got:', got, 'expected:', expected)\n"
            'print("PASS")\n'
            "EOF"
        ),
        subset=True,
    ),

    dict(
        id="ini-gen",
        title="Generate a config file",
        instructions=(
            "Create a file named app.ini with exactly this structure: a [core] section "
            "with keys port=8080, workers=4, debug=false; a [logging] section with keys "
            "level=INFO, file=/var/log/app.log; a [cache] section with keys ttl=300, "
            "backend=redis, url=redis://localhost:6379/1. No other sections or keys."
        ),
        timeout_s=300,
        files={},
        verify=(
            "python3 - <<'EOF'\n"
            "import configparser\n"
            "cp = configparser.ConfigParser(strict=True)\n"
            "cp.read('app.ini')\n"
            "assert set(cp.sections()) == {'core', 'logging', 'cache'}, cp.sections()\n"
            "assert cp['core']['port'] == '8080'\n"
            "assert cp['core']['workers'] == '4'\n"
            "assert cp['core']['debug'] == 'false'\n"
            "assert cp['logging']['level'] == 'INFO'\n"
            "assert cp['logging']['file'] == '/var/log/app.log'\n"
            "assert cp['cache']['ttl'] == '300'\n"
            "assert cp['cache']['backend'] == 'redis'\n"
            "assert cp['cache']['url'] == 'redis://localhost:6379/1'\n"
            'print("PASS")\n'
            "EOF"
        ),
        subset=True,
    ),

    dict(
        id="word-freq",
        title="Word frequency ranking",
        instructions=(
            "Write a file named freq.txt containing the 10 most frequent words from "
            "corpus.txt. A word is a maximal run of non-whitespace characters; normalize "
            "it by lowercasing and stripping every non-alphanumeric character from both "
            "ends; ignore words that are shorter than 3 characters after normalization. "
            "Rank by count descending; break ties alphabetically (ascending). Each line "
            "of freq.txt is: the word, one space, the count."
        ),
        timeout_s=300,
        files={
            "corpus.txt": (
                "The quick brown fox jumps over the lazy dog. The dog barked!\n"
                "Quick quick, quick -- the fox ran faster than the dog.\n"
                "a dog and a fox in the yard; the yard had a fence.\n"
                "The fence was old. Old fences fall. Fall fall FALL.\n"
                "Brown brown brown dog. A dog sat by the fence while the fox slept.\n"
                "Quick thinking. Quick acting. The dog caught the fox's tail.\n"
                "the the the fox dog dog dog quick quick quick\n"
                "fence yard fence yard fence yard\n"
                "The old dog and the quick fox near the tall fence in the yard.\n"
                "fall fall fall; the yard light was dim. Dim dim, quick quick.\n"
                "fox fox dog dog fence fence yard yard\n"
                "a quick brown fox, an old lazy dog, a tall fence, a quiet yard.\n"
            ),
        },
        verify=(
            "python3 - <<'EOF'\n"
            "import re\n"
            "from collections import Counter\n"
            "c = Counter()\n"
            "for tok in open('corpus.txt').read().split():\n"
            "    w = re.sub(r'[^a-z0-9]+', '', tok.lower())\n"
            "    if len(w) >= 3:\n"
            "        c[w] += 1\n"
            "top = sorted(c.items(), key=lambda kv: (-kv[1], kv[0]))[:10]\n"
            "expected = ''.join(f'{w} {n}\\n' for w, n in top)\n"
            "got = open('freq.txt').read()\n"
            "assert got == expected, ('got:', repr(got), 'expected:', repr(expected))\n"
            'print("PASS")\n'
            "EOF"
        ),
        subset=True,
    ),

    dict(
        id="log-stats",
        title="Aggregate an access log",
        instructions=(
            "access.log is an nginx combined-format log. Some lines are corrupted and "
            "must be ignored. Write summary.csv with one row per client IP, counting "
            "only requests whose HTTP status is 200. Columns are ip,count,bytes where "
            "count is the number of 200 responses from that IP and bytes is the sum of "
            "the response-size field over those 200 rows (a response size of '-' counts "
            "as 0). Sort rows by count descending, then ip ascending (character-code "
            "order). The first line must be exactly: ip,count,bytes"
        ),
        timeout_s=420,
        files={
            "access.log": (
                '10.0.0.1 - - [24/Aug/2026:10:00:01 +0000] "GET /index.html HTTP/1.1" 200 532\n'
                '10.0.0.1 - - [24/Aug/2026:10:00:02 +0000] "GET /style.css HTTP/1.1" 200 211\n'
                '10.0.0.2 - - [24/Aug/2026:10:00:03 +0000] "POST /login HTTP/1.1" 200 128\n'
                '10.0.0.1 - - [24/Aug/2026:10:00:04 +0000] "GET /about.html HTTP/1.1" 200 340\n'
                "### corrupt line from an old agent ###\n"
                '172.16.4.9 - - [24/Aug/2026:10:00:05 +0000] "GET /api/items HTTP/1.1" 200 1024\n'
                '172.16.4.9 - - [24/Aug/2026:10:00:06 +0000] "GET /api/items HTTP/1.1" 404 42\n'
                '10.0.0.2 - - [24/Aug/2026:10:00:07 +0000] "GET /index.html HTTP/1.1" 200 532\n'
                '10.0.0.2 - - [24/Aug/2026:10:00:08 +0000] "POST /login HTTP/1.1" 500 0\n'
                '192.168.1.50 - - [24/Aug/2026:10:00:09 +0000] "GET /index.html HTTP/1.1" 200 532\n'
                '192.168.1.50 - - [24/Aug/2026:10:00:10 +0000] "GET /style.css HTTP/1.1" 200 211\n'
                '192.168.1.50 - - [24/Aug/2026:10:00:11 +0000] "GET /app.js HTTP/1.1" 200 -\n'
                '10.0.0.1 - - [24/Aug/2026:10:00:12 +0000] "GET /missing.html HTTP/1.1" 404 42\n'
                '10.0.0.1 - - [24/Aug/2026:10:00:13 +0000] "GET /index.html HTTP/1.1" 200 532\n'
                '172.16.4.9 - - [24/Aug/2026:10:00:14 +0000] "GET /api/items HTTP/1.1" 200 1024\n'
                '172.16.4.9 - - [24/Aug/2026:10:00:15 +0000] "POST /api/items HTTP/1.1" 200 88\n'
                "this line is not a log line\n"
                '192.168.1.51 - - [24/Aug/2026:10:00:16 +0000] "GET /index.html HTTP/1.1" 200 532\n'
                '192.168.1.51 - - [24/Aug/2026:10:00:17 +0000] "GET /about.html HTTP/1.1" 200 340\n'
                '192.168.1.51 - - [24/Aug/2026:10:00:18 +0000] "GET /api/items HTTP/1.1" 500 17\n'
                '10.0.0.1 - - [24/Aug/2026:10:00:19 +0000] "GET /style.css HTTP/1.1" 200 211\n'
                '10.0.0.2 - - [24/Aug/2026:10:00:20 +0000] "GET /about.html HTTP/1.1" 200 340\n'
                '10.0.0.2 - - [24/Aug/2026:10:00:21 +0000] "POST /login HTTP/1.1" 200 128\n'
                '172.16.4.9 - - [24/Aug/2026:10:00:22 +0000] "GET /api/items HTTP/1.1" 200 1024\n'
                '192.168.1.50 - - [24/Aug/2026:10:00:23 +0000] "GET /index.html HTTP/1.1" 200 532\n'
                '192.168.1.50 - - [24/Aug/2026:10:00:24 +0000] "GET /missing.html HTTP/1.1" 404 42\n'
                '192.168.1.51 - - [24/Aug/2026:10:00:25 +0000] "GET /style.css HTTP/1.1" 200 211\n'
                '192.168.1.51 - - [24/Aug/2026:10:00:26 +0000] "GET /app.js HTTP/1.1" 200 -\n'
                '10.0.0.1 - - [24/Aug/2026:10:00:27 +0000] "POST /login HTTP/1.1" 200 128\n'
                '10.0.0.1 - - [24/Aug/2026:10:00:28 +0000] "GET /api/items HTTP/1.1" 200 1024\n'
                '10.0.0.2 - - [24/Aug/2026:10:00:29 +0000] "GET /index.html HTTP/1.1" 200 532\n'
                '172.16.4.9 - - [24/Aug/2026:10:00:30 +0000] "GET /about.html HTTP/1.1" 200 340\n'
                '192.168.1.50 - - [24/Aug/2026:10:00:31 +0000] "GET /style.css HTTP/1.1" 200 211\n'
                '192.168.1.51 - - [24/Aug/2026:10:00:32 +0000] "GET /api/items HTTP/1.1" 404 42\n'
                '10.0.0.1 - - [24/Aug/2026:10:00:33 +0000] "GET /index.html HTTP/1.1" 200 532\n'
                '10.0.0.2 - - [24/Aug/2026:10:00:34 +0000] "POST /login HTTP/1.1" 404 42\n'
                '172.16.4.9 - - [24/Aug/2026:10:00:35 +0000] "GET /index.html HTTP/1.1" 200 532\n'
                '192.168.1.50 - - [24/Aug/2026:10:00:36 +0000] "GET /app.js HTTP/1.1" 200 -\n'
                '192.168.1.51 - - [24/Aug/2026:10:00:37 +0000] "GET /about.html HTTP/1.1" 200 340\n'
                '10.0.0.1 - - [24/Aug/2026:10:00:38 +0000] "GET /style.css HTTP/1.1" 200 211\n'
                '10.0.0.2 - - [24/Aug/2026:10:00:39 +0000] "GET /api/items HTTP/1.1" 200 1024\n'
            ),
        },
        verify=(
            "python3 - <<'EOF'\n"
            "import re\n"
            "from collections import defaultdict\n"
            "pat = re.compile(\n"
            '    r"^(\\S+) \\S+ \\S+ \\[[^\\]]*\\] [^ ]+ [^ ]+ [^ ]+ (\\d{3}) (\\d+|-)"\n'
            ")\n"
            "cnt = defaultdict(int); byt = defaultdict(int)\n"
            "for line in open('access.log'):\n"
            "    m = pat.match(line.rstrip('\\n'))\n"
            "    if not m:\n"
            "        continue\n"
            "    ip, status, size = m.group(1), m.group(2), m.group(3)\n"
            "    if status == '200':\n"
            "        cnt[ip] += 1\n"
            "        byt[ip] += 0 if size == '-' else int(size)\n"
            "rows = sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0]))\n"
            "expected = 'ip,count,bytes\\n' + ''.join(f'{ip},{c},{byt[ip]}\\n' for ip, c in rows)\n"
            "got = open('summary.csv').read()\n"
            "assert got == expected, ('got:', repr(got), 'expected:', repr(expected))\n"
            'print("PASS")\n'
            "EOF"
        ),
        subset=False,
    ),

    dict(
        id="refactor-modules",
        title="Move a function between modules",
        instructions=(
            "Refactor this Python package: move the clamp function from "
            "utils/mathops.py into utils/textops.py. After your change: (1) "
            "`python3 main.py` must print exactly two lines, 10 and 0; (2) "
            "`python3 -c 'from utils.textops import clamp'` must succeed; (3) the "
            "module utils.mathops must no longer define clamp, while add must remain "
            "available there. Do not change main.py's output behavior."
        ),
        timeout_s=420,
        files={
            "utils/__init__.py": "",
            "utils/mathops.py": (
                "def add(a, b):\n"
                "    return a + b\n"
                "\n"
                "\n"
                "def clamp(x, lo, hi):\n"
                "    return max(lo, min(hi, x))\n"
            ),
            "utils/textops.py": (
                "def slug(s):\n"
                '    """Lowercase, collapse whitespace, join with dashes."""\n'
                "    return '-'.join(s.lower().split())\n"
            ),
            "main.py": (
                "from utils.mathops import add, clamp\n"
                "from utils.textops import slug\n"
                "\n"
                "\n"
                "def report(x, n):\n"
                "    return slug(str(clamp(x, 0, n)))\n"
                "\n"
                "\n"
                "if __name__ == '__main__':\n"
                "    print(report(42, 10))\n"
                "    print(report(-5, 10))\n"
            ),
        },
        verify=(
            "set -e\n"
            "out=$(python3 main.py)\n"
            "expected=$'10\\n0'\n"
            '[ "$out" = "$expected" ] || { echo "bad main.py output: $out"; exit 1; }\n'
            "python3 -c 'from utils.textops import clamp' || exit 1\n"
            'python3 -c "import utils.mathops as m; assert not hasattr(m, \'clamp\')" || exit 1\n'
            "python3 -c 'from utils.mathops import add; assert add(1, 2) == 3' || exit 1\n"
            'echo PASS'
        ),
        subset=False,
    ),

    dict(
        id="git-surgery",
        title="Create a branch at a specific commit",
        instructions=(
            "In the git repository ./repo (currently checked out on branch main) create "
            "a branch named hotfix that points at the commit whose commit message is "
            "exactly 'Fix bug'. Do not move or rewrite main, and leave the repository "
            "checked out on main when you are done."
        ),
        timeout_s=360,
        files={},
        setup_bash=(
            "set -e\n"
            "export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'\n"
            "git init -q -b main repo\n"
            "cd repo\n"
            "git config user.email dev@example.com\n"
            "git config user.name Dev\n"
            "echo v1 > app.py; git add .; git commit -qm 'Initial'\n"
            "echo v2 > app.py; git commit -qam 'Add feature'\n"
            "echo v3 > app.py; git commit -qam 'Fix bug'\n"
            'echo "top-secret-token" > secrets.txt; git add .; git commit -qm "Add secrets"\n'
            'echo "# notes" > README.md; git add .; git commit -qm "Tweak"\n'
        ),
        verify=(
            "set -e\n"
            "cd repo\n"
            'target=$(git log --format=%H%s main | sed -n "s/^\\(.*\\)Fix bug$/\\1/p" | head -1)\n'
            '[ -n "$target" ] || { echo "target commit not found"; exit 1; }\n'
            '[ "$(git rev-parse hotfix)" = "$target" ] || { echo "hotfix points at the wrong commit"; exit 1; }\n'
            '[ "$(git symbolic-ref --short HEAD)" = "main" ] || { echo "HEAD is not on main"; exit 1; }\n'
            'echo PASS'
        ),
        subset=False,
    ),

    dict(
        id="sql-report",
        title="Build a database and a report",
        instructions=(
            "orders.csv has the columns id,customer,region,amount. Load it into a "
            "SQLite database file named sales.db with a table named orders whose "
            "columns are id INTEGER, customer TEXT, region TEXT, amount REAL. Then "
            "write report.csv containing the top 3 regions by total amount: one row "
            "per region in the form region,total where total is formatted with exactly "
            "two decimal places (for example 1250.00), rows sorted by total "
            "descending. report.csv must have no header line and must end with a "
            "newline."
        ),
        timeout_s=420,
        files={
            "orders.csv": (
                "id,customer,region,amount\n"
                "1,Acme,North,310.50\n"
                "2,Beta,South,220.00\n"
                "3,Gamma,East,480.25\n"
                "4,Delta,West,150.00\n"
                "5,Epsilon,North,449.50\n"
                "6,Zeta,South,310.00\n"
                "7,Eta,East,625.25\n"
                "8,Theta,West,210.75\n"
                "9,Iota,North,490.00\n"
                "10,Kappa,South,450.00\n"
                "11,Lambda,East,0.00\n"
                "12,Mu,West,120.50\n"
                "13,Nu,North,0.00\n"
                "14,Xi,South,0.00\n"
                "15,Omicron,East,0.00\n"
                "16,Pi,West,239.00\n"
                "17,Rho,North,0.00\n"
                "18,Sigma,South,0.00\n"
                "19,Tau,East,0.00\n"
                "20,Upsilon,West,0.00\n"
            ),
        },
        verify=(
            "python3 - <<'EOF'\n"
            "import sqlite3\n"
            "con = sqlite3.connect('sales.db')\n"
            "rows = con.execute('SELECT region, SUM(amount) FROM orders GROUP BY region').fetchall()\n"
            "top = sorted(rows, key=lambda r: (-r[1], r[0]))[:3]\n"
            "expected = ''.join(f'{r[0]},{r[1]:.2f}\\n' for r in top)\n"
            "got = open('report.csv').read()\n"
            "assert got == expected, ('got:', repr(got), 'expected:', repr(expected))\n"
            'print("PASS")\n'
            "EOF"
        ),
        subset=False,
    ),

    dict(
        id="script-spec",
        title="Write a script to a spec",
        instructions=(
            "Write stats.py: a Python script that takes one command-line argument, the "
            "path to a JSON file containing a list of objects each with a numeric field "
            "'value'. It must print exactly two lines: first the mean of the 'value' "
            "fields, then the population standard deviation (ddof=0) of the 'value' "
            "fields, both rounded to 4 decimal places and formatted with exactly four "
            "digits after the decimal point (for example 3.6250). It must work with: "
            "python3 stats.py <file>"
        ),
        timeout_s=360,
        files={},
        verify=(
            "python3 - <<'EOF'\n"
            "import json, math, subprocess\n"
            "vals = [3.5, -1.25, 7.0, 2.25, 4.75, 0.0, 9.125]\n"
            "json.dump([{'value': v} for v in vals], open('hidden.json', 'w'))\n"
            "mean = sum(vals) / len(vals)\n"
            "std = math.sqrt(sum((v - mean) ** 2 for v in vals) / len(vals))\n"
            "got = subprocess.run(['python3', 'stats.py', 'hidden.json'], capture_output=True, text=True)\n"
            "assert got.returncode == 0, got.stderr\n"
            "lines = got.stdout.strip().splitlines()\n"
            "assert len(lines) == 2, got.stdout\n"
            "a, b = float(lines[0]), float(lines[1])\n"
            "assert abs(a - mean) < 1e-3, (a, mean)\n"
            "assert abs(b - std) < 1e-3, (b, std)\n"
            'print("PASS")\n'
            "EOF"
        ),
        subset=False,
    ),

    dict(
        id="permissions",
        title="Fix a directory tree's permissions",
        instructions=(
            "Adjust the file modes on the proj tree so that: the proj directory itself "
            "is 755; proj/src is 700; every .py file under proj is 644; every .log file "
            "under proj is 600; proj/docs is 755; proj/run.sh is 755. Also create a "
            "symbolic link named latest in the current directory that points to proj "
            "(a relative target)."
        ),
        timeout_s=300,
        files={},
        setup_bash=(
            "set -e\n"
            "mkdir -p proj/src proj/logs proj/docs\n"
            "echo x > proj/src/a.py\n"
            "echo x > proj/src/b.py\n"
            "echo x > proj/logs/x.log\n"
            "echo x > proj/logs/y.log\n"
            "echo x > proj/docs/z.md\n"
            "echo '#!/bin/sh' > proj/run.sh\n"
            "chmod 777 proj proj/src proj/docs proj/run.sh\n"
            "chmod 640 proj/src/a.py proj/src/b.py\n"
            "chmod 644 proj/logs/x.log proj/logs/y.log\n"
        ),
        verify=(
            "set -e\n"
            '[ "$(stat -c %a proj)" = "755" ] || { echo "proj: $(stat -c %a proj)"; exit 1; }\n'
            '[ "$(stat -c %a proj/src)" = "700" ] || { echo "src: $(stat -c %a proj/src)"; exit 1; }\n'
            '[ "$(stat -c %a proj/docs)" = "755" ] || { echo "docs: $(stat -c %a proj/docs)"; exit 1; }\n'
            '[ "$(stat -c %a proj/run.sh)" = "755" ] || { echo "run.sh: $(stat -c %a proj/run.sh)"; exit 1; }\n'
            'for f in proj/src/a.py proj/src/b.py; do [ "$(stat -c %a "$f")" = "644" ] || { echo "$f: $(stat -c %a "$f")"; exit 1; }; done\n'
            'for f in proj/logs/x.log proj/logs/y.log; do [ "$(stat -c %a "$f")" = "600" ] || { echo "$f: $(stat -c %a "$f")"; exit 1; }; done\n'
            '[ "$(readlink latest)" = "proj" ] || { echo "latest: $(readlink latest)"; exit 1; }\n'
            'echo PASS'
        ),
        subset=False,
    ),

    dict(
        id="render-template",
        title="Render a template from JSON data",
        instructions=(
            "Render template.txt using the data in data.json into a file named "
            "output.txt: replace each {{key}} placeholder with the value from "
            "data.json. For the key 'lines', which holds a JSON array, the placeholder "
            "is replaced by the array's elements joined with newlines. Do not add or "
            "remove any other characters."
        ),
        timeout_s=300,
        files={
            "template.txt": (
                "Hello {{name}}!\n"
                "Date: {{date}}\n"
                "Items:\n"
                "{{lines}}\n"
            ),
            "data.json": '{\n  "name": "World",\n  "date": "2026-08-25",\n  "lines": ["- alpha", "- beta"]\n}\n',
        },
        verify=(
            "python3 - <<'EOF'\n"
            "import json\n"
            "d = json.load(open('data.json'))\n"
            "expected = 'Hello ' + d['name'] + '!\\nDate: ' + d['date'] + '\\nItems:\\n' + '\\n'.join(d['lines']) + '\\n'\n"
            "got = open('output.txt').read()\n"
            "assert got == expected, ('got:', repr(got), 'expected:', repr(expected))\n"
            'print("PASS")\n'
            "EOF"
        ),
        subset=False,
    ),

    dict(
        id="data-clean",
        title="Clean a messy TSV",
        instructions=(
            "raw.tsv has two tab-separated columns, id and name; the file uses CRLF "
            "line endings. Write clean.tsv with: duplicate ids removed, comparing ids "
            "case-insensitively, keeping the first occurrence of each id; an empty name "
            "replaced with 'unknown'; rows sorted by id case-insensitively (stable); "
            "the id and name kept exactly as they appear in the kept row. No CRLF "
            "anywhere in the output, plain LF line endings, and the file must end with "
            "a newline."
        ),
        timeout_s=360,
        files={
            "raw.tsv": (
                "A1\talpha\r\n"
                "b2\t\r\n"
                "A1\tALPHA DUP\r\n"
                "C3\tcharlie\r\n"
                "b2\tbeta\r\n"
                "c3\t\r\n"
                "D4\tdelta\r\n"
                "a1\t\r\n"
                "E5\tepsilon\r\n"
            ),
        },
        verify=(
            "python3 - <<'EOF'\n"
            "rows = []\n"
            "for line in open('raw.tsv', newline=''):\n"
            "    line = line.rstrip('\\r\\n')\n"
            "    if not line:\n"
            "        continue\n"
            "    parts = line.split('\\t')\n"
            "    rid = parts[0]\n"
            "    name = parts[1] if len(parts) > 1 else ''\n"
            "    rows.append((rid, name))\n"
            "seen = set(); kept = []\n"
            "for rid, name in rows:\n"
            "    if rid.lower() in seen:\n"
            "        continue\n"
            "    seen.add(rid.lower())\n"
            "    kept.append((rid, name or 'unknown'))\n"
            "kept.sort(key=lambda kv: kv[0].lower())\n"
            "expected = ''.join(f'{rid}\\t{name}\\n' for rid, name in kept)\n"
            "raw = open('clean.tsv', newline='').read()\n"
            "assert '\\r' not in raw, 'CRLF in output'\n"
            "assert raw == expected, ('got:', repr(raw), 'expected:', repr(expected))\n"
            'print("PASS")\n'
            "EOF"
        ),
        subset=False,
    ),

    dict(
        id="debug-multi-bug",
        title="Find and fix three distributed bugs",
        instructions=(
            "The shop/ package (inventory, pricing, cart) is broken: its test "
            "suite fails. There are exactly three bugs, one in each of "
            "inventory.py, pricing.py and cart.py. The docstrings state the "
            "correct behavior. Run `PYTHONPATH=. python3 tests/test_shop.py` "
            "from the task root to see the failures (a plain "
            "`python3 tests/test_shop.py` cannot find the shop package), "
            "find and fix all three bugs, WITHOUT modifying "
            "tests/test_shop.py (it is checked). Also make `python3 main.py` "
            "print exactly these three lines:\n"
            "0\n"
            "88.0\n"
            "102.72\n"
            "Do not change main.py's logic."
        ),
        timeout_s=480,
        files={
            "shop/__init__.py": "",
            "shop/inventory.py": (
                "class Inventory:\n"
                "    def __init__(self):\n"
                "        self._stock = {}\n"
                "\n"
                "    def add(self, sku, qty):\n"
                "        self._stock[sku] = self._stock.get(sku, 0) + qty\n"
                "\n"
                "    def remove(self, sku, qty):\n"
                '        """Remove qty units; stock must never go below zero."""\n'
                "        self._stock[sku] = self._stock.get(sku, 0) - qty\n"
                "\n"
                "    def stock(self, sku):\n"
                "        return self._stock.get(sku, 0)\n"
            ),
            "shop/pricing.py": (
                "def price_after_discount(base, discount_pct, tax_pct):\n"
                '    """Apply the percentage discount first, then the percentage tax.\n'
                "\n"
                "    Return the result rounded to two decimals.\n"
                '    """\n'
                "    discounted = base * (1 - discount_pct / 100.0)\n"
                "    taxed = discounted * (1 + tax_pct / 100.0)\n"
                "    return round(taxed * (1 - discount_pct / 100.0), 2)\n"
            ),
            "shop/cart.py": (
                "PRICES = {\"widget\": 9.99, \"gadget\": 24.50, \"doohickey\": 4.75}\n"
                "\n"
                "\n"
                "def total(items):\n"
                '    """Exact total for (sku, qty) pairs, rounded to two decimals at the end."""\n'
                "    total = 0\n"
                "    for sku, qty in items:\n"
                "        total += int(PRICES[sku] * qty)\n"
                "    return round(total, 2)\n"
            ),
            "tests/test_shop.py": (
                "from shop.inventory import Inventory\n"
                "from shop.pricing import price_after_discount\n"
                "from shop.cart import total\n"
                "\n"
                "\n"
                "def test_inventory_clamp():\n"
                "    inv = Inventory()\n"
                '    inv.add("a", 5)\n'
                '    inv.remove("a", 3)\n'
                '    assert inv.stock("a") == 2\n'
                '    inv.remove("a", 10)\n'
                '    assert inv.stock("a") == 0\n'
                '    inv.remove("missing", 1)\n'
                '    assert inv.stock("missing") == 0\n'
                "\n"
                "\n"
                "def test_pricing_order():\n"
                "    assert price_after_discount(100.0, 20.0, 10.0) == 88.0\n"
                "    assert price_after_discount(50.0, 10.0, 5.0) == 47.25\n"
                "    assert price_after_discount(200.0, 0.0, 7.5) == 215.0\n"
                "\n"
                "\n"
                "def test_cart_total():\n"
                '    assert total([("widget", 3), ("gadget", 2)]) == 78.97\n'
                '    assert total([("doohickey", 5)]) == 23.75\n'
                "    assert total([]) == 0\n"
                "\n"
                "\n"
                "if __name__ == \"__main__\":\n"
                "    test_inventory_clamp()\n"
                "    test_pricing_order()\n"
                "    test_cart_total()\n"
                '    print("ALL TESTS PASSED")\n'
            ),
            "main.py": (
                "from shop.inventory import Inventory\n"
                "from shop.pricing import price_after_discount\n"
                "from shop.cart import total\n"
                "\n"
                "\n"
                "def main():\n"
                "    inv = Inventory()\n"
                '    inv.add("w", 10)\n'
                '    inv.remove("w", 4)\n'
                '    inv.remove("w", 99)\n'
                '    print(inv.stock("w"))\n'
                "    print(price_after_discount(100.0, 20.0, 10.0))\n"
                '    print(total([("widget", 3), ("gadget", 2), ("doohickey", 5)]))\n'
                "\n"
                "\n"
                "if __name__ == \"__main__\":\n"
                "    main()\n"
            ),
        },
        verify=(
            "set -e\n"
            "out=$(PYTHONPATH=. python3 tests/test_shop.py 2>&1) || { echo 'test suite failed:'; echo \"$out\" | tail -5; exit 1; }\n"
            "echo \"$out\" | grep -q 'ALL TESTS PASSED' || { echo 'suite did not report success'; exit 1; }\n"
            '[ "$(md5sum tests/test_shop.py | cut -d\' \' -f1)" = "5e02385ef9938820caec355fd94860e2" ] || { echo "tests/test_shop.py was modified (not allowed)"; exit 1; }\n'
            "main=$(python3 main.py)\n"
            "expected=$(printf '0\\n88.0\\n102.72')\n"
            '[ "$main" = "$expected" ] || { echo "bad main.py output: $main"; exit 1; }\n'
            "echo PASS"
        ),
        subset=False,
    ),

    dict(
        id="html-url-dedupe",
        title="Extract and normalize URLs",
        instructions=(
            "From messy.html, produce urls.txt as follows.\n"
            "1. Find every URL: a maximal run of characters that starts with "
            '"http://" or "https://" and is followed by at least one more '
            "character, of which every character is a letter, a digit, or one "
            "of: : / ? # = & % . _ ~ + - (so a bare 'https://' with nothing "
            "after it is NOT a URL)\n"
            "2. Normalize each URL:\n"
            "   - lowercase the scheme and the host (the host is the text between "
            "'://' and the first '/' or the end)\n"
            "   - drop the fragment: everything from the first '#' onward, including "
            "the '#'\n"
            "   - drop query parameters whose key (the part before '=', or the whole "
            "parameter if there is no '=') starts with 'utm_' or is exactly 'ref'; "
            "if no parameters remain, drop the '?' too\n"
            "   - remove the final character if it is exactly '/' and the URL is not the "
            "bare root 'scheme://host/' (i.e. test the last character of the "
            "whole URL string; a URL ending in a query string is never "
            "modified). So 'https://docs.example.com/guide/' becomes "
            "'https://docs.example.com/guide', while the root "
            "'https://example.com/' keeps its slash\n"
            "3. Remove duplicates (exact string equality after normalization) and "
            "sort the remaining URLs in ascending order using plain character-code "
            "comparison.\n"
            "4. Write them to urls.txt, one URL per line, with a trailing newline."
        ),
        timeout_s=360,
        files={
            "messy.html": (
                "<html>\n"
                "<body>\n"
                '<p>Visit <a href="https://Example.com/page">the page</a> or the '
                "mirror at <a href=\"https://EXAMPLE.COM/page\">here</a>.</p>\n"
                '<p>Anchor: <a href="https://example.com/page#frag">jump</a></p>\n'
                '<p>Tracking: <a href="https://example.com/page/?utm_source=news&x=1">click</a> '
                'and <a href="https://example.com/page?x=1&utm_medium=mail">click2</a></p>\n'
                '<p>Docs: <a href="https://docs.example.com/guide/">guide</a> aka '
                '<a href="https://docs.example.com/guide">guide2</a></p>\n'
                '<p>Old: <a href="http://example.com/old">legacy</a></p>\n'
                '<p>Root: <a href="https://example.com/">home</a></p>\n'
                '<p>API: <a href="https://api.example.com/v1/items?ref=abc&id=9">list</a></p>\n'
                '<p>Blog: <a href="https://blog.example.org/post/1?utm_campaign=x">post</a> and '
                '<a href="https://blog.example.org/post/1">post2</a></p>\n'
                '<p>Search: <a href="https://example.com/search?q=a+b&y=2">search</a></p>\n'
                '<p>Not a url: ftp://nope.example.com/x and https:// (incomplete) '
                "and just text example.com/nope</p>\n"
                "</body>\n"
                "</html>\n"
            ),
        },
        verify=(
            "python3 - <<'EOF'\n"
            "import re\n"
            "raw = open('messy.html').read()\n"
            "urls = re.findall(r'https?://[A-Za-z0-9:/?#=&%._~+-]+', raw)\n"
            "\n"
            "def norm(u):\n"
            "    u = u.split('#', 1)[0]\n"
            "    if '://' not in u:\n"
            "        return None\n"
            "    scheme, rest = u.split('://', 1)\n"
            "    if '/' not in rest:\n"
            "        host, pathq = rest, ''\n"
            "    else:\n"
            "        host, pathq = rest.split('/', 1)\n"
            "        pathq = '/' + pathq\n"
            "    if '?' in pathq:\n"
            "        path, query = pathq.split('?', 1)\n"
            "        keep = []\n"
            "        for p in query.split('&'):\n"
            "            if not p:\n"
            "                continue\n"
            "            key = p.split('=', 1)[0]\n"
            "            if key.startswith('utm_') or key == 'ref':\n"
            "                continue\n"
            "            keep.append(p)\n"
            "        pathq = path + ('?' + '&'.join(keep) if keep else '')\n"
            "    out = scheme.lower() + '://' + host.lower() + pathq\n"
            "    if out.endswith('/') and not out.endswith('://' + host.lower() + '/'):\n"
            "        out = out[:-1]\n"
            "    return out\n"
            "\n"
            "seen = set()\n"
            "out = []\n"
            "for u in urls:\n"
            "    n = norm(u)\n"
            "    if n and n not in seen:\n"
            "        seen.add(n)\n"
            "        out.append(n)\n"
            "expected = ''.join(u + '\\n' for u in sorted(out))\n"
            "got = open('urls.txt').read()\n"
            "assert got == expected, ('got:', repr(got), 'expected:', repr(expected))\n"
            'print("PASS")\n'
            "EOF"
        ),
        subset=False,
    ),

    dict(
        id="build-makefile",
        title="Write a Makefile with a build log",
        instructions=(
            "Write a Makefile (the default target builds everything) with these "
            "rules:\n"
            "1. a.log: raw.txt with every occurrence of the string 'foo' replaced by "
            "'bar' (all other characters unchanged).\n"
            "2. b.log: a.log with the line 'HEADER' added as its first line.\n"
            "3. c.log: a.log immediately followed by b.log (a.log first, no extra "
            "separators).\n"
            "4. done.txt: a single line 'OK'.\n"
            "Dependencies: b.log depends on a.log; c.log depends on both a.log and "
            "b.log; done.txt depends on c.log.\n"
            "After each artifact is built, append exactly one line to build.log "
            "(use >>, never >): 'made a.log', 'made b.log', 'made c.log', 'made ok' "
            "in the order the artifacts are built.\n"
            "Starting from a clean directory (no artifacts), `make` must produce all "
            "artifacts and a build.log containing exactly those four lines. A second "
            "`make` must rebuild nothing and must not change build.log."
        ),
        timeout_s=420,
        files={
            "raw.txt": (
                "foo alpha\n"
                "beta foo\n"
                "plain line\n"
                "foo foo foo\n"
            ),
        },
        verify=(
            "set -e\n"
            "rm -f a.log b.log c.log done.txt build.log\n"
            "make > /dev/null\n"
            '[ "$(cat build.log)" = "$(printf \'made a.log\\nmade b.log\\nmade c.log\\nmade ok\')" ] || { echo "bad build.log:"; cat build.log; exit 1; }\n'
            'exp_a=$(sed \'s/foo/bar/g\' raw.txt)\n'
            '[ "$(cat a.log)" = "$exp_a" ] || { echo "bad a.log"; exit 1; }\n'
            "exp_b=$(printf 'HEADER\\n%s' \"$exp_a\")\n"
            '[ "$(cat b.log)" = "$exp_b" ] || { echo "bad b.log"; exit 1; }\n'
            'exp_c=$(printf \'%s\\n%s\' "$exp_a" "$exp_b")\n'
            '[ "$(cat c.log)" = "$exp_c" ] || { echo "bad c.log"; exit 1; }\n'
            '[ "$(cat done.txt)" = "OK" ] || { echo "bad done.txt"; exit 1; }\n'
            "make > /dev/null 2>&1 || { echo 'second make failed'; exit 1; }\n"
            '[ "$(cat build.log)" = "$(printf \'made a.log\\nmade b.log\\nmade c.log\\nmade ok\')" ] || { echo "second make changed build.log:"; cat build.log; exit 1; }\n'
            "echo PASS"
        ),
        subset=False,
    ),

    dict(
        id="jsonl-recover",
        title="Recover valid records from a corrupted JSONL",
        instructions=(
            "events.jsonl is corrupted: some lines do not parse as JSON, one record "
            "is duplicated, and the file ends with a newline. Write recover.py: it "
            "reads events.jsonl from the current directory and writes out.txt and "
            "stats.txt there. Rules:\n"
            "- read the file line by line; ignore blank lines\n"
            "- a line is valid iff json.loads succeeds AND the result is a dict with "
            "an 'event_id' that is an int and a 'msg' that is a string\n"
            "- out.txt: one line per distinct event_id among the valid lines, "
            "formatted '<event_id>|<msg>', using the first valid occurrence of each "
            "id, sorted by event_id ascending, with a trailing newline\n"
            "- stats.txt: exactly three lines, 'valid=N' (count of valid lines, "
            "including duplicates), 'duplicates=D' (valid lines minus distinct "
            "event_ids), 'dropped=M' (non-blank lines that are not valid), each "
            "line newline-terminated.\n"
            "Run it so that out.txt and stats.txt exist and are correct."
        ),
        timeout_s=360,
        files={
            "events.jsonl": (
                '{"event_id": 1, "msg": "boot"}\n'
                '{"event_id": 2, "msg": "net up"}\n'
                '{"event_id": 3, "msg": "disk ok"}\n'
                '{"event_id": 4, "msg": "user login"}\n'
                '{"event_id": 5, "msg": "job start"}\n'
                '{"event_id": 5, "msg": "job start"}\n'
                '{"event_id": 6, "msg": "cache warm"}\n'
                '{"event_id": 7, "msg": "timer"}\n'
                '{"event_id": 8, "msg": "flush"}\n'
                '{"event_id": 9, "msg": "sync"}\n'
                '{"event_id": 10, "msg": "compress"}\n'
                '{"event_id": 11, "msg": "rotate"}\n'
                '{"event_id": 12, "msg": "vacuum"}\n'
                '{"event_id": 13, "msg": "purge"}\n'
                '{"event_id": 14, "msg": "shutdown"}\n'
                '{"event_id": 15, "msg": "trunca\n'
                '{"event_id": 16, "msg": "broken\\q escape"}\n'
                '{"event_id": 17, "msg": "missing brace"\n'
                '{"event_id": 18, "msg": "ok"}\n'
            ),
        },
        verify=(
            "python3 - <<'EOF'\n"
            "import json\n"
            "recs = {}\n"
            "valid = 0\n"
            "dropped = 0\n"
            "for line in open('events.jsonl'):\n"
            "    line = line.rstrip('\\n')\n"
            "    if not line.strip():\n"
            "        continue\n"
            "    try:\n"
            "        o = json.loads(line)\n"
            "    except Exception:\n"
            "        dropped += 1\n"
            "        continue\n"
            "    if isinstance(o, dict) and isinstance(o.get('event_id'), int) and not isinstance(o.get('event_id'), bool) and isinstance(o.get('msg'), str):\n"
            "        valid += 1\n"
            "        if o['event_id'] not in recs:\n"
            "            recs[o['event_id']] = o['msg']\n"
            "    else:\n"
            "        dropped += 1\n"
            "expected_out = ''.join(f'{k}|{recs[k]}\\n' for k in sorted(recs))\n"
            "expected_stats = f'valid={valid}\\nduplicates={valid - len(recs)}\\ndropped={dropped}\\n'\n"
            "got_out = open('out.txt').read()\n"
            "got_stats = open('stats.txt').read()\n"
            "assert got_out == expected_out, ('out.txt:', repr(got_out), 'expected:', repr(expected_out))\n"
            "assert got_stats == expected_stats, ('stats.txt:', repr(got_stats), 'expected:', repr(expected_stats))\n"
            'print("PASS")\n'
            "EOF"
        ),
        subset=False,
    ),
]

SUBSET = [t for t in TASKS if t.get("subset")]
ALL = list(TASKS)

if __name__ == "__main__":
    print(f"{len(ALL)} tasks, {len(SUBSET)} in the screening subset:")
    for t in ALL:
        print(f"  {'*' if t.get('subset') else ' '} {t['id']}")
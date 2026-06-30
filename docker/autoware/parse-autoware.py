#!/usr/bin/env python3
"""parse-autoware.py — extract the reference-system hot-path latency KPI into CSV.

The autoware_reference_system command nodes print, near shutdown, a line like:
  hot path latency: <v>ms [min=<>ms, max=<>ms, average=<>ms, deviation=<>ms]
captured per (run, rmw, executable) in <logdir>/<duration>s/<rmw>/<exe>/std_output.log.

We emit one CSV row per (executable, run) with min/mean/max/std-dev (ms) — matching the
paper's Table I columns (mean/std/percentile; NOTE the stock tooling does NOT compute
percentiles, only min/max/mean/deviation, so a p99 column is left blank unless raw
per-sample data is found). Usage: parse-autoware.py <results_dir> <duration_sec> <distro>
"""
import csv
import re
import sys
import pathlib

results_dir, duration, distro = sys.argv[1], sys.argv[2], sys.argv[3]
root = pathlib.Path(results_dir)

# hot path latency: 12.34ms [min=1.0ms, max=30.0ms, average=11.0ms, deviation=2.0ms]
# Each number capture also accepts signs and scientific notation (e.g. 1.2e+06, 3.4e-05)
# — the reference-system uses default double (%g-style) formatting, which can emit those
# for a degenerate/long run; a plain ([\d.]+) would fail to match and silently drop the row.
_NUM = r"[-+]?[\d.]+(?:[eE][-+]?\d+)?"
LAT_RE = re.compile(
    rf"hot path latency:\s*({_NUM})ms\s*\[min=({_NUM})ms,\s*max=({_NUM})ms,\s*"
    rf"average=({_NUM})ms,\s*deviation=({_NUM})ms\]", re.I)
DROP_RE = re.compile(r"hot path drops:\s*(\d+)", re.I)

writer = csv.writer(sys.stdout)
writer.writerow(["distro", "executor", "run", "duration_s",
                 "last_ms", "min_ms", "max_ms", "mean_ms", "stddev_ms", "p99_ms", "drops"])

rows = 0
# Walk run_* dirs; each contains <duration>s/<rmw>/<exe>/std_output.log
for run_dir in sorted(root.glob("run_*")):
    run_id = run_dir.name.replace("run_", "")
    for log in sorted(run_dir.rglob("std_output.log")):
        # path: .../<duration>s/<rmw>/<exe>/std_output.log
        exe = log.parent.name
        txt = log.read_text(errors="replace")
        m = None
        for m in LAT_RE.finditer(txt):
            pass  # keep the LAST occurrence (final aggregated stats)
        drop = DROP_RE.findall(txt)
        drops = drop[-1] if drop else ""
        if m:
            last, mn, mx, avg, dev = m.groups()
            writer.writerow([distro, exe, run_id, duration, last, mn, mx, avg, dev, "", drops])
            rows += 1
        else:
            # No latency line found — record the gap so it isn't silently dropped.
            writer.writerow([distro, exe, run_id, duration, "", "", "", "", "", "", drops])

if rows == 0:
    sys.stderr.write(
        f"WARN: no 'hot path latency' lines found under {root}. "
        "Check the run logs — the node may not have printed stats (too-short duration?).\n")

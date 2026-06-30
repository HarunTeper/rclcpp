#!/usr/bin/env python3
"""render-comparison.py — turn two google-benchmark JSON files + starvation logs
into docker/results/comparison-<distro>.md (the 3-way comparison table).

Inputs (positional):
  distro  results_dir  fixed_ref  baseline_ref  reps

Reads from results_dir:
  bench_fixed-<distro>.json, bench_baseline-<distro>.json   (google-benchmark JSON)
  starvation-fixed-<distro>.txt, starvation-baseline-<distro>.txt

Methodology recap (so the table is self-documenting):
  multi_thread_* rows  -> compare fixed vs baseline   = fixed-MTE vs unfixed-MTE overhead
  cbg_executor_*  rows -> EventsCBGExecutor (same code both refs; report the fixed-ref value)
  single_thread_* rows -> sanity control (fix must not perturb the single-threaded path)
"""
import json
import re
import sys
import pathlib

distro, results_dir, fixed_ref, baseline_ref, reps = sys.argv[1:6]
R = pathlib.Path(results_dir)


def load(label):
    p = R / f"bench_{label}-{distro}.json"
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"WARN: could not parse {p}: {e}\n")
        return None


fixed = load("fixed")
baseline = load("baseline")


def index_benchmarks(doc):
    """name -> aggregate entry. Prefer *_mean aggregate; fall back to the single run.

    google-benchmark with --benchmark_report_aggregates_only emits entries named
    '<name>_mean', '<name>_median', '<name>_stddev', '<name>_cv'. We key on the
    base <name> and keep the mean (and stddev for reporting)."""
    out = {}
    if not doc:
        return out
    for b in doc.get("benchmarks", []):
        name = b.get("name", "")
        agg = b.get("aggregate_name", "")          # 'mean','median','stddev','cv' or ''
        base = b.get("run_name", name)             # run_name strips the _mean suffix
        slot = out.setdefault(base, {})
        if agg:
            slot[agg] = b
        else:
            slot.setdefault("single", b)
    return out


fi = index_benchmarks(fixed)
bi = index_benchmarks(baseline)

# Allocation-counter discovery: performance_test_fixture adds heap counters whose
# exact key names vary by version. Match anything alloc/heap-ish.
ALLOC_RE = re.compile(r"(alloc|heap|free|malloc|new_delete)", re.I)


def numeric_counters(entry):
    """Return {counter_name: value} for numeric, non-bookkeeping fields of one entry."""
    skip = {"iterations", "real_time", "cpu_time", "threads", "repetitions",
            "repetition_index", "per_family_instance_index", "family_index"}
    out = {}
    for k, v in entry.items():
        if k in skip:
            continue
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            out[k] = v
    return out


def get_mean(slot, field):
    """Mean value of `field` for a benchmark slot (mean aggregate, else single run)."""
    if not slot:
        return None
    e = slot.get("mean") or slot.get("single")
    if not e:
        return None
    return e.get(field)


def get_stddev_time(slot):
    e = slot.get("stddev")
    return e.get("real_time") if e else None


def get_alloc(slot):
    """Sum of all allocation-ish counters (mean) for a slot."""
    if not slot:
        return None
    e = slot.get("mean") or slot.get("single")
    if not e:
        return None
    total = 0.0
    found = False
    for k, v in numeric_counters(e).items():
        if ALLOC_RE.search(k):
            total += v
            found = True
    return total if found else None


def time_unit(slot):
    if not slot:
        return ""
    e = slot.get("mean") or slot.get("single")
    return e.get("time_unit", "") if e else ""


def pct_delta(new, base):
    if new is None or base is None or base == 0:
        return None
    return (new - base) / base * 100.0


def fmt(v, unit=""):
    if v is None:
        return "—"
    if abs(v) >= 1000:
        return f"{v:,.0f}{(' ' + unit) if unit else ''}"
    return f"{v:.3g}{(' ' + unit) if unit else ''}"


def fmt_delta(d):
    if d is None:
        return "—"
    sign = "+" if d >= 0 else ""
    return f"{sign}{d:.2f}%"


# --- starvation parsing -------------------------------------------------------
# The test prints, on failure, gtest `<<` messages:
#   "timer_one never executed (starved)"  /  "timer_two never executed (starved)"
#   "counts diverged: one=<n> two=<n>"
# and a per-test `[ OK ]` / `[ FAILED ]` line. We key the verdict on the latter.
def _verdict_for(txt, test_name):
    if re.search(rf"\[\s*OK\s*\][^\n]*{re.escape(test_name)}", txt):
        return "OK"
    if re.search(rf"\[\s*FAILED\s*\][^\n]*{re.escape(test_name)}", txt):
        return "STARVES"
    if test_name not in txt:
        return "n/a"   # test not compiled/run in this build
    return "?"


def _evidence(txt):
    ev = re.search(r"counts diverged:\s*one=(\d+)\s*two=(\d+)", txt, re.I)
    if ev:
        return f"one={ev.group(1)} two={ev.group(2)}"
    starved = re.findall(r"timer_(one|two) never executed \(starved\)", txt)
    if starved:
        return "timer_" + "+".join(sorted(set(starved))) + " never executed (starved)"
    return ""


def parse_starvation(label):
    """Return (verdict, detail) for the MTE starvation test in this label's log."""
    p = R / f"starvation-{label}-{distro}.txt"
    if not p.exists():
        return "log missing", ""
    txt = p.read_text(errors="replace")
    return _verdict_for(txt, "starvation_mutually_exclusive_timers"), _evidence(txt)


fixed_starv, fixed_detail = parse_starvation("fixed")
base_starv, base_detail = parse_starvation("baseline")

# EventsCBG starvation: twin starvation_eventscbg_passes (compiled in both refs since
# the events_cbg_executor.hpp __has_include guard is satisfied on upstream too). Prefer
# the fixed-ref log; fall back to baseline.
def eventscbg_starv():
    for label in ("fixed", "baseline"):
        p = R / f"starvation-{label}-{distro}.txt"
        if p.exists():
            v = _verdict_for(p.read_text(errors="replace"), "starvation_eventscbg_passes")
            if v != "n/a":
                return v
    return "n/a"


# --- scenarios to report ------------------------------------------------------
# Each tuple: (display label, fixed-key prefix, mte-key, cbg-key, st-key)
# google-benchmark run_name for a BENCHMARK_F(Fixture, name) is "Fixture/name".
SCENARIOS = [
    ("spin_some (basic)",
     "PerformanceTestExecutor/single_thread_executor_spin_some",
     "PerformanceTestExecutor/multi_thread_executor_spin_some",
     "PerformanceTestExecutor/cbg_executor_spin_some"),
    ("MultipleCallbackGroups spin_some",
     "PerformanceTestExecutorMultipleCallbackGroups/single_thread_executor_spin_some",
     "PerformanceTestExecutorMultipleCallbackGroups/multi_thread_executor_spin_some",
     "PerformanceTestExecutorMultipleCallbackGroups/cbg_executor_spin_some"),
    ("Cascaded spin",
     "CascadedPerformanceTestExecutor/single_thread_executor_spin",
     "CascadedPerformanceTestExecutor/multi_thread_executor_spin",
     "CascadedPerformanceTestExecutor/cbg_executor_spin"),
    ("wait_for_work",
     "PerformanceTestExecutor/single_thread_executor_wait_for_work",
     "PerformanceTestExecutor/multi_thread_executor_wait_for_work",
     None),
    ("wait_for_work_rebuild",
     "PerformanceTestExecutor/single_thread_executor_wait_for_work_rebuild",
     "PerformanceTestExecutor/multi_thread_executor_wait_for_work_rebuild",
     None),
]

lines = []
A = lines.append
A(f"# MTE starvation fix — 3-way comparison ({distro})")
A("")
A(f"- **fixed ref:** `{fixed_ref}`  ·  **baseline ref:** `{baseline_ref}`")
A(f"- **benchmark:** `benchmark_executor` (upstream's own), `-DCMAKE_BUILD_TYPE=Release`, "
  f"`--benchmark_repetitions={reps}` aggregates-only (mean ± stddev).")
A("- **method:** the fix changes `MultiThreadedExecutor` in place, so *fixed vs unfixed MTE* "
  "= same benchmark binary built from the fix ref vs pristine upstream. `cbg_executor_*` rows "
  "are the `EventsCBGExecutor` (same code in both refs).")
A("")

# --- headline starvation table ------------------------------------------------
A("## Starvation (the bug)")
A("")
A("| Executor | Starvation-free? | Evidence |")
A("|---|---|---|")
A(f"| unfixed MTE | **{base_starv}** | {base_detail or '—'} |")
A(f"| fixed MTE | **{fixed_starv}** | {fixed_detail or '—'} |")
A(f"| EventsCBGExecutor | **{eventscbg_starv()}** | twin test `starvation_eventscbg_passes` |")
A("")

# --- overhead table: fixed MTE vs unfixed MTE --------------------------------
A("## MTE overhead — fixed vs unfixed (same binary)")
A("")
A("`real_time` is mean over repetitions; `Δ` = (fixed − unfixed)/unfixed. "
  "Allocations = sum of heap/alloc counters from `performance_test_fixture`.")
A("")
A("| Scenario | unfixed real_time | fixed real_time | Δ time | unfixed allocs | fixed allocs | Δ allocs |")
A("|---|---|---|---|---|---|---|")
for disp, stk, mtk, cbgk in SCENARIOS:
    mtf, mtb = fi.get(mtk), bi.get(mtk)
    if not mtf and not mtb:
        continue
    unit = time_unit(mtf) or time_unit(mtb)
    t_b = get_mean(mtb, "real_time")
    t_f = get_mean(mtf, "real_time")
    a_b = get_alloc(mtb)
    a_f = get_alloc(mtf)
    A(f"| {disp} | {fmt(t_b, unit)} | {fmt(t_f, unit)} | {fmt_delta(pct_delta(t_f, t_b))} "
      f"| {fmt(a_b)} | {fmt(a_f)} | {fmt_delta(pct_delta(a_f, a_b))} |")
A("")

# --- cross-executor table: fixed MTE vs EventsCBG vs SingleThread (fixed ref) -
A("## Cross-executor (fixed ref) — MTE vs EventsCBGExecutor vs SingleThreaded")
A("")
A("All three from the fixed-ref binary, so they share build flags & machine state.")
A("")
A("| Scenario | SingleThreaded | MTE (fixed) | EventsCBG | MTE allocs | EventsCBG allocs |")
A("|---|---|---|---|---|---|")
for disp, stk, mtk, cbgk in SCENARIOS:
    stf = fi.get(stk) if stk else None
    mtf = fi.get(mtk) if mtk else None
    cbgf = fi.get(cbgk) if cbgk else None
    if not (stf or mtf or cbgf):
        continue
    unit = time_unit(mtf) or time_unit(cbgf) or time_unit(stf)
    A(f"| {disp} | {fmt(get_mean(stf,'real_time'), unit)} "
      f"| {fmt(get_mean(mtf,'real_time'), unit)} "
      f"| {fmt(get_mean(cbgf,'real_time'), unit)} "
      f"| {fmt(get_alloc(mtf))} | {fmt(get_alloc(cbgf))} |")
A("")

# --- raw counter discovery note ----------------------------------------------
def discovered_counters(idx):
    names = set()
    for slot in idx.values():
        e = slot.get("mean") or slot.get("single")
        if e:
            names |= {k for k in numeric_counters(e) if ALLOC_RE.search(k)}
    return sorted(names)


disc = discovered_counters(fi) or discovered_counters(bi)
disc_str = ", ".join(disc) if disc else \
    "NONE FOUND — fixture may not emit heap counters in this build"
A("---")
A(f"_Allocation counters summed: {disc_str}._")
A(f"_Benchmarks present (fixed): {len(fi)}; (baseline): {len(bi)}._")

out = R / f"comparison-{distro}.md"
out.write_text("\n".join(lines) + "\n")
print(f"  wrote {out}")

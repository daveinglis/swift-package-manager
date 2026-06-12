#!/usr/bin/env python3
# ===----------------------------------------------------------------------===##
#
# This source file is part of the Swift open source project
#
# Copyright (c) 2026 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
#
# ===----------------------------------------------------------------------===##
"""Summarize or diff swift-testing event-stream runs.

The event stream is produced by `swift test --event-stream-output-path FILE`
(as `Utilities/build-using-self` already does). Use this to find the long-pole
test targets/classes in a run, or to A/B two runs -- e.g. measuring the wall-time
win from Windows Defender exclusions on a self-hosted CI agent.

Usage:
  test-timing.py RUN                 # summarize one run
  test-timing.py BASELINE TREATMENT  # diff two runs (e.g. defender-on vs -off)

Accepts either a raw --event-stream-output-path JSONL file or a captured console
log where each event line is prefixed with a "[timestamp]".

Note: per-target / per-class numbers are summed across overlapping parallel test
cases, so they are inflated by contention and are useful for *attribution*, not as
wall time. The honest top-line metric is "wall time" (runStarted -> runEnded).
"""
import json
import os
import re
import sys
from collections import defaultdict

TS = re.compile(r'^\s*\[[^\]]+\]\s*')   # optional leading "[timestamp]" console prefix


def parse(path):
    """Return a dict of timing metrics for one event-stream run."""
    run_start = run_end = None
    open_t = {}                       # testID -> start (suites + single tests)
    single = {}                       # leaf function testID -> duration
    open_cases = defaultdict(list)    # parameterized: testID -> [start, ...]
    case_dur = defaultdict(float)     # parameterized: testID -> summed duration
    case_n = defaultdict(int)
    issues = defaultdict(int)
    n_started = n_skipped = 0

    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            stripped = TS.sub('', line).strip()
            if not stripped.startswith('{"kind":"event"'):
                continue
            try:
                ev = json.loads(stripped)
            except ValueError:
                continue
            payload = ev["payload"]
            kind = payload.get("kind")
            instant = payload.get("instant", {}).get("absolute")
            tid = payload.get("testID")
            if kind == "runStarted":
                run_start = instant
            elif kind == "runEnded":
                run_end = instant
            elif kind == "testStarted":
                open_t[tid] = instant
                n_started += 1
            elif kind == "testEnded":
                # only leaf functions (testID has a "(...)" signature); skip suites
                if tid in open_t and "(" in (tid or ""):
                    single[tid] = instant - open_t[tid]
                open_t.pop(tid, None)
            elif kind == "testCaseStarted":
                open_cases[tid].append(instant)
            elif kind == "testCaseEnded":
                if open_cases[tid]:
                    case_dur[tid] += instant - open_cases[tid].pop()
                    case_n[tid] += 1
            elif kind == "testSkipped":
                n_skipped += 1
            elif kind == "issueRecorded":
                issues[(tid or "?").split(".")[0]] += 1

    # A leaf is a parameterized test (summed across its cases) or a single function.
    leaf = {tid: (dur, case_n[tid]) for tid, dur in case_dur.items()}
    for tid, dur in single.items():
        leaf.setdefault(tid, (dur, 1))

    by_target = defaultdict(lambda: [0.0, 0])
    by_class = defaultdict(lambda: [0.0, 0])
    for tid, (dur, count) in leaf.items():
        target = (tid or "?").split(".")[0]
        by_target[target][0] += dur
        by_target[target][1] += count
        parts = tid.split("/")
        func_idx = [i for i, seg in enumerate(parts) if "(" in seg]
        key = "/".join(parts[:func_idx[0]]) if func_idx else "/".join(parts[:-1]) or tid
        by_class[key][0] += dur
        by_class[key][1] += count

    return {
        "wall": (run_end - run_start) if (run_start and run_end) else None,
        "leaf_total": sum(dur for dur, _ in leaf.values()),
        "n_tests": n_started,
        "n_skipped": n_skipped,
        "n_leaf": len(leaf),
        "by_target": {k: tuple(v) for k, v in by_target.items()},
        "by_class": {k: tuple(v) for k, v in by_class.items()},
        "issues": dict(issues),
    }


def fmt_min(seconds):
    return "n/a" if seconds is None else f"{seconds / 60:.1f} min"


def summary(path, run):
    print(f"=== {os.path.basename(path)} ===")
    print(f"wall (runStarted->runEnded): {fmt_min(run['wall'])}")
    print(f"leaf-test core-time:         {run['leaf_total'] / 3600:.1f} core-hours")
    print(f"tests: {run['n_tests']} run, {run['n_skipped']} skipped, {run['n_leaf']} leaf")
    print("\nper target (leaf core-min):")
    for target, (total, count) in sorted(run["by_target"].items(), key=lambda x: -x[1][0]):
        print(f"  {total / 60:8.1f}  {count:5d}  {target}")
    print("\ntop 15 classes (leaf core-min):")
    for key, (total, count) in sorted(run["by_class"].items(), key=lambda x: -x[1][0])[:15]:
        print(f"  {total / 60:8.1f}  {count:5d}  {key}")
    if run["issues"]:
        print("\nissues recorded:", run["issues"])


def diff(path_a, run_a, path_b, run_b):
    name_a, name_b = os.path.basename(path_a), os.path.basename(path_b)
    print(f"=== DIFF  baseline={name_a}  treatment={name_b} ===\n")

    def row(name, val_a, val_b, unit="min", scale=60.0):
        if val_a is None or val_b is None:
            print(f"{name:28s} {str(val_a):>12} {str(val_b):>12}")
            return
        scaled_a, scaled_b = val_a / scale, val_b / scale
        ratio = (val_a / val_b) if val_b else float("inf")
        print(f"{name:28s} {scaled_a:10.1f}{unit:>4} {scaled_b:10.1f}{unit:>4}   "
              f"delta {scaled_a - scaled_b:+8.1f}{unit}  {ratio:5.2f}x")

    print(f"{'metric':28s} {'baseline':>14} {'treatment':>14}   {'change':>22}")
    row("wall time", run_a["wall"], run_b["wall"])
    row("leaf core-time", run_a["leaf_total"], run_b["leaf_total"], unit="h", scale=3600.0)
    print()

    print("per-target (leaf core-min)  baseline -> treatment  (ratio):")
    keys = sorted(
        set(run_a["by_target"]) | set(run_b["by_target"]),
        key=lambda k: -max(run_a["by_target"].get(k, (0,))[0],
                           run_b["by_target"].get(k, (0,))[0]),
    )
    for key in keys:
        total_a = run_a["by_target"].get(key, (0.0, 0))[0]
        total_b = run_b["by_target"].get(key, (0.0, 0))[0]
        ratio = (total_a / total_b) if total_b else float("inf")
        print(f"  {key:24s} {total_a / 60:8.1f} -> {total_b / 60:8.1f}   {ratio:5.2f}x")

    if run_a["wall"] and run_b["wall"]:
        saved = (run_a["wall"] - run_b["wall"]) / 60
        pct = (1 - run_b["wall"] / run_a["wall"]) * 100
        print(f"\n>> wall-time saved: {saved:+.1f} min ({pct:+.0f}%), "
              f"speedup {run_a['wall'] / run_b['wall']:.2f}x")


def main(argv):
    if len(argv) == 2:
        summary(argv[1], parse(argv[1]))
    elif len(argv) == 3:
        diff(argv[1], parse(argv[1]), argv[2], parse(argv[2]))
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

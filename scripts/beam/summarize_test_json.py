#!/usr/bin/env python3
"""Summarise a `flutter test --file-reporter json:<file>` log.

Usage: python3 -I scripts/beam/summarize_test_json.py <report.json> [--slowest N]

Prints pass / fail / error / skip counts, suites that failed to load (compile
errors), every failing test with its first error line, and the slowest tests.
Exit code 0 when nothing failed, 1 otherwise.
"""
import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    slowest_n = 10
    if "--slowest" in sys.argv:
        slowest_n = int(sys.argv[sys.argv.index("--slowest") + 1])

    suites, tests, errors, done = {}, {}, {}, {}
    total_time_ms = 0
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            kind = ev.get("type")
            if kind == "suite":
                suites[ev["suite"]["id"]] = ev["suite"].get("path") or "?"
            elif kind == "testStart":
                t = ev["test"]
                tests[t["id"]] = {
                    "name": t["name"],
                    "suite": t.get("suiteID"),
                    "start": ev["time"],
                }
            elif kind == "error":
                errors.setdefault(ev["testID"], []).append(ev.get("error", ""))
            elif kind == "testDone":
                done[ev["testID"]] = ev
            elif kind == "done":
                total_time_ms = ev.get("time", 0)

    counts = {"success": 0, "failure": 0, "error": 0, "skipped": 0}
    load_failures, failures, durations, skipped = [], [], [], []
    for tid, ev in done.items():
        t = tests.get(tid, {"name": "?", "suite": None, "start": ev["time"]})
        suite = suites.get(t["suite"], "?")
        if ev.get("hidden") and ev.get("result") == "success":
            continue  # setUpAll/tearDownAll bookkeeping entries
        if ev.get("skipped"):
            counts["skipped"] += 1
            skipped.append((suite, t["name"]))
            continue
        result = ev.get("result", "error")
        is_load = t["name"].startswith("loading ")
        if result == "success":
            counts["success"] += 1
            durations.append((ev["time"] - t["start"], suite, t["name"]))
        else:
            first = (errors.get(tid) or [""])[0].strip().splitlines()
            msg = first[0] if first else ""
            if is_load:
                load_failures.append((suite, msg))
            else:
                counts[result if result in counts else "error"] += 1
                failures.append((suite, t["name"], msg))

    print(f"suites: {len(suites)}  load failures: {len(load_failures)}")
    print(
        "tests: passed={success} failed={failure} errored={error} skipped={skipped}".format(
            **counts
        )
    )
    print(f"wall time: {total_time_ms / 1000:.1f}s")
    if load_failures:
        print("\nSUITES THAT FAILED TO LOAD:")
        for suite, msg in sorted(load_failures):
            print(f"  {suite}\n      {msg[:200]}")
    if failures:
        print("\nFAILING TESTS:")
        for suite, name, msg in sorted(failures):
            print(f"  {suite} :: {name}\n      {msg[:200]}")
    if skipped:
        print("\nSKIPPED:")
        for suite, name in sorted(skipped):
            print(f"  {suite} :: {name}")
    if durations:
        print(f"\nSLOWEST {slowest_n} PASSING TESTS:")
        for ms, suite, name in sorted(durations, reverse=True)[:slowest_n]:
            print(f"  {ms / 1000:7.2f}s  {suite} :: {name}")
    return 1 if (failures or load_failures) else 0


if __name__ == "__main__":
    sys.exit(main())

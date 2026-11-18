#!/usr/bin/env python3
"""Compare a counted walk with the WHOOP 5.0 on-strap step counter NOOP stored (issue #25).

Run on a COPY of NOOP's database (Settings > Data > export, or `sqlite3 whoop.sqlite ".backup copy.sqlite"`), never on
the live file. Read-only. Prints only aggregates for the window you give; nothing is written anywhere.

    python3 step_walk_check.py COPY.sqlite --start "2026-11-17 15:00:00" --end "2026-11-17 15:10:00" --counted 500

Times are local wall-clock (this Mac's time zone). The counter is UNVALIDATED: this script is how it gets validated.
Mirrors `StepCounterSample.window` in WhoopProtocol: increases between the last row at/before start and the last row
before end; at a decrease (a reset) the post-reset value counts as steps since the reset. Activity seconds are
not gap-aware here (the app's version stops at missing seconds): use windows with continuous sync.
"""
import argparse
import datetime
import sqlite3
import sys


def window(rows, start, end):
    rows = sorted(rows)
    ref = [r for r in rows if r[0] <= start]
    ref = ref[-1] if ref else None
    inside = [r for r in rows if start < r[0] < end]
    steps = resets = 0
    prev = ref[1] if ref else None
    for ts, counter, _ in inside:
        if prev is not None:
            if counter >= prev:
                steps += counter - prev
            else:
                resets += 1
                steps += counter
        prev = counter
    chain = ([ref] if ref else []) + inside
    active = 0
    for i, (ts, _, act) in enumerate(chain):
        if act == 1:
            a, b = max(ts, start), chain[i + 1][0] if i + 1 < len(chain) else end
            active += max(0, b - a)
    return {"steps": steps, "resets": resets, "has_start_reference": ref is not None, "activity_1_seconds": active,
            "rows": len(inside)}


def local_unix(text):
    return int(datetime.datetime.strptime(text, "%Y-%m-%d %H:%M:%S").astimezone().timestamp())


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("db")
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--counted", type=int, help="steps you counted by hand")
    ap.add_argument("--device", help="deviceId (default: the only one with step rows)")
    a = ap.parse_args(argv)
    start, end = local_unix(a.start), local_unix(a.end)
    if end <= start:
        sys.exit("end must be after start")
    con = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)
    try:
        devices = [r[0] for r in con.execute("SELECT DISTINCT deviceId FROM stepCounterSample")]
    except sqlite3.OperationalError:
        sys.exit("no stepCounterSample table: this database predates schema v19")
    device = a.device or (devices[0] if len(devices) == 1 else None)
    if device is None:
        sys.exit(f"pass --device (found {len(devices)} devices with step rows)")
    rows = con.execute("SELECT ts, counter, activity FROM stepCounterSample WHERE deviceId = ? AND ts <= ?",
                       (device, end)).fetchall()
    newest = con.execute("SELECT max(ts) FROM stepCounterSample WHERE deviceId = ?", (device,)).fetchone()[0]
    r = window(rows, start, end)
    print(f"window {a.start} -> {a.end} ({end - start} s)")
    if newest is None or newest < end:
        print("WARNING: stored data ends before the window does - let NOOP sync, then copy the database again")
    print(f"strap steps {r['steps']}  resets {r['resets']}  activity-1 seconds {r['activity_1_seconds']}  "
          f"change rows {r['rows']}  start reference {'yes' if r['has_start_reference'] else 'NO'}")
    if a.counted:
        diff = r["steps"] - a.counted
        print(f"counted {a.counted}  difference {diff:+d} ({100 * diff / a.counted:+.1f} %)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

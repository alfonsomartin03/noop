#!/usr/bin/env python3
"""List every WHOOP 5.0 step-counter decrease with the observation interval that bounds it (issue #25). Read-only.

    python3 -I step_reset_scan.py --db COPY.sqlite
    python3 -I step_reset_scan.py --raw PULL.jsonl [...]      # NOOP manual-pull / probe JSONL with v0x12 records

Run on COPIES only. Prints counter values and times of transitions only (no HR or other health values).

Why a bound and not a time: NOOP stores change points (`StepCounterSample.changePoints`), so an unchanged counter over
a stretch looks the same whether records exist or not. Record presence is therefore taken from the other per-second
streams written from the same v0x12 records (gravitySample, hrSample, skinTempSample). For each decrease we report
  last_seen_before  = latest record second before the first lower value (any stream), and
  first_lower       = the stored row with the lower value.
The reset happened in (last_seen_before, first_lower]; `gap_s` is that interval's length. A gap > 1 s means the reset
time is not known to the second. Times are STRAP clock (see strap_clock_offset.py: ~40 s behind the Mac in Nov 2026).

Each decrease is tested against candidate boundaries (local midnight in this Mac's zone, UTC midnight) and against a
16-bit wrap (previous value within 1,000 of 65,535 and the new value small). Several boundaries can be inside one
interval; then the data cannot tell them apart and the script says so.
"""
import argparse
import datetime
import glob
import sqlite3
import struct
import sys

U16 = 65535


def boundaries_in(lo, hi):
    """Which candidate day boundaries lie in the half-open interval (lo, hi] (unix seconds)."""
    out = []
    d = datetime.datetime.fromtimestamp(lo).date()
    while True:
        local_mid = int(datetime.datetime.combine(d + datetime.timedelta(days=1), datetime.time()).astimezone().timestamp())
        if local_mid > hi:
            break
        if local_mid > lo:
            out.append("local-midnight")
        d += datetime.timedelta(days=1)
    day = 86400
    u = (lo // day + 1) * day
    while u <= hi:
        out.append("utc-midnight")
        u += day
    return sorted(set(out))


def scan(changes, presence):
    """changes: [(ts, counter, activity)] change points; presence: sorted list of record seconds (may be empty).
    Returns one dict per decrease."""
    import bisect
    changes = sorted(changes)
    out = []
    for (t0, c0, _), (t1, c1, a1) in zip(changes, changes[1:]):
        if c1 >= c0:
            continue
        i = bisect.bisect_left(presence, t1)
        seen = presence[i - 1] if i > 0 else None
        last = max(t0, seen) if seen is not None else t0
        wrap = c0 >= U16 - 1000 and c1 < 1000
        out.append({"prev_ts": t0, "prev": c0, "last_seen_before": last, "first_lower": t1, "value": c1,
                    "activity": a1, "gap_s": t1 - last, "boundaries": boundaries_in(last, t1),
                    "wrap_plausible": wrap})
    return out


def from_db(path):
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    changes = con.execute("select ts, counter, activity from stepCounterSample order by ts").fetchall()
    if not changes:
        return [], []
    lo, hi = changes[0][0], changes[-1][0]
    pres = set()
    for table in ("gravitySample", "hrSample", "skinTempSample"):
        pres.update(r[0] for r in con.execute(f"select ts from {table} where ts between ? and ?", (lo, hi)))
    return changes, sorted(pres)


def from_raw(paths):
    import json
    recs = {}
    for path in paths:
        for line in open(path):
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            h = r.get("hex", "")
            if not h or h.startswith("<"):
                continue
            f = bytes.fromhex(h)
            p = f[8:-4]
            if len(p) >= 67 and p[0] == 47 and p[1] == 0x12:
                recs.setdefault(struct.unpack_from("<I", p, 7)[0], (struct.unpack_from("<H", p, 49)[0], p[55]))
    every = [(t, c, a) for t, (c, a) in sorted(recs.items())]
    return every, sorted(recs)


def fmt(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--db")
    ap.add_argument("--raw", nargs="*", default=[])
    a = ap.parse_args(argv)
    if not a.db and not a.raw:
        ap.error("give --db and/or --raw")
    changes, pres = [], []
    if a.db:
        c, p = from_db(a.db)
        changes += c
        pres += p
    if a.raw:
        files = [f for g in a.raw for f in glob.glob(g)]
        c, p = from_raw(files)
        changes += c
        pres += p
    changes = sorted(set(changes))
    pres = sorted(set(pres))
    if not changes:
        print("no step-counter rows")
        return 1
    print(f"step rows {len(changes)}  span {fmt(changes[0][0])} -> {fmt(changes[-1][0])} (strap clock, local zone)  "
          f"record seconds {len(pres)}  max counter {max(c for _, c, _ in changes)}")
    found = scan(changes, pres)
    if not found:
        print("no decreases: reset timing not observable in this data")
    for r in found:
        b = ", ".join(r["boundaries"]) or "none"
        print(f"decrease {r['prev']} -> {r['value']}: reset in ({fmt(r['last_seen_before'])}, {fmt(r['first_lower'])}] "
              f"gap {r['gap_s']} s; boundaries inside: {b}; 16-bit wrap plausible: {r['wrap_plausible']}; "
              f"first lower value activity {r['activity']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

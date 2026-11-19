#!/usr/bin/env python3
"""Test competing explanations for WHOOP 5.0 event 120 fields (issue #25). Offline, stdlib only, read-only.

    python3 -I event120_check.py COPY.sqlite                 # exploratory scan (every field x explanation)
    python3 -I event120_check.py COPY.sqlite --holdout       # frozen candidates on reports from HOLDOUT_FROM only

Run on a SQLite-backup COPY of NOOP's database. Prints correlations and counts only (no per-report values).

Event 120 arrives every 2 h. For every body offset (u8, and u16 LE) the script correlates the field with candidate
explanations computed from NOOP's own stored streams (strap clock, same as the event timestamp):
  hr_prev / hr_next   mean HR over the 2 h before / after the report (causal vs. delayed vs. predictive timing)
  hr_sd_prev          HR standard deviation over the 2 h before
  move_prev           mean |gravity change| per second over the 2 h before (movement)
  cover_prev          fraction of the 2 h before with an HR row (recording coverage / wear)
  hour                local hour of day (time-of-day confound)
Controls:
  - every field is correlated with the hour-of-day bin means removed from BOTH sides (residuals), so a field that
    just follows the daily cycle does not look like an HR measure;
  - multiple comparisons: |r| must exceed the Bonferroni threshold for (fields x explanations) at alpha 0.05
    (normal approximation, r_crit = z / sqrt(n - 3) on Fisher z);
  - replication: a pass must hold in BOTH halves of the reports (split by time), with the same sign.
Fields constant over all reports are listed as constant. A field that passes nothing stays UNKNOWN.

--holdout (issue #45, frozen 2026-11-19 before any report from HOLDOUT_FROM existed): tests only the FROZEN candidates
that came closest on the exploratory scan, with their predicted sign, on reports at or after HOLDOUT_FROM (local), with
the same time-of-day residuals and a Bonferroni threshold over len(FROZEN) tests. Below MIN_HOLDOUT reports it prints
UNDERPOWERED and no verdict. A candidate is SUPPORTED only with the predicted sign and |r| above the threshold; its
meaning stays a hypothesis either way (correlation with NOOP's own streams is not a decode).
"""
import json
import math
import sqlite3
import statistics
import struct
import sys
from statistics import NormalDist

WIN = 7200
HOLDOUT_FROM = "2026-11-20"
MIN_HOLDOUT = 80
# (field, explanation, predicted sign): exploratory 2026-11-19 on 219 reports (11-02 .. 11-19), r after time-of-day
# removal: u16@18 ~ hr_prev +0.32, u16@21 ~ hr_next -0.31, u8@9 ~ move_prev -0.43 (halves agreed in sign; per-half
# Bonferroni not reached).
FROZEN = (("u16@18", "hr_prev", +1), ("u16@21", "hr_next", -1), ("u8@9", "move_prev", -1))


def pearson(x, y):
    if len(x) < 5:
        return float("nan")
    mx, my = statistics.mean(x), statistics.mean(y)
    den = math.sqrt(sum((a - mx) ** 2 for a in x) * sum((b - my) ** 2 for b in y))
    return sum((a - mx) * (b - my) for a, b in zip(x, y)) / den if den else float("nan")


def residualize(values, groups):
    by = {}
    for v, g in zip(values, groups):
        by.setdefault(g, []).append(v)
    means = {g: statistics.mean(v) for g, v in by.items()}
    return [v - means[g] for v, g in zip(values, groups)]


def bonferroni_r(n, tests, alpha=0.05):
    z = NormalDist().inv_cdf(1 - alpha / (2 * tests))
    return math.tanh(z / math.sqrt(n - 3))


def fields(body):
    out = {}
    for i in range(len(body)):
        out[f"u8@{i}"] = body[i]
    for i in range(len(body) - 1):
        out[f"u16@{i}"] = struct.unpack_from("<H", body, i)[0]
    return out


def explain(con, dev, t):
    hr_prev = [r[0] for r in con.execute("select bpm from hrSample where deviceId=? and ts>=? and ts<?", (dev, t - WIN, t))]
    hr_next = [r[0] for r in con.execute("select bpm from hrSample where deviceId=? and ts>=? and ts<?", (dev, t, t + WIN))]
    g = con.execute("select x,y,z from gravitySample where deviceId=? and ts>=? and ts<? order by ts", (dev, t - WIN, t)).fetchall()
    move = statistics.mean(math.dist(a, b) for a, b in zip(g, g[1:])) if len(g) > 10 else None
    if len(hr_prev) < 600 or len(hr_next) < 600 or move is None:
        return None
    return {"hr_prev": statistics.mean(hr_prev), "hr_next": statistics.mean(hr_next),
            "hr_sd_prev": statistics.pstdev(hr_prev), "move_prev": move, "cover_prev": len(hr_prev) / WIN}


def analyse(rows, explanations, min_distinct=3):
    """rows: [(ts, hour, fields dict, expl dict)] -> list of (field, explanation, r_all, r_half1, r_half2, passes)."""
    n = len(rows)
    names = sorted(rows[0][2])
    varying = [f for f in names if len({r[2][f] for r in rows}) >= min_distinct]
    hours = [r[1] // 3 for r in rows]
    tests = max(1, len(varying) * len(explanations))
    crit = bonferroni_r(n, tests)
    half = sorted(r[0] for r in rows)[n // 2]
    out = []
    for f in varying:
        fv = residualize([float(r[2][f]) for r in rows], hours)
        for e in explanations:
            ev = residualize([float(r[3][e]) for r in rows], hours)
            r_all = pearson(fv, ev)
            idx1 = [i for i, r in enumerate(rows) if r[0] < half]
            idx2 = [i for i, r in enumerate(rows) if r[0] >= half]
            r1 = pearson([fv[i] for i in idx1], [ev[i] for i in idx1])
            r2 = pearson([fv[i] for i in idx2], [ev[i] for i in idx2])
            c1, c2 = bonferroni_r(len(idx1), tests), bonferroni_r(len(idx2), tests)
            ok = abs(r_all) > crit and abs(r1) > c1 and abs(r2) > c2 and (r1 > 0) == (r2 > 0)
            out.append((f, e, r_all, r1, r2, ok))
    return out, crit, [f for f in names if f not in varying]


def holdout(rows, frozen=FROZEN, min_n=MIN_HOLDOUT):
    """rows: [(ts, hour, fields, expl)] already limited to the hold-out period.
    -> (n, crit, [(field, explanation, sign, r, verdict)]); verdict SUPPORTED / NOT SUPPORTED / UNDERPOWERED."""
    n = len(rows)
    crit = bonferroni_r(n, len(frozen)) if n > 3 else float("nan")
    hours = [r[1] // 3 for r in rows]
    out = []
    for f, e, sign in frozen:
        if n < min_n:
            out.append((f, e, sign, float("nan"), "UNDERPOWERED"))
            continue
        r = pearson(residualize([float(x[2][f]) for x in rows], hours), residualize([float(x[3][e]) for x in rows], hours))
        ok = r == r and abs(r) > crit and (r > 0) == (sign > 0)
        out.append((f, e, sign, r, "SUPPORTED" if ok else "NOT SUPPORTED"))
    return n, crit, out


def main(argv):
    hold = "--holdout" in argv
    argv = [a for a in argv if a != "--holdout"]
    if len(argv) != 1:
        print(__doc__)
        return 2
    con = sqlite3.connect(f"file:{argv[0]}?mode=ro", uri=True)
    rows = []
    import datetime
    for dev, ts, payload in con.execute("select deviceId, ts, payloadJSON from event where kind in ('EVENT_120') order by ts"):
        body = bytes.fromhex(json.loads(payload).get("body", ""))
        if len(body) < 32:
            continue
        e = explain(con, dev, ts)
        if e is None:
            continue
        rows.append((ts, datetime.datetime.fromtimestamp(ts).hour, fields(body), e))
    total = con.execute("select count(*) from event where kind='EVENT_120'").fetchone()[0]
    if hold:
        start = datetime.datetime.fromisoformat(HOLDOUT_FROM).timestamp()
        kept = [r for r in rows if r[0] >= start]
        n, crit, res = holdout(kept)
        print(f"hold-out from {HOLDOUT_FROM}: {n} usable reports (need {MIN_HOLDOUT}); Bonferroni |r| > {crit:.2f} over {len(FROZEN)}")
        for f, e, sign, r, verdict in res:
            print(f"  {f:8s} ~ {e:10s} predicted {'+' if sign > 0 else '-'}  r={r:+.2f}  {verdict}")
        return 0
    print(f"event 120 reports {total}; with >= 10 min HR before and after and movement data: {len(rows)}")
    if len(rows) < 20:
        return 1
    expl = ["hr_prev", "hr_next", "hr_sd_prev", "move_prev", "cover_prev"]
    res, crit, const = analyse(rows, expl)
    print(f"constant or < 3 distinct values: {len(const)} fields; Bonferroni |r| > {crit:.2f} (after removing 3-h time-of-day means)")
    passed = [r for r in res if r[5]]
    for f, e, ra, r1, r2, _ in sorted(passed, key=lambda r: -abs(r[2]))[:25]:
        print(f"PASS {f:8s} ~ {e:10s} r={ra:+.2f} (halves {r1:+.2f}, {r2:+.2f})")
    best = {}
    for f, e, ra, r1, r2, ok in res:
        if e not in best or abs(ra) > abs(best[e][2]):
            best[e] = (f, e, ra, r1, r2, ok)
    for e, (f, _, ra, r1, r2, ok) in best.items():
        print(f"strongest for {e:10s}: {f:8s} r={ra:+.2f} halves {r1:+.2f}/{r2:+.2f} {'PASS' if ok else 'not significant/replicated'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

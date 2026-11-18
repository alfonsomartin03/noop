#!/usr/bin/env python3
"""Audit the unit of WHOOP 5.0 historical R-R words: milliseconds or 1/1024-s ticks (issue #25).

NOOP's decoder (`decodeWhoop5Historical`) stores each R18 R-R word as milliseconds. An external layout
(ryanbr/noop PROTOCOL_SENSORS.md, fw 50.42.1.0) calls the same words 1/1024-s ticks. If they are ticks, every stored
interval is 2.34 % too long (1000/1024) and RMSSD and RR-derived HR carry the same scale error.

Run on a COPY of NOOP's database (`sqlite3 whoop.sqlite ".backup copy.sqlite"` or the app's export), never the live
file. Read-only; prints aggregates only.

    python3 rr_unit_audit.py COPY.sqlite [--window 300] [--device ID]

Method (thresholds frozen 2026-11-17, before any real data was looked at):
1. Cut time into fixed windows (default 300 s). Keep a window only if every second has a stored strap HR sample and
   at least one R-R row exists.
2. Beat completeness, independent of the unit: beats/min from the COUNT of R-R rows (60 n / W) must be within 3 % of
   the window's mean strap HR. Windows with missed or extra beats are excluded.
3. In each complete window the beats tile the window, so sum(words) / (1000 W) is ~1.000 if words are ms and ~1.024 if
   they are 1/1024-s ticks (edge error ≈ one beat, ~0.3 % at 300 s).
4. Verdict on the median ratio over ≥ 30 complete windows: [0.990, 1.010] → ms; [1.014, 1.034] → ticks;
   otherwise inconclusive. Also reported: strap HR minus RR-implied HR under each unit (secondary: the strap's HR
   algorithm is not documented, so it is a cross-check, not the decision).
"""
import argparse
import sqlite3
import statistics
import sys

MS_BAND = (0.990, 1.010)
TICK_BAND = (1.014, 1.034)
COMPLETENESS_TOLERANCE = 0.03
MIN_WINDOWS = 30


def windows(hr_rows, rr_rows, width=300):
    """hr_rows: [(ts, bpm)], rr_rows: [(ts, word)] → per-window dicts for windows fully covered by HR."""
    hr = {}
    for ts, bpm in hr_rows:
        hr[ts] = bpm
    rr = {}
    for ts, w in rr_rows:
        rr.setdefault(ts, []).append(w)
    if not hr:
        return []
    out = []
    start = min(hr) - min(hr) % width
    end = max(hr)
    while start <= end:
        secs = range(start, start + width)
        if all(s in hr for s in secs):
            words = [w for s in secs for w in rr.get(s, [])]
            if words:
                mean_hr = sum(hr[s] for s in secs) / width
                out.append({"start": start, "beats": len(words), "sum": sum(words), "mean_hr": mean_hr,
                            "mean_word": sum(words) / len(words)})
        start += width
    return out


def assess(wins, width=300):
    complete = [w for w in wins
                if w["mean_hr"] > 0 and abs(60.0 * w["beats"] / width / w["mean_hr"] - 1) <= COMPLETENESS_TOLERANCE]
    ratios = [w["sum"] / (1000.0 * width) for w in complete]
    hr_ms = [w["mean_hr"] - 60000.0 / w["mean_word"] for w in complete]
    hr_ticks = [w["mean_hr"] - 61440.0 / w["mean_word"] for w in complete]
    result = {"windows": len(wins), "complete": len(complete)}
    if ratios:
        q = statistics.quantiles(ratios, n=10) if len(ratios) >= 10 else [min(ratios)] * 9
        result.update({
            "median_ratio": statistics.median(ratios),
            "p10_ratio": q[0], "p90_ratio": q[-1],
            "median_hr_minus_rr_hr_if_ms": statistics.median(hr_ms),
            "median_hr_minus_rr_hr_if_ticks": statistics.median(hr_ticks),
        })
    result["verdict"] = verdict(result)
    return result


def verdict(r):
    if r["complete"] < MIN_WINDOWS or "median_ratio" not in r:
        return "inconclusive (too few complete windows)"
    m = r["median_ratio"]
    if MS_BAND[0] <= m <= MS_BAND[1]:
        return "milliseconds"
    if TICK_BAND[0] <= m <= TICK_BAND[1]:
        return "1/1024-s ticks"
    return "inconclusive (ratio outside both bands)"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("db")
    ap.add_argument("--window", type=int, default=300)
    ap.add_argument("--device", help="deviceId (default: the one with the most R-R rows)")
    a = ap.parse_args(argv)
    con = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)
    try:
        dev = a.device or (con.execute(
            "SELECT deviceId FROM rrInterval GROUP BY deviceId ORDER BY COUNT(*) DESC LIMIT 1").fetchone() or [None])[0]
        if dev is None:
            sys.exit("no R-R rows")
        hr = con.execute("SELECT ts, bpm FROM hrSample WHERE deviceId = ?", (dev,)).fetchall()
        rr = con.execute("SELECT ts, rrMs FROM rrInterval WHERE deviceId = ? ORDER BY ts, seq", (dev,)).fetchall()
    finally:
        con.close()
    r = assess(windows(hr, rr, a.window), a.window)
    for k, v in r.items():
        print(f"{k}: {round(v, 4) if isinstance(v, float) else v}")


if __name__ == "__main__":
    main()

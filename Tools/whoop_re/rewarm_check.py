#!/usr/bin/env python3
"""Skin-temperature re-warming after re-wear, and its effect on the nightly value (issue #85). Read-only, stdlib only.

    python3 -I rewarm_check.py --db COPY.sqlite [--gap 60] [--tol 0.2]

Run on a COPY of NOOP's database (SQLite backup), never the live file. Prints per-episode aggregates only.

Episodes:
  labelled   = strap-reported WRIST_OFF (10) -> WRIST_ON (9) pairs (`EVENT_10`/`EVENT_9` before they were named).
  unlabelled = other holes >= --gap seconds in the 1-Hz skin-temperature stream. The strap stores no history off the
               wrist (T03, T04), but a hole can also be lost or unsynced records, so these are only "consistent with a
               removal" when a cool start follows; they are reported apart and never treated as removals.

Per episode, with `on` = first sample after the hole:
  before   = median of [off - 10 min, off)          (cool-down reference; None when not enough samples)
  steady   = median of [on + 10 min, on + 20 min)   (post-re-wear reference)
  first    = first sample after the hole; min60 = minimum in the first 60 s
  cool_start = min60 at least 0.5 °C below both `before` and `steady` (a hole from lost records starts where it
             left off; a removal starts cool)
  rewarm_s = seconds from `on` until the 30-s rolling median is within --tol of `steady` and stays there for 60 s;
             None when the series never settles in the first 10 min.

Nightly sensitivity (`skin-temp-night-v2`): for each NOOP primary sleep holding an episode, the night median over
asleep stages (light/deep/rem; strap-reported off time excluded, as the app does) is recomputed while also excluding
the first k seconds after every episode inside the night, for k in 0, 30, 60, 120, 300, 600. The spread of those
values is what excluding the re-warming tail would change. The app is not changed by this script.
"""
import argparse
import bisect
import datetime
import json
import sqlite3
import statistics
import sys

ASLEEP = {"light", "deep", "rem", "core", "asleep"}
OFF_KINDS = ("WRIST_OFF", "EVENT_10")
ON_KINDS = ("WRIST_ON", "EVENT_9")
EXCLUDE_K = (0, 30, 60, 120, 300, 600)


def removals(events):
    """Strap-reported (off, on) pairs from (ts, kind) rows; an off without a later on is open and skipped."""
    out, off = [], None
    for ts, kind in sorted(events):
        if kind in OFF_KINDS:
            off = ts if off is None else off
        elif kind in ON_KINDS and off is not None:
            out.append((off, ts))
            off = None
    return out


def holes(ts_sorted, min_gap):
    """(last_before, first_after) for every step >= min_gap seconds in a sorted list of sample seconds."""
    return [(a, b) for a, b in zip(ts_sorted, ts_sorted[1:]) if b - a >= min_gap]


def _window(samples, lo, hi):
    """Values with lo <= ts < hi from a sorted list of (ts, celsius)."""
    return [c for t, c in samples if lo <= t < hi]


def _median(xs, minimum=30):
    return statistics.median(xs) if len(xs) >= minimum else None


def rewarm(samples, off, on, tol=0.2, hold=60, roll=30):
    """Re-warming summary for one episode; `samples` sorted (ts, celsius). See module doc."""
    before = _median(_window(samples, off - 600, off))
    steady = _median(_window(samples, on + 600, on + 1200))
    after = [(t, c) for t, c in samples if on <= t < on + 600]
    first = after[0][1] if after else None
    min60 = min((c for t, c in after if t < on + 60), default=None)
    rewarm_s = None
    if steady is not None and after:
        ok_since = None
        for i, (t, _) in enumerate(after):
            win = [c for tt, c in after[max(0, i - roll + 1):i + 1] if tt > t - roll]
            within = abs(statistics.median(win) - steady) <= tol
            if within and ok_since is None:
                ok_since = t
            elif not within:
                ok_since = None
            if ok_since is not None and t - ok_since >= hold:
                rewarm_s = ok_since - on
                break
    # Cooler than both sides: a removal cools the sensor; a hole from lost records starts where it left off.
    cool_start = (min60 is not None and steady is not None and before is not None
                  and steady - min60 >= 0.5 and before - min60 >= 0.5)
    return {"off": off, "on": on, "off_s": on - off, "before": before, "steady": steady, "first": first,
            "min60": min60, "rewarm_s": rewarm_s, "cool_start": cool_start}


def night_median(samples, asleep, off_intervals, tails):
    """Median of samples inside asleep (start, end) segments, outside strap off intervals and outside tails."""
    vals = []
    for t, c in samples:
        if not any(a <= t < b for a, b in asleep):
            continue
        if any(a <= t < b for a, b in off_intervals) or any(a <= t < b for a, b in tails):
            continue
        vals.append(c)
    return (statistics.median(vals) if vals else None), len(vals)


def sensitivity(samples, asleep, off_intervals, episode_ons):
    """{k: (median, n)} for excluding k seconds after every re-wear in `episode_ons`."""
    return {k: night_median(samples, asleep, off_intervals, [(on, on + k) for on in episode_ons]) for k in EXCLUDE_K}


def _fmt(x, nd=2):
    return "—" if x is None else f"{x:.{nd}f}"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", required=True)
    ap.add_argument("--gap", type=int, default=60, help="minimum hole for an unlabelled episode, seconds")
    ap.add_argument("--trace", action="store_true", help="30-s medians for 15 min after each labelled re-wear")
    ap.add_argument("--tol", type=float, default=0.2, help="settled when within this many °C of the steady level")
    a = ap.parse_args(argv)
    db = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)
    rows = db.execute("select ts, raw, unit from skinTempSample order by ts").fetchall()
    samples = [(t, r / 100.0) for t, r, u in rows if u == "centi_celsius"]
    if not samples:
        print("no centi_celsius skin-temperature rows")
        return 1
    ev = db.execute(f"select ts, kind from event where kind in ({','.join('?' * 4)})", OFF_KINDS + ON_KINDS).fetchall()
    labelled = [(off, on) for off, on in removals(ev) if on > samples[0][0]]
    # The re-wear time used for a labelled pair is its first sample after the hole (the strap's ON can precede it).
    ts = [t for t, _ in samples]
    eps = []
    for off, on in labelled:
        i = bisect.bisect_left(ts, on)
        last = ts[bisect.bisect_left(ts, off) - 1] if bisect.bisect_left(ts, off) > 0 else off
        eps.append(("labelled", last, ts[i] if i < len(ts) else on))
    labelled_spans = [(last, first) for _, last, first in eps]
    for last, first in holes(ts, a.gap):
        if any(l <= last and first <= f + 1 for l, f in labelled_spans) or any(abs(first - f) <= 5 for _, f in labelled_spans):
            continue
        eps.append(("unlabelled", last, first))
    eps.sort(key=lambda e: e[2])

    print(f"skin-temperature rows {len(samples):,}; labelled removals {len(labelled)}; "
          f"unlabelled holes >= {a.gap} s {sum(e[0] == 'unlabelled' for e in eps)}")
    print("kind        off→on (local)            hole_s  before  steady  first  min60  rewarm_s  cool_start")
    results = []
    for kind, off, on in eps:
        r = rewarm(samples, off, on, tol=a.tol)
        r["kind"] = kind
        results.append(r)
        when = datetime.datetime.fromtimestamp(off).strftime("%m-%d %H:%M:%S") + "→" + \
            datetime.datetime.fromtimestamp(on).strftime("%H:%M:%S")
        print(f"{kind:<11} {when:<25} {r['off_s']:>6}  {_fmt(r['before']):>6}  {_fmt(r['steady']):>6}  "
              f"{_fmt(r['first']):>5}  {_fmt(r['min60']):>5}  {str(r['rewarm_s'] if r['rewarm_s'] is not None else '—'):>8}  "
              f"{'yes' if r['cool_start'] else 'no'}")
    if a.trace:
        for r in results:
            if r["kind"] != "labelled":
                continue
            meds = [_median(_window(samples, r["on"] + i * 30, r["on"] + (i + 1) * 30), minimum=5) for i in range(30)]
            print(f"trace {datetime.datetime.fromtimestamp(r['on']).strftime('%m-%d %H:%M')} (30-s medians, °C): "
                  + " ".join(_fmt(m, 1) for m in meds))
    settled = [r["rewarm_s"] for r in results if r["cool_start"] and r["rewarm_s"] is not None]
    if settled:
        print(f"cool-start episodes settled: n={len(settled)}, median {statistics.median(settled):.0f} s, max {max(settled)} s")

    print("\nnightly sensitivity (primary sleeps holding an episode), median °C by seconds excluded after re-wear:")
    print("night start (local)   episodes  " + "  ".join(f"k={k:<4}" for k in EXCLUDE_K) + "  spread")
    sleeps = db.execute("select startTs, endTs, stagesJSON from sleepSession where kind = 'primary' order by startTs").fetchall()
    offs = labelled
    for start, end, js in sleeps:
        inside = [r["on"] for r in results if start <= r["on"] < end]
        if not inside or not js:
            continue
        asleep = [(s["start"], s["end"]) for s in json.loads(js) if s.get("stage") in ASLEEP]
        night = [(t, c) for t, c in samples if start <= t < end]
        sens = sensitivity(night, asleep, offs, inside)
        meds = [m for m, _ in sens.values() if m is not None]
        print(f"{datetime.datetime.fromtimestamp(start).strftime('%Y-%m-%d %H:%M'):<20}  {len(inside):>8}  "
              + "  ".join(f"{_fmt(sens[k][0]):<6}" for k in EXCLUDE_K)
              + f"  {(max(meds) - min(meds)) if meds else 0:.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

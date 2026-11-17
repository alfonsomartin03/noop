#!/usr/bin/env python3
"""Check WHOOP 5.0 v0x1a optical bursts against the strap's own stored HR, with proper controls (issue #25).

Offline, stdlib only, read-only. Inputs are COPIES: NOOP's undecoded-history JSONL files (v0x1a records) and a SQLite
backup of NOOP's database (hrSample). Prints aggregates only.

    python3 -I ppg_burst_check.py --archive COPY/undecoded-history --db COPY.sqlite

Record layout (payload offsets, SUPPORTED + locally consistent, CAPABILITY_MATRIX.md §4): @7 u32 unix seconds,
@13 u8 burst counter, @14 u8 slow state, @15 u32 first optical code, @19 + 2i 24 x i16 deltas -> 25 samples / record.

Method:
- A burst = consecutive records (1 s apart) sharing the burst counter. Reconstruct each record as base + cumulative
  deltas; detrend every 1-s record by its own mean (removes the per-record base jump), concatenate.
- Spectrum: direct DFT over 40-200 bpm in 0.5-bpm steps on a Hann-windowed burst. Frequency resolution of a 40-s
  window is 1/40 Hz = 1.5 bpm, so "within 5 bpm" is ~3 resolution bins.
- Reference: median stored HR (hrSample, 30-220 bpm) over the burst's seconds. NOT independent: same strap, and the
  strap's HR may itself come from this optical signal.
- Controls (instead of a flat chance rate): (1) shuffled: each burst's peak vs the HR of a different burst >= 6 h
  away (preserves the HR distribution and the peak distribution); (2) shift: the HR window moved by +/- 10 min
  (preserves temporal dependence). Each control is repeated and reported as a mean rate.
- Harmonics: counts of peaks within 5 bpm of 2xHR and HR/2 are reported separately.
"""
import argparse
import cmath
import glob
import json
import math
import random
import sqlite3
import statistics
import struct
import sys

FS = 25.0


def load_records(paths):
    recs = {}
    for path in paths:
        for line in open(path):
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            if r.get("version") != 26:
                continue
            frame = bytes.fromhex(r["hex"])
            p = frame[8:-4]          # payload: after the 8-byte header, before the CRC32
            if len(p) < 67 or p[0] != 47 or p[1] != 0x1A:
                continue
            ts = struct.unpack_from("<I", p, 7)[0]
            base = struct.unpack_from("<I", p, 15)[0]
            deltas = struct.unpack_from("<24h", p, 19)
            samples, acc = [base], base
            for d in deltas:
                acc += d
                samples.append(acc)
            recs.setdefault(ts, (p[13], p[14], samples))
    return recs


def bursts(recs):
    out, cur = [], []
    for ts in sorted(recs):
        if cur and (ts - cur[-1] != 1 or recs[ts][0] != recs[cur[-1]][0]):
            out.append(cur)
            cur = []
        cur.append(ts)
    if cur:
        out.append(cur)
    return out


def signal(recs, seconds, mode="deltas"):
    """'deltas' (default): the stored per-sample differences (a derivative of the optical signal; the record boundary
    sample is 0). Suppresses baseline drift, which otherwise dominates the 40-200 bpm band. 'mean': each record minus
    its own mean (the 2026-11-17 first pass) - injects a 1 Hz step artifact (60 bpm) and does not track HR."""
    sig = []
    for ts in seconds:
        s = recs[ts][2]
        if mode == "deltas":
            sig.append(0)
            sig.extend(s[i + 1] - s[i] for i in range(len(s) - 1))
        else:
            m = sum(s) / len(s)
            sig.extend(x - m for x in s)
    return sig


def peak_bpm(sig, lo=40.0, hi=200.0, step=0.5, mask=()):
    n = len(sig)
    w = [0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1)) for i in range(n)]
    x = [a * b for a, b in zip(sig, w)]
    best, best_p = None, -1.0
    bpm = lo
    while bpm <= hi + 1e-9:
        f = bpm / 60.0
        rot, ph, z = cmath.exp(-2j * math.pi * f / FS), 1 + 0j, 0j
        for v in x:
            z += v * ph
            ph *= rot
        p = abs(z) ** 2
        if any(a <= bpm <= b for a, b in mask):
            p = -1.0
        if p > best_p:
            best, best_p = bpm, p
        bpm += step
    return best


def median_hr(hr, start, end):
    vals = [hr[t] for t in range(start, end + 1) if t in hr]
    return statistics.median(vals) if len(vals) >= 10 else None


def evaluate(items, tol=5.0):
    """items: [(peak, hr)] -> dict of rates."""
    n = len(items)
    hit = sum(abs(p - h) <= tol for p, h in items)
    dbl = sum(abs(p - 2 * h) <= tol for p, h in items)
    half = sum(abs(p - h / 2) <= tol for p, h in items)
    return {"n": n, "match": hit, "rate": hit / n if n else None, "at_2x": dbl, "at_half": half}


def shuffled_control(peaks, rng, min_gap_s=6 * 3600, reps=200, strata=1):
    """Pair each burst's peak with the HR of another burst >= min_gap_s away. strata > 1 restricts the partner to the
    same HR quantile, so the control keeps the HR distribution within each band (the stored HR is concentrated in the
    sleep range, where any low-frequency peak 'matches')."""
    hrs = [h for _, _, h in peaks]
    qs = statistics.quantiles(hrs, n=strata) if strata > 1 else []
    band = lambda h: sum(h > q for q in qs)
    rates = []
    for _ in range(reps):
        items = []
        for start, pk, h0 in peaks:
            others = [h for s, _, h in peaks if abs(s - start) >= min_gap_s and band(h) == band(h0)]
            if others:
                items.append((pk, rng.choice(others)))
        rates.append(evaluate(items)["rate"])
    return statistics.mean(rates)


def pearson(x, y):
    mx, my = statistics.mean(x), statistics.mean(y)
    den = math.sqrt(sum((a - mx) ** 2 for a in x) * sum((b - my) ** 2 for b in y))
    return sum((a - mx) * (b - my) for a, b in zip(x, y)) / den if den else float("nan")


def shift_control(peaks_with_bounds, hr, shift_s):
    items = []
    for start, end, pk in peaks_with_bounds:
        h = median_hr(hr, start + shift_s, end + shift_s)
        if h is not None:
            items.append((pk, h))
    return evaluate(items)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--archive", required=True, help="directory of undecoded-history *.jsonl COPIES")
    ap.add_argument("--db", required=True, help="SQLite backup COPY of NOOP's database")
    ap.add_argument("--min-seconds", type=int, default=30)
    ap.add_argument("--seed", type=int, default=25)
    ap.add_argument("--mode", choices=("deltas", "mean"), default="deltas")
    ap.add_argument("--mask-1hz", action="store_true", help="ignore 57-63 bpm (record-boundary artifact)")
    a = ap.parse_args(argv)
    recs = load_records(sorted(glob.glob(a.archive.rstrip("/") + "/*.jsonl")))
    bs = [b for b in bursts(recs) if len(b) >= a.min_seconds]
    con = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)
    lo, hi = (min(b[0] for b in bs), max(b[-1] for b in bs)) if bs else (0, 0)
    hr = dict(con.execute("select ts, bpm from hrSample where ts between ? and ? and bpm between 30 and 220",
                          (lo - 3600, hi + 3600)))
    rows, excluded = [], {"no_hr": 0}
    for b in bs:
        h = median_hr(hr, b[0], b[-1])
        pk = peak_bpm(signal(recs, b, a.mode), mask=((57, 63),) if a.mask_1hz else ())
        rows.append((b[0], b[-1], pk, h, recs[b[0]][1]))
        if h is None:
            excluded["no_hr"] += 1
    paired = [(s, e, pk, h, st) for s, e, pk, h, st in rows if h is not None]
    main_eval = evaluate([(pk, h) for _, _, pk, h, _ in paired])
    rng = random.Random(a.seed)
    shuf = shuffled_control([(s, pk, h) for s, _, pk, h, _ in paired], rng)
    shuf10 = shuffled_control([(s, pk, h) for s, _, pk, h, _ in paired], rng, strata=10, reps=100)
    shifts = {sh: shift_control([(s, e, pk) for s, e, pk, _, _ in paired], hr, sh) for sh in (-600, 600)}
    errs = sorted(abs(pk - h) for _, _, pk, h, _ in paired)
    print(f"records {len(recs)}  bursts >= {a.min_seconds} s: {len(bs)}  excluded {excluded}")
    print(f"matched within 5 bpm: {main_eval['match']}/{main_eval['n']} ({main_eval['rate']:.0%}); "
          f"at 2xHR {main_eval['at_2x']}, at HR/2 {main_eval['at_half']}; median |peak-HR| {statistics.median(errs):.1f} bpm")
    print(f"control shuffled (other bursts >= 6 h away, 200 reps): {shuf:.0%}; within HR deciles (100 reps): {shuf10:.0%}")
    print(f"correlation peak vs stored HR: {pearson([h for *_, h, _ in paired], [pk for _, _, pk, _, _ in paired]):.2f}")
    print(f"peaks at 57-63 bpm (1 Hz record rate): {sum(57 <= pk <= 63 for _, _, pk, _, _ in paired)}/{len(paired)}")
    for sh, ev in shifts.items():
        print(f"control HR shifted {sh:+d} s: {ev['match']}/{ev['n']} ({ev['rate']:.0%})")
    for state in sorted({st for *_, st in paired}):
        sub = [(pk, h) for _, _, pk, h, st in paired if st == state]
        ev = evaluate(sub)
        print(f"byte14 = {state}: {ev['match']}/{ev['n']} ({ev['rate']:.0%})")
    hrs = sorted(h for *_, h, _ in paired)
    for lo_, hi_ in ((0, 60), (60, 80), (80, 300)):
        sub = [(pk, h) for _, _, pk, h, _ in paired if lo_ <= h < hi_]
        if sub:
            ev = evaluate(sub)
            print(f"stored HR {lo_}-{hi_}: {ev['match']}/{ev['n']} ({ev['rate']:.0%})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

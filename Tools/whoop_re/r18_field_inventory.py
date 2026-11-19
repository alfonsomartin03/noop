#!/usr/bin/env python3
"""Offline field inventory of WHOOP 5.0 R18 history records (type 47, version 0x12) from research-capture COPIES
(issue #44). Stdlib only, read-only; prints aggregates only (no per-record values, no timestamps).

    python3 -I r18_field_inventory.py COPY_DIR_OR_FILES... [--since YYYY-MM-DD] [--json OUT.json]

`--since` keeps records whose strap timestamp is at or after local midnight of that date (hold-out days).

Input: `OpenWhoop/research-history/*.jsonl` copies (lines with type 47, version 18, hex = full frame). Frames are
CRC-checked (header CRC8 is not re-derived here; the body CRC32 is), de-duplicated by record timestamp (first kept).

Per payload offset (payload = frame[8:-4], 112 bytes) the inventory gives the known label (NOOP decoder or the pinned
external layout), the number of distinct u8 values, the share of the most common value and a class:
  constant · few-valued (<= 8 distinct: flag/state candidate) · varying
Float candidates: offsets where the f32 LE value is 0 or has a magnitude in [1e-4, 64] in >= 99 % of records (tiny
denormals from random bytes excluded) and is non-zero in >= 1 %.

Hypothesis-relevant summaries (exploratory; frozen hypotheses and the hold-out plan are in EVIDENCE_MATRIX.md §7):
  - quaternion vs vector: norm of the 3 gravity floats (37/41/45) and of the 4 floats (33..45), share within 1 +/- 0.05,
    and the first float (33) against activity code and against per-second gravity change |dg|;
  - few-valued bytes against activity code (@55): per-byte mutual information in bits (0 = independent);
  - varying u8 offsets against HR (@14): Pearson r (alternate-HR candidates need |r| near 1 AND a different value).
"""
import binascii
import glob
import json
import math
import os
import statistics
import struct
import sys
from collections import Counter

KNOWN = {0: "type", 1: "version", 3: "counter", 7: "timestamp u32", 14: "heart rate", 15: "rr count",
         16: "rr[0] u16", 18: "rr[1] u16", 20: "rr[2] u16", 22: "rr[3] u16",
         33: "float (dynamic accel? / quaternion w?)", 37: "gravity x f32", 41: "gravity y f32", 45: "gravity z f32",
         49: "step counter u16", 55: "activity code", 65: "skin temp u16 c°C"}
SPANS = {7: 4, 16: 2, 18: 2, 20: 2, 22: 2, 33: 4, 37: 4, 41: 4, 45: 4, 49: 2, 65: 2}


def covered():
    """offset -> label for every byte that belongs to a known multi-byte field."""
    out = {}
    for o, label in KNOWN.items():
        for i in range(SPANS.get(o, 1)):
            out[o + i] = label if i == 0 else f"({label})"
    return out


def records(paths, since_ts=None):
    """-> list of payloads (bytes), de-duplicated by record timestamp; plus counts (lines, bad crc, dupes)."""
    files = []
    for p in paths:
        files += sorted(glob.glob(os.path.join(p, "*.jsonl"))) if os.path.isdir(p) else [p]
    seen, out, lines, bad, dupes = set(), [], 0, 0, 0
    for f in files:
        with open(f, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                r = json.loads(line)
                if r.get("type") != 47 or r.get("version") != 18 or not r.get("hex"):
                    continue
                lines += 1
                fr = bytes.fromhex(r["hex"])
                if len(fr) < 8 + 112 + 4 or binascii.crc32(fr[8:-4]) & 0xFFFFFFFF != struct.unpack_from("<I", fr, len(fr) - 4)[0]:
                    bad += 1
                    continue
                p = fr[8:-4]
                ts = struct.unpack_from("<I", p, 7)[0]
                if since_ts is not None and ts < since_ts:
                    continue
                if ts in seen:
                    dupes += 1
                    continue
                seen.add(ts)
                out.append(p)
    out.sort(key=lambda p: struct.unpack_from("<I", p, 7)[0])
    return out, {"lines": lines, "bad_crc": bad, "duplicates": dupes}


def f32(p, o):
    return struct.unpack_from("<f", p, o)[0]


def pearson(x, y):
    if len(x) < 5:
        return float("nan")
    mx, my = statistics.fmean(x), statistics.fmean(y)
    sx = math.sqrt(sum((a - mx) ** 2 for a in x))
    sy = math.sqrt(sum((b - my) ** 2 for b in y))
    return sum((a - mx) * (b - my) for a, b in zip(x, y)) / (sx * sy) if sx and sy else float("nan")


def mutual_info(xs, ys):
    n = len(xs)
    if not n:
        return 0.0
    cx, cy, cxy = Counter(xs), Counter(ys), Counter(zip(xs, ys))
    return sum(c / n * math.log2((c / n) / (cx[a] / n * cy[b] / n)) for (a, b), c in cxy.items())


def quantiles(xs, qs=(0.01, 0.5, 0.99)):
    s = sorted(xs)
    return [s[min(len(s) - 1, int(q * (len(s) - 1)))] for q in qs] if s else []


def inventory(payloads):
    n = len(payloads)
    width = min(len(p) for p in payloads)
    cov = covered()
    rows = []
    for o in range(width):
        vals = [p[o] for p in payloads]
        c = Counter(vals)
        d = len(c)
        cls = "constant" if d == 1 else "few-valued" if d <= 8 else "varying"
        rows.append({"offset": o, "label": cov.get(o, ""), "distinct": d, "top_share": c.most_common(1)[0][1] / n,
                     "class": cls})
    floats = []
    for o in range(0, width - 3):
        v = [f32(p, o) for p in payloads]
        # Random bytes often decode as tiny denormals: require 0 or a magnitude in [1e-4, 64], and some non-zero values.
        ok = sum(1 for x in v if math.isfinite(x) and (x == 0 or 1e-4 <= abs(x) <= 64)) / n
        if ok >= 0.99 and sum(1 for x in v if x != 0) >= 0.01 * n and len(set(v)) > 1:
            floats.append({"offset": o, "label": cov.get(o, ""), "plausible_share": ok})
    return rows, floats


def gravity_tests(payloads):
    n3, n4, first, act, dg = [], [], [], [], []
    prev = None
    for p in payloads:
        g = (f32(p, 37), f32(p, 41), f32(p, 45))
        a = f32(p, 33)
        if not all(math.isfinite(x) for x in (*g, a)):
            prev = None
            continue
        n3.append(math.sqrt(sum(x * x for x in g)))
        n4.append(math.sqrt(a * a + sum(x * x for x in g)))
        first.append(a)
        act.append(p[55])
        ts = struct.unpack_from("<I", p, 7)[0]
        dg.append(math.dist(g, prev[1]) if prev and ts - prev[0] == 1 else None)
        prev = (ts, g)
    within = lambda xs: sum(1 for x in xs if abs(x - 1) <= 0.05) / len(xs) if xs else float("nan")
    by_act = {}
    for a, f in zip(act, first):
        by_act.setdefault(a, []).append(f)
    pairs = [(f, d) for f, d in zip(first, dg) if d is not None]
    return {"n": len(first), "norm3_q": quantiles(n3), "norm4_q": quantiles(n4),
            "norm3_within": within(n3), "norm4_within": within(n4),
            "first_q": quantiles(first), "first_negative_share": sum(1 for f in first if f < 0) / len(first) if first else None,
            "first_median_by_activity": {k: statistics.median(v) for k, v in sorted(by_act.items())},
            "first_vs_dg_r": pearson([a for a, _ in pairs], [b for _, b in pairs])}


def relations(payloads, rows):
    act = [p[55] for p in payloads]
    hr = [p[14] for p in payloads]
    few = [(r["offset"], r["label"], mutual_info([p[r["offset"]] for p in payloads], act)) for r in rows
           if r["class"] == "few-valued" and not r["label"]]
    var = [(r["offset"], r["label"], pearson([float(p[r["offset"]]) for p in payloads], [float(h) for h in hr]))
           for r in rows if r["class"] == "varying" and r["offset"] != 14]
    var = [v for v in var if v[2] == v[2]]
    return sorted(few, key=lambda x: -x[2]), sorted(var, key=lambda x: -abs(x[2]))


def hr_twin(payloads, o):
    """An alternate-HR candidate at u8 offset o vs HR @14: share equal, median |diff|, share where both are non-zero
    and differ by > 3 bpm (a twin that never differs is a copy, not a second estimate)."""
    pairs = [(p[o], p[14]) for p in payloads]
    both = [(a, b) for a, b in pairs if a and b]
    return {"equal": sum(1 for a, b in pairs if a == b) / len(pairs),
            "median_abs_diff": statistics.median(abs(a - b) for a, b in pairs),
            "differ_gt3_when_both": sum(1 for a, b in both if abs(a - b) > 3) / len(both) if both else None,
            "zero_here_hr_nonzero": sum(1 for a, b in pairs if a == 0 and b) / len(pairs),
            "nonzero_here_hr_zero": sum(1 for a, b in pairs if a and not b) / len(pairs)}


def float_summary(payloads, o):
    v = [f32(p, o) for p in payloads]
    by = {}
    for p, x in zip(payloads, v):
        by.setdefault(p[55], []).append(x)
    return {"q": quantiles(v), "zero_share": sum(1 for x in v if x == 0) / len(v),
            "median_by_activity": {k: statistics.median(xs) for k, xs in sorted(by.items())}}


def main(argv):
    out_json = None
    if "--json" in argv:
        i = argv.index("--json")
        out_json = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    since = None
    if "--since" in argv:
        i = argv.index("--since")
        import datetime
        since = int(datetime.datetime.fromisoformat(argv[i + 1]).timestamp())
        argv = argv[:i] + argv[i + 2:]
    if not argv:
        print(__doc__)
        return 2
    payloads, counts = records(argv, since)
    print(f"R18 lines {counts['lines']}, bad CRC {counts['bad_crc']}, duplicate timestamps {counts['duplicates']}, "
          f"unique records {len(payloads)} ({len(payloads) / 3600:.1f} h of seconds)")
    if len(payloads) < 100:
        print("too few records")
        return 1
    rows, floats = inventory(payloads)
    classes = Counter(r["class"] for r in rows)
    print(f"payload bytes {len(rows)}: " + ", ".join(f"{k} {v}" for k, v in sorted(classes.items())))
    print("\noffset  class        distinct  top%   label")
    for r in rows:
        if r["label"] or r["class"] != "constant":
            print(f"  {r['offset']:3d}   {r['class']:11s}  {r['distinct']:7d}  {100 * r['top_share']:5.1f}  {r['label']}")
    const = [r["offset"] for r in rows if r["class"] == "constant" and not r["label"]]
    print(f"  unlabelled constant offsets ({len(const)}): {const}")
    print("\nf32 candidates (0 or 1e-4 <= |x| <= 64 in >= 99 %): " + ", ".join(
        f"{f['offset']}{'*' if f['label'] else ''}" for f in floats) + "   (* = known field)")
    g = gravity_tests(payloads)
    fmt = lambda q: "/".join(f"{x:.3f}" for x in q)
    print(f"\nquaternion vs vector (n {g['n']}): |g3| p1/p50/p99 {fmt(g['norm3_q'])}, within 1±0.05 "
          f"{100 * g['norm3_within']:.1f} %; |g4| {fmt(g['norm4_q'])}, within {100 * g['norm4_within']:.1f} %")
    print(f"  float@33 p1/p50/p99 {fmt(g['first_q'])}, negative {100 * g['first_negative_share']:.1f} %; "
          f"r(float@33, |dg| per s) {g['first_vs_dg_r']:+.2f}")
    print("  float@33 median by activity code: " + ", ".join(f"{k}: {v:.3f}" for k, v in g["first_median_by_activity"].items()))
    few, var = relations(payloads, rows)
    print("\nfew-valued bytes vs activity code (mutual information, bits): " +
          ", ".join(f"@{o} {mi:.3f}" for o, _, mi in few[:10]))
    print("varying unlabelled u8 vs HR (Pearson r, top 8): " +
          ", ".join(f"@{o} {r:+.2f}" for o, lab, r in [v for v in var if not v[1]][:8]))
    for o, lab, r in var:
        if not lab and abs(r) >= 0.95:
            t = hr_twin(payloads, o)
            print(f"  HR twin @{o}: equal {100 * t['equal']:.1f} %, median |diff| {t['median_abs_diff']}, "
                  f"differs > 3 bpm when both non-zero {100 * (t['differ_gt3_when_both'] or 0):.1f} %, "
                  f"zero here/HR set {100 * t['zero_here_hr_nonzero']:.2f} %, set here/HR zero {100 * t['nonzero_here_hr_zero']:.2f} %")
    for f in floats:
        if not f["label"]:
            fs = float_summary(payloads, f["offset"])
            print(f"  unknown float @{f['offset']}: p1/p50/p99 " + "/".join(f"{x:.4g}" for x in fs["q"]) +
                  f", zero {100 * fs['zero_share']:.1f} %, median by activity " +
                  ", ".join(f"{k}: {x:.4g}" for k, x in fs["median_by_activity"].items()))
    if out_json:
        with open(out_json, "w", encoding="utf-8") as f:
            json.dump({"counts": counts, "records": len(payloads), "bytes": rows, "floats": floats, "gravity": g,
                       "few_vs_activity": few, "varying_vs_hr": var}, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

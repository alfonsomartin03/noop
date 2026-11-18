#!/usr/bin/env python3
"""Unit of WHOOP 5.0 LIVE R-R words (type-40 REALTIME_DATA): milliseconds or 1/1024-s ticks (issue #39). Read-only.

    python3 -I live_rr_audit.py LIVE_RR_DIR_OR_FILE [...] [--window 300] [--history COPY.sqlite]

Input: NOOP's `Application Support/OpenWhoop/live-rr/*.jsonl` (copies). NOOP writes there only for streaming
sessions that carried intervals: the 5 minutes before the first such packet and every live frame after it.

Method: identical to `rr_unit_audit.py` (thresholds frozen 2026-11-17 for history, reused unchanged here before any
live interval has been seen): fixed windows fully covered by live packets (one per strap second), beat completeness
(60 n / W within 3 % of the window's mean packet HR), then sum(words) / (1000 W): [0.990, 1.010] → ms,
[1.014, 1.034] → ticks, else inconclusive; ≥ 30 complete windows required. History (ms on fw 50.43.1.0) is never
assumed for live packets.

Paired method (`--history`, frozen 2026-11-18 after the first live session showed packets carry only SOME beats —
~0.5 interval per packet — so the beat-sum completeness gate above cannot pass; frozen before any live interval value
was examined): for each live second t with words, ratio = mean(live words at t) / mean(stored history R-R with
ts in [t-2, t+2]) — history is the confirmed-ms reference. Means, not nearest-beat matching, so neither unit is
favoured. Verdict on the median ratio over >= 100 paired seconds with the same bands ([0.990, 1.010] ms,
[1.014, 1.034] ticks). Secondary (reported, not decisive): share of live words exactly equal to a history word in the
same ±2-s span. Strap clock: both streams carry strap time, so no clock mapping is needed. Also prints the per-packet structure (how many packets carry intervals, counts, lengths)
so an "intervals never appear" result is explicit rather than silent.
"""
import argparse
import glob
import json
import os
import sqlite3
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rr_unit_audit as A  # noqa: E402
import whoop5_decode as D  # noqa: E402


def load(paths):
    """-> {strap_second: (hr, [words], rr_truncated, frame_len)} from archive lines (first copy of a second wins)."""
    files = []
    for p in paths:
        files += sorted(glob.glob(os.path.join(p, "*.jsonl"))) if os.path.isdir(p) else [p]
    out = {}
    for f in files:
        with open(f, encoding="utf-8") as fh:
            for line in fh:
                rec = json.loads(line)
                if rec.get("type") != 40:
                    continue
                try:
                    d = D.decode(bytes.fromhex(rec["hex"]))
                except D.FrameError:
                    continue
                if not (d.get("crc32_ok") and d.get("hdr_crc_ok")) or "rt_ts" not in d or d.get("kind") != 2:
                    continue
                out.setdefault(d["rt_ts"], (d["hr"], d["rr"], d["rr_truncated"], rec.get("len")))
    return out


def structure(packets):
    with_rr = [v for v in packets.values() if v[1]]
    lengths = {}
    for v in packets.values():
        lengths[v[3]] = lengths.get(v[3], 0) + 1
    return {"packets": len(packets), "with_intervals": len(with_rr), "words": sum(len(v[1]) for v in with_rr),
            "truncated": sum(1 for v in packets.values() if v[2]), "lengths": dict(sorted(lengths.items()))}


def audit(packets, width=300):
    hr_rows = [(t, v[0]) for t, v in packets.items()]
    rr_rows = [(t, w) for t, v in sorted(packets.items()) for w in v[1]]
    return A.assess(A.windows(hr_rows, rr_rows, width), width)


PAIR_HALFWIDTH = 2
MIN_PAIRS = 100


def paired(packets, history_rows, halfwidth=PAIR_HALFWIDTH):
    """packets as from load(); history_rows: [(ts, rr_ms)] (confirmed-ms history). -> result dict with verdict."""
    hist = {}
    for ts, w in history_rows:
        hist.setdefault(ts, []).append(w)
    ratios, exact, words = [], 0, 0
    for t, (_, live, _, _) in sorted(packets.items()):
        if not live:
            continue
        near = [w for s in range(t - halfwidth, t + halfwidth + 1) for w in hist.get(s, [])]
        if not near:
            continue
        ratios.append((sum(live) / len(live)) / (sum(near) / len(near)))
        words += len(live)
        exact += sum(1 for w in live if w in near)
    r = {"paired_seconds": len(ratios), "paired_words": words,
         "exact_equal_share": exact / words if words else None}
    if len(ratios) >= MIN_PAIRS:
        m = statistics.median(ratios)
        q = statistics.quantiles(ratios, n=10)
        r.update(median_ratio=m, p10_ratio=q[0], p90_ratio=q[-1])
        r["verdict"] = ("milliseconds" if A.MS_BAND[0] <= m <= A.MS_BAND[1] else
                        "1/1024-s ticks" if A.TICK_BAND[0] <= m <= A.TICK_BAND[1] else
                        "inconclusive (ratio outside both bands)")
    else:
        r["verdict"] = f"inconclusive (fewer than {MIN_PAIRS} paired seconds)"
    return r


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--window", type=int, default=300)
    ap.add_argument("--history", help="SQLite COPY with stored 5.0 history R-R (rrInterval), for the paired method")
    a = ap.parse_args(argv)
    packets = load(a.paths)
    for k, v in structure(packets).items():
        print(f"{k}: {v}")
    for k, v in audit(packets, a.window).items():
        print(f"{k}: {round(v, 4) if isinstance(v, float) else v}")
    if a.history:
        lo, hi = (min(packets) - 5, max(packets) + 5) if packets else (0, 0)
        con = sqlite3.connect(f"file:{a.history}?mode=ro", uri=True)
        rows = con.execute("SELECT ts, rrMs FROM rrInterval WHERE ts BETWEEN ? AND ? ORDER BY ts, seq", (lo, hi)).fetchall()
        con.close()
        print("paired (live vs stored history R-R):")
        for k, v in paired(packets, rows).items():
            print(f"  {k}: {round(v, 4) if isinstance(v, float) else v}")


if __name__ == "__main__":
    main()

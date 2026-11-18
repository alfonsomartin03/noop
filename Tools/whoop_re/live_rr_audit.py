#!/usr/bin/env python3
"""Unit of WHOOP 5.0 LIVE R-R words (type-40 REALTIME_DATA): milliseconds or 1/1024-s ticks (issue #39). Read-only.

    python3 -I live_rr_audit.py LIVE_RR_DIR_OR_FILE [...] [--window 300]

Input: NOOP's `Application Support/OpenWhoop/live-rr/*.jsonl` (copies). NOOP writes there only for streaming
sessions that carried intervals: the 5 minutes before the first such packet and every live frame after it.

Method: identical to `rr_unit_audit.py` (thresholds frozen 2026-11-17 for history, reused unchanged here before any
live interval has been seen): fixed windows fully covered by live packets (one per strap second), beat completeness
(60 n / W within 3 % of the window's mean packet HR), then sum(words) / (1000 W): [0.990, 1.010] → ms,
[1.014, 1.034] → ticks, else inconclusive; ≥ 30 complete windows required. History (ms on fw 50.43.1.0) is never
assumed for live packets. Also prints the per-packet structure (how many packets carry intervals, counts, lengths)
so an "intervals never appear" result is explicit rather than silent.
"""
import argparse
import glob
import json
import os
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


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--window", type=int, default=300)
    a = ap.parse_args(argv)
    packets = load(a.paths)
    for k, v in structure(packets).items():
        print(f"{k}: {v}")
    for k, v in audit(packets, a.window).items():
        print(f"{k}: {round(v, 4) if isinstance(v, float) else v}")


if __name__ == "__main__":
    main()

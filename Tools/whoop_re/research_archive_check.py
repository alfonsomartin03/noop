#!/usr/bin/env python3
"""Acceptance check for NOOP's history archives (#38). Read-only, stdlib only; prints aggregates.

    python3 -I research_archive_check.py ARCHIVE.jsonl|DIR [...] [--db COPY.sqlite]

Inputs are COPIES of `Application Support/OpenWhoop/research-history/` (full decoded-record frames kept during a
research capture) and/or `undecoded-history/` (records NOOP cannot decode), plus optionally a SQLite-backup copy of
the app database.

Checks:
1. Integrity: every line parses, the frame's header CRC16 and payload CRC32 verify, and the line's `len` matches.
2. Provenance: every line carries `capture`, `fw`, `hw`; for type-47 lines the stored `ts` equals the record time
   decoded from the bytes.
3. Duplicates: byte-identical repeats (dropped by NOOP's ResearchFrameFilter within a pull) vs distinct frames sharing
   a timestamp (kept on purpose).
4. Survival vs the store (`--db`): each decodable record (type 47, version 0x12) has the same heart rate in `hrSample`
   at its strap second — the complete bytes NOOP archived correspond to rows it saved and acknowledged.
5. Replay idempotence: decoded (ts, hr) rows are inserted twice into a fresh in-memory table keyed like `hrSample`
   (INSERT … ON CONFLICT DO NOTHING, as WhoopStore does); the second pass must add nothing.
"""
import argparse
import glob
import json
import os
import sqlite3
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import whoop5_decode as D  # noqa: E402


def lines(paths):
    for p in paths:
        for f in (sorted(glob.glob(os.path.join(p, "*.jsonl"))) if os.path.isdir(p) else [p]):
            with open(f, encoding="utf-8") as fh:
                for n, line in enumerate(fh, 1):
                    if line.strip():
                        yield f, n, line


def check(paths, db=None, device="my-whoop"):
    r = Counter()
    kinds, records, seen_bytes, by_ts = Counter(), [], set(), {}
    for f, n, line in lines(paths):
        r["lines"] += 1
        try:
            rec = json.loads(line)
            frame = bytes.fromhex(rec["hex"])
            d = D.decode(frame)
        except (ValueError, KeyError, D.FrameError):
            r["unparseable"] += 1
            continue
        if not (d.get("hdr_crc_ok") and d.get("crc32_ok")):
            r["bad_crc"] += 1
        if rec.get("len") != len(frame):
            r["len_mismatch"] += 1
        if not all(rec.get(k) for k in ("capture", "fw", "hw")):
            r["missing_provenance"] += 1
        kinds[(d.get("type"), d.get("version"))] += 1
        if frame in seen_bytes:
            r["byte_identical_repeats"] += 1
            continue
        seen_bytes.add(frame)
        if d.get("type") == 47 and "record_ts" in d:
            if rec.get("ts") != d["record_ts"]:
                r["ts_mismatch"] += 1
            if d["record_ts"] in by_ts:
                r["distinct_frames_sharing_ts"] += 1
            by_ts.setdefault(d["record_ts"], d)
            if d.get("version") == 0x12:
                records.append((d["record_ts"], d["hr"]))
    r["decodable_records"] = len(records)
    out = {"counts": dict(r), "types": {f"{t}/v{v}": c for (t, v), c in sorted(kinds.items(), key=str)}}

    # Replay idempotence (mirrors hrSample's primary key and ON CONFLICT DO NOTHING).
    mem = sqlite3.connect(":memory:")
    mem.execute("CREATE TABLE hr (deviceId TEXT, ts INTEGER, bpm INTEGER, PRIMARY KEY (deviceId, ts))")
    passes = []
    for _ in range(2):
        before = mem.execute("SELECT COUNT(*) FROM hr").fetchone()[0]
        mem.executemany("INSERT INTO hr VALUES (?, ?, ?) ON CONFLICT DO NOTHING", [(device, t, h) for t, h in records])
        passes.append(mem.execute("SELECT COUNT(*) FROM hr").fetchone()[0] - before)
    out["replay_rows_added"] = passes
    out["replay_idempotent"] = passes[1] == 0

    if db and records:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        lo, hi = min(t for t, _ in records), max(t for t, _ in records)
        stored = dict(con.execute("SELECT ts, bpm FROM hrSample WHERE deviceId = ? AND ts BETWEEN ? AND ?",
                                  (device, lo, hi)).fetchall())
        con.close()
        rows = {t: h for t, h in records}
        out["db_present"] = sum(1 for t in rows if t in stored)
        out["db_same_hr"] = sum(1 for t, h in rows.items() if stored.get(t) == h)
        out["db_checked"] = len(rows)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--db")
    a = ap.parse_args(argv)
    for k, v in check(a.paths, a.db).items():
        print(f"{k}: {v}")


if __name__ == "__main__":
    main()

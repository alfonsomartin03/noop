"""Synthetic tests for research_archive_check (#38). Stdlib only."""
import json
import os
import sqlite3
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import research_archive_check as R  # noqa: E402
import whoop5_decode as w  # noqa: E402

T0 = 1_795_040_000


def r18(ts, hr, tag=0):
    """A minimal type-47 v0x12 record (67+ bytes) with time at payload 7 and HR at 14; `tag` varies opaque bytes."""
    p = bytearray(70)
    p[0], p[1] = 47, 0x12
    struct.pack_into("<I", p, 7, ts)
    p[14] = hr
    p[60] = tag
    return w.build_frame(bytes(p))


def archive(frames, provenance=True, ts=True):
    d = tempfile.mkdtemp()
    with open(os.path.join(d, "2026-11-18.jsonl"), "w") as f:
        for fr in frames:
            rec = {"type": fr[8], "len": len(fr), "hex": fr.hex()}
            if ts:
                rec["ts"] = struct.unpack_from("<I", fr, 15)[0]
            if provenance:
                rec.update(capture="r18-test", fw="50.43.1.0", hw="WG50_r52")
            f.write(json.dumps(rec) + "\n")
    return d


class ResearchArchiveCheckTests(unittest.TestCase):
    def test_clean_archive_matches_store_and_replays_idempotently(self):
        frames = [r18(T0 + i, 60 + i % 5) for i in range(50)]
        db = os.path.join(tempfile.mkdtemp(), "copy.sqlite")
        con = sqlite3.connect(db)
        con.execute("CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER, synced INTEGER, PRIMARY KEY (deviceId, ts))")
        con.executemany("INSERT INTO hrSample VALUES ('my-whoop', ?, ?, 0)", [(T0 + i, 60 + i % 5) for i in range(49)])
        con.commit(); con.close()
        out = R.check([archive(frames)], db)
        self.assertEqual(out["counts"], {"lines": 50, "decodable_records": 50})
        self.assertEqual(out["replay_rows_added"], [50, 0])
        self.assertTrue(out["replay_idempotent"])
        self.assertEqual((out["db_checked"], out["db_present"], out["db_same_hr"]), (50, 49, 49), "one record not stored")

    def test_repeats_shared_timestamps_crc_and_provenance(self):
        good = r18(T0, 60)
        bad = bytearray(r18(T0 + 1, 61)); bad[-1] ^= 0xFF
        frames = [good, good, r18(T0, 60, tag=7), bytes(bad)]
        c = R.check([archive(frames, provenance=False)])["counts"]
        self.assertEqual(c["byte_identical_repeats"], 1)
        self.assertEqual(c["distinct_frames_sharing_ts"], 1, "kept on purpose; the store keeps the first")
        self.assertEqual(c["bad_crc"], 1)
        self.assertEqual(c["missing_provenance"], 4)

    def test_missing_stored_time_is_flagged(self):
        c = R.check([archive([r18(T0, 60)], ts=False)])["counts"]
        self.assertEqual(c["ts_mismatch"], 1)


if __name__ == "__main__":
    unittest.main()

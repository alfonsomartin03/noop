"""Synthetic tests for the #25 offline checks: step_reset_scan, strap_clock_offset, ppg_burst_check (stdlib only)."""
import datetime
import math
import os
import sqlite3
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import event120_check as E  # noqa: E402
import ppg_burst_check as P  # noqa: E402
import step_reset_scan as S  # noqa: E402
import strap_clock_offset as C  # noqa: E402


def local_ts(y, mo, d, h=0, mi=0, s=0):
    return int(datetime.datetime(y, mo, d, h, mi, s).astimezone().timestamp())


class StepResetScanTests(unittest.TestCase):
    def test_reset_bounded_by_last_record_not_last_change(self):
        # Counter flat from 23:00 (last change) but records continue to 00:00:05; the drop shows at 00:00:06.
        t_change = local_ts(2026, 11, 17, 23, 0, 0)
        t_drop = local_ts(2026, 11, 18, 0, 0, 6)
        changes = [(t_change - 60, 9000, 1), (t_change, 9100, 0), (t_drop, 0, 0)]
        presence = list(range(t_change, t_drop - 1 + 1))   # every second up to 00:00:05
        [r] = S.scan(changes, presence)
        self.assertEqual(r["last_seen_before"], t_drop - 1)
        self.assertEqual(r["gap_s"], 1)
        # The old value was still seen after local midnight, so midnight is excluded: the reset came later.
        self.assertNotIn("local-midnight", r["boundaries"])

    def test_gap_keeps_interval_open_and_reports_all_candidates(self):
        t0 = local_ts(2026, 11, 17, 22, 0, 0)
        t1 = local_ts(2026, 11, 18, 9, 0, 0)
        [r] = S.scan([(t0, 8000, 0), (t1, 12, 1)], [t0])
        self.assertEqual(r["gap_s"], t1 - t0)
        self.assertIn("local-midnight", r["boundaries"])
        self.assertFalse(r["wrap_plausible"])

    def test_wrap_flag_only_near_u16_max(self):
        [r] = S.scan([(100, 65400, 1), (101, 30, 1)], [100])
        self.assertTrue(r["wrap_plausible"])
        self.assertEqual(S.scan([(100, 5, 0), (101, 5, 0)], []), [])

    def test_no_boundary_inside_short_daytime_interval(self):
        t = local_ts(2026, 11, 17, 15, 0, 0)
        self.assertEqual(S.boundaries_in(t, t + 60), [])


class ClockOffsetTests(unittest.TestCase):
    def test_daily_minimum_ignores_late_deliveries_and_fits_drift(self):
        rows = []
        for day in range(5):
            base = local_ts(2026, 11, 5 + day, 12)
            off = 20 + 1.5 * day
            rows += [(base + off, base), (base + 3600 + off + 90, base + 3600)]   # second one = replayed late
        m = C.daily_minima(rows)
        self.assertEqual([round(x[2], 1) for x in m], [20.0, 21.5, 23.0, 24.5, 26.0])
        slope, ppm = C.drift(m)
        self.assertAlmostEqual(slope, 1.5, places=6)
        self.assertAlmostEqual(ppm, 1.5 / 86400 * 1e6, places=6)

    def test_reads_db_copy(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "c.sqlite")
            con = sqlite3.connect(path)
            con.execute("create table alarmEvent (receivedAt double, deviceTs integer, provenance text)")
            con.execute("insert into alarmEvent values (1000040.5, 1000000, 'live'), (5, 1, 'host')")
            con.commit()
            con.close()
            self.assertEqual(C.main([path]), 0)


def v1a_frame(ts, burst, state, samples):
    """Synthetic v0x1a frame: 8-byte header, 76-byte payload, 4-byte CRC placeholder (not checked by the tool)."""
    p = bytearray(76)
    p[0], p[1] = 47, 0x1A
    struct.pack_into("<I", p, 7, ts)
    p[13], p[14] = burst, state
    struct.pack_into("<I", p, 15, samples[0])
    for i in range(24):
        struct.pack_into("<h", p, 19 + 2 * i, samples[i + 1] - samples[i])
    return bytes(8) + bytes(p) + bytes(4)


class Event120HoldoutTests(unittest.TestCase):
    def rows(self, n, slope, seed=1):
        import random
        rnd = random.Random(seed)
        out = []
        for i in range(n):
            hr = 60 + rnd.random() * 30
            mv = rnd.random()
            f = {"u16@18": int(1000 + slope * hr + rnd.random() * 5), "u16@21": int(500 - slope * hr + rnd.random() * 5),
                 "u8@9": int(100 - slope * 50 * mv + rnd.random() * 5)}
            out.append((i * 7200, (i * 2) % 24, f, {"hr_prev": hr, "hr_next": hr, "move_prev": mv}))
        return out

    def test_underpowered_gives_no_verdict(self):
        n, _, res = E.holdout(self.rows(40, 5))
        self.assertEqual(n, 40)
        self.assertEqual({v for *_, v in res}, {"UNDERPOWERED"})

    def test_predicted_relations_pass_and_noise_does_not(self):
        _, crit, res = E.holdout(self.rows(120, 5))
        self.assertTrue(all(v == "SUPPORTED" for *_, v in res), res)
        _, _, noise = E.holdout(self.rows(120, 0))
        self.assertTrue(all(v == "NOT SUPPORTED" for *_, v in noise), noise)

    def test_wrong_sign_is_not_supported(self):
        _, _, res = E.holdout(self.rows(120, -5))
        self.assertTrue(all(v == "NOT SUPPORTED" for *_, v in res), res)


class PPGBurstTests(unittest.TestCase):
    def burst(self, bpm, drift=0.0, start=1_000_000):
        frames = []
        for k in range(40):
            s = [int(100000 + drift * (25 * k + i) + 400 * math.sin(2 * math.pi * bpm / 60 * (k + i / 25)))
                 for i in range(25)]
            frames.append(v1a_frame(start + k, 7, 0, s))
        return frames

    def write(self, frames):
        import json
        f = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        for fr in frames:
            f.write(json.dumps({"version": 26, "hex": fr.hex()}) + "\n")
        f.close()
        return f.name

    def test_reconstructs_25_samples_and_finds_pulse_with_drift(self):
        path = self.write(self.burst(72, drift=40.0))
        try:
            recs = P.load_records([path])
            [b] = P.bursts(recs)
            self.assertEqual(len(b), 40)
            self.assertEqual(len(recs[b[0]][2]), 25)
            self.assertAlmostEqual(P.peak_bpm(P.signal(recs, b, "deltas")), 72, delta=1.5)
        finally:
            os.unlink(path)

    def test_record_mean_mode_injects_1hz_artifact_under_drift(self):
        path = self.write(self.burst(72, drift=400.0))
        try:
            recs = P.load_records([path])
            [b] = P.bursts(recs)
            pk = P.peak_bpm(P.signal(recs, b, "mean"))
            self.assertTrue(abs(pk - 60) <= 1.5 or abs(pk - 120) <= 1.5, pk)
        finally:
            os.unlink(path)

    def test_bursts_split_on_counter_and_gaps(self):
        recs = {1: (1, 0, [0] * 25), 2: (1, 0, [0] * 25), 4: (1, 0, [0] * 25), 5: (2, 0, [0] * 25)}
        self.assertEqual(P.bursts(recs), [[1, 2], [4], [5]])

    def test_evaluate_counts_harmonics_separately(self):
        ev = P.evaluate([(60, 60), (120, 60), (30, 60), (90, 60)])
        self.assertEqual((ev["match"], ev["at_2x"], ev["at_half"]), (1, 1, 1))


if __name__ == "__main__":
    unittest.main()

import os
import random
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rr_unit_audit as a  # noqa: E402


def synthetic(seconds, scale, bpm=60.0, drop_every=0, seed=1):
    """Beats at a steady-ish rate; each word = interval_s * scale (1000 = ms, 1024 = ticks); HR stored every second."""
    rnd = random.Random(seed)
    hr, rr = [(t, round(bpm)) for t in range(seconds)], []
    t, i = 0.0, 0
    while True:
        interval = 60.0 / bpm * (1 + rnd.uniform(-0.03, 0.03))
        t += interval
        if t >= seconds:
            break
        i += 1
        if drop_every and i % drop_every == 0:
            continue
        rr.append((int(t), round(interval * scale)))
    return hr, rr


class RRUnitAuditTests(unittest.TestCase):
    def test_millisecond_words_read_as_ms(self):
        r = a.assess(a.windows(*synthetic(300 * 40, 1000)))
        self.assertEqual(r["verdict"], "milliseconds")
        self.assertAlmostEqual(r["median_ratio"], 1.0, delta=0.006)

    def test_tick_words_read_as_ticks(self):
        r = a.assess(a.windows(*synthetic(300 * 40, 1024)))
        self.assertEqual(r["verdict"], "1/1024-s ticks")
        self.assertAlmostEqual(r["median_hr_minus_rr_hr_if_ticks"], 0, delta=1)

    def test_missed_beats_are_excluded_not_mistaken_for_a_unit(self):
        # Every 10th beat missing: count-based rate is 10 % low, so no window is complete.
        r = a.assess(a.windows(*synthetic(300 * 40, 1024, drop_every=10)))
        self.assertEqual(r["complete"], 0)
        self.assertTrue(r["verdict"].startswith("inconclusive"))

    def test_hr_gaps_drop_the_window(self):
        hr, rr = synthetic(600, 1000)
        hr = [h for h in hr if h[0] != 450]
        self.assertEqual([w["start"] for w in a.windows(hr, rr)], [0])

    def test_cli_reads_a_copy(self):
        hr, rr = synthetic(300 * 35, 1000)
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "copy.sqlite")
            con = sqlite3.connect(path)
            con.execute("CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER)")
            con.execute("CREATE TABLE rrInterval (deviceId TEXT, ts INTEGER, rrMs INTEGER, synced INTEGER, seq INTEGER)")
            con.executemany("INSERT INTO hrSample VALUES ('dev', ?, ?)", hr)
            con.executemany("INSERT INTO rrInterval VALUES ('dev', ?, ?, 0, 0)", rr)
            con.commit()
            con.close()
            out = StringIO()
            with redirect_stdout(out):
                a.main([path])
            self.assertIn("verdict: milliseconds", out.getvalue())


if __name__ == "__main__":
    unittest.main()

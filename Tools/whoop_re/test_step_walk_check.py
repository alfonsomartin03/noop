import os
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import step_walk_check as s  # noqa: E402


class StepWalkCheckTests(unittest.TestCase):
    def test_window_matches_the_swift_rules(self):
        rows = [(0, 100, 0), (2, 100, 1), (3, 106, 1), (4, 107, 1), (5, 109, 1), (6, 109, 0)]
        self.assertEqual(s.window(rows, 1, 10),
                         {"steps": 9, "resets": 0, "has_start_reference": True, "activity_1_seconds": 4, "rows": 5})
        self.assertEqual(s.window(rows, 3, 5)["steps"], 1)
        r = s.window([(0, 10000, 0), (5, 10010, 0), (6, 3, 0), (9, 8, 0)], 0, 10)
        self.assertEqual((r["steps"], r["resets"]), (18, 1))

    def test_cli_on_a_synthetic_database(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "copy.sqlite")
            con = sqlite3.connect(path)
            con.execute("CREATE TABLE stepCounterSample (deviceId TEXT, ts INTEGER, counter INTEGER, activity INTEGER)")
            t0 = s.local_unix("2026-11-17 15:00:00")
            con.executemany("INSERT INTO stepCounterSample VALUES ('dev', ?, ?, ?)",
                            [(t0 - 60, 5000, 0), (t0 + 10, 5000, 1), (t0 + 20, 5250, 1), (t0 + 300, 5498, 1), (t0 + 900, 5498, 0)])
            con.commit()
            con.close()
            out = StringIO()
            with redirect_stdout(out):
                s.main([path, "--start", "2026-11-17 15:00:00", "--end", "2026-11-17 15:10:00", "--counted", "500"])
            text = out.getvalue()
            self.assertIn("strap steps 498", text)
            self.assertIn("difference -2 (-0.4 %)", text)
            self.assertNotIn("WARNING", text)


if __name__ == "__main__":
    unittest.main()

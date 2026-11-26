import unittest

import rewarm_check as rc


def flat(t0, t1, c):
    return [(t, c) for t in range(t0, t1)]


class RewarmCheckTests(unittest.TestCase):
    def test_removals_pair_off_then_on_and_accept_unnamed_kinds(self):
        ev = [(50, "EVENT_9"), (100, "EVENT_10"), (130, "EVENT_9"), (200, "WRIST_OFF"), (210, "WRIST_OFF"),
              (300, "WRIST_ON"), (400, "WRIST_OFF")]
        self.assertEqual(rc.removals(ev), [(100, 130), (200, 300)], "a leading ON and a trailing open OFF are skipped")

    def test_holes(self):
        self.assertEqual(rc.holes([0, 1, 2, 70, 71, 100], 30), [(2, 70)])

    def test_removal_cools_then_warms_back(self):
        # 32 °C before; off 1000..1200; re-wear at 27 °C rising 0.05 °C/s to 32 °C (100 s), then flat.
        s = flat(0, 1000, 32.0) + [(1200 + i, min(32.0, 27.0 + 0.05 * i)) for i in range(0, 1300)]
        r = rc.rewarm(s, 999, 1200)
        self.assertTrue(r["cool_start"])
        self.assertEqual(r["off_s"], 201)
        self.assertAlmostEqual(r["min60"], 27.0)
        # Rolling 30-s median reaches 31.8 at about 96 + 15 s.
        self.assertTrue(95 <= r["rewarm_s"] <= 115, r["rewarm_s"])

    def test_lost_records_hole_is_not_a_cool_start(self):
        s = flat(0, 1000, 32.0) + flat(1060, 2400, 32.0)
        r = rc.rewarm(s, 999, 1060)
        self.assertFalse(r["cool_start"])
        self.assertEqual(r["rewarm_s"], 0)

    def test_never_settles_within_ten_minutes(self):
        s = flat(0, 1000, 32.0) + [(1100 + i, 28.0 + 0.004 * i) for i in range(1300)]
        self.assertIsNone(rc.rewarm(s, 999, 1100)["rewarm_s"])

    def test_night_median_excludes_wake_off_and_tails(self):
        s = flat(0, 100, 30.0) + flat(100, 200, 33.0) + flat(200, 300, 20.0) + flat(300, 400, 33.0)
        asleep = [(100, 400)]
        self.assertEqual(rc.night_median(s, asleep, [], [])[1], 300, "wake time before the asleep segment is excluded")
        med, n = rc.night_median(s, asleep, [(200, 300)], [])
        self.assertEqual((med, n), (33.0, 200), "off-wrist time and wake time are excluded")
        med, n = rc.night_median(s, asleep, [(200, 300)], [(300, 350)])
        self.assertEqual(n, 150)

    def test_sensitivity_covers_every_k(self):
        s = flat(0, 1000, 33.0) + [(1000 + i, 30.0) for i in range(120)] + flat(1120, 4000, 33.0)
        out = rc.sensitivity(s, [(0, 4000)], [], [1000])
        self.assertEqual(sorted(out), list(rc.EXCLUDE_K))
        self.assertEqual(out[0][0], 33.0, "a 2-min cool tail does not move a median over ~66 min")
        self.assertEqual(out[600][1], 4000 - 600)


if __name__ == "__main__":
    unittest.main()

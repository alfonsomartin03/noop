"""Synthetic tests for r18_field_inventory (#44). Stdlib only; no private data."""
import binascii
import json
import math
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import r18_field_inventory as R  # noqa: E402


def payload(ts, hr=60, act=0, dyn=0.01, g=(0.0, 0.0, 1.0), twin=None, f105=-5.0):
    p = bytearray(112)
    p[0], p[1] = 47, 0x12
    struct.pack_into("<I", p, 7, ts)
    p[14] = hr
    p[29] = hr if twin is None else twin
    struct.pack_into("<f", p, 33, dyn)
    for i, o in enumerate((37, 41, 45)):
        struct.pack_into("<f", p, o, g[i])
    p[55] = act
    struct.pack_into("<f", p, 105, f105)
    return bytes(p)


def frame(p, bad=False):
    crc = binascii.crc32(p) & 0xFFFFFFFF
    return bytes(8) + p + struct.pack("<I", crc ^ (1 if bad else 0))


def line(fr, ts):
    return json.dumps({"type": 47, "version": 18, "ts": ts, "hex": fr.hex()})


class InventoryTests(unittest.TestCase):
    def write(self, d, lines):
        with open(os.path.join(d, "x.jsonl"), "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

    def test_crc_dedupe_since_and_order(self):
        with tempfile.TemporaryDirectory() as d:
            t = 1_795_000_000
            self.write(d, [line(frame(payload(t + 2)), t + 2), line(frame(payload(t + 1)), t + 1),
                           line(frame(payload(t + 1, hr=99)), t + 1),          # same second: first kept
                           line(frame(payload(t + 3), bad=True), t + 3),       # bad CRC
                           json.dumps({"type": 47, "version": 26, "hex": "00"})])
            ps, c = R.records([d])
            self.assertEqual([struct.unpack_from("<I", p, 7)[0] for p in ps], [t + 1, t + 2])
            self.assertEqual(c, {"lines": 4, "bad_crc": 1, "duplicates": 1})
            self.assertEqual(ps[0][14], 60)
            later, _ = R.records([d], since_ts=t + 2)
            self.assertEqual(len(later), 1)

    def test_dynamic_magnitude_vs_quaternion_signals(self):
        ps, t, ang = [], 1_795_000_000, 0.0
        for i in range(300):
            act = (0, 1, 2)[i // 100]
            ang += 0.05 * act                                  # wrist turns faster with more activity
            g = (math.sin(ang), 0.0, math.cos(ang))
            ps.append(payload(t + i, act=act, dyn=0.01 + 0.3 * act * (1 + 0.1 * math.sin(i)), g=g))
        r = R.gravity_tests(ps)
        self.assertAlmostEqual(r["norm3_within"], 1.0)
        self.assertEqual(r["first_negative_share"], 0)
        m = r["first_median_by_activity"]
        self.assertLess(m[0], m[1])
        self.assertLess(m[1], m[2])
        self.assertGreater(r["first_vs_dg_r"], 0.5)

    def test_hr_twin_and_unknown_float(self):
        ps = [payload(1_795_000_000 + i, hr=60 + i % 20, twin=60 + i % 20 + (1 if i % 4 == 0 else 0),
                      act=i % 3, f105=-5.0 + i % 3) for i in range(200)]
        t = R.hr_twin(ps, 29)
        self.assertAlmostEqual(t["equal"], 0.75)
        self.assertEqual(t["median_abs_diff"], 0)
        self.assertEqual(t["differ_gt3_when_both"], 0)
        rows, floats = R.inventory(ps)
        self.assertIn(105, [f["offset"] for f in floats])
        self.assertEqual(R.float_summary(ps, 105)["median_by_activity"], {0: -5.0, 1: -4.0, 2: -3.0})
        self.assertEqual(rows[0]["class"], "constant")
        few, var = R.relations(ps, rows)
        self.assertAlmostEqual(dict((o, r) for o, _, r in var)[29], 1.0, places=1)


if __name__ == "__main__":
    unittest.main()

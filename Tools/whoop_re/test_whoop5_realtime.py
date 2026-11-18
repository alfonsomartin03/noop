#!/usr/bin/env python3
"""Synthetic live REALTIME_DATA (type 40) bounds for whoop5_decode.py (#39). Needs no private fixture."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import whoop5_decode as w  # noqa: E402

TS = bytes([0x41, 0xBA, 0xE8, 0x6A])  # 2026-11-02


def frame(payload):
    return w.build_frame(bytes(payload))


class Realtime(unittest.TestCase):
    def test_valid_intervals(self):
        d = w.decode(frame([40, 2, *TS, 0, 0, 72, 2, 0x20, 0x03, 0x2A, 0x03]))
        self.assertEqual((d["hr"], d["rr"], d["rr_truncated"]), (72, [800, 810], False))

    def test_count_overrun_is_flagged_not_partial(self):
        d = w.decode(frame([40, 2, *TS, 0, 0, 60, 255, 0, 0]))
        self.assertEqual((d["hr"], d["rr"], d["rr_truncated"]), (60, [], True))
        d = w.decode(frame([40, 2, *TS, 0, 0, 61, 2, 0x20, 0x03]))
        self.assertEqual((d["rr"], d["rr_truncated"]), ([], True))

    def test_zero_words_and_count_zero(self):
        d = w.decode(frame([40, 2, *TS, 0, 0, 62, 2, 0, 0, 0x20, 0x03]))
        self.assertEqual((d["rr"], d["rr_truncated"]), ([800], False))
        d = w.decode(frame([40, 2, *TS, 0, 0, 64, 0]))
        self.assertEqual((d["hr"], d["rr"], d["rr_truncated"]), (64, [], False))

    def test_short_prefix_has_no_hr(self):
        d = w.decode(frame([40, 2, *TS]))
        self.assertNotIn("hr", d)


if __name__ == "__main__":
    unittest.main()

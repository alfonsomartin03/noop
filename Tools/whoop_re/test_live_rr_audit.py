"""Synthetic tests for live_rr_audit (#39). Stdlib only; frames built with whoop5_decode.build_frame."""
import json
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live_rr_audit as L  # noqa: E402
import whoop5_decode as w  # noqa: E402

T0 = 1_795_000_000


def live(ts, hr, words):
    p = bytes([40, 2]) + struct.pack("<IHBB", ts, 0, hr, len(words)) + b"".join(struct.pack("<H", x) for x in words)
    return w.build_frame(p)


def write(frames):
    d = tempfile.mkdtemp()
    with open(os.path.join(d, "2026-11-18.jsonl"), "w") as f:
        for fr in frames:
            f.write(json.dumps({"type": fr[8], "len": len(fr), "hex": fr.hex(), "capture": "live-rr"}) + "\n")
    return d


def session(seconds, hr, word, unit_scale=1.0):
    """One packet per second; beats at 60/hr s carried in the packet of the second they end in."""
    frames, t_beat, beats = [], 0.0, 60.0 / hr
    for s in range(seconds):
        words = []
        while t_beat + beats <= s + 1:
            t_beat += beats
            words.append(round(word * unit_scale))
        frames.append(live(T0 + s, hr, words))
    return frames


class LiveRRAuditTests(unittest.TestCase):
    def test_millisecond_words_give_a_ms_verdict(self):
        packets = L.load([write(session(300 * 32, 60, 1000))])
        r = L.audit(packets)
        self.assertEqual(r["verdict"], "milliseconds")
        self.assertEqual(L.structure(packets)["with_intervals"], 300 * 32)

    def test_tick_words_give_a_tick_verdict(self):
        packets = L.load([write(session(300 * 32, 60, 1000, unit_scale=1.024))])
        self.assertEqual(L.audit(packets)["verdict"], "1/1024-s ticks")

    def test_no_intervals_is_explicit_and_inconclusive(self):
        packets = L.load([write([live(T0 + s, 60, []) for s in range(600)])])
        st = L.structure(packets)
        self.assertEqual((st["packets"], st["with_intervals"], st["lengths"]), (600, 0, {24: 600}))
        self.assertTrue(L.audit(packets)["verdict"].startswith("inconclusive"))

    def test_bad_crc_other_types_and_duplicates_are_skipped(self):
        good = live(T0, 60, [1000])
        bad = bytearray(live(T0 + 1, 60, [1000])); bad[-1] ^= 0xFF
        other = w.build_frame(bytes([47, 0x12]) + bytes(70))
        dup = live(T0, 99, [500])
        packets = L.load([write([good, bytes(bad), other, dup])])
        self.assertEqual(list(packets), [T0])
        self.assertEqual(packets[T0][:2], (60, [1000]), "first copy of a second wins")


if __name__ == "__main__":
    unittest.main()

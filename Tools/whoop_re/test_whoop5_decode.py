#!/usr/bin/env python3
"""Tests for whoop5_decode.py against real captured frames (fixtures/whoop5_frames.json).

    python3 -m unittest Tools/whoop_re/test_whoop5_decode.py
"""
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import whoop5_decode as w  # noqa: E402

FIXTURES = {f["name"]: bytes.fromhex(f["hex"]) for f in json.load(open(os.path.join(HERE, "fixtures", "whoop5_frames.json")))}


class Envelope(unittest.TestCase):
    def test_every_fixture_passes_both_crcs(self):
        for name, frame in FIXTURES.items():
            d = w.decode(frame)
            self.assertTrue(d["hdr_crc_ok"] and d["crc32_ok"], name)

    def test_builder_reproduces_static_hello(self):
        self.assertEqual(w.build_frame(bytes([35, 1, 145, 1])), FIXTURES["tx_client_hello"])

    def test_builder_reproduces_probe_command(self):
        # The probe built this with Framing.swift's buildWhoop5CommandFrame; the Python builder must agree.
        self.assertEqual(w.build_frame(bytes([35, 201, 11])), FIXTURES["tx_get_clock"])

    def test_direction_bytes(self):
        self.assertEqual(w.decode(FIXTURES["tx_get_clock"])["header45"], "0001")          # app → strap
        self.assertEqual(w.decode(FIXTURES["rx_get_clock_success"])["header45"], "0100")  # strap → app

    def test_truncated(self):
        f = FIXTURES["rx_get_data_range_success"]
        with self.assertRaisesRegex(w.FrameError, "truncated"):
            w.decode(f[:-1])
        with self.assertRaisesRegex(w.FrameError, "too short"):
            w.decode(f[:7])

    def test_trailing_bytes_rejected(self):
        with self.assertRaisesRegex(w.FrameError, "trailing"):
            w.decode(FIXTURES["rx_link_valid_success"] + b"\x00")

    def test_bad_sof(self):
        f = bytearray(FIXTURES["rx_link_valid_success"]); f[0] = 0xAB
        with self.assertRaisesRegex(w.FrameError, "start-of-frame"):
            w.decode(bytes(f))

    def test_payload_corruption_fails_crc32_only(self):
        f = bytearray(FIXTURES["rx_get_battery_level_success"]); f[13] ^= 0x01
        d = w.decode(bytes(f))
        self.assertTrue(d["hdr_crc_ok"])
        self.assertFalse(d["crc32_ok"])

    def test_header_corruption_fails_crc16(self):
        f = bytearray(FIXTURES["rx_get_battery_level_success"]); f[5] ^= 0x01
        self.assertFalse(w.decode(bytes(f))["hdr_crc_ok"])

    def test_declared_length_too_small(self):
        f = bytearray(FIXTURES["rx_link_valid_success"]); f[2], f[3] = 2, 0
        with self.assertRaisesRegex(w.FrameError, "declared length"):
            w.decode(bytes(f))


class Reassembly(unittest.TestCase):
    def test_fragmented_and_concatenated(self):
        a, b = FIXTURES["rx_get_data_range_pending"], FIXTURES["rx_get_data_range_success"]
        stream = b"\x00\x13" + a + b   # leading garbage, then two frames split at awkward points
        r, out = w.Reassembler(), []
        for i in range(0, len(stream), 7):
            out += r.feed(stream[i:i + 7])
        self.assertEqual(out, [a, b])

    def test_partial_frame_waits(self):
        f = FIXTURES["rx_get_clock_success"]
        r = w.Reassembler()
        self.assertEqual(r.feed(f[:10]), [])
        self.assertEqual(r.feed(f[10:]), [f])

    def test_absurd_length_resyncs(self):
        f = FIXTURES["rx_link_valid_success"]
        r = w.Reassembler()
        self.assertEqual(r.feed(bytes([0xAA, 0x01, 0xFF, 0xFF]) + f), [f])


class Decoding(unittest.TestCase):
    def test_command_response_fields(self):
        d = w.decode(FIXTURES["rx_get_data_range_pending"])
        self.assertEqual((d["cmd"], d["origin_seq"], d["result_name"]), (34, 202, "PENDING"))

    def test_unsupported_commands_on_fw_50_43(self):
        for n in ("report_version_info", "get_extended_battery_info", "get_max_protocol_version", "get_all_haptics_pattern"):
            self.assertEqual(w.decode(FIXTURES[f"rx_{n}_unsupported"])["result"], 3, n)

    def test_battery_and_clock(self):
        self.assertEqual(w.decode(FIXTURES["rx_get_battery_level_success"])["battery_pct"], 20)
        self.assertEqual(w.decode(FIXTURES["rx_get_clock_success"])["clock_unix"], 1793636096)

    def test_link_valid_text(self):
        self.assertEqual(w.decode(FIXTURES["rx_link_valid_success"])["text"], "There it is.")

    def test_data_range_matches_last_ack(self):
        # The last ack before E02 was HISTORICAL_DATA_RESULT [01] 66960100 0f000000 (page 104038, block 15).
        words = w.decode(FIXTURES["rx_get_data_range_success"])["range_words"]
        self.assertEqual((words[1], words[3], words[4]), (104038, 104038, 15))

    def test_history_end(self):
        d = w.decode(FIXTURES["rx_history_end_app_log"])
        self.assertEqual((d["meta_name"], d["end_data"], d["trim_page"], d["trim_block"]),
                         ("HISTORY_END", "c58601000f000000", 0x186C5, 15))

    def test_event_body_length_is_consistent(self):
        for name, frame in FIXTURES.items():
            d = w.decode(frame)
            if d.get("type") == 48:
                self.assertTrue(d["body_len_ok"], name)
                self.assertEqual(len(d["body"]) // 2, d["body_len"], name)

    def test_hello_response_body_is_redacted(self):
        resp = w.build_frame(bytes([36, 1, 145, 1, 1]) + b"SECRET-SERIAL")
        self.assertEqual(w.decode(resp)["body"], "<redacted>")

    def test_realtime_hr_layout(self):
        # Synthetic frame in the E04 layout (real E04 frames are biometric and not committed). Real frames were
        # 32 bytes: 20-byte payload, R-R count 0, byte 18 = 0x01.
        payload = bytes([40, 0x02]) + (1793636929).to_bytes(4, "little") + bytes([0x47, 0x41, 69, 0]) + bytes(8) + bytes([1, 0])
        frame = w.build_frame(payload)
        self.assertEqual(len(frame), 32)
        d = w.decode(frame)
        self.assertEqual((d["kind"], d["rt_ts"], d["hr"], d["rr_count"], d["rr"]), (2, 1793636929, 69, 0, []))


if __name__ == "__main__":
    unittest.main()

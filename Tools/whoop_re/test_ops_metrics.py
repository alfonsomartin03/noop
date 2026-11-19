"""Synthetic tests for ops_metrics (#46). Stdlib only; no private data."""
import datetime
import json
import os
import tempfile
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ops_metrics as M  # noqa: E402


def local_ts(y, mo, d, h=0, mi=0, s=0):
    return int(datetime.datetime(y, mo, d, h, mi, s).astimezone().timestamp())


class DailyTableTests(unittest.TestCase):
    def test_counts_by_local_day_and_kind_aliases(self):
        d1 = local_ts(2026, 11, 3, 23, 59, 59)
        d2 = local_ts(2026, 11, 4, 0, 0, 1)
        t = M.daily_table([d1, d2, d2 + 1], [(d1, "STRAP_DRIVEN_ALARM_SET"), (d2, "EVENT_56"),
                                             (d2, "BLE_CONNECTION_UP"), (d2, "DOUBLE_TAP")])
        a, b = datetime.date(2026, 11, 3), datetime.date(2026, 11, 4)
        self.assertEqual(t[a]["hr_s"], 1)
        self.assertEqual(t[a]["alarm_set"], 1)
        self.assertEqual(t[b]["hr_s"], 2)
        self.assertEqual(t[b]["alarm_set"], 1, "old unnamed kind counts as the same event")
        self.assertEqual(t[b]["conn_up"], 1)

    def test_complete_days_exclude_partial_and_pre_event_days(self):
        row = lambda hr: {"hr_s": hr, **{k: 0 for k in M.EVENT_KINDS}}  # noqa: E731
        table = {datetime.date(2026, 11, 1): row(86400), datetime.date(2026, 11, 2): row(86400),
                 datetime.date(2026, 11, 3): row(86400), datetime.date(2026, 11, 4): row(40000)}
        full = M.complete_days(table, local_ts(2026, 11, 2, 11, 0))
        self.assertEqual(list(full), [datetime.date(2026, 11, 3)],
                         "Nov 1 had no stored events, Nov 2 only from 11:00, Nov 4 is partial")
        self.assertEqual(M.complete_days(table, None), {})

    def test_period_medians(self):
        row = lambda n: {"hr_s": 86400, "alarm_set": n, "conn_up": 0, "conn_down": 0, "battery_evt": 0}  # noqa: E731
        table = {datetime.date(2026, 11, d): row(n) for d, n in [(14, 40), (15, 50), (16, 60), (17, 2), (18, 3)]}
        [(_, n1, m1), (_, n2, m2)] = M.period_medians(table, [datetime.date(2026, 11, 17)])
        self.assertEqual((n1, m1["alarm_set"]), (3, 50))
        self.assertEqual((n2, m2["alarm_set"]), (2, 2.5))


class BandRateTests(unittest.TestCase):
    H = 3600

    def test_complete_pass_after_a_gradual_charge(self):
        # Discharge to 20, charge one point at a time to 100 (no jump >= 3 between readings), then discharge.
        r, t = [], 0
        for s in range(40, 19, -1):
            r.append((t, s)); t += self.H
        for s in range(21, 101):
            r.append((t, s)); t += 60
        start = t
        for s in range(100, 80, -1):
            r.append((t, s)); t += 2 * self.H
        [p] = M.band_rates(r)
        self.assertFalse(p["open"])
        self.assertEqual(p["start"], start + 2 * self.H)       # first reading at 99
        self.assertEqual(p["drop"], 14)
        self.assertAlmostEqual(p["rate_per_day"], 14 / 28 * 24)

    def test_charging_before_the_bottom_abandons_the_pass(self):
        r = [(0, 100), (self.H, 99), (2 * self.H, 95), (3 * self.H, 98), (4 * self.H, 100), (5 * self.H, 99),
             (6 * self.H, 85)]
        [p] = M.band_rates(r)
        self.assertEqual((p["start"], p["end"]), (5 * self.H, 6 * self.H))

    def test_open_pass_and_never_above_top(self):
        r = [(0, 100), (self.H, 99), (11 * self.H, 94)]
        [p] = M.band_rates(r)
        self.assertTrue(p["open"])
        self.assertEqual(p["drop"], 5)
        self.assertEqual(M.band_rates([(0, 80), (self.H, 70)]), [], "never started above the band")


class LogCountsTests(unittest.TestCase):
    def test_parses_commands_connects_and_power_offs(self):
        lines = [
            "Timestamp               Ty Process[PID:TID]",
            "2026-11-18 09:40:17.451 Df NOOP[1:2] [com.noopapp.noop:ble] → 5.0 Get Battery Level seq=254 payload=",
            "2026-11-18 09:40:17.451 Df NOOP[1:2] [com.noopapp.noop:ble] → 5.0 Get Clock seq=253 payload=",
            "2026-11-18 09:40:19.546 Df NOOP[1:2] [com.noopapp.noop:ble] → 5.0 Get Clock seq=1 payload=",
            "2026-11-18 09:41:27.598 Df NOOP[1:2] [com.noopapp.noop:ble] Connected — discovering services",
            "2026-11-18 09:41:34.162 Df NOOP[1:2] [com.noopapp.noop:ble] Central state: poweredOff (turn Bluetooth on)",
        ]
        cmds, connects, off, first, last = M.log_counts(lines)
        self.assertEqual(cmds, {"Get Battery Level": 1, "Get Clock": 2})
        self.assertEqual((connects, off), (1, 1))
        self.assertEqual((first, last), ("2026-11-18 09:40:17", "2026-11-18 09:41:34"))


class CounterFileTests(unittest.TestCase):
    """Day files in the shape `OpsCounterStore` writes (JSONEncoder, sorted keys)."""

    def write(self, d, name, body):
        with open(os.path.join(d, name), "w", encoding="utf-8") as f:
            f.write(body if isinstance(body, str) else json.dumps(body))

    def test_loads_sorted_days_and_skips_bad_files(self):
        with tempfile.TemporaryDirectory() as d:
            self.write(d, "2026-11-20.json", {"day": "2026-11-20", "connectedSeconds": 0})
            self.write(d, "2026-11-19.json", {"day": "2026-11-19", "connectedSeconds": 7200,
                                              "app": "0.1.0 (1)", "firmware": ["50.43.1.0"],
                                              "commands": {"Get Clock": 8}, "counts": {"connect": 3}})
            self.write(d, "2026-11-18.json", "{not json")
            self.write(d, "2026-11-17.json", {"day": "2026-11-16"})
            self.write(d, "notes.json", {"day": "x"})
            days, bad = M.load_counter_days(d)
        self.assertEqual([x["day"] for x in days], ["2026-11-19", "2026-11-20"])
        self.assertEqual(len(bad), 2)

    def test_summary_rates_per_connected_hour_and_no_rate_offline(self):
        s = M.counter_summary({"day": "2026-11-19", "connectedSeconds": 7200, "commands": {"Get Clock": 8},
                               "counts": {"connect": 3, "rxBytes": 1000}})
        self.assertEqual(s["hours"], 2)
        self.assertEqual(s["counts"]["connect"], 3)
        self.assertEqual(s["counts"]["bluetoothOff"], 0, "absent counter is a zero count, not missing")
        self.assertEqual(s["per_hour"]["cmd:Get Clock"], 4)
        self.assertEqual(s["per_hour"]["connect"], 1.5)
        off = M.counter_summary({"day": "2026-11-20", "connectedSeconds": 0, "counts": {"connect": 1}})
        self.assertIsNone(off["per_hour"]["connect"], "no connected time: no rate")


if __name__ == "__main__":
    unittest.main()

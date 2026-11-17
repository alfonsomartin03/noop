#!/usr/bin/env python3
"""Estimate the WHOOP strap's clock offset and drift from data NOOP already stores (issue #25). Read-only.

    python3 -I strap_clock_offset.py COPY.sqlite

Run on a COPY of NOOP's database (SQLite backup or the app's export), never the live file.

Evidence: every live strap event NOOP records in `alarmEvent` (provenance 'live') carries the strap's own timestamp
(`deviceTs`, strap clock) and the Mac's receipt time (`receivedAt`). receivedAt - deviceTs = (Mac - strap clock) +
delivery latency. Latency is >= 0, so the daily MINIMUM is the best offset estimate; spikes are history replays or
delayed deliveries. On fw 50.43.1.0 NOOP never sends SET_CLOCK (not in `BLEManager.whoop5Allowed`), so the offset is
the strap's free-running drift, and every stored 5.0 history timestamp (HR, steps, temperature, events) is in strap
time. Prints per-day minima and a least-squares drift in seconds/day and ppm.
"""
import datetime
import sqlite3
import sys


def daily_minima(rows):
    """rows: [(received_unix, device_ts)] -> [(date, n, min_offset_s)] in date order (local dates)."""
    days = {}
    for received, device in rows:
        d = datetime.date.fromtimestamp(received)
        off = received - device
        n, m = days.get(d, (0, None))
        days[d] = (n + 1, off if m is None else min(m, off))
    return [(d, n, m) for d, (n, m) in sorted(days.items())]


def drift(minima):
    """Least-squares slope of the daily minima (s/day) -> (slope_s_per_day, ppm) or None with < 2 days."""
    if len(minima) < 2:
        return None
    x0 = minima[0][0].toordinal()
    xs = [d.toordinal() - x0 for d, _, _ in minima]
    ys = [m for _, _, m in minima]
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    den = sum((x - mx) ** 2 for x in xs)
    if den == 0:
        return None
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den
    return slope, slope / 86400 * 1e6


def main(argv):
    if len(argv) != 1:
        print(__doc__)
        return 2
    con = sqlite3.connect(f"file:{argv[0]}?mode=ro", uri=True)
    rows = con.execute("select receivedAt, deviceTs from alarmEvent where provenance = 'live' and deviceTs is not null "
                       "and receivedAt is not null").fetchall()
    if not rows:
        print("no live strap events with both clocks")
        return 1
    m = daily_minima(rows)
    for d, n, off in m:
        print(f"{d}  events {n:4d}  Mac - strap >= {off:6.1f} s")
    dr = drift(m)
    if dr:
        print(f"drift {dr[0]:+.2f} s/day ({dr[1]:+.1f} ppm; positive = strap clock falls behind)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

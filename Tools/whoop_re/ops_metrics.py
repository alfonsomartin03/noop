#!/usr/bin/env python3
"""Ordinary-use operating metrics from data NOOP already stores (issue #46). Read-only, stdlib only.

    python3 -I ops_metrics.py COPY.sqlite [--split YYYY-MM-DD ...] [--log UNIFIED_LOG.txt] [--counters DIR]
    python3 -I ops_metrics.py --counters DIR

Run on a COPY of NOOP's database (SQLite backup or the app's export), never the live file. Prints aggregates only.

Per local day: synced HR seconds (coverage, so a quiet day is not mistaken for a day without data), and strap-reported
event counts — STRAP_DRIVEN_ALARM_SET (event 56: one per alarm-slot write), BLE connection up/down, BATTERY_LEVEL.
Events are keyed (deviceId, ts, kind) in the store, so live copies and history replays of one event count once.

Battery drain: discharge rate inside a fixed state-of-charge band (default 99 -> 85 %) per charge cycle, because the
percentage is quantized and not linear across the range. A cycle ends at any rise of >= 3 points (charging). An open
band (strap not yet at the bottom) is reported as such, from its newest reading.

`--split` dates divide days into periods (e.g. app changes) and print each period's median daily counts. Medians over
a few days are descriptive: wearer activity, charging and connection time are not controlled, so no saving is claimed.

`--log` reads a `log show --style compact` export of subsystem com.noopapp.noop and counts commands NOOP sent by label
(`→ 5.0 <label> seq=`), connects, and Mac Bluetooth power-offs (an exposure confound, not a NOOP reconnect).

`--counters` reads NOOP's own per-day counter files (a copy of Application Support/OpenWhoop/ops-counters, written by
the app since the #46 counter build): connected hours, connects, Mac Bluetooth power-offs
(builds before R86 also counted every Mac sleep there; later builds count those as `systemSleep`), pulls, frames, received
bytes and every command label, each also per connected hour. They survive log rotation. The newest day is partial.
"""
import glob
import json
import os
import datetime
import re
import sqlite3
import statistics
import sys

DEVICE = "my-whoop"
EVENT_KINDS = {
    "alarm_set": ("STRAP_DRIVEN_ALARM_SET", "EVENT_56"),
    "conn_up": ("BLE_CONNECTION_UP", "EVENT_11"),
    "conn_down": ("BLE_CONNECTION_DOWN", "EVENT_12"),
    "battery_evt": ("BATTERY_LEVEL", "EVENT_3"),
}


def local_day(ts):
    return datetime.date.fromtimestamp(ts)


def daily_table(hr_ts, events):
    """hr_ts: iterable of HR sample unix seconds; events: [(ts, kind)].
    -> {date: {'hr_s': n, 'alarm_set': n, ...}} in local dates."""
    out = {}

    def row(d):
        return out.setdefault(d, {"hr_s": 0, **{k: 0 for k in EVENT_KINDS}})

    for t in hr_ts:
        row(local_day(t))["hr_s"] += 1
    for t, kind in events:
        for name, kinds in EVENT_KINDS.items():
            if kind in kinds:
                row(local_day(t))[name] += 1
    return dict(sorted(out.items()))


def complete_days(table, first_event_ts, min_hr_fraction=0.9):
    """Days with >= min_hr_fraction of 86,400 s of HR (DST days are 82,800/90,000 s; the threshold absorbs that) that
    start after the first stored event: older builds stored no events, and no data must not read as zero events."""
    if first_event_ts is None:
        return {}
    first = local_day(first_event_ts)
    return {d: r for d, r in table.items() if d > first and r["hr_s"] >= min_hr_fraction * 86400}


def period_medians(table, splits):
    """splits: sorted dates; period i = [splits[i-1], splits[i]). -> [(label, n_days, {metric: median})]."""
    edges = [None] + sorted(splits) + [None]
    out = []
    for lo, hi in zip(edges, edges[1:]):
        days = [r for d, r in table.items() if (lo is None or d >= lo) and (hi is None or d < hi)]
        label = f"{lo or '…'} → {hi or '…'}"
        med = {k: statistics.median(r[k] for r in days) for k in EVENT_KINDS} if days else {}
        out.append((label, len(days), med))
    return out


def band_rates(readings, top=99, bottom=85, rise=3):
    """readings: [(ts, soc)] sorted by ts. For each pass through the band after the strap was above `top`: time from the
    first reading <= top to the first <= bottom. A rise of >= `rise` points above the lowest reading since the band
    started (charging) abandons that pass. -> [dict(start, end, hours, drop, rate_per_day, open)]; open = the newest
    pass has not reached `bottom` yet (end = newest reading)."""
    out, armed, a, low = [], False, None, None

    def emit(b, is_open):
        hours = (b[0] - a[0]) / 3600
        if hours > 0:
            drop = a[1] - b[1]
            out.append({"start": a[0], "end": b[0], "hours": hours, "drop": drop,
                        "rate_per_day": drop / hours * 24, "open": is_open})

    for t, s in readings:
        if s > top:
            armed, a = True, None
            continue
        if not armed:
            continue
        if a is None:
            a, low = (t, s), s
        if s >= low + rise:                     # charging before the bottom: not a comparable discharge
            armed, a = False, None
            continue
        low = min(low, s)
        if s <= bottom:
            emit((t, s), False)
            armed, a = False, None
    if armed and a is not None and readings:
        emit(readings[-1], True)
    return out


SEND = re.compile(r"→ 5\.0 (.+?) seq=")


def log_counts(lines):
    """Compact unified-log lines -> (command label counts, connects, bluetooth power-offs, first, last timestamp)."""
    cmds, connects, poweroff, first, last = {}, 0, 0, None, None
    for line in lines:
        m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)", line)
        if not m:
            continue
        first = first or m.group(1)
        last = m.group(1)
        s = SEND.search(line)
        if s:
            cmds[s.group(1)] = cmds.get(s.group(1), 0) + 1
        if "Connected — discovering services" in line:
            connects += 1
        if "Central state: poweredOff" in line:
            poweroff += 1
    return cmds, connects, poweroff, first, last


COUNTER_KEYS = ("connect", "disconnect", "bluetoothOff", "systemSleep", "setupAttempt", "pullStarted", "pullCompleted",
                "pullEndedEarly", "historyFrames", "rxBytes", "batteryReadSkipped", "batteryCharRead")


def load_counter_days(directory):
    """-> [day dict] sorted by day, from `yyyy-MM-dd.json` files; unreadable files are skipped and named."""
    days, bad = [], []
    for path in sorted(glob.glob(os.path.join(directory, "????-??-??.json"))):
        try:
            with open(path, encoding="utf-8") as f:
                d = json.load(f)
            if d.get("day") != os.path.basename(path)[:10]:
                raise ValueError("day does not match file name")
            days.append(d)
        except (OSError, ValueError) as e:
            bad.append(f"{os.path.basename(path)}: {e}")
    return days, bad


def counter_summary(day):
    """One day file -> dict: connected hours, every counter (0 when absent), commands, and per-connected-hour rates
    (None without connected time, so an offline day is not read as zero activity)."""
    hours = day.get("connectedSeconds", 0) / 3600
    counts = {k: day.get("counts", {}).get(k, 0) for k in COUNTER_KEYS}
    cmds = dict(day.get("commands", {}))
    rate = (lambda n: n / hours) if hours > 0 else (lambda n: None)
    apps = day.get("apps") or ([day["app"]] if day.get("app") else [])
    return {"day": day["day"], "apps": apps, "firmware": day.get("firmware", []), "hours": hours,
            "counts": counts, "commands": cmds,
            "per_hour": {**{k: rate(v) for k, v in counts.items()}, **{f"cmd:{k}": rate(v) for k, v in cmds.items()}}}


def print_counters(directory):
    days, bad = load_counter_days(directory)
    print(f"\nNOOP counter files in {directory}: {len(days)} day(s)" + (f", {len(bad)} unreadable" if bad else ""))
    for b in bad:
        print(f"  skipped {b}")
    for i, d in enumerate(days):
        s = counter_summary(d)
        c = s["counts"]
        tag = "  (newest: partial)" if i == len(days) - 1 else ""
        print(f"{s['day']}  app {' | '.join(s['apps']) or '?'}  fw {','.join(s['firmware']) or '?'}  connected {s['hours']:.1f} h  "
              f"connects {c['connect']}  BT off {c['bluetoothOff']}  Mac sleeps {c['systemSleep']}  pulls {c['pullStarted']} "
              f"(complete {c['pullCompleted']}, early {c['pullEndedEarly']})  frames {c['historyFrames']}  "
              f"rx {c['rxBytes'] / 1e6:.2f} MB  level reads skipped {c['batteryReadSkipped']}{tag}")
        for k, v in sorted(s["commands"].items(), key=lambda kv: -kv[1]):
            ph = s["per_hour"][f"cmd:{k}"]
            print(f"    {v:5d}  {k}" + (f"  ({ph:.2f}/connected h)" if ph is not None else ""))


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path, splits, log_path, counters = None, [], None, None
    it = iter(argv[1:])
    for a in it:
        if a == "--split":
            splits.append(datetime.date.fromisoformat(next(it)))
        elif a == "--log":
            log_path = next(it)
        elif a == "--counters":
            counters = next(it)
        elif a.startswith("--"):
            print(f"unknown option {a}")
            return 2
        elif path is None:
            path = a
        else:
            print(f"unexpected argument {a}")
            return 2
    if path is None:
        if counters is None:
            print(__doc__)
            return 2
        print_counters(counters)
        return 0
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    hr = (t for (t,) in db.execute("SELECT ts FROM hrSample WHERE deviceId=?", (DEVICE,)))
    kinds = tuple(k for ks in EVENT_KINDS.values() for k in ks)
    q = f"SELECT ts, kind FROM event WHERE deviceId=? AND kind IN ({','.join('?' * len(kinds))})"
    events = db.execute(q, (DEVICE, *kinds)).fetchall()
    table = daily_table(hr, events)
    (first_event,) = db.execute("SELECT MIN(ts) FROM event WHERE deviceId=?", (DEVICE,)).fetchone()
    full = complete_days(table, first_event)
    print("day         HR%   alarm_set  conn_up  conn_down  battery_evt")
    for d, r in table.items():
        mark = "" if d in full else "  (partial or before events were stored)"
        print(f"{d}  {r['hr_s'] / 864:5.1f}  {r['alarm_set']:9d}  {r['conn_up']:7d}  {r['conn_down']:9d}  "
              f"{r['battery_evt']:11d}{mark}")
    if splits:
        print("\nMedian per complete day, by period:")
        for label, n, med in period_medians(full, splits):
            print(f"  {label}: {n} day(s) " + ", ".join(f"{k} {v:g}" for k, v in med.items()))
    rows = db.execute("SELECT ts, soc FROM battery WHERE deviceId=? AND soc IS NOT NULL ORDER BY ts",
                      (DEVICE,)).fetchall()
    print("\nDischarge 99 → 85 % per pass (charging before 85 % abandons a pass):")
    for r in band_rates(rows):
        a = datetime.datetime.fromtimestamp(r["start"]).strftime("%m-%d %H:%M")
        b = datetime.datetime.fromtimestamp(r["end"]).strftime("%m-%d %H:%M")
        tag = " (open: bottom not reached)" if r["open"] else ""
        print(f"  {a} → {b}: {r['drop']:.0f} pts in {r['hours']:.1f} h = {r['rate_per_day']:.1f} %/day{tag}")
    if log_path:
        with open(log_path, encoding="utf-8", errors="replace") as f:
            cmds, connects, poweroff, first, last = log_counts(f)
        print(f"\nUnified log {first} → {last}: {connects} connects, {poweroff} Mac Bluetooth power-offs")
        for k, v in sorted(cmds.items(), key=lambda kv: -kv[1]):
            print(f"  {v:5d}  {k}")
    if counters:
        print_counters(counters)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

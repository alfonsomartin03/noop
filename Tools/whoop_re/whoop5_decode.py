#!/usr/bin/env python3
"""Standalone WHOOP 5.0 frame decoder for saved captures (no device, no dependencies).

    python3 Tools/whoop_re/whoop5_decode.py CAPTURE.jsonl [...]     # per-frame decode + summary
    python3 Tools/whoop_re/whoop5_decode.py --hex AA01...           # decode one frame
    python3 Tools/whoop_re/whoop5_decode.py --stream FRAGHEX ...    # reassemble fragments, then decode

Reads the JSONL written by NOOP's manual history pull ({"ch","type","len","hex"}) and by
Tools/ble_probe ({"kind":"frame","dir","ch","hex",...}). Only fields marked CONFIRMED or SUPPORTED in
docs/reverse-engineering/PACKET_TYPES.md are decoded; everything else is reported as raw bytes.
"""
import json
import re
import struct
import sys
import zlib
from collections import Counter

PACKET_TYPES = {
    35: "COMMAND", 36: "COMMAND_RESPONSE", 37: "PUFFIN_COMMAND", 38: "PUFFIN_COMMAND_RESPONSE",
    40: "REALTIME_DATA", 43: "REALTIME_RAW_DATA", 47: "HISTORICAL_DATA", 48: "EVENT", 49: "METADATA",
    50: "CONSOLE_LOGS", 51: "REALTIME_IMU_DATA_STREAM", 52: "HISTORICAL_IMU_DATA_STREAM",
    53: "RELATIVE_PUFFIN_EVENTS", 54: "PUFFIN_EVENTS_FROM_STRAP", 55: "RELATIVE_BATTERY_PACK_CONSOLE_LOGS",
    56: "PUFFIN_METADATA",
}
RESULT_CODES = {0: "FAILURE", 1: "SUCCESS", 2: "PENDING", 3: "UNSUPPORTED"}  # names from Goose; 1/2/3 seen on device
META_KINDS = {1: "HISTORY_START", 2: "HISTORY_END", 3: "HISTORY_COMPLETE"}
COMMANDS = {
    1: "LINK_VALID", 2: "GET_MAX_PROTOCOL_VERSION", 3: "TOGGLE_REALTIME_HR", 7: "REPORT_VERSION_INFO",
    10: "SET_CLOCK", 11: "GET_CLOCK", 14: "TOGGLE_GENERIC_HR_PROFILE", 22: "SEND_HISTORICAL_DATA",
    23: "HISTORICAL_DATA_RESULT", 26: "GET_BATTERY_LEVEL", 34: "GET_DATA_RANGE", 63: "SEND_R10_R11_REALTIME",
    80: "GET_ALL_HAPTICS_PATTERN", 84: "GET_BODY_LOCATION_AND_STATUS", 98: "GET_EXTENDED_BATTERY_INFO",
    141: "GET_ADVERTISING_NAME", 145: "GET_HELLO", 151: "GET_BATTERY_PACK_INFO",
}
EVENTS = {
    3: "BATTERY_LEVEL", 7: "CHARGING_ON", 8: "CHARGING_OFF", 9: "WRIST_ON", 10: "WRIST_OFF",
    11: "BLE_CONNECTION_UP", 12: "BLE_CONNECTION_DOWN", 13: "RTC_LOST", 29: "STRAP_CONDITION_REPORT",
    14: "DOUBLE_TAP", 23: "BLE_BONDED", 24: "BLE_HR_PROFILE_ENABLED", 25: "BLE_HR_PROFILE_DISABLED",
    33: "BLE_REALTIME_HR_ON", 34: "BLE_REALTIME_HR_OFF", 56: "STRAP_DRIVEN_ALARM_SET",
    57: "STRAP_DRIVEN_ALARM_EXECUTED", 58: "APP_DRIVEN_ALARM_EXECUTED", 59: "STRAP_DRIVEN_ALARM_DISABLED",
    60: "HAPTICS_FIRED", 63: "EXTENDED_BATTERY_INFORMATION", 96: "HIGH_FREQ_SYNC_PROMPT",
    97: "HIGH_FREQ_SYNC_ENABLED", 98: "HIGH_FREQ_SYNC_DISABLED", 100: "HAPTICS_TERMINATED",
}
ADDR_RE = re.compile(r"[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}")
MAX_FRAME = 16 * 1024


def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def build_frame(record: bytes) -> bytes:
    """Wrap an inner record ([type][seq][cmd][data]) exactly like buildWhoop5Frame in Framing.swift."""
    padded = record + b"\x00" * (-len(record) % 4)
    head = bytes([0xAA, 0x01]) + struct.pack("<H", len(padded) + 4) + bytes([0x00, 0x01])
    return head + struct.pack("<H", crc16_modbus(head)) + padded + struct.pack("<I", crc32(padded))


class FrameError(ValueError):
    pass


def check(frame: bytes) -> dict:
    """Validate the envelope. Raises FrameError for anything that is not a complete frame."""
    if len(frame) < 12:
        raise FrameError(f"too short ({len(frame)} bytes, minimum 12)")
    if frame[0] != 0xAA:
        raise FrameError(f"bad start-of-frame 0x{frame[0]:02x}")
    declared = struct.unpack_from("<H", frame, 2)[0]
    if declared < 4:
        raise FrameError(f"declared length {declared} < 4")
    total = declared + 8
    if len(frame) < total:
        raise FrameError(f"truncated: have {len(frame)} of {total} bytes")
    if len(frame) > total:
        raise FrameError(f"{len(frame) - total} trailing bytes after a {total}-byte frame")
    hdr_ok = crc16_modbus(frame[:6]) == struct.unpack_from("<H", frame, 6)[0]
    payload = frame[8:total - 4]
    crc_ok = crc32(payload) == struct.unpack_from("<I", frame, total - 4)[0]
    return {"format": frame[1], "header45": frame[4:6].hex(), "declared": declared,
            "hdr_crc_ok": hdr_ok, "crc32_ok": crc_ok, "payload": payload}


class Reassembler:
    """Per-characteristic byte stream → whole frames (mirrors Reassembler(family: .whoop5))."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, fragment: bytes):
        self.buf += fragment
        out = []
        while True:
            sof = self.buf.find(0xAA)
            if sof < 0:
                self.buf.clear()
                return out
            del self.buf[:sof]
            if len(self.buf) < 4:
                return out
            total = struct.unpack_from("<H", self.buf, 2)[0] + 8
            if total > MAX_FRAME:
                del self.buf[0]
                continue
            if len(self.buf) < total:
                return out
            out.append(bytes(self.buf[:total]))
            del self.buf[:total]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def decode(frame: bytes, redact: bool = True) -> dict:
    env = check(frame)
    p = env.pop("payload")
    d = {"len": len(frame), **env}
    if not p:
        return d
    t = p[0]
    d["type"] = t
    d["type_name"] = PACKET_TYPES.get(t, f"type{t}")
    if t in (35, 37) and len(p) >= 3:
        d.update(seq=p[1], cmd=p[2], cmd_name=COMMANDS.get(p[2], f"cmd{p[2]}"), data=p[3:].hex())
    elif t in (36, 38) and len(p) >= 5:
        # [type][seq][cmd echo][origin seq][result][body…] — CONFIRMED on device (cmd/seq echo, result codes 1/2/3)
        cmd, body = p[2], p[5:]
        d.update(seq=p[1], cmd=cmd, cmd_name=COMMANDS.get(cmd, f"cmd{cmd}"), origin_seq=p[3],
                 result=p[4], result_name=RESULT_CODES.get(p[4], f"RESULT_{p[4]}"), body_len=len(body))
        if redact and cmd in (145, 141, 76):
            d["body"] = "<redacted>"
        else:
            d["body"] = body.hex()
            if cmd == 11 and p[4] == 1 and len(body) >= 8:
                # CONFIRMED E02: unix seconds u32 + subseconds u32 (1/32768 s, per Goose)
                d.update(clock_unix=u32(body, 0), clock_subsec=u32(body, 4))
            if cmd == 26 and p[4] == 1 and len(body) >= 1:
                d["battery_pct"] = body[0]   # CONFIRMED E02: equals standard 0x2A19
            if cmd == 1 and p[4] == 1:
                d["text"] = body.rstrip(b"\x00").decode("latin-1")
            if cmd == 34 and p[4] == 1 and len(body) >= 25:
                # body[0] revision; u32 words at 1,5,9,13,17,21 (Goose); see PACKET_TYPES.md for what is confirmed
                d["range_words"] = [u32(body, o) for o in range(1, 25, 4)]
                if len(body) >= 65:
                    d["range_times"] = {f"body+{o}": u32(body, o) for o in (33, 41, 49, 57)}
    elif t == 48 and len(p) >= 12:
        # [48][seq][event u16][unix u32][subsec u16][body_len u16][body…] — body_len checked on every capture
        ev, sub, blen = struct.unpack_from("<H", p, 2)[0], struct.unpack_from("<H", p, 8)[0], struct.unpack_from("<H", p, 10)[0]
        d.update(seq=p[1], event=ev, event_name=EVENTS.get(ev, f"event{ev}"), event_ts=u32(p, 4),
                 event_subsec=sub, body_len=blen, body=p[12:12 + blen].hex(),
                 body_len_ok=12 + blen <= len(p))
    elif t in (49, 56) and len(p) >= 3:
        kind = p[2] if t == 49 else struct.unpack_from("<H", p, 2)[0]
        d.update(seq=p[1], meta=kind, meta_name=META_KINDS.get(kind, f"meta{kind}"))
        if kind == 2 and len(p) >= 21:
            d.update(meta_unix=u32(p, 3), end_data=p[13:21].hex(), trim_page=u32(p, 13), trim_block=u32(p, 17))
    elif t == 50 and len(p) >= 11:
        text = p[11:].replace(b"\x00", b"").decode("latin-1")
        d.update(seq=struct.unpack_from("<H", p, 1)[0], log_ts=u32(p, 3), text=ADDR_RE.sub("<addr>", text))
    elif t == 40 and len(p) >= 10:
        # CONFIRMED E04: [40][kind 0x02][unix u32][subsec u16][hr u8][rr_count u8][rr u16…]; R-R never non-zero yet
        n = p[9]
        rr = [struct.unpack_from("<H", p, 10 + 2 * i)[0] for i in range(n) if 11 + 2 * i < len(p)]
        d.update(kind=p[1], rt_ts=u32(p, 2), rt_subsec=struct.unpack_from("<H", p, 6)[0], hr=p[8], rr_count=n,
                 rr=[x for x in rr if x], tail=p[10 + 2 * n:].hex())
    elif t == 47 and len(p) >= 20:
        d.update(version=p[1], record_ts=u32(p, 7), hr=p[14], rr_count=p[15])
    else:
        d["raw"] = p.hex()
    return d


def iter_capture(path):
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        h = r.get("hex", "")
        if r.get("kind", "frame") != "frame" or not h or h.startswith("<"):
            continue
        yield r, bytes.fromhex(h)


def summarize(paths):
    types, results, events, metas, bad = Counter(), Counter(), Counter(), Counter(), 0
    for path in paths:
        for rec, frame in iter_capture(path):
            try:
                d = decode(frame)
            except FrameError as e:
                bad += 1
                print(f"MALFORMED {path}: {e}")
                continue
            if not (d["hdr_crc_ok"] and d["crc32_ok"]):
                bad += 1
            types[(rec.get("ch", "?"), d.get("type_name"), d["len"])] += 1
            if "result" in d:
                results[(d["cmd_name"], d["result_name"], d["len"])] += 1
            if "event" in d:
                events[(d["event_name"], d["len"])] += 1
            if "meta" in d:
                metas[(d["meta_name"], d["len"])] += 1
    print("frames by (characteristic, type, length):")
    for k, v in sorted(types.items(), key=str):
        print(f"  {v:6d}  {k}")
    for title, c in (("command results", results), ("events", events), ("metadata", metas)):
        print(f"{title}:")
        for k, v in sorted(c.items(), key=str):
            print(f"  {v:6d}  {k}")
    print(f"frames failing CRC or framing: {bad}")


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    if argv[0] == "--hex":
        for h in argv[1:]:
            print(json.dumps(decode(bytes.fromhex(h)), indent=1))
        return 0
    if argv[0] == "--stream":
        r = Reassembler()
        for h in argv[1:]:
            for f in r.feed(bytes.fromhex(h)):
                print(json.dumps(decode(f)))
        return 0
    verbose = "-v" in argv
    paths = [a for a in argv if a != "-v"]
    if verbose:
        for path in paths:
            for _, frame in iter_capture(path):
                try:
                    print(json.dumps(decode(frame)))
                except FrameError as e:
                    print(json.dumps({"error": str(e)}))
    summarize(paths)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

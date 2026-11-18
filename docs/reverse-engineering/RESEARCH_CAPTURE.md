# Research capture, archives and restore (#38)

What NOOP keeps on this Mac besides the database, and how to back it up, restore and replay it. Paths are inside
the app's sandbox: `~/Library/Containers/com.noopapp.noop/Data/Library/Application Support/OpenWhoop/`.

| Item | What it is | Written when | Backed up by Settings ▸ Data export? |
| --- | --- | --- | --- |
| `whoop.sqlite` (+ `-wal`, `-shm`) | All decoded data, scores, imports | Always | **Yes** (export / restore-by-replacement) |
| `undecoded-history/YYYY-MM-DD.jsonl` | History records NOOP cannot decode (e.g. v0x1a optical), flushed before the chunk is acked | Always, never pruned | No |
| `research-history/YYYY-MM-DD.jsonl` | Complete bytes of every decoded history record, with capture id, fw, hw and strap time | Only while a research capture runs (≤ 7 days / 400 MB) | No |
| `live-rr/YYYY-MM-DD.jsonl` | Live packet-40 frames from streaming sessions that carried R-R | Only for such sessions | No |
| App preferences (`com.noopapp.noop`) | Profile, alarms, settings, capture state | Always | No |

Files are named by **UTC** day. Each line: `t` (Mac receive time), `type`, `version`, `len`, `ts` (strap time),
`capture`, `fw`, `hw`, `hex` (the full frame). Lines from builds before provenance lack `capture`/`fw`/`hw`/`ts`.

## Back up

1. Quit NOOP (or make the DB copy with SQLite's backup, never by copying `whoop.sqlite` alone while it runs):
   `sqlite3 …/OpenWhoop/whoop.sqlite ".backup '/path/whoop-copy.sqlite'"`.
2. Copy the three archive folders as they are (append-only JSONL; safe to copy while NOOP runs).
3. Preferences: `defaults export com.noopapp.noop /path/noop-prefs.plist`.

## Restore

1. Quit NOOP.
2. Database: Settings ▸ Data ▸ restore a backup (replaces the DB, relaunches), or put the copy back as
   `whoop.sqlite` and delete `whoop.sqlite-wal`/`-shm`.
3. Archives: copy the folders back. Appending continues in the same per-day files.
4. Preferences: `defaults import com.noopapp.noop /path/noop-prefs.plist`.

## Check and replay (offline, on copies)

- `python3 -I Tools/whoop_re/research_archive_check.py <archive dir or file> [--db whoop-copy.sqlite]`:
  integrity (CRC, length), provenance, repeats vs distinct same-time frames, records present in the DB with the
  same HR, and replay idempotence (a second insert adds nothing).
- `python3 -I Tools/whoop_re/whoop5_decode.py <file>`: decodes frames (type 47 v0x12 fields, v0x1a optical bursts,
  events, live packets).
- `python3 -I Tools/whoop_re/live_rr_audit.py <live-rr dir> --history whoop-copy.sqlite`: live R-R unit audit.

Replay into the app database is not offered. History is re-derived by the strap's own re-send of unacked chunks,
and the store's ON CONFLICT DO NOTHING makes duplicates harmless.

## Results

A01 (2026-11-18, `EXPERIMENT_LOG.md`): 1,831 captured records, all intact, all present in the DB, replay
idempotent; ordinary sync unaffected.

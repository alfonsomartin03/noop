# NOOP local data model

The schema source of truth is [`Database.swift`](../Packages/WhoopStore/Sources/WhoopStore/Database.swift). `WhoopStore` is the actor-backed GRDB/SQLite access layer. Read the migrations and store APIs before writing queries; this guide is an index, not a second schema definition.

## Location and ownership

[`StorePaths.swift`](../Strand/Collect/StorePaths.swift) resolves `OpenWhoop/whoop.sqlite` under Application Support (within the container for sandboxed builds). SQLite WAL/SHM files may accompany it. Raw history archives and UserDefaults preferences are separate from database tables.

Raw strap records, imported WHOOP records, and NOOP-derived rows have separate identities. Derived rows use `<device>-noop`; display merging does not make imported data part of NOOP's causal baseline. User labels, effort, strength sets, and sleep corrections are source records that rescoring must preserve.

## Tables and APIs

| Data | Tables | Main store files |
| --- | --- | --- |
| Devices and source streams | `device`, `hrSample`, `rrInterval`, `event`, `battery`, `spo2Sample`, `skinTempSample`, `respSample`, `gravitySample` | `StreamStore.swift`, `Reads.swift` |
| Collection bookkeeping | `rawBatch`, `cursors` | `RawOutbox.swift`, `Cursors.swift` |
| Daily/sleep results | `dailyMetric`, `sleepSession` | `MetricsCache.swift`, `DerivedStore.swift` |
| Import/session caches | `journal`, `workout`, `appleDaily` | `JournalWorkoutAppleCache.swift` |
| Generic metric series | `metricSeries` | `MetricSeriesStore.swift` |
| Measurement lineage | `metricProvenance` | `DerivedStore.swift` |
| Cardiovascular load | `loadRecord` | `DerivedStore.swift` |
| User training records | `sessionEffort`, `strengthSet`, `workoutLabel` | `TrainingLogStore.swift` |
| Incremental scoring inputs/state | `dayScoreState` | `DerivedStore.swift` |

Store files are in `Packages/WhoopStore/Sources/WhoopStore/`. Table presence does not imply a visible app feature or a calibrated measurement: Apple Health tables/parsers remain, and decoded raw sensor values must not be presented as validated physiological units without evidence.

Migration v10 preserves within-second R-R sequence. v11 adds metric provenance, v12 load records, v13 training logs, and v14 workout labels plus incremental day state. The current checkout also contains **uncommitted v15 work** adding sleep-session classification fields and `sleepCorrection`; see [SLEEP_SESSIONS.md](SLEEP_SESSIONS.md). Do not describe v15 as deployed merely because it exists locally.

## Change requirements

- Preserve ordered R-R observations and stream deduplication semantics.
- Persist derived results and their scoring state consistently; invalidate on relevant source/configuration changes.
- Add migrations rather than editing ones users may already have applied. Test upgrading an existing database and preserving user-entered records.
- Keep missing, unknown, partial and zero values distinct. Units, source, algorithm and aggregation are part of metric identity.
- Do not remove schema or legacy source rows just because a UI entry point was removed.
- Use copied databases for replay and performance tools: store initialization can migrate them.

Settings → Data provides database backup and replacement restore through `DataBackup`. A restore requires relaunch. It does not merge datasets or back up all UserDefaults preferences. See [privacy](PRIVACY_SECURITY.md) and [analytics](ANALYTICS.md).

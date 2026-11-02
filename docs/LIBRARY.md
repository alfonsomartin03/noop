# NOOP packages

The app depends on five local Swift packages. Their manifests and source declarations are the API reference; tests show supported behavior. The app integration map is in [ARCHITECTURE.md](ARCHITECTURE.md).

| Package | Responsibility | Dependencies |
| --- | --- | --- |
| `WhoopProtocol` | Frame verification/reassembly, device families, packet/stream decoding and bundled protocol schema | No external package |
| `WhoopStore` | SQLite persistence, migrations, queries, source/derived records, training logs and caches | WhoopProtocol, GRDB.swift |
| `StrandAnalytics` | HRV, sleep, recovery, load, workout detection, causal baselines/replay, incremental scoring | WhoopProtocol, WhoopStore |
| `StrandImport` | WHOOP ZIP/CSV and Apple Health XML/ZIP parsing/aggregation | WhoopProtocol, WhoopStore, ZIPFoundation |
| `StrandDesign` | SwiftUI palette, typography, motion, cards, gauges, charts and status components | No external package |

Package manifests declare macOS 13+ and iOS 16+. The application itself is macOS-only; these declarations do not establish tested app support on iOS.

## Integration notes

- `WhoopProtocol` does not open a Bluetooth connection. The app owns transport and feeds packets into decoding.
- `WhoopStore` owns persisted source data and derived caches. Opening a store can apply migrations; tools must use disposable database copies.
- `StrandAnalytics` includes pure numerical routines **and** a store-backed incremental scoring coordinator. Preserve provenance, causal ordering, and invalidation when reusing it.
- `StrandImport` returns parsed models. The current app wires WHOOP import through `WhoopImporter`; retained Apple Health APIs are library functionality, not an app import screen.
- `StrandDesign` supplies shared styling. Prefer its tokens/components over parallel per-screen implementations.

Run package tests using the commands in [BUILD.md](BUILD.md). Review actual declarations before copying an API call; dated research documents may describe earlier signatures or behavior.

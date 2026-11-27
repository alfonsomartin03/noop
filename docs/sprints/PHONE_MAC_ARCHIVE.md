# Sprint: iPhone collector and Mac analysis

**Vision (owner, 2026-11-27).** The iPhone is a collector and a display. It downloads data from the strap, keeps it only until the Mac has it, and shows the scores the Mac sends back. The Mac stores everything, runs the existing analytics and returns the scores. The phone never scores and never keeps a long-term history of raw data.

    Strap → iPhone outbox (temporary) → trusted Mac → WhoopStore → IncrementalScorer
                  ↑            │ deleted after the Mac's receipt          │
                  └──── daily scores and summaries, cached for display ───┘

**Roadmap:** [Sprint 2](DATA_FUNCTIONALITY.md) → [Sprint 3, first round trip](SPRINT_3_PHONE_MAC.md) → this plan. **Planning only:** no iPhone app, sync or phone cleanup exists yet. The shared packages build for iOS (floor iOS 17, 2026-11-27). Current status lives in [AGENTS.md](../../AGENTS.md).

## GitHub tracking

- [Phone + Mac 1 - Collection and local sync](https://github.com/alfonsomartin03/noop/milestone/7): #76–#79
- [Phone + Mac 2 - Phone cleanup, score history and recovery](https://github.com/alfonsomartin03/noop/milestone/8): #80–#81

| Work | Issue |
| --- | --- |
| 1: Feasibility, install and outbox budget | [#76](https://github.com/alfonsomartin03/noop/issues/76) |
| 2: Durable outbox and Mac receipts | [#77](https://github.com/alfonsomartin03/noop/issues/77) |
| 3: iPhone collector and score display | [#78](https://github.com/alfonsomartin03/noop/issues/78) |
| 4: Trusted local sync and handoff | [#79](https://github.com/alfonsomartin03/noop/issues/79) |
| 5: Score history on the phone | [#80](https://github.com/alfonsomartin03/noop/issues/80) |
| 6: Delete phone data after Mac receipt, recovery and release gate | [#81](https://github.com/alfonsomartin03/noop/issues/81) |
| Future: read-only personal API gateways | [#82](https://github.com/alfonsomartin03/noop/issues/82) |

## Constraints

- One strap, one iPhone, one trusted Mac on the same local network. No hosted database, account, subscription or paid service. Installation uses a free Apple ID personal team (apps must be re-signed from the Mac every 7 days; owner choice 2026-11-27).
- The strap pairs with one device. After pairing with the phone, the Mac cannot collect without re-pairing. Never depend on two strap connections.
- Both apps open for reliable sync in the first release. iPhone background collection is an evidence gate, not a promise.
- Mac-only operation stays available for anyone who does not switch to phone collection. Existing Mac history is never touched by the switch.

## What each device keeps

| Data | iPhone | Mac |
| --- | --- | --- |
| Strap history (HR, R–R, temperature, gravity, steps, events) and mandatory undecoded history | Outbox only: kept until the Mac's receipt for that batch, then deleted | Everything, permanently (the archive) |
| Scores, sleep, recovery, strain, vitals, coverage | Cache of what the Mac returned, for display (small) | Computed and stored here only |
| Profile, sleep corrections, workout labels, check-ins | Not stored in the first release | Stays on the Mac |
| Alarms | Not in the first release (the Mac cannot command a strap paired to the phone) | Unavailable in phone mode |
| Research/debug captures | Off | Existing policies |

Rules:
- Never acknowledge strap data the phone could not save. Never delete outbox data without a durable Mac receipt for exactly that batch.
- If the Mac is away, the outbox grows. Show pending size and the last sync time; at low space, pause optional work and say collection is at risk. Never drop data silently.
- Scores shown on the phone carry date, revision, source, coverage and when the Mac computed them. Stale, partial and missing stay distinct from zero.

## Repository map

| Area | Planned work |
| --- | --- |
| `project.yml`, proposed `StrandPhone/` | Separate iOS target; the Mac target and test-host isolation unchanged. |
| `Strand/BLE/`, `Strand/Collect/` | Reuse decoding, persist-before-ack and command safeguards on the phone; add a phone lifecycle adapter and a Mac companion mode (no scanning, reconnects, clock or alarm writes). |
| `Packages/WhoopProtocol/` | Reused as is. |
| `Packages/WhoopStore/` | Phone outbox (batch identity, sequence, digest, receipt state); Mac receipt table; a small table for cached returned scores. |
| Proposed `Packages/StrandSync/` | Versioned batch envelopes, receipts, score-summary responses, replaceable transport for tests. |
| `Strand/Data/`, `Packages/StrandAnalytics/` | Unchanged scoring on the Mac; a summary builder for what the phone displays. |
| `Packages/StrandDesign/` | Reused for the phone screens. |

## Ordered work packages

### 1. Feasibility, install and outbox budget (#76)

- ~~Build the shared packages for iOS~~ (done 2026-11-27).
- Add a minimal iOS target (*done 2026-11-27: `StrandPhone`, runs in the simulator*) and install it on the owner's iPhone with a free personal team; record the 7-day re-signing and any capability limits (Bluetooth, local network).
- Measure outbox growth per day by data class on a SQLite-backup copy, including mandatory undecoded history, so we know how long the phone can hold data while the Mac is away.
- Inventory the macOS-only code (AppKit, menu bar, file panels, notifications, CoreBluetooth lifecycle) the phone must replace.
- Test foreground pairing and history download on hardware, plus lock and relaunch. Switching the strap to the phone is an explicit, owner-coordinated step.

Acceptance: working install, measured outbox budget, coupling list, recorded foreground/lock/relaunch behaviour.

**Measured outbox budget (2026-11-27).** One WHOOP 5.0 (fw 50.43.1.0), 7 complete local days 11-20 → 11-26 (≈ 84,000 history records/day, near-full wear), from a SQLite-backup copy and the archive folders. Bytes include each table's unique index.

| Data class | Rows/day | MB/day stored as rows |
| --- | --- | --- |
| Gravity (x, y, z) | 84,185 | 6.3 |
| Skin temperature | 84,346 | 5.5 |
| Heart rate | 84,343 | 4.2 |
| R–R intervals | 42,998 | 2.4 |
| Step counter + activity | 7,207 | 0.4 |
| Events, battery, alarm events | ~1,900 | 0.2 |
| **Decoded rows, total** | | **18.9** |
| Mandatory undecoded history (JSONL) | ~2,900 lines | 0.9 (0.2 compressed) |

The same day as raw history frames (124 bytes each) is 10.6 MB, or 3.5 MB compressed (zlib level 6).

What this means for the phone:

| Mac away for | Decoded rows + undecoded | Raw frames + undecoded |
| --- | --- | --- |
| 1 day | ~20 MB | ~11.5 MB |
| 7 days | ~140 MB | ~80 MB |
| 30 days | ~600 MB | ~350 MB |
| 90 days | ~1.8 GB | ~1.0 GB |

- Any modern iPhone can hold weeks of outbox; the budget is not a blocker. With daily syncs the outbox stays around one day (~20 MB) plus the batch in flight.
- A compressed daily transfer is ~3.5–4 MB, small for a local network.
- Design option for #77, not decided: keep the outbox as raw frames (about half the size, and the Mac re-decodes with its own decoder) rather than decoded rows. Persist-before-ack still applies either way.
- Not measured: WAL and temporary-transfer peaks on the phone, iOS file-system overhead, research capture (off on the phone; ~34 MB/day as JSONL on the Mac).

**macOS-only code inventory (2026-11-27).** Found by searching `Strand/` for AppKit, notification, file-panel and window APIs, then compiling `Strand/BLE` + `Strand/Collect` into a temporary copy of the `StrandPhone` target for the iOS Simulator (reverted afterwards).

*Collection path, reusable on the phone.* `Strand/BLE` and `Strand/Collect` compile for iOS except for three references:

| Blocker | Where | Fix when extracting |
| --- | --- | --- |
| `AlarmStrapLink`, `AlarmStrapCommand` | defined in `Strand/Alarm/AlarmController.swift` (imports AppKit), used by `BLEManager` | Move the two types into their own file under `Strand/BLE`, or leave the alarm link out of the phone build |
| `TodayDetail` | `StorePaths.fixtureDetail` (fixture launch option) | Move the fixture options next to the screens, or compile them only on macOS |

Compiling is not the same as working: on iOS the collector still needs a phone lifecycle (foreground only at first; suspension, relaunch and CoreBluetooth state restoration are untested), and the liveness/reconnect timers assume a Mac that stays running. `PowerOffClassifier`'s Mac-sleep classification has no phone meaning.

*Mac shell, to be replaced or left out on the phone.*

| Code | macOS dependency | On the phone |
| --- | --- | --- |
| `StrandApp.swift` (`AppEntry`), `ContentView.swift` | `NSApplication`, `NSApp`, `NSAppearance`, window and menu-bar scenes, commands | New `StrandPhone` entry (exists) |
| `AppModel.swift` | `NSWorkspace.open`; owns scoring, imports, alarms | New, smaller phone model: collector + outbox + sync + score cache |
| `RootView.swift` | `NSEvent` outside-click monitor, `NSHapticFeedbackManager`, `NSViewRepresentable`, hover/keyboard shortcuts | New phone screens; StrandDesign components reused |
| `MenuBar/MenuBarContent.swift` | `MenuBarExtra` | None |
| `Alarm/AlarmController.swift` | `NSWorkspace` sleep/wake notifications, UserNotifications | Not in the first release |
| `Data/DataBackup.swift`, `Screens/DataSourcesView.swift` | `NSOpenPanel`/`NSSavePanel`, file importer | None (backup and import stay on the Mac) |
| `Device/BatteryMonitor.swift`, `Data/CheckInSettings.swift` | UserNotifications (exists on iOS) | Battery alerts optional later; check-ins stay on the Mac |
| `Data/Repository.swift`, `IntelligenceEngine.swift`, `Profile.swift`, all of `Strand/Screens` | SwiftUI with Mac-only modifiers in places (hover, help, context menus, keyboard) | Stay on the Mac; scoring and history are the Mac's job |

The shared packages (WhoopProtocol, WhoopStore, StrandAnalytics, StrandImport, StrandDesign) already build for iOS (PR #92). The phone needs WhoopProtocol, WhoopStore and StrandDesign. It doesn't need StrandAnalytics or StrandImport.

### 2. Durable outbox and Mac receipts (#77)

- Phone: stable source identity, monotonic batch sequence, batch ID and digest. Save every collected record and mandatory undecoded history before acknowledging the strap.
- Mac: archive the batch (raw payloads first, then observations) and the receipt in one transaction; reply only after commit. Replays are idempotent, including same-second R–R and late history.
- Receipts are bound to the Mac's archive identity and generation, so a restored or replaced Mac cannot confirm data it no longer has.

Acceptance: tests for lost replies, duplicates, out-of-order and late batches, interrupted transactions, disk full, incompatible versions and archive-generation changes. Phone deletion stays disabled.

*2026-11-27, Mac side done:* the outbox holds decoded rows (owner choice). `StrandSync` defines the versioned, digested envelope and `MacArchiveIngestor`; `WhoopStore` v20 stores receipts with the archive identity and writes rows + receipt in one transaction. Covered by tests: lost reply, replay, digest mismatch, taken sequence, rollback before the receipt, raw-archive failure, out-of-order/late batches, version refusal, generation bump. *Phone side done the same day:* `OutboxStore` (v21) claims row ranges into numbered batches (sequence persisted, rebuilt identically after a crash) and `PhoneOutbox` sends pending batches oldest first and keeps each until a matching receipt; batches carry R–R within-second positions. Tested end to end over an in-memory transport (lost reply, Mac unreachable, foreign receipt, crash after cut). Left for #77: disk-full on the phone and wiring collection into the outbox (with #78); the network transport is #79.

### 3. iPhone collector and score display (#78)

- Phone screens: connection and collection status, pending outbox (count and size), last sync, and the latest daily scores returned by the Mac.
- Mac companion mode: no strap activity; keeps all current screens with "last received" status.
- No scoring, alarms or profile editing on the phone.

Acceptance: collect with the Mac offline; reopen both apps; scores appear after sync; stale, partial and missing states are correct after relaunch.

### 4. Trusted local sync and handoff (#79)

- Native local-network transport, pairing confirmed with a code, trust in Keychain, unknown peers rejected; no unauthenticated health-data endpoint. Works without internet.
- Handoff: back up the Mac archive, switch the Mac to companion mode, then pair the strap with the phone. Reconcile any overlap with old Mac history.
- After each upload the Mac scores affected days and returns revisioned daily summaries.

Acceptance: pairing, wrong/revoked peer, denied local-network permission, interrupted upload and retry; new data appears once on the Mac; returned scores match the Mac's own screens.

### 5. Score history on the phone (#80)

- Cache every daily summary the Mac returns, so past scores can be browsed on the phone offline. Summaries only: no raw data, charts or detail downloads.
- When the Mac re-scores a day (late data, correction, algorithm change), it sends the new revision; the phone replaces the old one and shows when it changed.

Acceptance: months of scores browse offline; a late batch updates the right day without duplicates; DST and time-zone boundaries correct; cache size measured.

### 6. Delete phone data after Mac receipt, recovery and release gate (#81)

- Turn on deletion: remove an outbox batch only after its durable, generation-matched receipt, in small recoverable transactions; reclaim disk space (WAL included) without disrupting collection.
- Show phone storage, pending bytes and last archive sync. Encourage a local Mac backup, since the Mac then holds the only copy.
- On a restored Mac archive (new generation), re-send anything still on the phone and report ranges lost on both devices.
- Document phone replacement, Mac replacement, trust reset and returning to Mac collection (needs re-pairing).

Acceptance: crash before/after commit, receipt and deletion; full disks; long Mac absence; restored older archive; phone reinstall. Demonstrate collect → upload → receipt → delete → scores still shown, on copies first.

## Future extension: personal API gateways

The owner may later build API gateways so other apps can pull NOOP data. Preserve that option in this sprint without shipping a gateway, exposing an internet endpoint, or adding a hosted database. The Mac archive is the natural initial data source; it must be running and reachable to serve requests. A future remote-access design is separate work and must retain the owner's cost constraints.

- Define transport-independent, versioned read interfaces for daily summaries, sleep, workouts, and bounded measurement ranges. Share domain query logic between the app, sync detail retrieval and future adapters; keep external contracts independent of SQLite table layout and internal replication envelopes.
- Return stable IDs, revisions, units, timestamps/time-zone context, provenance, algorithm versions, coverage and available detail level. Support bounded pagination and incremental reads with explicit cursor expiry/reset semantics. Consumers must be able to distinguish unavailable data from an empty result and process corrections/deletions.
- Start future integrations read-only with explicit per-client, revocable access scoped by data category. An API client cannot acknowledge archival receipt, permit phone cleanup, change strap ownership or send strap commands. Sync-peer trust does not automatically grant third-party access.
- Keep access opt-in and credentials out of logs. Decide loopback versus authenticated local-network access when implementing the adapter; internet exposure and writes require their own design. Document that data pulled into another app is then subject to that app's storage and privacy behavior.
- Avoid tying journal retention to an external consumer indefinitely. A slow consumer gets an explicit resnapshot path; it must not grow the phone outbox or block phone cleanup. Add bounded query work so bulk reads do not starve collection or sync.

Within this sprint, package 2 defines reusable record/read contracts and package 5 uses them for the summaries sent to the phone. A later gateway sprint can add an HTTP/JSON adapter and contract tests without replacing the database or collection pipeline. Do not build speculative endpoints or another general-purpose framework now.

## Delivery and verification

Small PRs in package order. Packages 1–4 are the first release (deletion off); 5–6 complete it. For each implementation PR update AGENTS §§3/5/7/8/9, run affected package and hosted tests, build both targets, and record real results. Sync tests use fake transports and temporary databases; deletion and recovery need fault-injection tests. Never use the live health database as a fixture.

Done means: no paid service; owner-accepted install; Mac does no strap activity in phone mode; old history intact; phone data deleted only after verified receipt; scores from the Mac shown on the phone, offline included; measured phone storage; documented hardware and lifecycle limits.

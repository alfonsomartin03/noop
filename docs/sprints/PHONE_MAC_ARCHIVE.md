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
- Add a minimal iOS target and install it on the owner's iPhone with a free personal team; record the 7-day re-signing and any capability limits (Bluetooth, local network).
- Measure outbox growth per day by data class on a SQLite-backup copy, including mandatory undecoded history, so we know how long the phone can hold data while the Mac is away.
- Inventory the macOS-only code (AppKit, menu bar, file panels, notifications, CoreBluetooth lifecycle) the phone must replace.
- Test foreground pairing and history download on hardware, plus lock and relaunch. Switching the strap to the phone is an explicit, owner-coordinated step.

Acceptance: working install, measured outbox budget, coupling list, recorded foreground/lock/relaunch behaviour.

### 2. Durable outbox and Mac receipts (#77)

- Phone: stable source identity, monotonic batch sequence, batch ID and digest. Save every collected record and mandatory undecoded history before acknowledging the strap.
- Mac: archive the batch (raw payloads first, then observations) and the receipt in one transaction; reply only after commit. Replays are idempotent, including same-second R–R and late history.
- Receipts are bound to the Mac's archive identity and generation, so a restored or replaced Mac cannot confirm data it no longer has.

Acceptance: tests for lost replies, duplicates, out-of-order and late batches, interrupted transactions, disk full, incompatible versions and archive-generation changes. Phone deletion stays disabled.

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

# Sprint: iPhone collection and local Mac archive

**November 26 roadmap.** [Sprint 2, acquisition evidence and data features](DATA_FUNCTIONALITY.md) → [Sprint 3, iPhone collection and Mac analysis](SPRINT_3_PHONE_MAC.md). Sprint 3 supersedes the earlier phone-scoring proposal for the first release.

Created November 21, 2026. **Planning only: no iPhone app, device sync, or pruning is implemented.** Current implementation and verification status remain in [AGENTS.md](../../AGENTS.md). This is an ordered delivery plan, not a time estimate; feasibility gates determine the final scope.

## GitHub tracking

- [Phone + Mac 1 - Collection and local sync](https://github.com/alfonsomartin03/noop/milestone/7)
- [Phone + Mac 2 - Compact history and safe archival](https://github.com/alfonsomartin03/noop/milestone/8)

| Work | Issue |
| --- | --- |
| Phone + Mac 1: Feasibility and storage budget | [#76](https://github.com/alfonsomartin03/noop/issues/76) |
| Phone + Mac 2: Sync model and durable transfer engine | [#77](https://github.com/alfonsomartin03/noop/issues/77) |
| Phone + Mac 3: iPhone collector and scoring | [#78](https://github.com/alfonsomartin03/noop/issues/78) |
| Phone + Mac 4: Trusted local-network sync and initial handoff | [#79](https://github.com/alfonsomartin03/noop/issues/79) |
| Phone + Mac 5: Compact history and on-demand detail | [#80](https://github.com/alfonsomartin03/noop/issues/80) |
| Phone + Mac 6: Safe pruning, recovery and release gate | [#81](https://github.com/alfonsomartin03/noop/issues/81) |
| Future: read-only personal API gateways for NOOP data | [#82](https://github.com/alfonsomartin03/noop/issues/82) |

Issues #76–#79 belong to milestone 7; #80–#81 to milestone 8. #82 is unscheduled future backlog. Dependencies and acceptance requirements are included in each issue; no due dates or assignees are presumed.

## Outcome and constraints

Pair the strap to the iPhone once. Collect and score on the phone, archive full detail on the Mac, and browse years of compact history on either device. Use direct local-network transfers with no hosted database, account, subscription, or paid infrastructure. Treat the owner's reported pairing behavior as a requirement: the Mac cannot collect from the strap after phone pairing without re-pairing it. Do not depend on simultaneous strap connections.

There are two independent SQLite stores and one logical history, not a shared SQLite file. The phone owns new collection and user edits; the Mac owns the complete historical archive. Existing Mac history stays intact. Mac-only operation remains available for users who have not switched to phone collection.

First release: one phone, one trusted Mac, both apps open for reliable local sync. No remote internet access, relay, automatic switching of strap ownership, or concurrent editing on both devices. iPhone background collection and smart wake are separate evidence gates, not promised capabilities. Verify a no-additional-cost personal installation workflow before committing to the rollout; record provisioning, renewal, and capability constraints from current Apple documentation and an actual device trial. If acceptable installation is not possible under the owner's cost constraint, stop rollout and report the tradeoff without purchasing anything.

## Storage and ownership contract

| Record | Phone | Mac | Writer |
| --- | --- | --- | --- |
| Detailed HR, R–R, temperature, gravity, steps, events | Initially retain 30 days, plus unarchived data and scoring dependencies | All received records | Phone after handoff; existing Mac history preserved |
| Daily scores, vitals, coverage, provenance, sleep/workout summaries | All history | All history | Phone for current scoring; revision-checked Mac recomputation for archived dates |
| Genuine sleep-stage segments and compact HR charts | All history, measured size budget | Full and compact representations | Versioned derivation from complete inputs |
| Profile, check-ins, sleep corrections, workout labels, alarm configuration | Durable authoritative records | Replicated records | Phone after handoff |
| Requested full-detail days | Bounded evictable cache; optional pinned days | Archive | Mac supplies immutable/revisioned data |
| Research and debug captures | Optional research off by default; bounded diagnostics | Only explicitly retained captures | Existing capture policies until separately reviewed |

Thirty days is a starting target, not permission to delete at day 31. Audit all scoring lookbacks first; retain required inputs or validated sufficient state. Compact charts must preserve gaps, coverage, units, source, time zones and extrema where meaningful, and be labelled as reduced detail. Never feed chart downsampling into scoring or manufacture sleep stages.

Mandatory undecoded-history preservation is separate from optional research capture. `RawHistoryArchive` currently never prunes undecoded records; do not change that guarantee as an incidental storage optimization. Include database, WAL, raw archives, temporary transfers and caches in storage measurements.

Phone eviction requires all of: the exact record revision is durably archived by the trusted Mac; compact history is committed; the interval is outside scoring dependencies and active sessions; no pending edit or transfer needs it. Eviction is local cache management, never a replicated user deletion. Explicit user deletions need a separate versioned tombstone policy so sync cannot resurrect records.

If the Mac is absent, retain unarchived data beyond the target window and show pending bytes. A bounded phone footprint cannot be guaranteed indefinitely while the archive is unavailable. At low space, clear only safe caches, pause optional capture, and surface collection/storage failure; never acknowledge strap data that could not be saved.

## Repository implementation map

| Existing area | Planned work |
| --- | --- |
| `project.yml`, `Strand/App/`, `Strand/Resources/` | Add a separate iOS target and shell; preserve the existing Mac target and test-host isolation. Proposed iOS source directory: `StrandPhone/`. |
| `Strand/BLE/`, `Strand/Collect/` | Extract reusable collection/lifecycle interfaces; retain frame decoding, persist-before-ack and command safeguards. Add phone lifecycle adapters and explicit Mac companion mode. |
| `Packages/WhoopProtocol/` | Reuse device framing and decoding; avoid protocol changes just for platform support. |
| `Packages/WhoopStore/` | Add migrations for stable sync identities, revisions, change journal, archive receipts, availability metadata and compact history. Existing cursors alone are not a sync protocol. |
| Proposed `Packages/StrandSync/` | Typed versioned transfer envelopes, bounded batches, resume/replay, receipt validation, retention policy and transport abstraction. Keep network transport replaceable for tests. |
| `Strand/Data/Repository.swift`, `IntelligenceEngine.swift`, `Packages/StrandAnalytics/` | Read full/compact/remote history explicitly; audit scoring input retention and recomputation ownership. |
| `Strand/Data/Profile.swift`, `CheckInSettings.swift`, `Strand/Alarm/` | Separate portable domain records from device-local preferences, permissions and delivery state. Do not copy all UserDefaults between devices. |
| `Strand/Data/DataBackup.swift`, `Strand/Collect/StorePaths.swift` | Consistent initial transfer and archive recovery; platform-specific storage locations and UI adapters. Existing AppKit backup UI is not an iOS transfer implementation. |
| `Strand/Screens/`, `Packages/StrandDesign/` | Reuse suitable components; add phone history and storage status, Mac archive status, and offline detail states. |

Proposed paths above do not exist yet. Package platform declarations alone do not establish iOS compatibility.

## Ordered work packages

### 1. Feasibility and storage budget

- Build existing shared packages for iOS; inventory AppKit, notification, Bluetooth, file-access and lifecycle coupling before extraction.
- Validate personal device installation under the no-extra-cost requirement. Document actual maintenance needed, not a promise of permanent free installation.
- Measure bytes per day by data class using synthetic fixtures and, only when available, a SQLite-backup copy of representative data. Estimate 30 days of detail, one year of compact history, transfer peak space and archive growth; record measurements without private health content.
- Audit analytics lookbacks, late-arriving records, cross-midnight sleep, corrections and version rescoring. Decide the minimum safe retention window and baseline state.
- Test phone pairing, foreground history collection, lock/background/relaunch recovery and alarm feasibility on supported hardware, following the research safety documents. Make any actual strap ownership switch an explicit user-coordinated step; this planning task does not switch it.

Acceptance: measured storage budget, dependency map, viable installation workflow, and documented foreground/background limitations. If a gate fails, revise scope before migrating the user's collection.

### 2. Sync model and durable transfer engine

- Define stable dataset/device identities; migrate the current `my-whoop`/`my-whoop-noop` identity assumptions without merging unrelated devices. Define deduplication keys per table, preserving legitimate equal-timestamp samples and R–R sequence identity.
- Add a transactionally written monotonic change journal. Do not use sample timestamps as the sole transfer cursor: late inserts, corrections and imports must transfer too.
- Define version negotiation and bounded envelopes with dataset, batch ID, sequence range, record revisions, count and digest. Reject incompatible versions before writes or pruning.
- Apply records, receipt and checkpoint in one Mac transaction. Return an acknowledgement only after durable commit; replay after a lost acknowledgement must be idempotent. Keep phone-to-Mac receipts separate from strap history acknowledgements.
- Persist the phone receipt before pruning. Bind it to the trusted archive identity and archive generation, so a restored or replaced Mac cannot silently reuse stale checkpoints.
- Model profile/correction revisions and deletion tombstones. Mac recomputation includes algorithm and input revisions; a stale result cannot overwrite newer phone edits or scores.

Acceptance: deterministic tests cover duplicate/out-of-order batches, late records, interrupted transactions, lost acknowledgements, corruption, disk full, schema mismatch, deletion versus eviction, and archive-generation changes. Keep pruning disabled.

### 3. iPhone collector and scoring

- Add the iOS target and extract only the reusable code needed for collection, local storage and scoring. Build both apps throughout the extraction.
- Provide phone onboarding, connection status, Overview/history, essential profile/edit controls and explicit retry after interruption.
- Persist collection independently of whether the Mac is online. Retain existing safe handling for undecodable history and failed writes.
- Introduce an explicit Mac companion mode that stops strap scanning, reconnect attempts, stream ownership, clock writes and alarm writes; retain historical displays with last-updated status.
- Phone owns strap alarm configuration after handoff. Do not carry Mac delivery timers into iOS and assume they work while suspended. Gate smart wake separately; do not advertise it until tested under real phone lifecycle conditions.

Acceptance: synthetic ingestion and scoring match the Mac for identical complete inputs; Mac tests still pass; phone foreground collection is demonstrated on hardware. Background and alarm results are recorded separately.

### 4. Trusted local-network sync and initial handoff

- Start with a native local-network transport (evaluate Network.framework/Bonjour in the feasibility work), explicit pairing and encrypted authenticated connections. Confirm peer identity with a code/QR flow, store trust in Keychain, support revocation, and reject unknown peers.
- Add only the required platform permissions, usage descriptions and Mac network entitlements. Discovery must not advertise health data; logs remain redacted. No open unauthenticated health-data endpoint.
- Transfer old Mac summaries, compact charts, portable profile/edit records and the recent scoring inputs needed by the phone. Leave the bulk archive on the Mac. Transfer in chunks rather than copying the complete archive onto the phone.
- Use a consistent snapshot plus a journal boundary for initial migration; validate totals/digests and provenance before handoff. Use SQLite backup facilities or a supported consistent snapshot, not an arbitrary live DB/WAL file copy.
- Preserve the old Mac database and verified backup. Record handoff boundary and reconcile overlap if the phone has already collected records. Switch the Mac into companion mode before phone collection becomes authoritative.

Acceptance: two-device pairing, interrupted initial migration/resume, denied local-network permission, wrong peer and revoked peer checks; old history remains intact and new data appears once on the Mac. Local sync works with internet access unavailable. Neither pruning nor re-pairing back to the Mac is automatic.

### 5. Compact history and on-demand detail

- Generate versioned daily summaries, genuine stage segments and gap-aware compact charts from complete data. Store coverage and input/algorithm revision with them.
- Serve requested date intervals from the Mac using the same authenticated transport; support cancellation, range limits and integrity checking.
- Add bounded cache eviction and explicit pinned-day controls. Show full detail, compact detail, download in progress, Mac unavailable, and archive missing as distinct states.
- Keep current-day scoring on the phone. For old corrections or algorithm changes requiring pruned inputs, queue Mac recomputation; retain the previous labelled result until updated inputs are available. Never recompute a misleading score from an incomplete compact view.

Acceptance: years of summary browsing works offline; old full detail loads when the Mac is reachable; missing/stale data is explicit. Verify DST, travel/time-zone boundaries, cross-day sessions and source separation. Measure actual storage against package 1's budget.

### 6. Safe pruning, recovery and release gate

- Enable pruning only after transfer and compact-history checks pass. Use small recoverable transactions and recheck revision/receipt eligibility at deletion time.
- Bound temporary downloads and caches; distinguish archive backlog from downloaded detail. Confirm physical disk reuse/reclamation, including WAL behavior, without disruptive full-database maintenance during collection.
- Show last archive sync, pending bytes, phone usage, retention target and pinned usage. Explain that overdue archive transfers extend phone retention.
- Verify archive backup and restore independently of sync. Once phone detail is evicted, the Mac may hold the sole full-detail copy; encourage an existing local backup destination without requiring a paid service.
- On archive restore, change its generation, reconcile manifests and re-send any detail still on the phone. Surface ranges lost from both devices; never describe an older backup as complete.
- Document phone replacement, Mac replacement, trust reset and explicit return to Mac collection. Returning requires re-pairing and reconciliation; neither device assumes ownership because the other is offline.

Acceptance: test crashes before/after commit, receipt persistence and pruning; full phone/Mac disk; long offline periods; restored older archive; phone reinstall; and unavailable pinned downloads. Demonstrate a complete collect → archive → evict → offline summary → retrieve detail cycle on copies before enabling retention on real history.

## Future extension: personal API gateways

The owner may later build API gateways so other apps can pull NOOP data. Preserve that option in this sprint without shipping a gateway, exposing an internet endpoint, or adding a hosted database. The Mac archive is the natural initial data source; it must be running and reachable to serve requests. A future remote-access design is separate work and must retain the owner's cost constraints.

- Define transport-independent, versioned read interfaces for daily summaries, sleep, workouts, and bounded measurement ranges. Share domain query logic between the app, sync detail retrieval and future adapters; keep external contracts independent of SQLite table layout and internal replication envelopes.
- Return stable IDs, revisions, units, timestamps/time-zone context, provenance, algorithm versions, coverage and available detail level. Support bounded pagination and incremental reads with explicit cursor expiry/reset semantics. Consumers must be able to distinguish unavailable data from an empty result and process corrections/deletions.
- Start future integrations read-only with explicit per-client, revocable access scoped by data category. An API client cannot acknowledge archival receipt, permit phone pruning, change strap ownership or send strap commands. Sync-peer trust does not automatically grant third-party access.
- Keep access opt-in and credentials out of logs. Decide loopback versus authenticated local-network access when implementing the adapter; internet exposure and writes require their own design. Document that data pulled into another app is then subject to that app's storage and privacy behavior.
- Avoid tying journal retention to an external consumer indefinitely. A slow consumer gets an explicit resnapshot path; it must not grow the phone backlog or block safe archival. Add bounded query work so bulk reads do not starve collection or sync.

Within this sprint, package 2 defines reusable record/read contracts and package 5 uses them for detail retrieval. A later gateway sprint can add an HTTP/JSON adapter and contract tests without replacing the database or collection pipeline. Do not build speculative endpoints or another general-purpose framework now.

## Delivery and verification

Ship the packages in order through small PRs. Package 1 is the first executable slice; packages 2–4 establish a foreground collection/sync MVP with pruning disabled. Packages 5–6 complete the low-storage experience. Do not call the overall sprint complete at the MVP milestone.

For each implementation PR, update AGENTS §§3/5/7/8/9, run affected package and hosted tests, regenerate/build both targets where relevant, and record actual results. Proposed new suites should exercise the sync engine with in-memory/fake transport and temporary databases; retention/recovery needs fault injection and migration tests, not only happy-path UI tests. Never use the live health database as a test fixture.

Final completion requires: no paid runtime service; an owner-accepted installation workflow; Mac collector disabled in phone mode; old history preserved; current scoring available away from the Mac; compact historical browsing offline; full-detail retrieval locally; measured storage reduction; no deletion before verified archiving; and documented hardware/lifecycle limits. iPhone behavior remains unknown until those device checks run.

# Sprint 3 · Collect on iPhone, analyze on Mac

Proposed first release, November 26, 2026. One strap, one iPhone, one trusted Mac on the same local network. Both apps are open during transfer. The phone collects while the Mac is away and displays the last result it received. The Mac owns the historical archive and runs the existing analytics. Start with one round trip that the owner can verify on both screens.

    Strap → iPhone durable inbox → paired Mac → WhoopStore → IncrementalScorer
                  ↑                                |
                  └──── durable receipt + later daily summary ────┘

## Build in this order

| Slice | Work and issue mapping | Acceptance |
| --- | --- | --- |
| 1. Fixture round trip (#76, #77, #79) | Start the receiver explicitly on the Mac. Pair once using a displayed code to verify a pinned peer key. Use one authenticated encrypted LAN connection and a manually entered address. Upload one bounded fixture batch and fetch one daily result. Keep trust in Keychain | With internet disconnected, the paired phone receives the expected dated summary. Denied LAN access and an untrusted peer leave the archive untouched |
| 2. Durable ingestion (#77) | Give the phone a persistent source identity, monotonic collection sequence and batch digest. Store every supported collected record and mandatory undecoded history before acknowledging the strap. On Mac, durably archive associated raw payloads before committing observations and the matching receipt. Bind receipts to dataset, batch and archive generation | Stop either app before commit and after commit but before reply. Retry delivers one logical copy, including same-second R–R and late history. Disk-full or incompatible input leaves the phone batch pending |
| 3. Foreground collector (#76, narrowed #78, #79) | Verify personal iPhone installation and shared package builds. Back up the Mac archive, mark the ownership boundary, disable Mac strap reconnect and writes in companion mode, then coordinate the pairing switch. Keep a local phone outbox and visible pending count | On hardware, collect with Mac offline, reopen both apps, reconnect locally and reconcile overlap with old Mac history. Record family, firmware, lock/relaunch observations and any gaps |
| 4. Daily display (#78, #79) | After Mac commit, score affected days with existing analytics. Phone requests latest daily summary with date, revision, source, units, coverage and computed time. Cache it for offline display. Show collection status, last analysis time and pending sync separately | Compare the returned summary with the Mac for identical fixture inputs. Show missing values, partial activity and stale results correctly. A late batch updates the affected day without duplicating it |

The upload receipt means the Mac has saved the data. Analysis can finish later or retry independently. Keep phone detail throughout the pilot. A restored Mac generation triggers reconciliation. A lost link leaves the existing local history readable on each device.

## Scope and release decision

Sprint 3 narrows the November 21 archive proposal and issue #78 by assigning all scoring to the Mac. Phone scoring, background guarantees, phone alarms, multi-year compact browsing, pruning (#80–81), discovery convenience and third-party access (#82) are outside this first release. The existing plan remains the reference for retention, backup, recovery and later history browsing. [Archive work packages and GitHub links](PHONE_MAC_ARCHIVE.md)

Exit on one demonstrated hardware cycle: collect offline on iPhone, deliver locally after reconnection, analyze on Mac, display the result on iPhone, then disconnect and reopen the cached result. Record transfer counts, retry behavior, ownership handoff and installation constraints without private readings. A simulator round trip establishes protocol behavior only. If personal installation or foreground BLE collection fails, retain the Mac collector and document the exact blocker before switching the owner's strap.

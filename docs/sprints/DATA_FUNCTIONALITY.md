# Sprint 2 · Turn collected data into dependable features

Decision record, November 26, 2026. Deliver a daily activity breakdown with explicit coverage, then decide whether the evidence warrants a steps trend. Sprint 3 can use the coverage breakdown even if the steps gate fails.

## Issue review

The repository tracker returned 34 issues across both states. The numbers below are issue IDs. The experiment log records findings that arrived after the research issues closed. [Issue tracker](https://github.com/alfonsomartin03/noop/issues?q=is%3Aissue) · [Experiment log, T04 and HO1](../reverse-engineering/EXPERIMENT_LOG.md)

| State and issues | Delivered or decided | Remaining work |
| --- | --- | --- |
| Closed #1–5, #15, #26 | Charging, alarm delivery and skip, Overview coverage, HR zones and workout boundaries | Reuse existing presentations and gap rules |
| Closed #12–14, #16–19, #48 | Check-ins, highlights, Health, HRV interpretation, Trends, nap evidence and date-stable trend tests | #49 carries the functional-age follow-up |
| Closed #25, #38–43 | Durable capture, live R–R units, named configuration reads, charging, steps and wear evidence | Counted steps, charger transitions and post-removal rewarming |
| Closed #44–47 | Motion inventory, optical feasibility, operational counters and firmware decision | Passive follow-ups below. Firmware work remains closed |
| Open #49 | Functional age ships experimentally. Its pace projection lost to a no-change baseline | In-app real-input and VoiceOver checks, NOOP-source replay at 180 days, steps subject to validation |
| Open #76–79 | Feasibility, durable transfer, phone collection and trusted local sync are planned | Deliver the smaller Mac-scored path in Sprint 3 |
| Open #80–82 | Compact history, safe pruning and an optional read API | Schedule after two-device transfer works. #82 remains future backlog |

## From strap to screen today

The Mac selects 4.0 or 5.0 framing in BLEManager. FrameRouter sends live readings to LiveState. Collector and Backfiller persist observations in WhoopStore, including the history cursor before strap acknowledgement. Undecodable 5.0 history has a mandatory raw archive. Full-frame research capture is separately opt-in. WHOOP exports enter through StrandImport. IntelligenceEngine runs incremental analytics, and Repository resolves coverage and per-field provenance for the screens. Preserve the distinction between imports, measured strap fields and NOOP estimates. [Architecture](../ARCHITECTURE.md)

| Acquisition or capability | Evidence and current use | Decision |
| --- | --- | --- |
| HR, historical R–R and gravity | Feed HR, load, sleep and recovery estimates. Live packet-40 R–R has confirmed millisecond units on the tested 5.0 | Keep live and historical sources distinguishable. Accuracy of derived scores requires separate evidence |
| Step counter and activity code | Experimental Strain tile. Run code confirmed, walk/still supported. Resets observed after rings and one removal | Validate counted walks and reset boundaries before Trends or age-model use |
| Wrist events and skin temperature | Off/on events and first nightly change observed. T04 saw an overnight removal with no samples while off | Quantify rewarming before changing the nightly exclusion window |
| R18 motion | HO1 repeated the still/walk/run ordering for float@33 across 481,897 records. Its physical scale is unknown. Byte 29 remains unresolved. Float@105 may track short-window motion energy | Use annotated still, rotation and translation sessions for a fresh check before proposing a motion feature |
| Event 120 and R26 optical bursts | Three event-120 correlations repeated in 83 reports. Field meanings remain unknown. Single-channel bursts supplied no usable SpO₂ result | Keep experimental fields out of health scores. Imported SpO₂ retains its source |
| Battery, charging, clock and haptics | Tested 5.0 reports pack presence/full state, drift and alarm events. Read-before-write reduced alarm traffic | Observe interrupted charging, reconnect with pack, counter rates and controlled discharge before claiming battery savings |

Hardware evidence above applies to WHOOP 5.0 firmware 50.43.1.0 on WG50_r52. The 4.0 decoder has its own framing and fixtures. Record family, firmware, source and availability before extending a feature to another device. A missing signal stays unavailable. [Capability inventory](../reverse-engineering/CAPABILITY_MATRIX.md) · [Research closure and outstanding gates](../reverse-engineering/EVIDENCE_MATRIX.md#8--program-closure-2026-11-20)

## Delivery order and acceptance

1. **Expose daily activity coverage.** Reuse StepCounterSample.window, Repository.strapSteps and DayCoverage. Show recorded walking/running duration and synced time together in Strain detail. Test an empty day, missing first reference, midday gap, reset and DST day. Count activity only across observed seconds and keep partial totals labelled as lower bounds. *Implemented 2026-11-26 (#83): `ActivityCoverage` and the Strain-detail Walking & running tile; in-app check pending (#86).*
2. **Make the steps release decision.** Run W04 with at least 1,000 manually tallied steps and still edges. Record error against the tally, firmware and coverage. Observe a deadline ring and tap-free removal for reset evidence. Above 5% error, drop the proposed steps feature and review the experimental tile. A passing walk alone cannot establish daily completeness. Add Trends only when the reset/reference and coverage gates also pass. Leave #49 steps gated pending evidence appropriate to that model.
3. **Check temperature and operational claims on copies.** Inspect post-reattachment temperature across recorded removals. Report usable intervals and sensitivity of nightly change to excluding rewarming. Record interrupted-charge/reconnect observations and multi-day operation counts separately. Retain existing behavior where evidence is insufficient. *Done 2026-11-26 (#85, EXPERIMENT_LOG R85): re-warming ~3–5 min awake / ~10–12 min asleep, nightly value moves 0.01 °C → kept; no charge since 11-20; ~1 Bluetooth power-off/reconnect per minute since 11-22, cause open.*
4. **Close the loop in the app.** Verify the activity breakdown on a fixture store, check VoiceOver labels for partial and unavailable states, and record #49's independent real-input/VoiceOver results when available. Keep its 180-day replay on the backlog until enough NOOP data exists.

Exit with a working coverage breakdown, its regression results, and a ship/defer/drop decision for each candidate. Record hardware-dependent gates still waiting on observations. Sprint 3 requires the coverage contract, not a successful counted walk. [Sprint 3](SPRINT_3_PHONE_MAC.md)

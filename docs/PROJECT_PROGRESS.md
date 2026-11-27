# NOOP project progress

**November 26 roadmap.** [Sprint 2, acquisition evidence and data features](sprints/DATA_FUNCTIONALITY.md) → [Sprint 3, iPhone collection and Mac analysis](sprints/SPRINT_3_PHONE_MAC.md). Sprint 3 supersedes the earlier phone-scoring proposal for the first release.

*Plain-language project snapshot, last updated November 19, 2026.*

NOOP is an independent macOS companion for WHOOP straps. It works locally on the Mac: there is no NOOP account or cloud service. This page summarizes what has been built and learned so far, and separates working software from findings that still need more evidence.

## What is working in the app

- **Connect and collect:** NOOP can pair with supported WHOOP 4.0 and 5.0 straps, receive live readings, and download stored history over Bluetooth.
- **Keep data on the Mac:** readings and computed results are stored in a local database. Users can import a WHOOP export and make or restore a database backup.
- **Review daily and historical information:** Overview and Trends show sleep, recovery, strain, heart rate, and other recorded measurements, with details about missing data and where values came from.
- **Get context from your own records:** Health views compare selected measurements with personal history; Highlights call out notable days and streaks. Optional morning and evening check-ins can be compared with later measurements. These features describe patterns in a person's data, not causes or diagnoses.
- **See device status:** the app presents live heart rate and battery information. Battery and charging details depend on what the strap reports and may be unavailable on some devices or firmware.
- **Use alarms:** NOOP includes alarm scheduling, smart-wake logic, delivery tracking, and alarm history. The logic has been tested in software; the complete alarm and vibration experience has not been confirmed across real strap and Mac sleep conditions.
- **Explore strap steps:** a Strain detail tile shows recorded step-counter increases and walking/running time from a WHOOP 5.0. The owner accepted the step counter as accurate on 2026-11-27 from the earlier walk and reset tests (#84), so the Steps tile is no longer marked experimental; a day with sync gaps still shows its count as a lower bound. Walking/running time stays experimental. Steps do not affect NOOP scores or functional age.

NOOP computes its own estimates. Imported WHOOP scores are kept separate; agreement with an imported score does not prove either result is accurate. The app is not a medical device.

The Health page shows an experimental **functional age** and 6-month pace once a birth date, a measured VO₂max and enough resting-heart-rate and sleep history are available. It is a transparent, versioned NOOP model built from published associations, not a biological or clinical age, and it has not been evaluated against real outcomes yet.

## What has been learned about the strap

Most direct testing so far used one WHOOP 5.0 with firmware **50.43.1.0** and hardware **WG50_r52**. Findings should not be assumed to apply to every strap or firmware version.

- The Bluetooth framing and several live and historical message types are understood well enough to collect and decode heart rate, beat intervals, battery reports, temperature, step-counter changes, and strap-reported wrist-wear events.
- Stored and live 5.0 beat intervals were both checked and are milliseconds on the tested device (live intervals were paired one-to-one with stored history).
- Historical skin-temperature readings are saved with their units, and NOOP can calculate a nightly change from a personal baseline. This has not been checked against a reference thermometer and should not be read as core body temperature.
- The 5.0 step counter tracks walking and running in the captures reviewed. There is not yet a dependable step-accuracy result. The counter is not a calendar-day count: across two nights it never reset at midnight, reset once seconds after an alarm, and did not reset on a morning without an alarm.
- The app can preserve undecoded history records. An optional, time- and size-limited research capture retains complete history frames before the app acknowledges a download; it was checked on live downloads (every captured frame intact and present in the database).
- Offline analysis narrowed several sensor and event hypotheses. It has not established a reliable SpO₂ measurement or a useful new optical sensor feature.
- The strap's clock drifts about 1.4 s a day; NOOP now corrects it at most once a day after a download, and the first automatic correction was seen working.
- No verified way to read the strap's exact installed firmware image or run custom firmware has been found. Firmware modification is not part of the current app or research workflow.

The technical evidence, its limits, and the safety rules are documented in the [strap research index](reverse-engineering/README.md). Private health data and unredacted captures are not included in this repository.

## Recent completed work

- **PR #50:** added the experimental step tile and bounded research capture; later review fixes preserve distinct frames and mark incomplete step/activity coverage.
- **PR #51:** made trend-comparison tests independent of the current date and time zone. [Issue #48 is complete.](https://github.com/alfonsomartin03/noop/issues/48)
- **PR #52:** bounded live packet decoding to the message payload so checksum bytes cannot be mistaken for heart-rate data; malformed beat-interval counts are reported as incomplete.
- **PRs #56–#62:** daily strap-clock correction, ordinary-use measurements, the functional-age model and Health page section, and live acceptance of research capture and live beat-interval units ([#38](https://github.com/alfonsomartin03/noop/issues/38) and [#39](https://github.com/alfonsomartin03/noop/issues/39) are complete).

These changes have automated test coverage, including synthetic packet and missing-data cases. That is software verification, not proof of sensor accuracy or complete hardware behavior. This repository has no continuous-integration checks configured; see the merged pull requests for the recorded local validation.

## What remains

The strap-research program ([issue #25](https://github.com/alfonsomartin03/noop/issues/25)) closed on November 20, 2026. Every question it raised was answered, ruled out, or moved to a short passive backlog; the per-issue outcomes and that backlog are in [the evidence matrix closure](reverse-engineering/EVIDENCE_MATRIX.md#8--program-closure-2026-11-20).

- **Done:** research capture, live beat-interval units, configuration reads, deterministic trend tests, battery-pack decoding with a "fully charged" signal, the experimental step tile, wrist on/off events, nightly skin temperature, alarm-write and battery-read reductions, daily strap-clock correction, and in-app usage counters.
- **Decided against:** custom or extracted firmware (no-go), and product use of the optical bursts (no benefit over existing heart rate, no blood-oxygen path).
- **Still waiting on time or the wearer (no strap writes):** the temperature re-warming tail after a removal, and a few charging and removal edge cases.
- **Hold-out checks done (November 26):** both frozen checks passed on data collected after the rules were fixed. The R18 motion field still reads as dynamic acceleration, the second heart-rate byte is not a delayed copy, and the three event-120 candidates replicated. None of this changes the app.
- **Healthspan:** the functional-age model and Health section are implemented ([#49](https://github.com/alfonsomartin03/noop/issues/49)); an in-app check with real inputs, accessibility review, evaluation and steps as an input (after #42) remain. It is separate from clinical biological age.

## Planned sprint

[The iPhone collection and local Mac archive sprint](sprints/PHONE_MAC_ARCHIVE.md) outlines phone-only strap pairing, direct local sync, compact phone history, safe archival and on-demand detail. It is planning only; no iOS target, sync or pruning has been implemented. Installation feasibility and measured storage/scoring requirements are the first gates.

## How to read project claims

- **Implemented** means the behavior is present in the code.
- **Tested** means software checks exercised it; it does not mean the hardware or measurement is accurate.
- **Observed on strap** means a result was seen on the tested device, with the scope and repeat count recorded in the research documents.
- **Unknown or unverified** means more evidence is needed. Missing data is not treated as zero, and unsupported measurements are not presented as established facts.

For app setup, see [build instructions](BUILD.md). For detailed implementation and evidence, start at the [documentation index](README.md).

# NOOP analytics

NOOP computes local estimates from stored strap observations and also displays imported WHOOP results. These are distinct sources, not interchangeable measurements or a reproduction of WHOOP's proprietary algorithms. No clinical validation is claimed.

## Current processing path

`Strand/Data/IntelligenceEngine.swift` coordinates `IncrementalScorer` in `Packages/StrandAnalytics`. The scorer reads source streams and persisted provenance, identifies changed days, runs analysis in causal order, and persists derived records under `<device>-noop`. The app uses scoring version 5 at this refresh. Explicit full rescoring and scoring-version upgrades have separate invalidation/archive paths.

`Repository` merges display data while retaining source identities. Imported values can take precedence for displayed fields; they must not silently become inputs to NOOP-only physiological baselines.

| Concern | Main implementation |
| --- | --- |
| R-R cleaning and HRV | `HRVAnalyzer.swift`, metric identity/provenance types |
| Sleep evidence and stages | `SleepStager.swift`, `SleepState.swift` |
| Causal personal references | `Baselines.swift`, `CausalReference.swift`, `CausalReplay.swift` |
| Recovery components and quality | `RecoveryAssessment.swift`, `RecoveryScorer.swift` |
| Supported HR time and coverage | `SupportedHR.swift` |
| HR calibration and cardiovascular load | `HRCalibration.swift`, `CardioLoad.swift`, `HRZones.swift` |
| Versioned strain display index | `StrainScorer.swift` |
| Possible activity and calories | `WorkoutDetector.swift` |
| User activity labels, effort and sets | `WorkoutLabels.swift`, `TrainingLog.swift` |
| Day orchestration / incremental persistence | `AnalyticsEngine.swift`, `IncrementalScorer.swift` |

These files are under `Packages/StrandAnalytics/Sources/StrandAnalytics/`. Some helpers are pure; the package also contains store-backed orchestration and calendar state.

## Measurement rules

- Missing observation is not zero, awake time, or confirmed sleep. Preserve coverage and quality reasons through persistence and display.
- Sleep stages are experimental estimates. Keep unknown and unstaged intervals distinct; do not invent a stage timeline from summary durations.
- Baselines use compatible metric identities and prior data, not future days or mixed vendor/NOOP definitions.
- Cardiovascular load uses supported elapsed time. Gaps, duplicate samples, or overlapping sessions must not create extra load.
- Version 5 daily strain excludes confidently classified sleep/naps. Keep excluded, observed, and unknown time explicit.
- Activity detection does not establish a sport. User labels and imported labels carry their own provenance.
- Perceived effort and strength volume are separate from HR-derived strain; neither is an implicit ingredient in the cardio index.
- A 0–21 index is a versioned presentation of load, not a validated universal measure of exertion. Agreement with an imported score is a compatibility comparison.

## Detail and evidence

[MEASUREMENT_VALIDITY.md](MEASUREMENT_VALIDITY.md) records metric identity, causal baseline and quality work. [WORKOUT_STRAIN_REPORT.md](WORKOUT_STRAIN_REPORT.md) records the load/detection implementation and later version-5 changes. Their dated observations must be checked against current source/tests before changing an algorithm.

[SLEEP_SESSIONS.md](SLEEP_SESSIONS.md) describes local session-classification/correction work in progress at this refresh. It supersedes older nap/primary rules where that work is present. Protocol research and historical sleep/recovery reports are indexed in [docs/README.md](README.md).

The current app no longer has the old live stress nudges, zone coaching, or standalone Insights/Compare screens. Retained correlation/comparison library code should be evaluated by actual callers rather than old feature descriptions.

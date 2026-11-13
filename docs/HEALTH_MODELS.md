# Health page models (issue #14)

What the Health page computes, from which inputs, and why some estimates stay off. Code: `Packages/StrandAnalytics/Sources/StrandAnalytics/HealthMonitor.swift` (analytics), `Strand/Screens/HealthPageView.swift` (presentation). Unit tests (`HealthMonitorTests`) check logic only. They are **not** clinical validation.

## Inputs NOOP actually has

| Input | NOOP (strap) | WHOOP import | Notes |
| --- | --- | --- | --- |
| Resting HR, HRV (RMSSD) | nightly, `DailyMetric.restingHr`/`avgHrv` | nightly | |
| Respiratory rate | nightly `respRateBpm` | nightly | |
| SpO₂ | nightly `spo2Pct` where the strap reports it | nightly | wrist SpO₂ is less precise than a fingertip oximeter |
| Skin temperature | nightly **deviation** from baseline (`skinTempDevC`) | **absolute °C** | different quantities; imported skin temp is not compared with NOOP's |
| Continuous HR | yes (`hrSample`) | no | used for the activation timeline |
| Accelerometer | raw gravity samples (no validated activity model) | no | |
| Age, sex, height, weight | profile (user-entered) | — | |
| Blood biomarkers, VO₂max test, waist circumference, questionnaires | **no** | no | |

## Biological age / healthspan — **unavailable**

Models reviewed (from the literature as recalled; check the primary sources before quoting them elsewhere):

- **Klemera–Doubal method** (Klemera & Doubal, 2006): combines several biomarkers regressed on age. Validated versions use blood chemistry, lung function and blood pressure. NOOP has none of the blood or spirometry inputs.
- **PhenoAge** (Levine et al., 2018): chronological age plus nine blood biomarkers (albumin, creatinine, glucose, CRP, lymphocyte %, MCV, RDW, alkaline phosphatase, white-cell count). It needs lab results.
- **Epigenetic clocks** (Horvath 2013; GrimAge; DunedinPACE, Belsky et al. 2022, the source of "pace of aging"): these need DNA methylation from blood or saliva.
- **Fitness age** (Nes et al., 2013, HUNT Fitness Study): estimates VO₂peak from age, sex, waist circumference, resting HR and a physical-activity index, then maps it to an age. It's the closest fit for the inputs NOOP collects. NOOP doesn't collect waist circumference or the activity questionnaire, and the model was calibrated on a Norwegian adult population. **Dependency:** if both inputs are added with a faithful port of the published equations and population limits, this is the candidate. It's a fitness-age estimate, not biological age.
- **Vendor ages** (e.g. WHOOP's age/healthspan features): these are proprietary and NOOP can't reproduce or validate them. NOOP doesn't claim parity with them.

Decision: `BiologicalAgeModel.version = nil`. The hero shows chronological age from the profile, "estimate unavailable", "pace of aging: needs an age model" and the missing inputs. NOOP never synthesizes missing biomarkers or shows a wellness score labelled as biological age.

## Health Monitor — personal ranges (implemented)

- Five metrics: respiratory rate, SpO₂, resting HR, HRV and skin temperature. Skin temperature is labelled as skin, not core, temperature.
- **Source isolation:** each metric uses NOOP's values when they are fresh, otherwise imported values when those are fresher. The value and its baseline always come from the same source. Imported values never enter NOOP baselines.
- **Latest value:** the newest night up to today with a plausible value. Implausible values are dropped (not zero).
- **Stale:** the latest value is more than 2 days old.
- **Baseline (causal):** nights strictly before the latest night, within 30 days of it. At least 14 nights are needed; otherwise the status is "building baseline (n of 14)".
- **Outliers:** values more than 4 scaled MADs from the median are dropped once. The range is then median ± max(2 scaled MADs, a per-metric minimum half-width: RR 0.6, SpO₂ 1 %, RHR 3 bpm, HRV 6 ms, skin 0.3 °C). A scaled MAD is 1.4826 × MAD.
- **Status:** within / above / below the personal range, building baseline, stale, or no data.
- **Summary:** counts usable metrics and deviations, and names the unavailable count. A missing or stale metric never produces an all-clear.
- **Calendar:** day keys are local calendar days, so DST doesn't change day boundaries in this logic.
- **Recompute:** the page reloads on `Repository.dataVersion` (sync and scoring), on daily-row changes (imports and rescoring) and when the day changes. The computation runs in a detached task, never in view bodies. Nothing is stored, so a model change can't leave stale results behind.

### HRV position against the median (issue #17)

- Before: the Recovery detail compared HRV with a 30-day **mean** and coloured any non-zero difference green/amber; its summary said "HRV below your norm" for a value 1 ms under that mean, while the Health page called the same value "within your range". Two rules disagreed.
- Now one rule (`PersonalRangePosition`, StrandAnalytics) feeds the Health Monitor HRV tile/detail and the Recovery detail: personal range = `HealthMonitor.baseline` (median ± max(2 robust SD, 6 ms), ≥ 14 of 30 earlier nights, same source, causal). Within **one robust SD** of the median (floor 3 ms, half the range floor, for very steady histories) = "Typical for you"; one–two spreads = "Within your range, higher/lower than usual"; outside = above/below range. No population cut-offs; the 1-SD band is half the existing 2-SD range, not a new tuned threshold.
- Stale, missing or < 14 prior nights: no position (building baseline / stale shown as before).

### Nightly maximum HRV (issue #17)

- Recovery detail only (not Overview): highest 5-min RMSSD among the selected night's main-sleep windows that pass `SleepVitalsCalculator`'s HRV gates (inside the session, past onset/waking edges, ≥ 90 % asleep and known state, beat coverage, ≥ 60 clean beats, ≥ 80 % surviving artifact rejection). Needs ≥ 6 valid windows; otherwise "Unavailable" with the reason. Recomputed from this Mac's raw RR, so imported nights show unavailable. It never replaces the nightly median used by recovery and baselines.
- Eligible sleep interval: the NOOP **main sleep whose final wake falls on the selected day** (`Repository.mainSleepEpisodes`), resolved as a whole session — every episode sharing its session id, including a fragment that ended before midnight. Naps and uncertain episodes are never eligible. Two main sessions waking the same day: the longer one.
- Source: always NOOP strap data. The tile is titled "Nightly maximum HRV (NOOP)" and its caption gives the time of the maximum, the main-sleep bounds (and the number of parts), the clean-window count and "not used for recovery"; when the recovery values beside it come from the WHOOP import it adds "(not from the WHOOP import)". An imported-only night is unavailable — no average is borrowed and no maximum invented.
- Refresh: the lookup is keyed by day + `Repository.dataVersion` + shown source (`NightlyMaxHRVRequest`), so a late RR sync, rescoring, a sleep correction or a source change recomputes it while the detail stays open; a superseded lookup is cancelled and cannot overwrite the newer result; the previous value stays visible during a same-night refresh.
- Tested (hosted `NightlyMaxHRVTests`, in-memory store, synthetic streams): maximum in a pre-midnight fragment, pre-midnight fragment counted toward the ≥ 6-window gate, imported-only and uncertain-only nights unavailable, late sync and a nap correction changing the result, request identity. The view-level cancellation guard is not unit-tested.

Personal ranges describe the wearer's usual values. They are not clinical reference ranges or diagnoses.

## Stress Monitor — heart-rate activation timeline (implemented); stress score — **unavailable**

Methods considered for a stress score:

- **HRV-based indices** (RMSSD, LF/HF and Baevsky's stress index): these need clean beat-to-beat intervals in stationary windows. Awake RR from a wrist strap is intermittent and dominated by movement artefacts, and NOOP has no validated way to separate movement from mental load.
- **Vendor stress scores** (e.g. Firstbeat/Garmin, WHOOP): these are proprietary HRV- and HR-based models that can't be reproduced or validated here.

Decision: no numerical stress score. The page instead shows **heart-rate activation**:

- 15-minute bins over the local day (up to now for today), scaled to the day's real length (23–25 h across DST).
- Bins inside NOOP sleep episodes are labelled "Asleep", and bins inside stored workouts are labelled "Workout". A bin is "No data" when its readings span less than 50 % of it. Gaps are never shown as calm.
- Other bins are classified by mean HR as a share of heart-rate reserve (resting HR → profile HR max): < 20 % near resting, 20–40 % moderately raised, ≥ 40 % strongly raised.
- Resting HR comes from NOOP's latest scored night up to that day, or from the imported night (labelled) when NOOP has none. With no resting HR at all, the section reports that it's unavailable.
- The copy says this can't separate stress from movement, heat, caffeine or illness. It infers nothing about emotions or mental health.

## Not validated

None of the above has been checked against labelled real-world data. The thresholds are defensible starting points, not tuned values.

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

Models reviewed (references under *Sources* below; DOIs resolved 2026-11-13, numbers quoted from the papers' abstracts as recalled — read the paper before relying on a figure):

- **Klemera–Doubal method** (Klemera & Doubal, 2006): combines several biomarkers regressed on age. Validated versions use blood chemistry, lung function and blood pressure. NOOP has none of the blood or spirometry inputs.
- **PhenoAge** (Levine et al., 2018): chronological age plus nine blood biomarkers (albumin, creatinine, glucose, CRP, lymphocyte %, MCV, RDW, alkaline phosphatase, white-cell count). It needs lab results.
- **Epigenetic clocks** (Horvath 2013; GrimAge; DunedinPACE, Belsky et al. 2022, the source of "pace of aging"): these need DNA methylation from blood or saliva.
- **Fitness age** (Nes et al., 2011, HUNT Fitness Study non-exercise VO₂peak model): estimates VO₂peak from age, sex, waist circumference, resting HR and a physical-activity index, then maps it to an age. It's the closest fit for the inputs NOOP collects. NOOP doesn't collect waist circumference or the activity questionnaire, and the model was calibrated on a Norwegian adult population. **Dependency:** if both inputs are added with a faithful port of the published equations and population limits, this is the candidate. It's a fitness-age estimate, not biological age.
- **Vendor ages** (e.g. WHOOP's age/healthspan features): these are proprietary and NOOP can't reproduce or validate them. NOOP doesn't claim parity with them.

Decision: `BiologicalAgeModel.version = nil`. The hero shows chronological age from the profile, "estimate unavailable", "pace of aging: needs an age model" and the missing inputs. NOOP never synthesizes missing biomarkers or shows a wellness score labelled as biological age.

Researched decision (issue #16, 2026-11-13): **stays unavailable.** What each candidate needs and NOOP lacks:

| Model | Required inputs | NOOP has | Missing |
| --- | --- | --- | --- |
| Klemera–Doubal | a panel of age-related biomarkers (published versions: blood chemistry, blood pressure, lung function) + a reference population | age | every biomarker, reference data |
| PhenoAge | age + 9 blood biomarkers | age | all 9 lab values |
| Horvath / GrimAge / DunedinPACE | DNA methylation array | — | the assay |
| HUNT non-exercise VO₂peak → fitness age | age, sex, waist circumference, resting HR, self-reported activity index; age/sex reference table | age, sex, resting HR (sleep-derived, a different protocol) | waist, activity questionnaire, reference table |

No subset of NOOP's inputs (age, sex, height, weight, sleep-derived HR/HRV, respiratory rate, skin-temperature deviation) is a published, validated biological-age model. A fitness estimate is **not** substituted for it.

Issue #16 re-review: still unavailable. The VO₂max estimate below is a *fitness* measure, not biological age, and no fitness-age mapping is shown because the published age/sex reference medians (HUNT) and waist/activity inputs are not in NOOP; the hero keeps its unavailable state.

## VO₂max estimate (issue #16, `vo2-hr-ratio-v1`, implemented, **not validated**)

- Method: Uth, Sørensen, Overgaard & Pedersen (2004), "heart rate ratio method": VO₂max ≈ 15.3 × HRmax ÷ HRrest mL/kg/min. Only heart rate is needed, which is all NOOP has (no pace, power, GPS or lab test). Code: `FitnessEstimates.swift` (`VO2MaxEstimate`); UI: `VO2MaxCard` on the Health page.
- Source population and protocol: well-trained men aged 21–51; HRrest measured awake, supine, after rest; HRmax and VO₂max **measured** in a maximal test. Outside that group (women, older or untrained people, heart-rate-altering medication) the proportionality constant is not established by the paper.
- Inputs in NOOP: HRmax = the profile's entered max (preferred) else Tanaka et al. (2001) 208 − 0.7·age; HRrest = median NOOP sleep-derived resting HR over ≥ 5 of the last 7 nights, newest ≤ 3 days old. Imported resting HR is not used (different measurement).
- Known mismatches, stated in the UI:
  - **Resting-HR protocol.** The model's HRrest is an awake supine value; NOOP's is derived from sleep and is lower, so the ratio — and the estimate — is biased **upward** by an amount NOOP cannot measure (it has no awake-rest protocol).
  - **Predicted HRmax.** Tanaka's equation has a between-person spread of roughly ±10 bpm (1 SD) around the prediction; at HRrest 50 that alone moves the estimate by about ±3 mL/kg/min, on top of the method's own error. An entered, measured max removes this term only.
- Uncertainty shown: none as a number — no interval is displayed because none has been derived for NOOP's inputs. The card says "estimate", names the version and the two inputs with their dates.
- Unavailable (with the missing inputs listed) without age/max or enough recent nights.
- **Validation: not done.** It needs a measured VO₂max (lab CPET, or at least a graded field test) for the wearer, close in time to a 7-night window; none is available. Until then the number is a formula output, not a validated estimate.
- **Protocol mismatch.** Uth's HRrest is the lowest 1-min mean of a 5-min awake supine morning recording and HRmax the highest 5-s exercise mean; NOOP uses the median of sleep-derived resting HR (≥ 5 of 7 nights) and an entered or Tanaka age-predicted HRmax. Sleep HR is typically lower than awake supine HR, which raises the ratio; age-predicted HRmax has a wide individual error. The paper's error figures therefore do not transfer to NOOP.
- **Reference packet (when one exists).** Per test, privately: test time/zone, kind (measured CPET vs field prediction — secondary only), mode, VO₂ in mL/kg/min (`1000 × L/min ÷ kg` if given in L/min; keep VO₂peak vs VO₂max as reported), maximality notes, measured HRmax and its date/source, any awake-rest HR and protocol, NOOP resting HR with its nights, age, model version, applicability notes, exclusion reason. Freeze the model's reference day; compare measured-HRmax and predicted-HRmax variants separately; report individual errors and, with enough independent references, bias, MAE/RMSE and Bland–Altman limits (correlation alone is not agreement).
- **Decision rule must be set by the owner before evaluation** (intended claim and population, tolerable error in mL/kg/min, precision, sample-size rationale). None of the sources gives a universal threshold, so none is invented here. One person's single test is a sanity check, not validation; if the method proves unsuitable, an unavailable state with a documented failed validation beats a "validated" label.

## NOOP sleep performance (issue #16, `noop-sleep-perf-v1`, implemented)

- `SleepPerformance`: 100 × min(1, asleep ÷ need), need = max(7.5 h, mean asleep over up to 14 earlier NOOP nights) (`SleepNeed` fallback). Causal; NOOP rows only; a night without minutes asleep has no value (not 0 %).
- Shown in Trends ▸ Sleep ("Sleep performance — NOOP estimate") and Highlights (NOOP source: Best sleep + sleep streak, labelled "NOOP sleep performance … hours vs estimated need").
- WHOOP research: `docs/WHOOP_REVERSE_ENGINEERING.md` in-sample fit = hours-vs-need + consistency + efficiency (MAE 3.0). `Tools/reverse_engineer/sleep_performance_eval.py` now gives a **held-out** (time-split) MAE for the hours-vs-need hypothesis and the 3-term fit on a user-supplied export. No parity is claimed. NOOP v1 deliberately uses hours-vs-need only (NOOP has no WHOOP consistency score or sleep-stress input).
- **Real-export held-out run (2026-11-13, one person's export, private, not in the repo).** Both CSVs joined per sleep; 641 main sleeps after dropping 103 naps; 634 with a reported performance (7 excluded: no reported performance; 2 more lack consistency/efficiency for H2). Chronological 70/30 split, 443 fit / 191 held out, both hypotheses scored on the same 191 nights:

  | Hypothesis | Held-out MAE (points) |
  | --- | --- |
  | H1 `100·min(1, asleep/need)` with WHOOP's own need | 7.84 |
  | H2 intercept + hours-vs-need + consistency + efficiency, fitted on the first 443 nights | 3.46 |

  A 50/50 split gives 9.47 / 4.90 over 317 nights. The fitted H2 coefficients differ a lot between the two splits and from the in-sample fit in `WHOOP_REVERSE_ENGINEERING.md`, so the structure (three terms) is supported but **the weights are not pinned down**. Limits: one person, one device generation and time span; WHOOP's formula may have changed inside the span; "sleep stress" is not exported; H1 here uses WHOOP's own asleep and need, whereas NOOP's v1 uses its own asleep minutes and estimated need. 7.84 is therefore **not** a lower bound on NOOP-vs-WHOOP disagreement: NOOP's input errors can cancel or add to the formula difference. It describes the formula on exported inputs only.

### NOOP vs WHOOP on the same nights (`perf_probe … --sleepperf`, `SleepPairing`)

- **Pairing is by sleep interval, never by date string.** The importer keys a cycle's values by its cycle-start date and NOOP by final-wake date; the two need not match. A NOOP main sleep (first onset → final wake, longest per wake day) matches the imported main sleep it overlaps with IoU ≥ 0.5; none, several, or one imported sleep claimed by two NOOP nights → excluded with a logged reason. WHOOP values come only from the cycle that **declares** that sleep: the importer stores each cycle's Sleep/Wake onset (`sleep_onset_ts`/`wake_onset_ts`; from the cycle row, else the single main sleep in sleeps.csv naming that cycle start) and the link needs both within 60 s. Cycle start time is never used to guess the link — in the bundled fixture the cycle starts at wake, 7 h 15 min after onset. No declared sleep, or two cycles declaring one sleep → excluded. Cycles imported before 2026-11-13 have no declared sleep: re-import the export (upserts are idempotent) before running the report.
- **Four comparisons, reported separately**, each over all pairs and over stable-history pairs (the night's NOOP need had ≥ 14 earlier NOOP nights): NOOP performance vs WHOOP performance (*agreement*, not parity — WHOOP also weighs consistency, efficiency and sleep stress); NOOP performance vs `100·min(1, WHOOP asleep / WHOOP need)` (the comparable hours-vs-need component, capped like NOOP's); the same vs the importer's **uncapped** `hours_vs_needed_pct` (so cap differences are not mistaken for model error); NOOP asleep vs exported asleep; NOOP need vs exported need. Each row gives n, MAE, median absolute error, signed bias (NOOP − WHOOP) and how many pairs lacked the WHOOP field. Aggregates only.
- **Result (local data, 2026-11-13): 0 pairs.** 22 NOOP nights (2026-10-22 → 11-12), each with a main sleep; 634 imported main sleeps end 2026-10-20; every NOOP night is excluded as "no overlapping WHOOP sleep". No agreement figure exists.
- **Next data needed:** a fresh WHOOP account export after a period both systems recorded the same nights (WHOOP must have ingested those nights; already-acknowledged strap history may not be re-offloadable). Keep the ZIP private; run the probe on a SQLite-backup copy. One person's nights are not population generalisation; with enough pairs, add participant/day-block uncertainty.


## Overview activation strip (issue #16)

The Overview heart-rate card shows the latest known activation state (15-min bin), a thin day strip and coverage, from the same `HRActivation.timeline` as the Stress Monitor (`ActivationViews.swift`). Labelled "not a stress score"; no-data bins stay empty. Only confirmed NOOP sessions (main, interrupted main, nap) are drawn as Asleep; an **uncertain** episode is not sleep — its bins show activation where readings exist and no data where they don't, and it adds nothing to coverage (`ActivationLoad.sleepIntervals`, hosted `ActivationLoadTests`).

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

## Sources

Resolved through Crossref on 2026-11-13. Titles and venues are from the registry; population notes are summaries.

| Reference | Used for | Population / inputs |
| --- | --- | --- |
| Uth N, Sørensen H, Overgaard K, Pedersen PK. *Estimation of VO₂max from the ratio between HRmax and HRrest — the Heart Rate Ratio Method.* Eur J Appl Physiol 2004;91:111–115. https://doi.org/10.1007/s00421-003-0988-y | VO₂max estimate | well-trained men 21–51; measured HRmax, awake supine HRrest |
| Tanaka H, Monahan KD, Seals DR. *Age-predicted maximal heart rate revisited.* J Am Coll Cardiol 2001;37:153–156. https://doi.org/10.1016/S0735-1097(00)01054-8 | predicted HRmax | meta-analysis + lab sample of healthy adults; 208 − 0.7·age |
| Nes BM, et al. *Estimating VO₂peak from a nonexercise prediction model: the HUNT Study, Norway.* Med Sci Sports Exerc 2011;43:2024–2030. https://doi.org/10.1249/MSS.0b013e31821d3f6f | fitness-age candidate (not implemented) | Norwegian adults; age, sex, waist, resting HR, activity index |
| Klemera P, Doubal S. *A new approach to the concept and computation of biological age.* Mech Ageing Dev 2006;127:240–248. https://doi.org/10.1016/j.mad.2005.10.004 | biological age (reviewed) | biomarker panel + reference population |
| Levine ME, Lu AT, Quach A, et al. *An epigenetic biomarker of aging for lifespan and healthspan.* Aging 2018;10:573–591. https://doi.org/10.18632/aging.101414 | PhenoAge (reviewed) | age + 9 blood biomarkers; methylation |
| Horvath S. *DNA methylation age of human tissues and cell types.* Genome Biol 2013;14:R115. https://doi.org/10.1186/gb-2013-14-10-r115 | epigenetic clock (reviewed) | DNA methylation |
| Belsky DW, Caspi A, Corcoran DL, et al. *DunedinPACE, a DNA methylation biomarker of the pace of aging.* eLife 2022;11:e73420. https://doi.org/10.7554/eLife.73420 | "pace of aging" (reviewed) | DNA methylation |

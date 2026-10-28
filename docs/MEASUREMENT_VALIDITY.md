# Measurement validity: specification and change report (October 2026)

Implements the first phases of [`SLEEP_RECOVERY_RESEARCH_2026-10-27.md`](SLEEP_RECOVERY_RESEARCH_2026-10-27.md). Scope: make NOOP's numbers **traceable, causal, honest about missing data, and separately interpretable**. Nothing here makes any estimate more accurate against a reference. No reference data (PSG, ECG, respiratory belt, outcome measures) was used, so the right summary is **"implemented and tested," not "validated."**

Evidence labels used below:
- **Definition**: an established mathematical or measurement definition.
- **Research**: an empirical finding from cited literature.
- **NOOP choice**: a provisional engineering decision. It is configurable and unvalidated.
- **Experimental**: shown with a label and kept out of composite claims.

---

## 1. Defects found and fixed

| # | Defect (verified in code) | Fix | Where |
|---|---|---|---|
| 1 | Every historical day was scored against **one baseline folded from all history**: it included the day itself and every later night. The walk ran newest→oldest. | Days are scored **oldest→newest**. Each day uses only NOOP nights dated **strictly before** it, and its own result joins the history afterwards. | `IntelligenceEngine.analyzeRecent`, `CausalBaselines`, `Baselines.causalState`, `CausalReference` |
| 2 | Baselines mixed **imported WHOOP values** (vendor aggregation) with **NOOP median-window RMSSD** through the merged dashboard rows. | A typed `MetricIdentity` (definition, unit, source, hardware, algorithm version, context, aggregation). References accept only identical identities, so WHOOP nights start no NOOP baseline. | `MetricProvenance.swift` |
| 3 | Sparse valid rows were folded as consecutive nights, so staleness never saw calendar gaps. | `causalState` inserts a missing night for every calendar day without one. `CausalReference` works in calendar days (`CalendarDay.index`, no DST dependence). | `CausalReference.swift` |
| 4 | Missing-gravity epochs were labelled **`wake`**. A session with no motion data was labelled entirely **`light`**. | `SleepState`: `wake`, `asleep` (unstaged), `light`, `deep`, `rem`, `unknown`, with a `reason`. Missing data is `unknown`. Sleep epochs without HR are `asleep` (abstention), not a default `light`. | `SleepState.swift`, `SleepStager.stageSession`, `classifyEpochs` |
| 5 | Efficiency treated unscored time as sleep, then (after #4) would have treated it as wake. | Efficiency is sleep ÷ **observed** period time, with unknown time in neither term. TST includes unstaged sleep. Stage percentages are of all sleep and don't sum to 100 when part of it is unstaged. | `SleepStager.efficiency`, `hypnogramMetrics` |
| 6 | Raw R-R table key `(deviceId, ts, rrMs)` silently **dropped a genuine second beat with the same ms value** in the same second. Reads used `ORDER BY ts, rrMs`, which **reordered same-second beats by value** and corrupted successive differences. | Migration **v10** adds `seq` (position within the second, acquisition order) with key `(deviceId, ts, seq, rrMs)`. Existing rows keep insertion order. Reads order by `ts, seq, rowid`. Duplicate records within a batch are dropped only when they physically can't fit in one second. | `WhoopStore` `Database.swift`, `StreamStore.swift`, `Reads.swift` |
| 7 | `analyzeTimed` relied on an unspecified sort for same-second beats. | Stable sort by (ts, input position). `nPairs` (RMSSD/pNN50 denominator) is reported separately from `nClean`. | `HRVAnalyzer.swift` |
| 8 | HR coverage counted **rows** as seconds, so duplicate rows inflated it. Nothing caught **duplicated or overlapping beat streams** (the standard-BLE channel and the history offload write the same device). | Coverage counts **distinct seconds**. A window is rejected when summed R-R exceeds elapsed time by > 15 % ("excess beats"). Windows mostly in `unknown` state are excluded. | `SleepVitals.swift` |
| 9 | Respiration built its time axis from R-R lengths alone, so a dropped packet was **spliced out of time**. | `RespiratoryRate.estimate(beats:)` splits the series where stamped time and summed R-R time disagree (> 2 s) or stamps jump > 3 s, and analyses one continuous run. | `RespiratoryRate.swift` |
| 10 | Inferred respiration was being fed into the legacy recovery term. That weight was fitted to WHOOP's *measured* rate. | Not passed to the legacy model. Still stored in `respRateBpm` and labelled experimental. | `RecoveryAssessor` |
| 11 | Apple Health SDNN was flattened under the generic `"hrv"` key that means RMSSD for WHOOP. It had no persisting caller, so this was latent. | Key renamed to `hrv_sdnn`, with a test that `"hrv"` is absent. | `AppleHealthAggregator.metricPoints` |
| 12 | A rule-version re-score destroyed previous algorithm outputs. | `recomputeAll` archives the old `-noop` daily rows under `-noop-v<old>` before wiping. `deleteDerived` also clears NOOP's metric-series rows. Imports and raw samples are never touched (tested). | `IntelligenceEngine.recomputeAll`, `MetricsCache.deleteDerived` |

Preserved unchanged: median valid-window RMSSD, the lower-quartile-window resting HR, gap/rejection-aware adjacency in `analyzeTimed`, and every existing gate value.

---

## 2. Metric specifications

### Heart-rate variability and heart rate

| Metric | Inputs → units | Equation | Window / aggregation | Quality requirements (NOOP choice) | Missing → | Baseline identity | Evidence |
|---|---|---|---|---|---|---|---|
| RMSSD | accepted adjacent NN, ms | `sqrt(Σ ΔNN² / nPairs)` | 5-min window | ≥ 20 clean beats, ≥ 10 adjacent pairs. A pair needs both beats accepted, original neighbours, stamps ≤ 3 s apart | `nil` | — | Definition (Task Force 1996). Cleaning is a Malik 20 % local-median rule, **not** Lipponen–Tarvainen |
| SDNN | accepted NN, ms | `sqrt(Σ(NN−mean)² / (N−1))` | 5-min window | as above | `nil` | separate definition; never shares an RMSSD reference | Definition |
| pNN50 | adjacent pairs, % | `100 · count(|ΔNN|>50) / nPairs` | 5-min window | as above | `nil` | — | Definition |
| Nightly HRV (`avgHrv`) | window RMSSDs, ms | median of valid windows | sleep session, excluding the first 10 and last 5 min | ≥ 6 valid windows. Per window: ≤ 10 % wake **and** ≤ 10 % unknown, HR in ≥ 60 % of distinct seconds, beats ≥ 50 % of expected, ≥ 60 clean, ≥ 80 % retained, summed R-R ≤ 115 % of elapsed time | `nil` | `noopNightlyRMSSD` (`vitals-2026.10`, sleep, medianOf5MinWindows) | Aggregation is a candidate, not a validated nightly index |
| HRV distribution | valid windows | count per third of the session; `hrvTemporalCoverage` = valid ÷ all windows; `hrvSpansNight` = valid windows in ≥ 2 thirds | — | — | reported | — | NOOP choice (representativeness flag) |
| Sleeping resting HR | window mean HR, bpm | mean of the lowest 25 % of valid windows | sleep session | ≥ 6 valid HR windows | `nil` | `noopSleepRestingHR` | NOOP choice. It is distinct from overnight mean HR (`avgSleepHR`), the minimum-window HR (`minWindowHR`) and awake resting HR (not produced) |

### Respiration (experimental)

| Metric | Inputs → units | Method | Quality | Missing → | Evidence |
|---|---|---|---|---|---|
| Inferred breathing rate | timestamped R-R → breaths/min | Longest continuous run (stamp/R-R-clock drift ≤ 2 s, stamp gaps ≤ 3 s), 4 Hz resample, 10 s moving-average detrend, Hann window, Goertzel 0.15–0.40 Hz, `60 × Hz` | ≥ 30 beats, ≥ 120 s continuous, ≥ 80 % kept, peak ≥ 35 % of band power, not at the band edge. Nightly median of ≥ 6 windows | `nil` | **Experimental.** Synthetic tests only show known-frequency recovery. It has no reference validation, isn't in any recovery score, and shares no baseline with a direct respiration channel |

### Sleep accounting (`SleepAccounting`)

| Metric | Definition | Missingness / denominator |
|---|---|---|
| TST | union of all sleep states (incl. `asleep`) | `[S, S+U]` bounds from unknown time. These are **not** a confidence interval |
| 24-h sleep | union of nights, naps and overlapping imports, clipped to a window | elapsed seconds; overlap counted once; DST days handled by timestamp arithmetic |
| Efficiency (TIB) | `100 · TST / TIB` | `nil` without a real in-bed boundary source. NOOP has none today, so the stored `efficiency` field is the separately defined *observed sleep-period* efficiency |
| SOL | onset − attempt time | `nil` without an attempt time (never 0) |
| WASO | observed wake between first onset and final awakening | unknown time in that span reported beside it (`unknownInSleepPeriodS`) |
| Stage durations | per state | `stagedCoverage` = staged ÷ all sleep; `classifiedFractions` (sum to 1) vs `wholeSleepFractions` (sum to `stagedCoverage`) |
| Wake bouts | maximal observed-wake runs ≥ `minBoutS`, merged across sleep gaps < `mergeGapS` | never merged across unknown. **Not EEG arousals** |
| SRI | `200 · p_same − 100` over epochs exactly 86 400 s apart, sleep vs wake | only pairs where both states are known; `nil` when the valid-pair fraction is < 0.5 (NOOP choice); never clipped (−100…100). `stateGrid` marks only *worn* time outside sleep as wake |
| Bed/wake timing | circular mean, resultant length R, circular SD `sqrt(−2 ln R)·1440/2π` min | local clock per instant via `ZoneTimeline` |
| Shortfall | `max(0, target − sleep24h)`; `meetsTarget = sleep ≥ target` | `nil` when sleep is unknown. Window sums use observed days only and report completeness. Default target **7 h** (AASM/SRS adult consensus "≥ 7 h"). It is configurable and never lowered toward habitual sleep. Efficiency never enters it. No debt decay/repayment model |

### Personal references

| Reference | Transform | Center / scale | Eligibility | States |
|---|---|---|---|---|
| ln RMSSD (`ReferenceConfig.lnRMSSD`) | `ln(RMSSD / 1 ms)` | median; `max(1.4826 · MAD, 0.05)` in ln units | same identity; strictly earlier calendar days within 60 d; 5–250 ms; finite | `calibrating` < 5 prior, `provisional` < 14, `established`, `stale` > 21 d since last |
| Sleeping RHR (`ReferenceConfig.restingHR`) | identity | median; `max(1.4826 · MAD, 1 bpm)` | 30–120 bpm, rest as above | as above |
| Legacy EWMA (`Baselines.causalState`) | raw | Winsorized EWMA; mean-abs-dev × 1.253 | same identity; strictly earlier days; calendar gaps folded as missing nights | `calibrating` / `provisional` / `trusted` / `stale` (> 14 missing nights) |

All windows, floors and counts in this table are **NOOP choices**. 1.4826 (median absolute deviation) and 1.253 (mean absolute deviation) are different estimators; the two paths aren't mixed. Valid unusual nights still update the robust reference, because median/MAD tolerate them. Implausible or failed-quality values are excluded with a reason.

### Recovery (`RecoveryAssessor`)

| Component | Content | Missing behaviour | Evidence |
|---|---|---|---|
| Legacy score `legacy-whoop-fit-v1` | `RecoveryScorer` logistic; weights 0.86/0.04/(0.07 unused)/0.03 fitted to one WHOOP export | `nil` without ≥ 3 h sleep, HRV, RHR and a usable HRV baseline. **Withheld** (reason given) when \|HRV z\| > 3 on a marginal night (< 12 valid HRV windows or one third only). No population fallback | Index for continuity. Agreement with WHOOP is not validity |
| Sleep sufficiency | shortfall vs target; efficiency shown separately | `nil` sleep → unknown | Target from consensus guidance; the person's need is unknown |
| Autonomic deviation | ln-RMSSD z and RHR z vs the causal references, plus quality notes | `complete` / `partial` / `unavailable`, each with notes (`reference calibrating`, `stale`, `valid HRV windows cover only one third…`) | Signed deviations; no good/bad direction implied |
| Unusual values | \|z\| ≥ 2 in **either** direction, flagged `lowQuality` when measurement is marginal | none when unscored | NOOP choice |

Respiration inferred from the same R-R as HRV isn't counted as independent evidence, and there's no separate "stress" term. Components are persisted per day to `metricSeries` under `<device>-noop` with keys `noop.*` (not yet shown in the UI).

### Staging evaluation harness (`StagingEvaluation`)

- Epoch confusion matrix (wake/light/deep/rem), per-stage precision/recall/F1, macro-F1, Cohen's κ.
- Binary sleep sensitivity, wake specificity and κ.
- Sleep/wake coverage and stage coverage. Abstentions count as neither right nor wrong.
- Failure rate.
- Night-level TST, onset and final-wake bias, 95 % limits of agreement and MAE.
- κ 95 % interval from a **participant-level** bootstrap.
- Deterministic participant-disjoint folds.

Preprocessing must be fitted on training participants only; the harness can't enforce that.

---

## 3. Tests

| Package | Result | New |
|---|---|---|
| StrandAnalytics | 218 / 218 pass | 34 (`MeasurementValidityTests`), covering acceptance items 1–11 and the harness |
| WhoopStore | 81 / 81 pass | 6 (`RRSequenceTests`, `DerivedIsolationTests`), covering item 2 at storage level, item 12, and the v9→v10 migration |
| StrandImport aggregator | 28 / 28 pass | 1 assertion: SDNN is not under `"hrv"` |
| StrandImport importer/coordinator | 27 failures **before and after** this change | missing `export.xml` fixtures; unrelated |
| App (`xcodebuild`, macOS, unsigned) | builds | — |

Item 12 is partly out of reach. Raw samples, imports and earlier algorithm outputs survive. **Manual corrections** don't exist as a feature yet, so there's nothing to preserve.

---

## 4. What changes for the user

- **First launch** runs store migration v10, which rebuilds the R-R table (a one-time cost proportional to stored beats). Then scoring v3 runs a full re-score with v2 rows archived.
- **Recovery needs NOOP's own history.** Imported WHOOP nights no longer seed NOOP baselines, so a strap-only history needs ≥ 4 NOOP-measured nights (legacy) or ≥ 5 (autonomic component) before a score appears. Days with only an import still show WHOOP's own score.
- Recovery values shift: no inferred respiration term, causal baselines, and some nights withheld by the quality guard.
- Nightly HRV/RHR may be unavailable more often: duplicated streams, rows-not-seconds coverage, and unknown-state windows are now rejected.
- The stored `efficiency` now excludes unknown time. Hypnograms show `unknown` and `asleep` segments as gaps (the UI decoder ignores unrecognised labels). TST still counts unstaged sleep.
- **Before/after values on real data weren't measured** in this pass: no device database was read.

---

## 5. Claims that still need external data

| Claim | Needed |
|---|---|
| Sleep/wake and stage accuracy of `heuristic-quota-v1` (and of any replacement) | Simultaneous PSG and strap recordings from many participants, scored with `StagingEvaluation` |
| That the Malik 20 % rule removes artifacts without removing genuine variability | ECG-referenced beat annotations, or a Lipponen–Tarvainen reference run on the same R-R |
| Nightly RMSSD aggregation (median of windows vs other summaries) and its day-to-day noise floor | Repeated nights with ECG, plus a test-retest design |
| Inferred respiration accuracy | A respiratory reference (belt, capnography or PSG airflow) |
| Any recovery composite predicting anything | Pre-registered outcomes (morning self-report, vigilance test, standardised exercise test), compared against sleep-only, HRV-only, self-report-only and persistence baselines on future time blocks |
| A single missing beat inside a ≤ 3 s stamp gap | Device beat sequence numbers; whole-second stamps can't reveal it |

## 6. Not done here (deliberately)

- **No new stage classifier or quota removal.** Without labels, deleting the quotas would swap one unvalidated heuristic for another. The method is now named, documented as quota-constrained, abstains without cardiac data, and the evaluation harness is ready for when labels exist.
- **No morning check-in UI.** The `journal` table could hold it, but the screen work is out of scope for a measurement-repair pass.
- **SRI isn't wired into the app.** It needs a multi-day worn-time grid (`stateGrid` exists). It is only meaningful with daytime wear.
- **Components aren't surfaced in the UI** yet. They're persisted as `noop.*` metric series.

## 7. Next highest-value validation experiment

**A paired overnight recording study: NOOP strap plus a chest-strap ECG, then in-lab or home PSG.**

1. **Phase A (no lab):** 10–20 people, 5+ nights each, recording the strap (raw R-R and gravity) alongside a chest-strap ECG R-R logger (e.g. Polar H10).
   - Compare per-window and nightly RMSSD, RHR and beat coverage, with bias and limits of agreement per participant.
   - Quantify artifact-filter performance against ECG beats.
   - Estimate the night-to-night noise floor of ln RMSSD; it replaces the placeholder 0.05.
   - This needs only consumer hardware and gives the HRV pipeline its first reference.
2. **Phase B:** add PSG for 2+ nights per participant (at least 30 people, varied ages, skin tones and sleep quality). Export 30-s reference epochs and score `heuristic-quota-v1` with `StagingEvaluation` in participant-held-out folds. Report sleep sensitivity, **wake specificity**, κ with participant-clustered intervals, TST/WASO bias, and stage coverage.
3. Both phases need informed consent and an ethics review for any recruitment beyond the developer.

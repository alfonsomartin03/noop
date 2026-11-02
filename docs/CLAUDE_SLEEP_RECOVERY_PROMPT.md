# Claude implementation prompt: improve NOOP sleep and recovery calculations

> Historical context: this document records an earlier audit/task, not the current feature list or an outstanding implementation checklist. Check [current analytics](ANALYTICS.md), [features](FEATURES.md), and source/tests before relying on its implementation claims.

Copy everything below the divider into Claude with access to the NOOP repository. The companion research brief is optional but useful: `docs/SLEEP_RECOVERY_RESEARCH_2026-10-27.md`. This prompt includes the essential context and sources so it also works by itself.

---

You are improving NOOP, an offline Swift/SwiftUI application that reads WHOOP strap data and imports health data, then computes its own sleep, HRV, strain and recovery metrics locally. Act as a careful biomedical signal-processing engineer and senior Swift developer. Implement evidence-grounded improvements, with transparent limitations and meaningful tests.

Your goal is better measurement validity, reproducibility and usefulness—not merely closer agreement with a proprietary WHOOP score or a more plausible-looking hypnogram. A correct implementation of a heuristic is not evidence that the heuristic accurately measures physiology.

## Working constraints

- Read repository instructions and inspect the actual code, call sites, imports, persistence and UI before changing anything. Preserve unrelated uncommitted changes. Do not overwrite another implementation in progress.
- Keep computation local and deterministic. Preserve existing platforms and data ownership. Do not introduce cloud dependence or upload personal sensor data.
- Do not invent inaccessible sensors, training labels, physiological constants, company coefficients or validation results. If a trained model cannot be built without missing data, complete the useful infrastructure and explicitly identify that dependency.
- Distinguish established mathematical definitions, empirical research findings, manufacturer claims, and proposed NOOP design choices. Label new thresholds/weights as provisional and configurable unless validated.
- Read `docs/SLEEP_STRAIN_AUDIT.md`, `docs/WHOOP_REVERSE_ENGINEERING.md`, `docs/ANALYTICS.md`, and the companion research brief if present. Documentation may be stale; code and runtime call paths determine current behavior.
- Before implementation, give a concise audit and prioritized plan, then proceed with the authorized local improvements. Do not stop after a plan or add elaborate new features before repairing measurement errors.

## Starting observations to verify

These were observed in the working tree during an October 2026 research pass. Re-check each rather than assuming it is still true:

1. `Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryScorer.swift` uses weights HRV 0.86, RHR 0.04, respiration 0.07, sleep 0.03 and a logistic mapping fitted against one person's WHOOP export. Its sleep input is efficiency. Current recovery call paths appear to use raw RMSSD despite a research-fit document discussing log HRV.
2. `Strand/Data/IntelligenceEngine.swift` creates a baseline from all `repo.days` before looping over past days. It passes the same baseline into historical calculations. Audit future-data leakage, ordering, self-inclusion and reproducibility.
3. That baseline path explicitly mixes imported WHOOP vitals and NOOP-computed vitals with different measurement methods.
4. `SleepStager.swift` labels missing-gravity epochs as `wake`, while comments call them unscored. Stage selection uses maximum deep/REM shares of 17%/22%, no REM during the first 30 minutes, and deep restricted to the first half.
5. `SleepVitals.swift` already uses median valid five-minute RMSSD and lower-quartile-window HR. `HRVAnalyzer.analyzeTimed` already protects against some false adjacency after rejected beats/gaps. Preserve these fixes and verify every alternative call path.
6. The sleep-vitals gates include six valid windows, 60% HR sample coverage, 50% beat coverage, 60 clean intervals and 80% retained intervals. These are current engineering choices, not established universal validity cutoffs.
7. `AppleHealthAggregator.swift` preserves SDNN in its typed fields but also publishes a generic `hrv` key. Trace all consumers before asserting or fixing a metric collision.
8. New respiratory estimation reconstructs elapsed time from RR lengths and receives value arrays from sleep vitals. Audit whether dropped packets can be compressed out of the time axis.

Start with `HRVAnalyzer.swift`, `SleepVitals.swift`, `SleepStager.swift`, `Baselines.swift`, `RecoveryScorer.swift`, `AnalyticsEngine.swift`, `IntelligenceEngine.swift`, import aggregators, storage types and their tests.

## Scientific guardrails

Wearables infer sleep stages from peripheral signals; PSG is the reference for staging. Sleep detection can be strong while quiet-wake detection and stage classification remain substantially weaker. Do not apply a published commercial-device accuracy number to NOOP. Do not turn a population-average stage distribution into an individual-night constraint. [Chinoy 2021](https://pubmed.ncbi.nlm.nih.gov/33378539/), [Schyvens 2025](https://pubmed.ncbi.nlm.nih.gov/40303381/).

Recovery is multidimensional. Validation of HR or HRV does not validate a proprietary composite score. Keep autonomic status, sleep sufficiency, unusual vital signs and subjective readiness distinguishable. A logistic score is an index unless calibrated to a specifically defined event; it is not a literal percentage recovered. [de Zambotti 2024](https://academic.oup.com/sleep/article/47/4/zsad325/7501518).

## Priority 1: provenance, time and missing data

Implement a typed metric identity carrying metric definition, units, source/device, hardware and algorithm version where known, measurement context, aggregation method, timestamps, validity, coverage and exclusion reasons. Preserve unknown metadata explicitly. Keep imported values distinct from locally calculated values.

Partition baseline state by compatible measurement identity. SDNN and RMSSD never share a baseline. Do not silently merge daytime spot checks, paced breathing, nighttime window medians or whole-night summaries. A source/method change needs a new calibration period or a separately validated overlap-based migration.

For score at t, use only eligible prior observations. Compute the score, then update the baseline. Replaying later observations must not change earlier outputs for the same data and algorithm version. Account for actual calendar gaps, DST and travel; a sparse list of valid records is not a sequence of consecutive nights. Preserve historical algorithm versions and manual corrections.

Represent sleep state with at least wake, asleepUnstaged, light, deep, REM and unknown, with off-wrist provenance. Missing data cannot count as wake, light or deep. Sleep/wake confidence and stage confidence are different. Do not invent numerical confidence probabilities from heuristic margins; use descriptive quality flags until calibration exists.

## Priority 2: trustworthy HRV and vitals

For accepted adjacent normal-to-normal intervals in milliseconds:

`RMSSD = sqrt(sum(successiveDifference²) / validAdjacentPairCount)`

`SDNN = sqrt(sum((NN − meanNN)²) / (N − 1))`

`pNN50 = 100 × count(abs(successiveDifference) > 50 ms) / validAdjacentPairCount`

Use original acquisition adjacency and timing; do not create a successive difference across a rejected beat or missing packet. Preserve multiple valid beats with the same coarse second timestamp using sequence information. Never derive HRV by applying these formulas to sparse bpm samples. Track pair count separately from clean interval count. [HRV standards](https://pubmed.ncbi.nlm.nih.gov/8598068/).

Retain raw data and rejection masks. Examine artifact rules against missed/extra beats and genuine high variability. Do not claim that a simple 20% local rule equals the full adaptive Lipponen–Tarvainen algorithm. Add a reference comparison or fixture-based evaluation before replacing the filter. [Artifact method](https://pubmed.ncbi.nlm.nih.gov/31314618/).

Preserve fixed-window summaries and add temporal coverage, contiguous-pair coverage and valid-window distribution over the night. Deduplicate packets without deleting genuine beats. Replace naive sample-count-as-time assumptions where sampling is variable. Thirty valid minutes clustered at onset must not automatically establish a representative whole-night measurement.

Keep overnight mean HR, low-quantile overnight HR, minimum-window HR and awake resting HR separate. The present lower-quartile choice is a candidate aggregation, not a universal resting-HR definition. Do not condition all recovery HRV on a guessed deep-sleep stage: stage errors would contaminate HRV selection.

For log HRV use `x = ln(RMSSD / 1 ms)` with positive finite values and matching historical transformation. Refit or re-version any coefficients previously fitted in raw units. Candidate robust reference:

`center = median(prior eligible x)`

`scale = max(1.4826 × median(abs(x − center)), noiseFloor)`

`z = (x − center) / scale`

Do not confuse median absolute deviation's 1.4826 factor with the existing mean-absolute-deviation approximation of 1.253. Floors belong to the estimator's actual units. For EWMA, use a clearly specified observation-time or calendar-time convention; time-based `alpha = 1 − 2^(−elapsedDays / halfLifeDays)` is an option, not a validated recovery rule. Compare short-term trend and slower personal reference. Distinguish physiological anomalies from corrupted signals; unusual valid nights can remain visible even when baseline updating is limited.

Respiratory estimates from RR require continuity, a trustworthy time axis and respiratory-signal quality. Preserve gaps before any resampling. Convert frequency with `breathsPerMinute = 60 × Hz`. Separate direct respiration samples from inferred respiratory sinus-arrhythmia estimates. Do not reward arbitrarily low respiratory rate. Without reference validation, keep the estimator experimental and exclude it from confident recovery claims. [Charlton review](https://pubmed.ncbi.nlm.nih.gov/29990026/).

## Priority 3: sleep metrics with explicit denominators

Implement or correct:

- Total sleep time: union of intervals known/estimated asleep, including unstaged sleep.
- Primary sleep and naps: preserve separate episodes; compute 24-hour sleep without overlap or double counting.
- Time in bed / attempt-to-sleep: require an actual boundary source or clearly label an inferred rest/sleep-period window.
- Sleep efficiency: `100 × TST/TIB` only when TIB and coverage justify it. Efficiency does not equal sleep sufficiency.
- Sleep onset latency: onset minus attempt time; unavailable if attempt time is unknown.
- WASO: observed wake after onset and before final awakening, with the convention and missingness reported.
- Stage durations and coverage: do not force light/deep/REM to sum to all sleep when some sleep is unstaged. Label classified-sleep fractions separately from whole-sleep fractions.
- Wake bouts: explicit duration/merge policy; never call these EEG arousals.
- With S observed sleep minutes and U unknown minutes, `[S,S+U]` can describe missingness bounds, but it is not a statistical confidence interval or protection against classifier error.

Implement SRI only if full-day sleep/wake observation quality supports it:

`SRI = 200 × validPairAgreementAt24Hours − 100`

Use only pairs where both states are known and include naps. The theoretical range is −100 to 100. Do not fabricate observed wake outside detected sleep or silently clip the index. Preserve an exact-24-hour reference implementation; a same-local-clock regularity metric is a separately named variant. Bedtime and wake-time variability require circular statistics. [SRI methods](https://pmc.ncbi.nlm.nih.gov/articles/PMC5468315/).

For duration adequacy, start with a transparent user target supported by appropriate age/context guidance. Do not infer exact sleep need from chronically curtailed habitual sleep. Track an observed shortfall such as `max(0,target−sleep24h)` with completeness. A debt-decay formula and repayment rate are hypotheses, not settled constants. Do not let high efficiency on four hours produce “excellent sleep sufficiency.” [Adult consensus](https://pubmed.ncbi.nlm.nih.gov/26039963/), [sleep restriction experiment](https://pubmed.ncbi.nlm.nih.gov/12683469/).

## Priority 4: stage estimation and recovery model

Remove hard stage quotas from any claim of measured sleep architecture. Simply deleting quotas does not create a validated classifier. Keep experimental estimates explicitly labeled, support abstention/asleepUnstaged, and preserve a legacy comparison path. Temporal priors must be soft and tested; unusual patterns must not be erased merely because they are uncommon.

Inventory sensor resolution before choosing a model. Sparse gravity vectors are not interchangeable with high-frequency raw acceleration; occasional HR is not raw PPG. Prototype a reproducible binary model first. If data permit, evaluate a learned four-state classifier with temporal context. Public data can support prototyping, but source-to-target transfer needs validation on NOOP's actual signals. [Walch dataset](https://www.physionet.org/content/sleep-accel/1.0.0/), [author code](https://github.com/ojwalch/sleep_classifiers), [Oura feature study](https://pmc.ncbi.nlm.nih.gov/articles/PMC8271886/), [SleepPPG-Net](https://peterhcharlton.github.io/publication/kotzen-2022/).

Create separate explainable outputs for sleep sufficiency, autonomic deviation/trend, unusual vitals, and optional self-report. Keep the WHOOP-export-fitted recovery model versioned as a legacy heuristic. Do not replace its weights with equally arbitrary “scientific” numbers. If a new composite is needed before outcome data exist, make it explicitly experimental, show inputs and missingness, expose coefficients as configuration, and do not present clinically meaningful bands without evidence.

Missing drivers must not silently make a different model look equally trustworthy. Require sufficient primary inputs or report a partial result. Higher HRV and lower HR are not unconditionally better; inspect implausible extremes and contextual changes. Avoid counting correlated HRV-derived stress, respiration and HRV itself as three independent confirmations.

Add a minimal optional morning check-in for fatigue, soreness, sleep quality and perceived readiness if consistent with project scope. Use task-specific outcomes to evaluate useful predictions, not the score's own ingredients. Subjective measures can add useful information; HRV-guided training evidence does not justify universal “push/rest” prescriptions. [Self-report review](https://pubmed.ncbi.nlm.nih.gov/26423706/), [HRV-guided training meta-analysis](https://pmc.ncbi.nlm.nih.gov/articles/PMC8507742/).

Keep skin-temperature versus core-temperature semantics, oxygen quality, menstrual-cycle context, medication, travel and illness in mind. Do not infer diagnoses or causes from generic deviations. Show associations and uncertainty. Do not convert an observed association between sleep regularity and mortality into personalized lifespan advice.

## Lessons from company publications

Use these for design context, not hidden formula reconstruction:

- [Apple stage paper](https://www.apple.com/health/pdf/Estimating_Sleep_Stages_from_Apple_Watch_Oct_2025.pdf): richer acceleration and quiet-wake modeling; [sleep score](https://support.apple.com/en-eg/108906): duration, consistency and interruptions.
- [WHOOP](https://support.whoop.com/s/article/WHOOP-Recovery): public inputs, undisclosed weights/interactions. Historical measurement protocols may differ from today's.
- [Oura](https://ouraringhelp.zendesk.com/hc/en-us/articles/360057791533-Readiness-Contributors): acute contributors plus longer-term balance.
- [Polar](https://www.polar.com/img/static/whitepapers/pdf/polar-nightly-recharge-white-paper.pdf): distinct sleep and autonomic components with a specified measurement window.
- [Garmin](https://www.garmin.com/en-US/garmin-technology/running-science/physiological-measurements/training-readiness/): load, recovery time, sleep and autonomic context.
- [Google/Fitbit 2026 report](https://research.google/pubs/performance-analysis-of-updated-sleep-tracking-algorithms-across-google-and-fitbit-wearable-devices/): distinguish session/time-attempting-sleep detection from staging. Listed as “to appear”; do not describe it as confirmed independent peer-reviewed validation.

## Acceptance tests and evaluation

Write tests that verify scientific/accounting invariants and real failure cases, not just duplicate the implementation:

1. Hand-checkable contiguous NN fixture yields correct RMSSD/SDNN/pNN50. A rejected beat or packet gap creates no artificial adjacent pair.
2. Duplicate packets do not increase valid coverage or alter metric values; two legitimate beats within one second remain distinct.
3. Missing/off-wrist epochs do not become wake, sleep or stage minutes. All-unknown input produces unavailable metrics.
4. Four efficient hours remain four hours and cannot be classified as adequate against an eight-hour target.
5. Overlapping imports, naps across midnight, travel and 23/25-hour DST days preserve elapsed durations without double counting.
6. 23:55 and 00:05 have a sensible circular midpoint/dispersion. Regularity calculations use only valid pairs; constant identical schedules produce SRI 100.
7. SDNN never enters an RMSSD baseline. Device/algorithm/window changes trigger explicit compatibility handling.
8. Adding a future night cannot alter an earlier score; scoring then updating differs correctly from including the current night in its reference. Replays are deterministic and idempotent.
9. Cold start, zero variance, stale history, nonfinite data and insufficient temporal coverage produce appropriate states rather than fake population-average recovery.
10. A poor-quality extreme HRV value cannot produce a confident maximum recovery. Missing input behavior and component contributions are stable and explained.
11. Inferred respiration preserves gaps and passes synthetic known-frequency checks, while recognizing that these tests do not establish physiological accuracy.
12. Manual edits, imported authoritative records and original raw samples survive migration/recomputation with provenance.

For sleep validation build a reproducible evaluation harness with participant-held-out splits, per-stage confusion matrices/precision/recall/F1, macro-F1, sleep sensitivity, wake specificity, kappa, duration and boundary errors, bias/limits of agreement, coverage and failure rate. Fit preprocessing only on training subjects. Report participant-clustered uncertainty, not falsely independent epoch-level intervals. [Evaluation framework](https://pubmed.ncbi.nlm.nih.gov/32882005/).

For recovery, compare with sleep-only, HRV-only, self-report-only and persistence baselines on future time blocks and held-out participants as appropriate. Separate predicting subjective readiness from predicting performance. Never use agreement with WHOOP as the sole endpoint. Without reference/outcome data, report “implemented and tested,” not “validated accuracy improved.”

## Deliverables

Produce concrete code changes in a sensible sequence, appropriate migration/versioning, meaningful tests, updated calculation documentation and a concise change report. For every new metric specify inputs, units, equation, aggregation/window, data-quality requirements, missingness behavior, baseline compatibility and evidence status. Explain which observed defects were fixed, what tests passed, what changed in sample outputs if available, and which accuracy claims still require external data. Finish with the next highest-value validation experiment and its actual data requirements.

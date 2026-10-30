# Claude prompt: improve NOOP workout detection and strain

Copy the text below into Claude. If Claude can access this repository, also have it read `docs/WORKOUT_STRAIN_RESEARCH_2026-10-30.md`. The prompt includes the essential requirements independently of that file.

---

You are improving NOOP's workout detection, training-load calculations, and strain presentation. Act as a careful wearable-signal engineer and sports-science researcher. Implement defensible improvements in the repository, with tests and documented limitations. Do not merely propose a more elaborate score or tune results to resemble WHOOP.

Read repository instructions and inspect the current working tree first. Preserve existing user changes, especially ongoing sleep/recovery, causal replay, and transactional derived-storage work. Recheck the findings below against current code; they describe a review on 2026-10-30, not immutable facts. Work incrementally. Do not erase raw data, overwrite imported workouts, or trigger destructive historical rescoring. Implement and validate changes before any optional production-data migration.

## Scientific and product requirements

Separate five concepts:

1. Detecting an episode that may be exercise.
2. Classifying its activity type.
3. Measuring cardiovascular load from supported HR observations.
4. Recording perceived effort and exercise-specific resistance-training work.
5. Predicting recovery, adaptation, or injury.

Success at one does not establish validity of the others. HR-derived load is not muscular strain, calories, tissue damage, or recovery hours. A 0–21 display score is a versioned NOOP index unless independently validated; fitting another product's outputs does not reproduce its proprietary algorithm or validate physiology.

Use these evidence anchors:

- Internal/external load and multiple measures: [Bourdon 2017](https://pubmed.ncbi.nlm.nih.gov/28463642/), [Impellizzeri 2019](https://pubmed.ncbi.nlm.nih.gov/30614348/).
- Session-RPE: [Foster 2001](https://pubmed.ncbi.nlm.nih.gov/11708692/).
- Wearable HR validation: [INTERLIVE 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8273688/).
- HRmax population estimate: [Tanaka 2001](https://pubmed.ncbi.nlm.nih.gov/11153730/).
- Free-living recognition: [CAPTURE-24](https://www.nature.com/articles/s41597-024-03960-3), [Yuan 2024](https://www.nature.com/articles/s41746-024-01062-3).
- Resistance-exercise recognition limitations: [Brennan 2025](https://pubmed.ncbi.nlm.nih.gov/40745224/).
- Injury-prediction limitations: [Impellizzeri 2020](https://pubmed.ncbi.nlm.nih.gov/32502973/).
- Transparent manufacturer designs: [Polar technical paper](https://www.polar.com/en/img/static/whitepapers/pdf/polar-training-load-pro-white-paper.pdf), [Google 2025 white paper](https://arxiv.org/html/2508.11613v2). Label manufacturer evidence separately from independent studies; the Google source is a white paper/preprint.

Do not claim a comprehensive full-text review from abstracts. Cite any additional scientific claims you introduce. Document engineering choices as choices, not findings from research.

## Audit the entire path

Inspect `WorkoutDetector.swift`, `StrainScorer.swift`, `HRQuality.swift`, `AnalyticsEngine.swift`, `Strand/Data/IntelligenceEngine.swift`, models, storage, source-merging behavior, UI consumers, and relevant tests/tools.

Find all duplicate implementations and document how inputs reach the displayed result. Specifically verify:

- Motion is currently computed in the detector but not used in its HR-only trigger.
- An active HR run can span a long timestamp gap; minimum duration uses elapsed span.
- Legacy load paths infer every sample's duration from the first two timestamps.
- The timed load path caps credit at five seconds and adds one final second; coverage uses a different 60-second cap and can mishandle exclusions/boundaries.
- Minimum sufficiency is sometimes 600 rows rather than supported duration.
- “Edwards” currently uses HRR zones; fitted WHOOP uses HRmax zones; displayed zone statistics can therefore mean something else again.
- Session and daily HRmax fallbacks differ; the observed percentile/Tanaka-floor rule is not a measured personal maximum.
- Session average/zone summaries are sample-weighted, not time-weighted.
- Detector scoring and persisted workout scoring use different calculation paths.
- Daily load depends on detected sessions, a filtered high-HR fallback, and an invented rest-day floor.
- Banister coefficient/aggregation conventions are implicit; the logarithmic score can exceed its advertised bound.
- Overlap reconciliation keeps the longer workout, potentially discarding distinct activity.

Treat these as audit leads. Do not report a production bug as reproduced unless you actually reproduce it.

## First deliverable: one time-accounting and quality layer

Create a canonical non-overlapping interval representation shared by load, coverage, mean HR, zone time, and session summaries.

Define sample support from the acquisition contract. A point observation is not proof of continuous HR until the next point. If a bounded hold or interpolation is used, declare its maximum duration and identify it as estimated support. Do not bridge unknown gaps as measured exercise. Handle timestamp units, ordering, source collisions, duplicates, and invalid/nonfinite values deterministically.

Use half-open `[start,end)` ranges and exact interval intersection/subtraction. Clip at workout/day boundaries, known pauses, and exclusions. Midnight/DST day lengths must follow the declared timezone; do not assume every civil day is 86,400 seconds. Store elapsed, observed, active, paused, and unknown duration separately where applicable.

Calculate:

```text
mean_HR = sum(HR_i * supported_seconds_i) / sum(supported_seconds_i)
zone_minutes[z] = sum(supported_seconds in zone z) / 60
coverage = duration(union(valid support)) / requested_duration
```

Replace row-count sufficiency with duration and coverage. Missing is not zero. An incomplete day must not appear as a confidently low-load day. Never scale a short recorded period to an assumed complete day without a distinct, explicitly experimental estimation model.

Store raw metric, unit, algorithm version, calibration snapshot, input/source identity, quality/coverage, and relevant timestamps. Missing outputs need reason codes. Numeric confidence should not masquerade as a calibrated probability if no calibration study exists.

## Calculations and naming

Implement a clear method registry rather than loosely interchangeable “strain” formulas.

**Edwards:** weighted minutes in %HRmax bands 50–60, 60–70, 70–80, 80–90, 90–100 with weights 1–5, zero below 50%. Define exact boundary behavior and flag HR above configured maximum. Ten minutes in each band yields 150 arbitrary units. If retaining an HRR-zone variant, give it a different name. [Published method example](https://pmc.ncbi.nlm.nih.gov/articles/PMC7240108/).

**Banister-style:** `x=(HR−HRrest)/(HRmax−HRrest)`. Validate the denominator and explicitly define out-of-range behavior. Conventional session-mean form is `T_minutes*x_mean*a*exp(b*x_mean)`. Conventional coefficient pairs are `.64/1.92` and `.86/1.67`. [Primary methods example](https://pmc.ncbi.nlm.nih.gov/articles/PMC10944953/).

An integrated variant is `sum(dt_minutes*x_i*a*exp(b*x_i))`. It is not numerically identical to applying the exponential to session-average HR. Polar describes second-by-second computation; Google publishes its own minute-level modified formulation and shares `.64` across its exponents. Specify which model NOOP implements rather than mixing conventions. Do not infer model coefficients from gender identity or invent an unsupported average.

For additive daily accounting use an explicitly integrated metric. Session-mean nonlinear TRIMP is not generally invariant to session splitting. Keep it separate if retained for comparison.

**Session RPE:** actual user-reported RPE × consistently defined session minutes. Store scale, collection time, and provenance. Missing RPE remains missing. Do not name an HR-derived estimate “user RPE.”

**Strength:** exercise identity, sets, reps, external load, optional RIR; volume load is `sum(reps*kg)` under declared conventions. It is not joules or universal muscle damage. Avoid unsupported multipliers based solely on workout category or duration. Automatic reps/exercise recognition requires a separate labeled evaluation.

**Power, if available:** mechanical work is `sum(watts*seconds)/1000` kJ. Power-based TSS requires defined normalized power, FTP, and `100*hours*(NP/FTP)^2`; do not substitute average HR or HRR. [Formula](https://www.trainingpeaks.com/learn/articles/estimating-training-stress-score-tss/).

Do not expand into calorie-model redesign unless required to stop misleading reuse of those values as load evidence.

## HR calibration

Use one calibration snapshot for detection, load, and displayed zones. Store HRmax/resting-HR values, sources, effective dates, and uncertainty. A documented user override or credible measured maximum can be below Tanaka's population prediction. A normal day's upper HR percentile is not a maximal test.

Use `208−.7*age` only as a labeled estimate when appropriate. Avoid hidden age-30/RHR-60 fallbacks presented as measured personal values. Declare the resting-HR protocol: overnight minimum and standardized awake resting HR are not automatically interchangeable.

Keep historical calculations causal and reproducible. Adding future data must not silently change an earlier day's calibration/result. Explicit retrospective recalculation is a separate versioned operation. Calibration should not drift simply because a workout window was split differently.

## Daily load and the display index

Compute raw integrated load on unique supported intervals independently of workout grouping, then attribute it to sessions or incidental activity. Define all-day HR-derived load separately from exercise-attributed load. HR elevation without activity evidence can remain unclassified; it must not automatically become a confirmed workout.

Do not add logarithmic session scores to obtain daily strain. Sum compatible raw load and apply the display transformation once. Enforce finite, bounded, monotonic output with documented saturation. Retain raw units, version the mapping, and remove the fabricated rest-day floor from measurement-grade results. Preserve legacy results as legacy where compatibility requires it.

Seven/28-day summaries should expose valid-day coverage and compare like units/versions. Do not present acute:chronic ratios as injury-risk probabilities, safe zones, or justified prescriptions. Do not convert a strain value directly into recovery hours.

## Workout detector

Implement explicit inactive/candidate/active/paused/unknown/ended states or an equivalent testable model. Separate sensor gaps from observed pauses. Require sufficient supported evidence, not just wall duration. Explain and tune thresholds on labeled data; they are engineering parameters.

Audit whether the available motion channel is raw accelerometry, a gravity vector, or a sparse summary. Verify sample rate, units, placement, and synchronization. Do not transplant raw-accelerometer models into an incompatible representation. When input is insufficient, retain HR-only uncertainty rather than inventing motion features.

Use motion as contextual evidence without categorically rejecting still-wrist cycling/strength activity. Allow manual and imported sessions, including short workouts. Preserve user corrections and provenance. Add activity labels only when validated. Reconcile overlapping sessions through stable identity/source rules rather than keeping whichever row is longest.

## Required tests and evaluation

Write focused regression tests demonstrating failures before fixes where practical:

1. Two high-HR points an hour apart do not establish an hour-long workout or load.
2. Constant supported HR gives the analytical load; equivalent representations at different sampling rates agree within declared tolerance.
3. Irregular timestamps, repeated ingestion, ordering, duplicates, and conflicting sources follow deterministic rules.
4. Gaps do not become observed time; a supported interval crossing an exclusion or midnight is clipped exactly.
5. Splitting/merging sessions preserves integrated daily raw load; duplicated session/import records do not double-count intervals.
6. No unsupported final sample credit; zero-duration windows and invalid calibration cannot produce nonfinite scores.
7. Edwards boundaries and each Banister coefficient/aggregation variant match independent numerical examples.
8. The display score is bounded and monotonic; missing input differs from measured zero.
9. Future observations do not alter earlier results under frozen calibration.
10. Detector, batch engine, persisted rows, and UI consume the same canonical metrics.

Evaluate detection with independently annotated sessions and ordinary negative days: event precision/recall/F1, false positives per observed day, onset/offset error, fragmentation, and merging. Predefine one-to-one matching/overlap criteria. Split by participant and recording session before windowing. Report per-activity errors and unknown-class behavior.

Validate HR against a suitable synchronized reference, and load arithmetic against that reference using the same disclosed formula. These checks do not establish a universal biological “true strain.” Validate perceived effort and strength outputs against their own references. Keep company-export agreement as a separate compatibility evaluation.

If no labeled corpus exists, build the evaluation interface and document that empirical accuracy remains unvalidated. Do not manufacture performance numbers or declare clinical validity because unit tests pass. Run appropriate package tests and a read-only replay comparison; inspect changed results and missingness. Preserve existing transaction/replay protections.

## Return

Deliver the implementation, tests, and a concise report covering: actual bugs found; calculation and behavior changes; method/source/version choices; test evidence; remaining unsupported claims; data needed for empirical validation; and any backward-compatibility or migration impact. Prioritize deterministic accounting and honest outputs before adding complex models.

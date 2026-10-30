# NOOP: workout detection, training load, and strain

Research and repository review: 30 October 2026. Companion: [Claude implementation prompt](CLAUDE_WORKOUT_STRAIN_PROMPT.md).

## Main recommendation

Build a trustworthy measurement pipeline before adding a more elaborate strain formula. Detecting a workout, measuring its cardiovascular demand, recording strength-training work, and predicting recovery are different tasks. Give each its own inputs, uncertainty, and validation.

For NOOP, prioritize: correct elapsed-time accounting; explicit missing-data handling; reproducible heart-rate calibration; workout detection that uses available evidence; separate cardio, perceived, and strength metrics; and evaluation on unseen people and everyday non-workout activity. Retain any 0–21 score as a versioned presentation index, with the underlying load visible.

This is a targeted research synthesis, not a systematic review or proof that every paper was read in full. The source register distinguishes peer-reviewed research, reviews/consensus, manufacturer documentation, and a manufacturer preprint. Some papers were accessible through abstracts or indexed methods; numerical claims are deliberately limited. Manufacturer documentation describes product behavior, not independent validation. Repository observations reflect the working tree at review time, which already contains ongoing sleep/recovery changes. No application code was changed for this report.

## 1. Findings that should change the product

### Training load has multiple dimensions

External load describes work performed; internal load describes the person's response. Heart rate, perceived exertion, power, and resistance-training volume are related but not interchangeable. A scalar can be useful for summarization without being a universal measure of physiological damage or adaptation. NOOP should retain distinct underlying measures rather than add correlated proxies together without validation. [Bourdon et al., 2017](https://pubmed.ncbi.nlm.nih.gov/28463642/), [Impellizzeri et al., 2019](https://pubmed.ncbi.nlm.nih.gov/30614348/).

**Product consequence:** offer cardiovascular load, user-reported session effort, and exercise-specific strength volume as separate fields. Unsupported dimensions remain unavailable. A low cardio score during lifting must not be described as an easy muscular session.

### Heart-rate elevation does not establish that a workout occurred

Heart rate reflects physiological context as well as physical work. Activity recognition needs evidence beyond a universal HR threshold. Conversely, a quiet wrist does not establish inactivity: cycling, carrying loads, and some resistance exercises can involve little wrist movement. Motion should inform confidence rather than become an unconditional veto for every sport. [Buchheit, 2014](https://pubmed.ncbi.nlm.nih.gov/24578692/), [Yuan et al., 2024](https://www.nature.com/articles/s41746-024-01062-3).

**Engineering recommendation:** separate candidate episode detection from activity classification. With HR-only input, use “possible activity” or an uncertain episode rather than confidently naming a sport. Manual starts, user corrections, and imported sessions provide useful context, with explicit provenance.

### Laboratory classification accuracy does not establish free-living workout detection accuracy

CAPTURE-24 contains 151 participants and 2,562 annotated hours of everyday behavior. Its relevance is the diversity of ordinary activity surrounding exercise. Yuan and colleagues demonstrate the value of large-scale accelerometer pretraining, but their results do not establish performance on NOOP's sparse motion representation or device. [CAPTURE-24](https://www.nature.com/articles/s41597-024-03960-3), [Yuan et al.](https://www.nature.com/articles/s41746-024-01062-3).

**Product consequence:** evaluate false workouts per day as well as recall of known workouts. Include commuting, chores, standing, carrying bags, hand gestures, vehicle vibration, sensor removal, and elevated HR without exercise. Split participants and recording sessions before generating overlapping training windows.

### Wrist HR accuracy and calorie accuracy are separate questions

Shcherbina and colleagues compared seven devices with reference measurements in 60 participants; HR performed substantially better than energy-expenditure estimates. These historical devices do not quantify current NOOP accuracy. INTERLIVE provides a stronger framework for validating HR under the actual activities, populations, and conditions of use. [Shcherbina et al., 2017](https://pubmed.ncbi.nlm.nih.gov/28538708/), [INTERLIVE, 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8273688/).

**Product consequence:** quality-check HR before scoring, retain sensor/source information, and report activity-specific errors. Do not treat calories as a second independent confirmation of strain when both are derived from the same HR stream.

### Resistance-training detection and resistance-training dose need different validation

A 2025 systematic review included 44 exercise-classification studies. Results depended on the technology and the exercises being distinguished; recognizing similar movements remains a challenge. Correctly recognizing “squat” does not measure the lifted load, repetitions in reserve, muscle damage, or recovery time. [Brennan et al., 2025](https://pubmed.ncbi.nlm.nih.gov/40745224/).

**Product consequence:** start with exercise, sets, repetitions, external load, and optional repetitions in reserve (RIR) or session RPE. Treat automatic exercise/repetition recognition as a separately evaluated feature. Velocity-based metrics require a validated measurement method and exercise-specific interpretation. [Resistance-training monitoring review](https://pmc.ncbi.nlm.nih.gov/articles/PMC7706636/), [RIR–velocity study](https://pubmed.ncbi.nlm.nih.gov/38418370/).

### Age-predicted HRmax is an estimate, not a personal lower bound

Tanaka's population equation is `208 − 0.7 × age`. Individual measured HRmax can be below the equation. A high percentile of one day's ordinary HR is not automatically a valid maximum either. [Tanaka et al., 2001](https://pubmed.ncbi.nlm.nih.gov/11153730/).

**Engineering recommendation:** store the value, source, measurement date, confidence, and effective dates. Prefer credible measured/user-entered calibration over a population fallback. Use quality-controlled history for candidate updates; do not silently increase HRmax from an artifact or reduce it after an easy week. Freeze the calibration used for a historical result unless the user requests an explicitly versioned retrospective recalculation.

### Load history does not justify an injury-risk or recovery-hours prediction

Acute:chronic workload ratios have conceptual and statistical problems; association does not establish that changing a ratio prevents injury. Seven- and 28-day summaries can describe recent training without supporting a “safe zone.” [Impellizzeri et al., 2020](https://pubmed.ncbi.nlm.nih.gov/32502973/).

**Product consequence:** use “higher than your recent recorded load,” with coverage, rather than “unsafe” or “fully recovered in 24 hours.” A recovery prediction needs its own prospective outcome study.

## 2. Calculations worth implementing correctly

### Shared time and quality foundation — engineering specification

Represent each usable observation as a supported time interval. A timestamp alone is not proof of continuous measurement until the next timestamp. Define support using the acquisition contract and a documented maximum hold/interpolation policy. A bounded hold is an estimate and must be labeled accordingly; it is not evidence that a gap was measured.

For each non-overlapping interval `i`:

```text
dt_i = duration of valid interval intersected with the requested range, seconds
observed_minutes = sum(dt_i) / 60
mean_HR = sum(HR_i * dt_i) / sum(dt_i)
zone_minutes[z] = sum(dt_i for intervals in z) / 60
coverage = duration(union(valid support)) / duration(requested window)
```

Use half-open intervals `[start, end)`. Clip at day, workout, pause, and exclusion boundaries. Remove overlaps before summing. Unknown intervals stay unknown; do not fill them with resting HR, zero exercise, or an extrapolated full-day score. Distinguish elapsed duration, observed duration, active duration, known pauses, and missing duration. Qualify active duration by the method used to classify it.

Minimum data requirements must use observed seconds and coverage, not row counts. Account for conflicting duplicate timestamps through stable source/quality precedence. Resampling invariance applies when the samples represent the same supported signal; sparse point samples cannot recover unobserved fluctuations.

### Edwards zone load

The commonly used Edwards definition is weighted time in **percentage-of-HRmax** zones:

```text
q = HR / HRmax
weight = 0 below 0.50
         1 in [0.50, 0.60)
         2 in [0.60, 0.70)
         3 in [0.70, 0.80)
         4 in [0.80, 0.90)
         5 in [0.90, 1.00]
Edwards load = sum(zone_minutes[z] * weight[z])
```

Published implementations include this zone formulation in [the ballet session-RPE study](https://pmc.ncbi.nlm.nih.gov/articles/PMC7240108/). Treat HR above the configured maximum as a calibration/quality flag and document its scoring policy; do not silently rewrite HRmax mid-session. Ten minutes in each nonzero zone gives **150 arbitrary units**. HRR zones are a legitimate alternative convention, but must not be silently substituted under this method name.

Example: HR 120, resting HR 60, HRmax 180 gives 66.7% HRmax but 50% HRR. Those are different intensities and produce different zone assignments.

### Banister-style TRIMP: specify which version

Let `x = (HR − HRrest)/(HRmax − HRrest)`. Validate `HRmax > HRrest`; flag out-of-range observations and document any clipping.

```text
Session-mean version:
T * x_mean * a * exp(b * x_mean), where T is minutes

Time-integrated version:
sum((dt_i / 60) * x_i * a * exp(b * x_i))
```

Conventional coefficient pairs are `(a=.64, b=1.92)` and `(a=.86, b=1.67)` for the historical male/female formulations. These are population conventions, not individualized lactate curves. An accessible primary study explicitly reports both pairs. [2024 experimental study](https://pmc.ncbi.nlm.nih.gov/articles/PMC10944953/).

Because the weighting is nonlinear, averaging HR before applying it differs from integrating interval values. The session-mean metric is also not generally invariant to splitting a variable-intensity session. Use an explicitly named integrated variant when additive interval accounting is required; do not add session-mean TRIMPs and claim segmentation invariance.

A complication worth preserving: Google's 2025 white paper explicitly uses `.64` with both sex-specific exponents in its modified approach. Thus a shared `.64` is not inherently a coding error in every model; it is a mismatch if NOOP claims the conventional female Banister formula. Choose and cite the intended model rather than mix conventions. [Google white paper](https://arxiv.org/html/2508.11613v2).

Do not infer a coefficient from gender identity or invent a “nonbinary physiological average.” Declare the model assumption and allow an unknown/unconfigured state. More precise individualized TRIMP requires additional calibration data; it cannot be obtained by relabeling generic weights.

### Session RPE

```text
session_RPE_load = session_duration_minutes * user_reported_session_RPE
```

Use a defined scale and a consistent post-session collection protocol. Store the actual response and time collected. Foster's study supports its practical use across cycling and basketball; its absolute units differed from the HR comparison. Missing RPE is missing, not zero. An HR-derived effort estimate must have a different field from user-reported RPE. [Foster et al., 2001](https://pubmed.ncbi.nlm.nih.gov/11708692/), [Haddad et al., 2017](https://pmc.ncbi.nlm.nih.gov/articles/PMC5673663/).

Example: 45 minutes × RPE 7 = **315 arbitrary units**. That is not 315 TRIMP, calories, or a muscle-damage measurement.

### Strength and power

```text
external volume load = sum(repetitions * external mass_kg), per exercise
mechanical work_kJ = sum(power_watts * dt_seconds) / 1000
```

Volume load needs consistent conventions for unilateral movements, dumbbells, machines, bodyweight, assistance, range of motion, and partial reps. Do not silently add full body mass to every lift. Keep sets, reps, load, exercise identity, and optional RIR alongside the aggregate. The same tonnage across different exercises is not equivalent tissue stress. [Resistance-training monitoring review](https://pmc.ncbi.nlm.nih.gov/articles/PMC7706636/).

Mechanical work requires measured or separately validated estimated power. For power-based cycling TSS, `IF = normalized_power / FTP` and `TSS = 100 × duration_hours × IF²`. It requires the defined normalized-power procedure and credible FTP; average power or HRR is not a drop-in replacement. [TrainingPeaks formula](https://www.trainingpeaks.com/learn/articles/estimating-training-stress-score-tss/).

### A display score is a separate model

First calculate additive observed load `L`; then map it to a presentation score once. A possible **engineering choice, not a validated physiological formula**, is `S = Smax × (1 − exp(−L/k))`, with `k > 0`. A clipped logarithmic mapping is another choice. Neither mapping establishes recovery need, comparability between people, or WHOOP equivalence.

Version the mapping, retain raw units, disclose saturation, and test monotonicity and bounds. Do not invent a rest-day floor to imitate another product. Missing-day data must never produce a confident low-strain day. Daily exercise-attributed load and all-day HR-derived load should have separate definitions; elevated HR without movement can be shown as unclassified cardiovascular activity, not automatically awarded exercise credit.

### Trends

Summarize the same metric and version over time. Report valid-day counts and partial-day status. An optional descriptive exponential smoother is `E_t = αL_t + (1−α)E_previous`, with `α = 1−exp(−Δt/τ)`; define whether `τ` is a time constant, not a half-life. Do not insert zero for an unobserved day or manufacture a constant load over the gap. Seven/28-day averages and smoothing constants are product/model choices, not universal physiological recovery constants.

## 3. What major companies actually disclose

| Company | Public disclosure reviewed | Implication for NOOP |
|---|---|---|
| WHOOP | 0–21 strain incorporates cardiovascular and, in supported contexts, muscular demand. Public detection descriptions use HR and motion. | A fitted export curve is an imitation of outputs, not access to the production algorithm. [Strain](https://www.whoop.com/us/en/thelocker/how-does-whoop-strain-work-101/), [detection](https://www.whoop.com/us/en/thelocker/how-whoop-detects-and-labels-your-workouts-activities/) |
| WHOOP strength | Describes inertial sensing, biomechanics, and exercise logging; reports internal development/testing. | Do not interpret company claims of muscular stress as independent proof of tissue-load accuracy. [Development account](https://www.whoop.com/us/en/thelocker/the-research-and-development-behind-strength-trainer/) |
| Polar | Separates HR-based cardio load, power-derived work, and perceived load; its white paper describes second-by-second TRIMP. | Useful transparent architecture. Its particular status thresholds are not independent proof of injury prediction. [2025 white paper](https://www.polar.com/en/img/static/whitepapers/pdf/polar-training-load-pro-white-paper.pdf) |
| Garmin / Firstbeat | Describes training load derived from estimated EPOC; recent-load summaries use weighting. | A generic weighted HR sum is not a reproduced EPOC algorithm. [Firstbeat](https://www.firstbeat.com/en/science-and-physiology/epoc-and-training-effect/), [Garmin](https://www.garmin.com/en-US/garmin-technology/cycling-science/physiological-measurements/training-load/) |
| Apple | Effort and duration inform training load, comparing seven days with a 28-day baseline. | Preserve effort provenance and user correction. [Apple announcement](https://www.apple.com/ie/newsroom/2024/06/watchos-11-brings-powerful-health-and-fitness-insights/) |
| Google / Fitbit | Manufacturer white paper describes minute-level HRR weighting, movement evidence, a 30% HRR threshold, and down-weighting from 30–40%; includes incidental activity. | A useful documented modified-TRIMP design, not a peer-reviewed validation of NOOP or a universal threshold. [2025 white paper](https://arxiv.org/html/2508.11613v2) |
| TrainingPeaks | Publishes duration/normalized-power/FTP calculation for cycling TSS. | Reproducible when required inputs and conventions exist; not a universal lifting score. [Formula](https://www.trainingpeaks.com/learn/articles/estimating-training-stress-score-tss/) |

Current WHOOP documentation also describes personalized HRR zones. Do not assume the app's displayed zones reveal its full strain calculation, or that coefficients fit to an older export reproduce the current product. [WHOOP zones](https://www.whoop.com/us/en/thelocker/more-personalized-heart-rate-zones-with-whoop/).

## 4. Specific findings in NOOP's current code

These are static code findings, not reproduced production incidents. Reinspect the current revision before implementing changes.

| Priority | Location / finding | Required direction |
|---|---|---|
| P1 | `WorkoutDetector.detect` constructs `motion` but does not use it; actual trigger is the HR-only run detector. | Correct documentation and either use validated available motion evidence or expose HR-only uncertainty. |
| P1 | `hrOnlyRuns` can stay active across a timestamp gap without checking continuity; minimum duration uses wall-clock span. | Reset/mark missing gaps; require supported active duration and coverage. Two high-HR observations an hour apart must not establish an hour of exercise. |
| P1 | `sampleDurationMinutes` uses only the first two rows; legacy strain/Edwards/Banister paths reuse this duration for every row. | Replace with a shared interval accounting layer. Irregular input and ordering must not change the represented dose. |
| P1 | `whoopZoneLoadTimed` caps support at five seconds but always credits one final second; its comment says gaps add nothing. | Specify bounded hold versus observed support honestly, clip boundaries, and use one policy throughout. |
| P1 | `coveredSeconds` uses a different 60-second cap, removes excluded sample starts rather than subtracting interval overlaps, and does not fully clip credited spans. | Coverage and load must use the same interval union and exact exclusions. |
| P1 | `AnalyticsEngine` derives daily load from detected workouts, a high-HR fallback, and a coverage-scaled rest-day floor. | Compute additive load independently of episode splitting; remove fabricated floor from measurement-grade output. |
| P1 | “Edwards” weighting uses %HRR, while fitted WHOOP weighting uses %HRmax. Displayed zone percentages also use HRR. | Give each zone system an explicit ID; correct the Edwards definition or rename the variant. |
| P1 | Detector can estimate HRmax from the input day's 99.5th percentile, with Tanaka as a floor; day fallback uses a different route. | One versioned calibration snapshot across detection, session load, daily load, and zone display. |
| P2 | `minReadings = 600` is used as duration sufficiency. | Replace row count with supported seconds and coverage. |
| P2 | `boutIntensity`/average HR use sample counts rather than elapsed-time weighting. | Time-weight summaries consistently. |
| P2 | `.banister` integrates sample values but shares scale `.64`; method naming omits the distinction from session-mean/conventional female variants. | Explicit model/coefficients, separate numerical tests and migration version. |
| P2 | Detector session scoring uses the older `strain` path; persistence recomputes with `activityStrain`. | One canonical result consumed by persistence and UI. |
| P2 | `trimpToStrain` claims 0–21 but is not bounded at large TRIMP and does not validate its denominator. | Validate finite arguments and enforce the documented display range. |
| P2 | `highEffortLoad` filters hot points before joining, which can conceal intervening low/missing periods. | Evaluate continuity on the full supported timeline, preserving unknown and inactive states. |
| P2 | `IntelligenceEngine` resolves overlapping detected workouts by retaining the longer row. | Reconcile event identity and provenance; overlap alone does not prove duplicates. Split/merge must not discard distinct activities. |

Relevant files: `Packages/StrandAnalytics/Sources/StrandAnalytics/{WorkoutDetector,StrainScorer,HRQuality,AnalyticsEngine}.swift`, `Strand/Data/IntelligenceEngine.swift`, and the current `WhoopStore` derived-write/cache models.

The fitted `.whoop` constants are described in code as fitted to 428 workouts and 628 days. Those counts and reported fitting errors are repository claims, not independently reproduced validation here. Holding out dates from one person tests that person's temporal generalization; it does not establish generalization to other people or devices.

## 5. Implementation and validation plan

### First: deterministic measurement correctness

Create the shared supported-interval representation, explicit quality states, frozen calibration, canonical zone definitions, and raw load outputs. Preserve imported records and existing user edits. Route batch analysis, persistence, and UI through the same calculation. Store algorithm version, input identity, source, calibration snapshot, and coverage.

Use analytic fixtures for constant HR, threshold crossings, irregular cadence, duplicates, conflicting sources, long gaps, midnight, daylight-saving changes, and explicit pauses. A sample-support interval that crosses midnight must be split precisely, not assigned twice. For integrated load, splitting or merging episodes must preserve the daily raw load. Do not impose this invariant on the session-mean nonlinear TRIMP definition.

### Second: conservative workout candidates

Use a state machine such as inactive → candidate → active → paused/unknown → ended. Thresholds, dwell times, and gap tolerances are tunable engineering parameters, not established physiological laws. Keep low-confidence candidates distinct from confirmed sessions. Do not import WHOOP's approximate 15-minute auto-detection behavior as a universal minimum for meaningful exercise; short manually logged sessions remain valid.

Audit what motion data really represents: raw acceleration, gravity vector, derived activity, sampling rate, axis units, sensor placement, and synchronization. Do not apply raw-accelerometer pretrained models directly to sparse gravity summaries. Add sport labels only when the available input and validation support them.

### Third: strength and perceived load

Collect optional session RPE and exercise logs. Preserve measured versus user-entered versus inferred values. Provide exercise-specific strength trends. Add power-based metrics only when a suitable input exists. Keep an unknown state for muscular demand rather than generating a multiplier from workout duration alone.

### Fourth: evaluate each claim independently

| Claim | Reference / evaluation |
|---|---|
| Workout detection | Independently annotated starts/ends and non-workout time; one-to-one event matching; precision, recall, F1, false positives per observed day, onset/offset error, fragmentation and merging. Predefine overlap criteria. |
| Activity classification | Per-class precision/recall, confusion matrix, macro-F1, unknown-class behavior; unseen participants/devices and realistic competing activities. |
| HR accuracy | Synchronized ECG or a suitably validated reference, activity-specific error and bias/limits of agreement; participant-level uncertainty, including excluded/failed data. |
| Load arithmetic | Known synthetic trajectories and reference-HR calculations using the same disclosed formula. This validates arithmetic/sensor propagation, not “true strain.” |
| Perceived effort | Actual user RPE; evaluate separately from HR-derived targets. Correlation alone is not agreement or interchangeability. |
| Strength metrics | Logged/observed reps and loads, independently measured movement where needed; exercise-specific errors. |
| Recovery or performance prediction | Prospectively defined outcome, temporal availability, unseen participants, calibrated uncertainty, and comparison with simple baselines. A score from another wearable is not a physiological ground truth. |

Choose acceptable error rates before inspecting the held-out set. Report limitations where data are absent. Compare new and legacy outputs on a read-only historical replay; inspect disagreements, do not optimize merely for legacy similarity. Existing transactional derived-write/replay work should be reused, not replaced casually.

## 6. Research register

The references below are the core reading set, not a claim of 32 independent validations. Method papers, reviews, and company pages answer different questions.

1. [Bourdon et al. 2017 — Monitoring Athlete Training Loads](https://pubmed.ncbi.nlm.nih.gov/28463642/). Peer-reviewed consensus; framework for multiple load dimensions. Abstract/indexed text reviewed.
2. [Impellizzeri et al. 2019 — Internal and External Training Load: 15 Years On](https://pubmed.ncbi.nlm.nih.gov/30614348/). Peer-reviewed conceptual paper; definitions. Abstract reviewed.
3. [Foster et al. 2001 — A new approach to monitoring exercise training](https://pubmed.ncbi.nlm.nih.gov/11708692/). Original study; session-RPE. Abstract reviewed.
4. [Haddad et al. 2017 — Session-RPE Method for Training Load Monitoring](https://pmc.ncbi.nlm.nih.gov/articles/PMC5673663/). Peer-reviewed review; practical factors and validity. Indexed material reviewed.
5. [Impellizzeri et al. 2020 — ACWR conceptual issues](https://pubmed.ncbi.nlm.nih.gov/32502973/). Peer-reviewed critical analysis; injury-claim limitations. Abstract reviewed.
6. [Tanaka et al. 2001 — Age-predicted maximal heart rate revisited](https://pubmed.ncbi.nlm.nih.gov/11153730/). Original research; population HRmax equation. Abstract reviewed.
7. [Shcherbina et al. 2017 — Wrist HR and energy expenditure](https://pubmed.ncbi.nlm.nih.gov/28538708/). Original validation; distinct measurement errors. Abstract/indexed results reviewed.
8. [INTERLIVE 2021 — Wearable HR validation recommendations](https://pmc.ncbi.nlm.nih.gov/articles/PMC8273688/). Peer-reviewed expert statement; full text available and consulted.
9. [Buchheit 2014 — Monitoring training status with HR measures](https://pubmed.ncbi.nlm.nih.gov/24578692/). Peer-reviewed review; interpretation and context. Abstract/indexed material reviewed.
10. [Ballet study 2020 — Session-RPE validity](https://pmc.ncbi.nlm.nih.gov/articles/PMC7240108/). Original study; indexed methods include Edwards definition.
11. [Keytel et al. 2005 — HR prediction of energy expenditure](https://pubmed.ncbi.nlm.nih.gov/15966347/). Original research; relevant to NOOP's calorie coefficients, not a strain validation. Abstract reviewed.
12. [Yuan et al. 2024 — Self-supervised learning using 700,000 person-days](https://www.nature.com/articles/s41746-024-01062-3). Original research; full-text sections consulted for activity-recognition direction.
13. [Chan et al. 2024 — CAPTURE-24](https://www.nature.com/articles/s41597-024-03960-3). Peer-reviewed dataset descriptor; abstract and indexed text reviewed.
14. [PAMAP2 dataset, UCI](https://archive.ics.uci.edu/dataset/231/pamap2+physical+activity+monitoring). Primary dataset documentation; useful laboratory benchmark, limited transfer to daily life.
15. [Brennan et al. 2025 — Resistance-exercise classification review](https://pubmed.ncbi.nlm.nih.gov/40745224/). Systematic review; abstract and results reviewed.
16. [Methods for Regulating and Monitoring Resistance Training, 2020](https://pmc.ncbi.nlm.nih.gov/articles/PMC7706636/). Peer-reviewed review; indexed material reviewed.
17. [Methods of controlling/reporting proximity to failure, 2022](https://pubmed.ncbi.nlm.nih.gov/35247203/). Peer-reviewed review; useful follow-on for RIR field design. Abstract/indexed material reviewed.
18. [RIR–velocity relationship study, 2024](https://pubmed.ncbi.nlm.nih.gov/38418370/). Original research; exercise-specific velocity interpretation. Abstract/indexed methods reviewed.
19. [Experimental fatigue-judgment study, 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC10944953/). Original research; indexed methods explicitly state conventional Banister coefficient pairs.
20. [WHOOP strain explanation](https://www.whoop.com/us/en/thelocker/how-does-whoop-strain-work-101/). Manufacturer product documentation.
21. [WHOOP detection explanation](https://www.whoop.com/us/en/thelocker/how-whoop-detects-and-labels-your-workouts-activities/). Manufacturer product documentation.
22. [WHOOP personalized HR zones](https://www.whoop.com/us/en/thelocker/more-personalized-heart-rate-zones-with-whoop/). Manufacturer product documentation.
23. [WHOOP Strength Trainer research/development](https://www.whoop.com/us/en/thelocker/the-research-and-development-behind-strength-trainer/). Manufacturer research account; no independent validation inferred.
24. [WHOOP muscular-load explanation](https://www.whoop.com/us/en/thelocker/how-whoop-measures-muscular-load/). Manufacturer description of logged and estimated modes.
25. [Polar Training Load Pro white paper, revised March 2025](https://www.polar.com/en/img/static/whitepapers/pdf/polar-training-load-pro-white-paper.pdf). Manufacturer technical paper; calculation and limitations sections read.
26. [Firstbeat EPOC and Training Effect](https://www.firstbeat.com/en/science-and-physiology/epoc-and-training-effect/). Manufacturer scientific explanation.
27. [Garmin Training Load](https://www.garmin.com/en-US/garmin-technology/cycling-science/physiological-measurements/training-load/). Manufacturer product documentation.
28. [Garmin Acute Load manual](https://www8.garmin.com/manuals/webhelp/GUID-28E0106C-B05A-44E9-BF7C-9CB36A596B82/EN-US/GUID-AEDB0872-C5A1-4378-86D5-2239734B59E8.html). Manufacturer documentation of weighted recent load.
29. [Apple watchOS 11 training-load announcement](https://www.apple.com/ie/newsroom/2024/06/watchos-11-brings-powerful-health-and-fitness-insights/). Manufacturer disclosure; duration/effort and baseline.
30. [Google Adaptive Cardio Load Targets, 2025](https://arxiv.org/html/2508.11613v2). Manufacturer white paper/preprint, not established here as peer-reviewed; calculation section read.
31. [Google/Fitbit cardio-load help](https://support.google.com/googlehealth/answer/15402655?hl=en-GB). Manufacturer operational documentation.
32. [TrainingPeaks TSS formula](https://www.trainingpeaks.com/learn/articles/estimating-training-stress-score-tss/). Manufacturer methodology article; formula read.

## Recommended delivery order

1. Correct interval accounting, zones, calibration, and provenance.
2. Separate observed daily cardio load from episode detection and legacy score fitting.
3. Improve candidate detection and gather labeled everyday data.
4. Add genuine RPE and strength logs; keep unsupported outputs unavailable.
5. Validate independently before stronger activity, muscular-load, recovery, or injury claims.

# NOOP sleep and recovery: evidence and engineering direction

Research date: October 27, 2026. Prepared for improving NOOP's local calculations and informing a Claude implementation session.

This is a focused evidence review, not a registered systematic review or an exhaustive search of every publication. It combines peer-reviewed validation experiments, reviews and consensus statements, manufacturer technical material, public datasets, and inspection of the current working tree. Full-text passages were inspected where accessible; some papers were available only through abstracts/indexed excerpts. Those limitations are recorded in the source register. Manufacturer performance is not independent validation. A study of one hardware/software version does not validate another version—or NOOP's use of that hardware.

## 1. The decisions that matter most

1. **Repair measurement lineage and temporal baselines before tuning weights.** The current code mixes measurement methods and appears to reuse an all-history baseline when rescoring earlier days. These are concrete engineering risks independent of which physiological theory is chosen.
2. **Make missing data a distinct state.** Off-wrist time and absent gravity samples are not observed wake. Separate unknown sleep/wake state from sleep with unknown stage.
3. **Prioritize sleep duration, timing, continuity, regularity, and coverage.** Sleep stage estimates remain useful descriptive outputs, but should not dominate recovery or imply precise restorative benefit. Wearables repeatedly show weaker wake detection and stage classification than sleep detection. [Chinoy 2021](https://pubmed.ncbi.nlm.nih.gov/33378539/), [Schyvens 2025](https://pubmed.ncbi.nlm.nih.gov/40303381/).
4. **Keep HRV definitions and measurement protocols distinct.** RMSSD is not SDNN; nighttime is not a paced-breathing session; median five-minute RMSSD is not whole-night RMSSD. Consistent measurement conditions are essential. [Task Force 1996](https://pubmed.ncbi.nlm.nih.gov/8598068/), [Buchheit 2014](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2014.00073/full).
5. **Replace population stage quotas with an explicitly experimental model, then a trained model when appropriate labels exist.** Making every night look physiologically typical is not evidence of correct staging. Model performance must be measured on people held out of training. [Menghini 2021](https://pubmed.ncbi.nlm.nih.gov/32882005/).
6. **Treat recovery as an estimate of several dimensions, not a measured percentage of biological restoration.** Validate autonomic status, sleep sufficiency, subjective recovery, and task performance separately. A successful HR sensor validation does not validate a composite readiness score. [de Zambotti 2024](https://academic.oup.com/sleep/article/47/4/zsad325/7501518).
7. **Use several timescales and independent outcomes.** Tonight's deviation, recent trend, and longer reference level answer different questions. A brief morning fatigue/soreness check and optional vigilance or standardized exercise test provide outcomes beyond a competitor's score. [Saw 2016](https://pubmed.ncbi.nlm.nih.gov/26423706/), [Manresa-Rocamora 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8507742/).

## 2. What the current NOOP tree shows

These observations describe files inspected on the research date, including existing uncommitted changes. No application source was modified for this research. Re-check the working tree before implementation: some documentation is older than the code.

| Observation | Evidence in the local tree | Direction |
|---|---|---|
| Recovery weights are HRV 0.86, RHR 0.04, respiration 0.07, sleep 0.03, fitted against one WHOOP export | `RecoveryScorer.swift`, `docs/WHOOP_REVERSE_ENGINEERING.md`, `docs/SLEEP_STRAIN_AUDIT.md` | Preserve as a versioned legacy comparator; agreement with WHOOP is not physiological validity. |
| The scorer receives raw HRV and uses linear deviations; the research-fit document discusses log HRV | `RecoveryScorer.breakdown`, `IntelligenceEngine.baselines` | Audit the actual transform end to end. Transform both present and historical RMSSD consistently. |
| One baseline is constructed from `repo.days` before the historical rescore loop | `Strand/Data/IntelligenceEngine.swift`, around lines 62–73 and 116 | Score day t using only eligible observations preceding t; update state afterward. Replaying future days must not change a previously computed past score. |
| Imported WHOOP and locally measured vitals share the baseline path | Same file, including explicit comment | Partition by metric, source, hardware and processing version, aggregation and measurement context. |
| Missing gravity epochs are labeled `wake` despite a comment describing them as unscored | `SleepStager.swift`, around lines 684–685 | Introduce explicit unknown states and propagate them through durations, efficiency, vitals eligibility and UI. |
| Deep/REM allocation uses maximum shares of 17%/22%; deep is limited to the first half and REM excluded in the first 30 minutes | `SleepStager.swift`, around lines 174–187 | Remove hard physiological quotas from claims of measured staging. Any remaining temporal priors must be soft, documented, and benchmarked. |
| Sleep contribution is efficiency centered on 0.85, not achieved sleep divided by estimated need | `RecoveryScorer.swift`; `AnalyticsEngine.swift`, around line 161 | Keep efficiency, sufficiency and continuity distinct. Four efficient hours cannot imply adequate sleep duration. |
| Recent improvements already compute median valid-window RMSSD and preserve adjacency in the timed HRV path | `SleepVitals.swift`, `HRVAnalyzer.analyzeTimed` | Preserve and test these improvements. Do not repeat the old mistake of differencing across discarded beats or gaps. |
| Six five-minute windows can qualify a night; HR coverage uses a sample-count assumption | `SleepVitals.swift`, around lines 63–72 and 104 | Add actual time coverage, duplicate detection, valid-pair coverage and temporal distribution. Thirty minutes from one part of a long night need not represent the whole night. |
| Apple import has an explicitly named SDNN field, but exports it under generic `hrv` | `AppleHealthAggregator.swift`, around line 410 | Trace consumers; prevent a generic label from allowing SDNN to enter an RMSSD baseline. This is a collision risk, not a confirmed finding that every recovery path mixes them. |
| New respiratory estimation reconstructs time from interval lengths | `RespiratoryRate.swift`; call from `SleepVitals.swift` passes RR values | Audit packet gaps and time compression. Cumulative interval time is appropriate only when beat continuity is established. |

Code entry points: [analytics package](/Users/alfonsomartin/Desktop/noop/Packages/StrandAnalytics/Sources/StrandAnalytics), [app orchestration](/Users/alfonsomartin/Desktop/noop/Strand/Data/IntelligenceEngine.swift), [existing audit](/Users/alfonsomartin/Desktop/noop/docs/SLEEP_STRAIN_AUDIT.md).

## 3. What validation studies actually establish

| Study | Population/design and finding | What NOOP should learn |
|---|---|---|
| [Chinoy et al., 2021](https://pubmed.ncbi.nlm.nih.gov/33378539/) | Seven trackers compared with PSG; reported sleep sensitivity at least 0.93 but wake specificity 0.18–0.54; poorer/disrupted sleep was harder. | Overall accuracy can hide systematic false sleep. Benchmark quiet wake explicitly. |
| [Miller et al., 2021](https://pubmed.ncbi.nlm.nih.gov/34201016/) | Six adults, 54 sleeps. WHOOP automatic detection: 86% two-state agreement versus 63% four-state agreement. | Many nights from six people do not equal a broad population sample; binary and staging results are different claims. |
| [Bellenger et al., 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8160717/) | WHOOP 2.0 versus ECG, six adults and 15 opportunities. HR agreement was stronger than the precision needed to interpret small HRV changes; artifact filtering mattered. | Report measurement uncertainty. Do not treat a small daily HRV change as unquestionably biological. |
| [Altini & Kinnunen, 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8271886/) | Oura-affiliated study: 106 people, 440 nights. Four-stage accuracy rose from 57% with acceleration features to 79% with the full multisensor/circadian model. | Multimodal features and learned context help in that dataset. This does not transfer the reported accuracy to a WHOOP gravity/HR heuristic. |
| [Miller et al., 2022](https://pmc.ncbi.nlm.nih.gov/articles/PMC9412437/) | Six-device validation. WHOOP 3.0 four-state agreement was 60%, while nocturnal HR/HRV agreement with ECG was much stronger. | Validate each metric independently. Measurement windows differed across devices. |
| [Svensson et al., 2024](https://pubmed.ncbi.nlm.nih.gov/38382312/) | Oura Gen3/OSSA 2.0, 96 participants and 421,045 epochs, multi-night ambulatory PSG. | Valuable larger, home-based validation design. Abstract/index record inspected; do not invent unverified numerical results. |
| [Robbins et al., 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC11511193/) | 35 healthy adults, one lab night, Oura Gen3/Fitbit Sense 2/Apple Watch 8. Sleep sensitivity ≥95%; stage sensitivity varied. Oura funded the study. | Results are generation- and cohort-specific. An academic laboratory does not automatically mean manufacturer-independent funding. |
| [Schyvens et al., 2025](https://pubmed.ncbi.nlm.nih.gov/40303381/) | 62 adults, two to four of six devices per participant. Sleep sensitivity >90%; wake specificity 29.39–52.15%; kappa 0.21–0.53. | Do not rank all modern brands from one study; device sample sizes and software versions differ. |
| [Sridhar et al., 2020](https://research.google/pubs/deep-learning-algorithm-for-automated-sleep-stage-scoring-using-heart-rate-variability/) | ECG-derived staging evaluated on independent datasets of 800 and 993 subjects; reported accuracy 0.76, kappa 0.65. | Strong motivation for sequence models; ECG performance is not proof of performance with sparse wearable PPG intervals. |
| [Kotzen et al., SleepPPG-Net](https://peterhcharlton.github.io/publication/kotzen-2022/) | Raw-PPG deep learning with 2,374 patients across two datasets; held-out median kappa 0.75; external adaptation reported. | Requires continuous waveform data and domain evaluation; cannot run unchanged on occasional HR samples or gravity summaries. |

The practical distinction is between **sensor validity**, **derived-metric validity**, **composite-score validity**, and **decision usefulness**. Each needs its own evidence. A high correlation can coexist with substantial systematic bias; group-average bias can be near zero while individual errors are large. [Menghini framework](https://pubmed.ncbi.nlm.nih.gov/32882005/), [rigorous performance evaluation](https://pubmed.ncbi.nlm.nih.gov/35513978/).

## 4. What major companies disclose

| Company | Publicly described approach | Useful idea / limitation |
|---|---|---|
| Apple | Its October 2025 staging paper describes accelerometer-based classification, including foundation-model improvements for quiet wake. Separately, its sleep score allocates 50 points to duration, 30 to bedtime consistency and 20 to interruptions. | Raw high-frequency accelerometry is richer than a sparse gravity proxy. The score provides a precedent for focusing on actionable sleep dimensions, but its weights are product choices. [Technical paper](https://www.apple.com/health/pdf/Estimating_Sleep_Stages_from_Apple_Watch_Oct_2025.pdf), [score documentation](https://support.apple.com/en-eg/108906). |
| WHOOP | Public recovery documentation lists HRV, RHR, breathing, sleep and other vitals; exact weights and interactions are not disclosed in the reviewed material. Historical studies used particular nocturnal windows. | Avoid declaring a historical slow-wave-window method to be the exact current algorithm. Neither a recovered BLE signal nor a regression against an export reproduces their full system. [Recovery documentation](https://support.whoop.com/s/article/WHOOP-Recovery). |
| Oura | Readiness combines personal deviations and longer-term contributors. The HRV balance documentation compares a weighted recent 14-day period with a longer reference. | Separate acute status from accumulated trends; don't assume one baseline window fits every contributor. Public explanations are not a reproducible score formula. [Contributors](https://ouraringhelp.zendesk.com/hc/en-us/articles/360057791533-Readiness-Contributors). |
| Garmin / Firstbeat | Training Readiness incorporates sleep, HRV status, recovery time, acute load and stress/sleep history. Firstbeat describes HRV-based stress and recovery methods. | Autonomic state, load and time since exercise are different dimensions. Body Battery is an index, not measured stored energy. [Garmin](https://www.garmin.com/en-US/garmin-technology/running-science/physiological-measurements/training-readiness/), [Firstbeat 2014 white paper](https://assets.firstbeat.com/firstbeat/uploads/2015/09/Stress-and-recovery_white-paper_20146.pdf). |
| Polar | Nightly Recharge separates ANS charge and sleep charge; uses approximately the first four hours and comparisons with the past 28 days. | Explicit separation of sleep and autonomic measures is useful. Copying a window or weight does not validate NOOP. [White paper](https://www.polar.com/img/static/whitepapers/pdf/polar-nightly-recharge-white-paper.pdf), [documentation](https://support.polar.com/us-en/nightly-recharge-recovery-measurement?product_id=91090). |
| Google / Fitbit | Readiness documentation describes HRV, recent sleep and RHR. A 2026 technical report distinguishes session detection from stage estimation and reports updated staging tests. | Model session boundaries independently from within-session stages. The report is labeled “to appear” on Google Research; treat as manufacturer technical evidence, not confirmed independent peer review. [Readiness](https://support.google.com/googlehealth/answer/14236710?hl=en), [2026 report](https://research.google/pubs/performance-analysis-of-updated-sleep-tracking-algorithms-across-google-and-fitbit-wearable-devices/). |

## 5. Calculation specification

The definitions below are mathematical or measurement definitions. Window sizes, validity gates, weights, score mappings and display thresholds proposed for NOOP are **engineering hypotheses requiring validation**, unless a source is explicitly attached. They are not a newly discovered clinical recovery algorithm.

### Sleep quantities and missingness

Use nonoverlapping timestamp intervals, a stable source precedence policy, and explicit `wake`, `asleepUnstaged`, `light`, `deep`, `REM`, `unknown`, and off-wrist provenance. Off-wrist maps to unknown for sleep inference, not automatically wake. Distinguish candidate rest episode, time attempting sleep, time in bed, first sleep onset, and final awakening.

- **TST:** sum durations labeled asleep, including asleep-unstaged.
- **TIB:** elapsed time between separately established in-bed boundaries. A motion-inferred sleep period is not necessarily TIB.
- **Sleep efficiency:** `100 × TST / TIB`, only when TIB and coverage support that interpretation.
- **Sleep onset latency:** sleep onset minus attempt-to-sleep time. If attempt time is unavailable, return unavailable, rather than “0.”
- **WASO:** observed wake between first sleep onset and final awakening; report coverage and the exact convention. Do not include pre-sleep latency or quietly treat unknown as wake.
- **Stage fraction:** stage duration divided by TST when all sleep is staged. For partial staging, report stage duration, staged-sleep coverage, and optionally a clearly labeled fraction of *classified* sleep; never disguise it as a full-night fraction.
- **Observed awakenings/hour:** number of qualifying wake bouts divided by observed sleep hours; disclose bout-duration and merging rules. This is not an EEG arousal index.
- **24-hour sleep:** union of primary sleep and naps, with no double counting across midnight or overlapping imports.

For a known session with `S` observed sleep minutes and `U` unknown minutes, `[S, S+U]` is an interval caused by missingness, **not** a confidence interval for the classifier's accuracy. With known TIB, corresponding bounds are `[100S/TIB, 100(S+U)/TIB]`. Reject or qualify summaries if coverage is inadequate. These interval rules are proposed NOOP accounting conventions, not claims that classified epochs are error-free.

### Regularity and sleep shortfall

The Sleep Regularity Index compares sleep/wake states 24 hours apart:

`p_same = matching valid pairs / all valid pairs`

`SRI = 200 × p_same − 100`

Only pairs with both states known qualify. Include naps and full-day states; never fill all unobserved daytime with wake. The theoretical range is −100 to 100; do not silently clip it to 0–100 or call it a percentile. Use the original exact 24-hour comparison for research replication; if adding a same-local-clock variant, name it separately. [Phillips et al. 2017](https://pmc.ncbi.nlm.nih.gov/articles/PMC5468315/).

For bedtime/wake-time variability, use circular clock-time statistics so 23:55 and 00:05 are close together. Keep this separate from SRI. A large UK Biobank analysis linked regularity with mortality, but that observational association cannot become a user's mortality prediction or a promise that increasing a score extends life. [Windred et al. 2024](https://pubmed.ncbi.nlm.nih.gov/37738616/).

Start with a configurable sleep target grounded in age-appropriate guidance and user context. The AASM/SRS adult consensus recommends regularly obtaining at least seven hours for healthy adults; it does not estimate each person's exact need. Do not infer that chronic six-hour sleepers only need six hours. [Watson et al. 2015](https://pubmed.ncbi.nlm.nih.gov/26039963/).

An auditable first feature is **observed shortfall relative to a declared target**, `max(0, target − 24hSleep)`, with a sum over a specified recent window and completeness shown. An experimental debt model could use `D_t = max(0, λD_(t−1) + target_t − sleep24h_t)`. Neither λ nor one-for-one repayment is established by this equation. Missing days are unknown; a long night must not automatically erase evidence of chronic impairment. Chronic sleep restriction can produce accumulating performance deficits without proportionate subjective awareness. [Van Dongen et al. 2003](https://pubmed.ncbi.nlm.nih.gov/12683469/).

### HRV and heart rate

For accepted adjacent normal-to-normal intervals in milliseconds:

`RMSSD = sqrt(Σ (NN_(i+1) − NN_i)^2 / numberOfValidAdjacentPairs)`

`SDNN = sqrt(Σ (NN_i − meanNN)^2 / (N−1))`

`pNN50 = 100 × count(|successive difference| > 50 ms) / numberOfValidAdjacentPairs`

The base definitions come from [Task Force 1996](https://pubmed.ncbi.nlm.nih.gov/8598068/). In NOOP, valid adjacency must preserve original acquisition sequence and timing. Dropping a bad beat must not manufacture a new successive pair. Equal coarse timestamps may represent multiple legitimate beats, so preserve sequence identifiers rather than deduplicating by second alone.

Retain raw intervals and quality masks. Assess missing/extra beats, ectopy-like artifacts, clipping, packet duplication and long gaps. The local 20% rule is a heuristic, not a complete implementation of adaptive artifact correction. Benchmark it against a more capable method before tightening it; excessive filtering can remove genuine physiological variability. [Lipponen & Tarvainen 2019](https://pubmed.ncbi.nlm.nih.gov/31314618/).

For candidate nightly aggregation: compute fixed-duration clean windows and compare median RMSSD, geometric mean, first-four-hour summaries and full-night summaries on reference data. Report valid windows by night segment, contiguous-pair counts and coverage. Do not pool all nights' beats into one “daily HRV.” Separate spontaneous breathing from paced-breathing measurements. Preserve distinct overnight mean HR, lower-quantile HR, and awake resting HR definitions.

### Personal baselines

Proposed baseline key:

`person × metricDefinition × sensor/source × hardwareVersion × algorithmVersion × measurementContext × aggregationMethod`

For positive RMSSD, investigate `x_t = ln(RMSSD_t / 1 ms)`. All reference values and dispersion floors must be in the same transformed units. Candidate robust reference:

`m_t = median(eligible x before day t)`

`s_t = max(1.4826 × median(|x − m_t|), validatedNoiseFloor)`

`z_t = (x_t − m_t) / s_t`

The factor 1.4826 applies to **median absolute deviation about a median**. NOOP's 1.253 convention approximates Gaussian SD from **mean absolute deviation**; these are not interchangeable estimators. Robust standardized deviations are not diagnostic probabilities.

For an EWMA, `alpha = 1 − 2^(−Δdays/halfLifeDays)` gives a time-based weight. Decide explicitly whether the process is calendar-time or observation-time; neither sparse historical rows nor missing nights may silently become consecutive days. Score against the previous state and update afterward. Keep an acute deviation and a slower reference so an ongoing deterioration is not quickly normalized away. Candidate windows such as 7, 28 and 60–90 days should be compared, not presented as universal biological constants.

Distinguish signal corruption from a genuine unusual day. A plausible illness-associated deviation may be important to display even if excluded or downweighted in baseline adaptation. Store exclusion reasons, last accepted observation date, valid-night count and elapsed calibration period.

### Recovery, respiration, temperature and oxygen

Prefer separate sleep sufficiency, autonomic status, unusual-vitals indicators and subjective readiness. A candidate UI composite can be `100 × sigmoid(b + Σw_j f_j)`, but its coefficients, shape and thresholds are unvalidated until tested against specified outcomes. A logistic output is not automatically a probability. Explain component contributions and missing-input behavior; do not renormalize one remaining weak input into a confident complete score.

Higher HRV or lower HR is not unconditionally better. Context, unusual high values, breathing changes and signal artifacts matter. Avoid an indefinitely increasing reward for either. HRV-guided training research does not establish universal day-level performance forecasts or a recovery percentage. [Buchheit 2014](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2014.00073/full), [2021 meta-analysis](https://pmc.ncbi.nlm.nih.gov/articles/PMC8507742/).

Breathing derived from intervals is an estimate of respiratory modulation, not a direct breath count. Use actual continuous timing, detrending, a documented frequency range, quality checks and validation against a respiratory reference; `breaths/min = 60 × frequencyHz`. Resampling across dropped packets can create misleading periodicity. Raw PPG also carries amplitude/baseline respiratory information that interval-only input lacks. [Charlton et al. 2018](https://pubmed.ncbi.nlm.nih.gov/29990026/).

Keep skin temperature distinct from core temperature, and absolute temperature distinct from baseline deviation. Treat menstrual phase, illness, environment, alcohol, travel and medication as possible context, not automatically inferred causes. SpO₂ requires trustworthy device measurements and quality information; an isolated low value or inferred breathing rate must not become an apnea diagnosis. Optional respiratory/temperature inputs should remain explanatory or experimental until independently validated in this pipeline.

## 6. Development and validation sequence

**Phase 1 — trustworthy accounting.** Add source/versioned metric types; fix historical leakage; preserve sleep unknown states; make interval unions deterministic; verify units and coverage; protect manual edits and imported records; migrate without overwriting provenance. Retain legacy outputs for before/after comparison.

**Phase 2 — useful descriptive metrics.** Add TST, nap-inclusive sleep, explicit sleep-period versus TIB distinction, regularity, target shortfall, clean-window HRV trends and quality explanations. Return unavailable when unsupported. Version changes in aggregation instead of silently shifting a person's baseline.

**Phase 3 — model development.** Inventory which raw sensors actually exist. Begin with a simple reproducible sleep/wake baseline; evaluate learned multisensor features and sequence context. Public Apple Watch/PSG data can prototype methods but does not establish transfer to WHOOP. Raw-PPG neural networks are conditional on obtaining usable waveform data. Preserve participant-level train/validation/test splits; fit preprocessing on training data only. [Walch dataset](https://www.physionet.org/content/sleep-accel/1.0.0/), [SleepPPG-Net](https://peterhcharlton.github.io/publication/kotzen-2022/).

**Phase 4 — prospective validity.** Collect synchronized NOOP sensor data and PSG for sleep/staging, ECG for beat metrics and a respiratory reference for breathing estimates. Recruit varied ages, skin tones, sleep quality, schedules and relevant conditions. Establish ethical/consent procedures for any new human study. Validate recovery against outcomes chosen before fitting: morning self-report, standardized vigilance, and repeatable exercise performance are different targets. Do not validate a score solely against variables it already contains.

Report sleep sensitivity and wake specificity, per-stage precision/recall/F1, macro-F1, confusion matrices, kappa, duration/boundary MAE, bias and limits of agreement, failure rate and usable coverage. Confidence intervals should respect participant/night clustering. Measure confidence calibration separately from classification accuracy. Keep within-night smoothing from erasing genuine awakenings merely to improve visual appeal. [Menghini 2021](https://pubmed.ncbi.nlm.nih.gov/32882005/), [de Zambotti 2022](https://pubmed.ncbi.nlm.nih.gov/35513978/).

Compare recovery models with simple baselines: sleep duration alone, recent log-HRV alone, self-report alone, and persistence from yesterday. Use chronological holdouts for personal predictions and participant holdouts for generalization. A more complicated score should demonstrate incremental value. Report both score changes due to physiology and changes due to algorithms/data availability.

## 7. Source register and reading priorities

“Full” means relevant full-text sections were accessible and inspected, not a claim that every line was reviewed. “Abstract/index” means restrict conclusions to the available abstract or indexed material. Historical publication dates come from the paper, not a search engine's crawl date.

### Peer-reviewed research, reviews and consensus material

1. [Task Force, 1996 — HRV standards](https://pubmed.ncbi.nlm.nih.gov/8598068/). Guideline; indexed record and official ESC document excerpts. Essential metric definitions; does not validate a readiness score.
2. [Lipponen & Tarvainen, 2019 — artifact correction](https://pubmed.ncbi.nlm.nih.gov/31314618/). Method paper; abstract/index. Priority for evaluating beat cleaning, not a claim that NOOP already implements it.
3. [Buchheit, 2014 — monitoring training with HR measures](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2014.00073/full). Review/technical report; article/PDF excerpts. Measurement error and training context.
4. [Saw et al., 2016 — subjective athlete monitoring](https://pubmed.ncbi.nlm.nih.gov/26423706/). Systematic review; abstract/index. Supports including self-report; not evidence that feelings detect every sleep-loss effect.
5. [Manresa-Rocamora et al., 2021 — HRV-guided training](https://pmc.ncbi.nlm.nih.gov/articles/PMC8507742/). Meta-analysis; full discussion inspected. Small favorable effects did not establish significant superiority for all performance outcomes.
6. [Van Dongen et al., 2003 — cumulative sleep restriction](https://pubmed.ncbi.nlm.nih.gov/12683469/). Controlled experiment, 48 adults; abstract and author-hosted paper passages. Supports accumulated impairment, not a universal debt-repayment formula.
7. [Watson et al., 2015 — adult sleep duration](https://pubmed.ncbi.nlm.nih.gov/26039963/). Consensus; abstract and related discussion. Population guidance, not individualized sleep-need estimation.
8. [Phillips et al., 2017 — Sleep Regularity Index](https://pmc.ncbi.nlm.nih.gov/articles/PMC5468315/). Observational study; full methods inspected. Exact SRI definition and missing-pair treatment.
9. [Windred et al., 2024 — regularity and mortality](https://pubmed.ncbi.nlm.nih.gov/37738616/). Prospective cohort, 60,977 participants; abstract. Association and population limitations matter.
10. [Chinoy et al., 2021 — seven-device sleep validation](https://pubmed.ncbi.nlm.nih.gov/33378539/). PSG comparison; indexed article/PDF excerpts. Wake detection and disrupted sleep are key failure modes.
11. [Miller et al., 2021 — WHOOP sleep detection](https://pubmed.ncbi.nlm.nih.gov/34201016/). Validation; detailed abstract. Automatic and manual session boundaries change results.
12. [Bellenger et al., 2021 — WHOOP HR/HRV](https://pmc.ncbi.nlm.nih.gov/articles/PMC8160717/). Validation; full methods/results excerpts. Small sample, old hardware, filtering and window specificity.
13. [Altini & Kinnunen, 2021 — Oura multisensor staging](https://pmc.ncbi.nlm.nih.gov/articles/PMC8271886/). Company-affiliated methods study; full abstract/method context. Useful feature ablation design.
14. [Miller et al., 2022 — six-device sleep/HR/HRV](https://pmc.ncbi.nlm.nih.gov/articles/PMC9412437/). Validation; indexed results sections. Distinct measurement windows prevent naive device equivalence.
15. [Svensson et al., 2024 — Oura OSSA 2.0](https://pubmed.ncbi.nlm.nih.gov/38382312/). Multi-night validation; abstract/index only, access restricted on direct open. Review full paper before using detailed numerical claims.
16. [Robbins et al., 2024 — three commercial trackers](https://pmc.ncbi.nlm.nih.gov/articles/PMC11511193/). Validation; full abstract and funding declaration inspected. Explicitly Oura-funded.
17. [Schyvens et al., 2025 — six wrist devices](https://pubmed.ncbi.nlm.nih.gov/40303381/). Validation; author-repository abstract/table excerpts. Hardware and per-device sample sizes matter.
18. [Sridhar et al., 2020 — HRV deep-learning staging](https://research.google/pubs/deep-learning-algorithm-for-automated-sleep-stage-scoring-using-heart-rate-variability/). npj Digital Medicine paper; author/company-hosted abstract. ECG-to-wearable transfer remains a separate question.
19. [Kotzen et al. — SleepPPG-Net](https://peterhcharlton.github.io/publication/kotzen-2022/). IEEE JBHI journal article; author page and manuscript excerpts. Raw waveform architecture reference; do not confuse preprint date with journal issue date.
20. [Menghini et al., 2021 — standardized evaluation framework](https://pubmed.ncbi.nlm.nih.gov/32882005/). Methods paper; abstract/index. Priority reference for benchmark implementation.
21. [de Zambotti et al., 2022 — rigorous performance evaluation](https://pubmed.ncbi.nlm.nih.gov/35513978/). Evaluation guidance; abstract/index. Metric-specific and intended-use-specific claims.
22. [de Zambotti et al., 2024 — state of sleep wearable science](https://academic.oup.com/sleep/article/47/4/zsad325/7501518). Review/recommendations; indexed full-text sections. Explicit uncertainty around proprietary composite metrics.
23. [Evaluating reliability in wearable devices for sleep staging, 2024](https://www.nature.com/articles/s41746-024-01016-9). Review; indexed text and tables. Diversity, reporting and algorithm transparency.
24. [Accuracy of Wristband Fitbit Models, 2019](https://pubmed.ncbi.nlm.nih.gov/31778122/). Systematic review/meta-analysis; abstract/index. Useful historical progression, not a test of current devices.
25. [AASM consumer sleep technology position statement, 2018](https://pmc.ncbi.nlm.nih.gov/articles/PMC5940440/). Position statement; indexed abstract. Apply its validation principle to NOOP; do not interpret a 2018 statement as the current regulatory status of every wearable feature.
26. [Charlton et al., 2018 — breathing estimation review](https://pubmed.ncbi.nlm.nih.gov/29990026/). Review; abstract and author-repository excerpts. Signal modulation, algorithms and validation references.
27. [Charlton et al., 2016 — respiratory algorithm comparison](https://pmc.ncbi.nlm.nih.gov/articles/PMC5390977/). Method comparison; abstract/index. Useful validation design under controlled conditions.
28. [Constantin et al., 2026 — long-term wearable reflective PPG staging](https://academic.oup.com/sleep/article/49/3/zsaf246/8239172). Journal research; indexed technical passages. Follow-up on device/domain transfer; no performance figure adopted here.
29. [Considerations for commercial wearables in sleep/rest-activity research, 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12405641/). Review; abstract/index. Deployment and software-iteration context.
30. [Acute Readiness Monitoring Scale validation, 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8498198/). Research; indexed methods/results. Candidate independent readiness outcomes; inspect instrument requirements before adoption.

### Manufacturer publications and public implementation resources

31. [Apple sleep-stage technical paper, October 2025](https://www.apple.com/health/pdf/Estimating_Sleep_Stages_from_Apple_Watch_Oct_2025.pdf). Manufacturer white paper; indexed original excerpts inspected; full PDF open exceeded tool size limit. No unverified updated accuracy number used here.
32. [Apple sleep score documentation](https://support.apple.com/en-eg/108906). Official support; indexed content. Publicly stated component weights.
33. [WHOOP Recovery](https://support.whoop.com/s/article/WHOOP-Recovery). Official support; indexed content. Inputs, not disclosed coefficients.
34. [Oura Readiness Contributors](https://ouraringhelp.zendesk.com/hc/en-us/articles/360057791533-Readiness-Contributors). Official support; indexed content. Contributor-specific histories.
35. [Garmin Training Readiness](https://www.garmin.com/en-US/garmin-technology/running-science/physiological-measurements/training-readiness/). Official description; indexed content. Multidimensional product architecture.
36. [Polar Nightly Recharge white paper](https://www.polar.com/img/static/whitepapers/pdf/polar-nightly-recharge-white-paper.pdf). September 30, 2019; PDF accessed. ANS versus sleep charge.
37. [Polar Nightly Recharge documentation](https://support.polar.com/us-en/nightly-recharge-recovery-measurement?product_id=91090). Official support; indexed content. Measurement window and baseline.
38. [Firstbeat Stress and Recovery white paper](https://assets.firstbeat.com/firstbeat/uploads/2015/09/Stress-and-recovery_white-paper_20146.pdf). Updated November 4, 2014; indexed PDF passages. Manufacturer methodology, not disclosure of every current Garmin formula.
39. [Firstbeat athletic recovery white paper](https://assets.firstbeat.com/firstbeat/uploads/2015/11/Recovery-white-paper_15.6.20153.pdf). Manufacturer technical material; indexed PDF passages. Individual baselines and measurement context.
40. [Google/Fitbit readiness documentation](https://support.google.com/googlehealth/answer/14236710?hl=en). Official support; indexed content. Current public input description.
41. [Google/Fitbit sleep algorithms, 2026](https://research.google/pubs/performance-analysis-of-updated-sleep-tracking-algorithms-across-google-and-fitbit-wearable-devices/). Manufacturer technical report, publication status “to appear”; full hosted abstract inspected. Separate session/TATS detection from PSG-trained staging.
42. [Walch PhysioNet sleep-accel dataset, 2019](https://www.physionet.org/content/sleep-accel/1.0.0/). Dataset, 31 subjects; official description inspected. Apple Watch acceleration/HR plus PSG labels.
43. [Walch sleep-classifiers implementation](https://github.com/ojwalch/sleep_classifiers). Author code; repository description inspected. Check licensing and preprocessing before reuse.

Not counted as established evidence: news, Reddit accuracy rankings, and search snippets making unsupported comparisons. A 2025 composite-score review (DOI 10.1515/teb-2025-0001) was located through an aggregator but publisher access failed; it is a follow-up lead, not the basis of a numerical claim in this report.

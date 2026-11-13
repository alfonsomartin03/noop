# Nap detection (issue #19)

Status: **audit + one evidence fix implemented and unit-tested (`nap-evidence-v2`, `sessions-v2`; low-evidence spans stay correctable). No labelled real-world evaluation has been run**, so no accuracy improvement is claimed. Code: `SleepStager.detectSleep` (episodes, nap evidence), `SleepSessionClassifier` (primary / nap / uncertain labels).

## What other wearables document

Looked up 2026-11-13. "Official" = the vendor's own support/blog page; everything about *how* detection works is proprietary unless stated. None of these vendors publishes nap-specific accuracy.

| Device | What the vendor documents | Source (type) | Unknown / proprietary | Applies to NOOP? |
| --- | --- | --- | --- | --- |
| Oura Ring | A nap must be 15 min–3 h and contain at least one sleep stage; naps within ~4 h of the end of the main sleep are often missed; movement or elevated HR turns a presumed nap into "restful" time; naps can't be manually adjusted. | [Oura support, "Nap detection"](https://support.ouraring.com/hc/articles/1500009653181) (official; page last updated 2026-05-29) | Signals and thresholds | Duration bounds and "rest, not nap, when HR is elevated" match NOOP's design; ring sensors (finger PPG, temperature) are not NOOP's inputs |
| Fitbit / Google | Devices detect and record naps of at least 20 min; stages may be incomplete for some naps. Older help text required ≥ 3 h of sleep for stages and ≥ 1 h for a sleep log. | [Google Fitbit help](https://support.google.com/fitbit/answer/14236407) (official; wording has changed over time, date of change not found) | Method; which devices | Minimum-duration precedent only |
| Garmin | Naps up to 3 h, outside the user's configured sleep window, on Venu 3 and later devices (fēnix 7/8, Epix, Forerunner 965, Enduro, …). Users reported naps logged while awake and resting. | [Garmin blog](https://www.garmin.com/en-SG/blog/does-your-garmin-smartwatch-track-naps/) (official); [Advnture report](https://www.advnture.com/news/garmin-detecting-too-many-naps) (press, false-positive reports) | Minimum duration, method | Confirms quiet-wake false positives are the industry failure mode; NOOP uses a learned habit, not a fixed sleep window |
| Apple Watch | watchOS 11+ records sleep, naps included, without a schedule; earlier versions needed a Sleep schedule/Focus. | [Apple support, "Track your sleep"](https://support.apple.com/guide/watch/apd830528336/watchos) (official, thin); version details from third-party coverage | Minimum duration, method | Little |
| WHOOP | **Official page not yet verified.** A WHOOP support article, "Automatic and Manual Activity Detection" (support.whoop.com), is indexed and its indexed text describes a 50-minute separation rule, but the live page failed to load when checked (2026-11-13); archive the full official text before quoting it. Community posts relay that naps are auto-detected after sync from a sustained drop in HR and movement, with conflicting minimums (15 min vs > 1 h), a new sleep after ≥ 50 min awake, and manual "Add sleep". | [WHOOP community thread](https://www.community.whoop.com/t/auto-detect-naps/7913) (user reports, not documentation) | Everything | Treat as unverified; the "50 min awake → new sleep" figure coincides with NOOP's `alwaysJoinGapMin` but is not a documented WHOOP rule |

## Primary validation literature

| Study | Finding | Applies to NOOP? |
| --- | --- | --- |
| Kanady JC, Drummond SPA, Mednick SC. *Actigraphic assessment of a polysomnographic-recorded nap: a validation study.* J Sleep Res 2011;20:214–222. https://doi.org/10.1111/j.1365-2869.2010.00858.x | 57 adults, wrist actigraphy vs PSG during a daytime nap opportunity: sensitivity 92–96 %, **specificity 40–67 %**, accuracy 82–86 % depending on settings; quiet wake is the weak point. | Directly: NOOP's first stage is motion-only. Research actigraph at 1-min epochs, lab nap opportunity — not free-living, not NOOP's sensor. |
| Chinoy ED, Cuellar JA, Huwa KE, et al. *Performance of seven consumer sleep-tracking devices compared with polysomnography.* Sleep 2021;44:zsaa291. https://doi.org/10.1093/sleep/zsaa291 | Overnight lab sleep, consumer devices: sensitivity ≥ 0.93, specificity 0.18–0.54. | Night sleep only (no naps); shows adding HR does not by itself fix wake detection. |

No peer-reviewed, nap-specific validation of a consumer wearable (WHOOP included) was found in this search; that gap is itself a finding. Figures above are from abstracts/search summaries — read the paper before quoting.

Takeaways: vendors document *that* they detect naps and their duration bounds, rarely *how*. Actigraphy-style detection is sensitive but unspecific for quiet wakefulness — exactly the nap failure mode — so motion must be combined with cardiac evidence relative to the wearer's own awake and sleeping HR, and the result must stay correctable. Other wearables' outputs are comparison data, not ground truth.

## Inputs NOOP actually has

Gravity (accelerometer orientation) and HR samples at strap cadence; RR intervals when the strap sends them. No skin-temperature series fine enough for nap onset, no EEG. HR and RR can be missing for stretches (sync gaps, off-wrist); missing evidence is not sleep.

Measured on a SQLite-backup copy of one wearer's store (2026-10-15 → 2026-11-13, 28.5 days, WHOOP 5.0; aggregates only, measured 2026-11-13):

| Stream | Median / p95 spacing | Gaps ≥ 5 min | Minutes with ≥ 1 sample, 10:00–20:00 local |
| --- | --- | --- | --- |
| HR | 1 s / 1 s | 2 (134 h, both multi-day off-strap/sync gaps) | 82 % |
| Gravity | 1 s / 1 s | 2 (same spans as HR) | 82 % |
| RR | 1 s / 2 s | 529 (268 h) | 47 % |

So 1 Hz HR + gravity is a fair assumption when the strap is worn and synced, and the long gaps are whole-day outages, not daytime dropouts. RR is present for under half of daytime minutes, so a nap rule must not require RR/HRV; it can only add confidence when present. Respiration series are empty on this store. One wearer, one firmware; repeat on each evaluation record before relying on it.

## Pipeline audit

1. Quiet-minute runs (gravity) → candidate spans ≥ 20 min.
2. Evidence: quiet fraction (naps ≥ 90 %) and HR dip vs the day's awake-moving median (naps ≥ 10 %), **skipped when there is no awake reference or < 30 HR samples in the span**.
3. Post-filter: nap median HR ≤ the wearer's sleeping level + max(12 bpm, 25 %), or (no sleeping level) dip ≥ 18 %; **a span with no HR at all was accepted**.
4. Classifier (layer D): one primary per wake day by sleep × circadian weight learned from the wearer's own primaries (so day-sleeping shift workers keep a daytime primary); others ≥ 20 min asleep with a ≥ 30 min episode are naps; shorter ones `uncertain`.

Failure cases found (reproduced in `SleepStagerTests`):

- **F1 — still span with no HR** (strap off-wrist on a table, HR dropout): passed on motion alone → reported as a nap. `testStillSpanWithoutHeartRateIsNotANap`.
- **F2 — sparse HR** (10 readings in an hour): dip test skipped (< 30 samples) → nap. `testStillSpanWithSparseHeartRateIsNotANap`.
- **F3 — a user correction lost on rescoring** (found in review of the first v2 cut): v2 deleted F1/F2 candidates inside `detectSleep`, before `SleepSessionClassifier` applied stored corrections, so a span the wearer had already marked as a nap vanished on the version re-score while its correction row stayed in the store. `testStoredNapCorrectionOnALowEvidenceSpanSurvivesRescoring`.
- Not yet addressed (needs labelled data to tune, so left alone): quiet TV/reading with a modest HR drop near the sleeping level; very short naps (< 20 min) stay `uncertain` by design; first days with no sleeping-HR reference rely on the 18 % awake-dip rule.

## Change: `nap-evidence-v2` + `sessions-v2`

- A nap candidate needs HR in ≥ 50 % of its minutes (`SleepStager.napMinHRCoverage`) and an HR median. A candidate that fails is **not a nap and not deleted**: it is emitted with `SleepSession.lowEvidence = true`.
- `SleepSessionClassifier` (`sessions-v2`): a low-evidence episode never joins a neighbouring episode, can never be chosen as main sleep, and is labelled **uncertain** with the reason "Still, but too little heart-rate data to tell sleep from an off-wrist strap: confirm or reject it". Uncertain sessions count nowhere: not in night totals, 24-h sleep, recovery inputs, or sleep excluded from load (`AnalyticsEngine` keeps its time in the day's awake window).
- User corrections act on it like on any other session and survive rescoring: confirm / mark as nap → nap (counted in 24-h sleep and excluded from load); mark as main sleep → primary; reject → removed. Nothing is invented for a confirmed span: resting HR and HRV stay nil without valid windows, and the stager already withholds a stage where there is no cardiac data (`asleep` / "no cardiac data").
- Main-sleep detection is unchanged. Both version strings are part of `IncrementalScorer.algorithmKey`, so stored days re-score once. Imported sleep is untouched (separate identity).
- Limits: the sleep screen can only act on sessions the detector emitted. There is **no way to add a sleep where no still span was detected** (an earlier version of this document suggested otherwise); a real nap during a strap dropout with movement artefacts is still missed. In the app the uncertain row has not been visually checked.
- Trade-off: a real nap during an HR dropout is now shown as uncertain until confirmed, instead of counted automatically.

## Real-data replay (first v2 cut, 2026-11-13)

v1 and the first v2 cut were replayed with `SleepStager.detectSleep` on a private SQLite-backup copy of one wearer's store over 29 consecutive days. Output was identical on every day; the single daytime nap in the period (wearer-confirmed afterwards, times approximate and kept private) has full HR coverage and is detected by both. No HR-less still spans occurred, so the rule changed nothing on this data. This shows the rule did not cost that one nap; it does **not** show improved accuracy. The replay has not been repeated after the low-evidence/`sessions-v2` change (on data with no low-evidence spans the output is the same by construction, but that is an argument, not a run). Detector timestamps are predictions, not ground-truth labels; one confirmed event and unlabelled other days give no precision, recall or false-positive rate.

## Validation plan (not done)

Acceptance targets, **frozen 2026-11-13 before any threshold tuning** (changing them later requires saying so here): event-level recall ≥ 0.8 for naps ≥ 30 min, precision ≥ 0.8, false-positive naps ≤ 0.1 per observed day, median onset/offset error ≤ 10 min — on held-out people/days, broken down by nap length (< 30, 30–90, > 90 min) and HR coverage.

- **Harness** (`DetectionEvaluation`, 2026-11-13): one-to-one greedy IoU matching (`minIoU = 0.5`, fixed for both versions), FP per observed day, fragmentation/merging, participant folds, and now **median** onset/offset error (`medianOnsetErrorS`/`medianOffsetErrorS` — the targets are medians; the older `onsetErrorS`/`offsetErrorS` are means and stay labelled as such), per-event edge and signed event-span duration errors, median |duration error|, 95 % Wilson intervals for precision/recall, and recall per reference-duration stratum (`durationEdgesS: [1800, 5400]`; every reference is matched before stratifying, so a true short nap never becomes a false positive). Wilson intervals assume independent events; with one person's days they are too narrow — resample by participant/day blocks and say which unit was resampled.

### Evaluation protocol (proposed 2026-11-13; freeze before running on test data)

1. **Labels** (private, never in the repo or issues): `schema_version, participant_id, recording_id, reference_session_id, label [nap | daytime_main_sleep | quiet_awake | off_wrist | unknown], context [ordinary | reading_tv | meditation | passenger_travel | post_exercise_rest | fragmented | shift_work | other], reference_method [PSG | validated_actigraphy | prospective_diary | retrospective_approximate | unknown], recorded_at_utc, timezone_IANA, onset_earliest_utc, onset_latest_utc, offset_earliest_utc, offset_latest_utc, awake_gaps_or_segments, confidence_notes, annotation_completeness, raw_recording_private_id, hr_coverage, gravity_coverage, rr_coverage, split [development | test], exclusion_reason`. Times as UTC instants plus the IANA zone; bounds instead of forced exact times (exact → earliest = latest). Diary entries written soon after the event (Consensus Sleep Diary style); intent-to-rest time is not onset. The one confirmed afternoon nap stays `retrospective_approximate`; its recalled times are never replaced with detector output. Imprecise references are left out of the IoU/edge-error analysis and reported in a separate presence check.
2. **Denominator.** Evaluated monitoring intervals are fixed before scoring: drop spans with no detector input (report their duration); report off-wrist/low-HR-coverage spans with usable motion as their own challenge set. Observed days = eligible monitoring seconds ÷ 86 400 (also report calendar days and hours). Only **fully annotated** monitored days count for precision and FP/day; unlabelled time is unknown, never a negative. A fully annotated day with no nap is in the denominator.
3. **What is scored.** Final classified nap sessions (`sessions-v2`), not raw `SleepStager` candidates (a `lowEvidence` candidate classified *uncertain* is not a predicted nap). Deduplicate sessions replayed across overlapping daily windows. Daytime main sleep and uncertain outcomes are reported separately. Primary run injects **no** diary-derived corrections; a separate run checks that existing confirmations/rejections survive.
4. **Pinning and splits.** Record baseline and candidate commit SHA, algorithm keys, time zone, profile/calibration, correction policy and input snapshot. Split by participant before windowing; with one participant, disjoint chronological days with causal history for both versions, stated as a limitation. All fragments of a recording stay in one split. No tuning on the test split.
5. **Targets** (frozen above): recall ≥ 0.80 for reference naps ≥ 30 min; precision ≥ 0.80 over all emitted naps; FP naps ≤ 0.10 per observed day; median absolute onset **and** offset error ≤ 600 s. **Owner decision still needed before the test run:** whether each target is judged on the point estimate or on a confidence bound, and the improvement rule versus baseline (proposal: fewer FP/day at recall ≥ the target, judged on point estimates with block-bootstrap intervals reported). Zero denominators are reported as "not estimable".
6. **Report.** TP/FP/FN, precision/recall/F1 with intervals, FP/day, mean and median edge errors, duration errors, uncertain/unavailable counts, fragmented/merged counts, people/days/events/exclusions, per duration and coverage stratum, and baseline → candidate deltas on identical inputs. Identical output is not an improvement; inconclusive results keep the acceptance item open.

- **Status: no labelled set exists.** The harness additions are unit-tested on synthetic events only; the measured-improvement criterion of issue #19 is not met. More calendar weeks without labelled events do not reduce the uncertainty — labelled positive and negative events do.

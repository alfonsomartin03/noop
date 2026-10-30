# Workout detection and strain: change report (October 2026)

Implements the first two delivery stages of [the research review](WORKOUT_STRAIN_RESEARCH_2026-10-30.md): deterministic accounting, then conservative detection. The method specification is in [ANALYTICS.md](ANALYTICS.md). Unit tests check bookkeeping against hand-worked values. They do not show that any number reflects true physiological strain.

> **Update, scoring v5:** strain now covers awake time only. See section 10. Figures in sections 3–7 describe v4.

## 1. Defects: what was actually reproduced

Each row was run against the code before this change.

| Lead | Measured before | Now |
|---|---|---|
| Active run crossing a timestamp gap | Two 5-min bursts an hour apart became a 65-min workout, strain 6.83. 20 min + 1 h hole + 20 min became one 100-min session. | No session; two sessions. Holes are unknown time. |
| Duration from the first two rows | One late first reading moved strain from 9.75 to 20.53. | Each second is credited once. |
| Coverage vs load used different rules | Same two samples: 6 s of load, 31 s of coverage. | One interval set behind both. |
| Exclusion not subtracted | Coverage 51 s; exact value 21 s. | Exact interval subtraction. |
| `HRZones.timeInZone` gap credit (found in this audit) | Two samples 5 h apart reported 5 h in a zone, although its comment said gaps were capped. Displayed on the Strain screen. | 6 s. |
| Sample-weighted mean | Mean HR 107 where the time-weighted mean is about 140. | Time-weighted everywhere. |
| "Edwards" on %HRR | 120 bpm, rest 60, max 180 scored band 1; the published %HRmax definition gives band 2. | `edwards` uses %HRmax; the old form is the named variant `edwardsHRR`. |
| Tanaka as a floor | A true maximum of 170 at age 30 was overridden to 187. | A declared value wins. Tanaka is a labelled estimate only. |
| Log map out of bounds | `trimpToStrain(1e6)` = 32.66; a bad denominator gave `inf`. | Removed. The one index is bounded and rejects non-finite input. |
| Rest-day floor | 4.57 with no load at all. | Removed. No measured load is 0; unmeasured time is unknown. |
| Hot points filtered before joining | A 100 s cool stretch inside a run was hidden. | Continuity is judged on the full timeline. |

**Not reproduced:** reversing input order did not change the legacy dose, because the first-gap read used `abs()`. Only irregular spacing did.

**Other confirmed, by reading:** the detector built `motion` and never used it, and its header described a motion gate and an intensity gate that did not exist. Detector and persistence scored sessions by different paths. Day and session HRmax came from different routes. `Repository` and `IntelligenceEngine` each kept their own keep-the-longest rule.

## 2. How input reaches the display now

```
hrSample → HRQuality.clean → SupportedHR (intervals) ─┬→ LoadSummary (day)     → DayLoadRecord → strain index → DailyMetric.strain
                                                      └→ WorkoutDetector → LoadSummary (session) → SessionLoadRecord + WorkoutRow
HRCalibration snapshot ─────────── shared by detection, load and zones ───────────┘
```

Removed as duplicates: `strain()`, `whoopLoad`, `whoopZoneLoad`, `whoopZoneLoadTimed`, `sampleDurationMinutes`, `coveredSeconds`, `highEffortLoad`, `dayStrain`, `activityStrain`, `trimpToStrain`, `fitStrainDenominator`, `estimateHRmax`, `boutIntensity`. Calories were left alone apart from the HR they receive; their own fallbacks (220 / 60) remain and never feed load.

## 3. Behaviour changes

- **Daily load** is integrated over every supported second, then attributed to sessions or incidental activity. Splitting or merging sessions cannot change it, and duplicate records cannot double-count it.
- **No HRmax, no score.** The hidden 190 is gone: load is withheld with the reason `hrmax_unavailable`.
- **Missing differs from zero.** Days under 10 observed minutes get no index and a reason code. Days under 90 % coverage are `partial`, scored on observed time, never scaled up, and labelled on the Strain screen.
- **Detection** needs 15 min of supported active time and 80 % coverage. Observed pauses and sensor gaps are separate. A hole over 5 min is never bridged.
- **Motion** labels evidence and never rejects an episode. No sport is named.
- **Finished days keep their calibration.** An incremental run reuses the stored snapshot, so a later HRmax change does not rewrite history. Settings → recompute is the explicit retrospective operation. Today stays open.
- **Overlap** no longer discards a distinct activity. Rows merge only when 80 % of the shorter lies inside the other.
- **UI** adds partial-day and session-evidence notes, says muscular work isn't measured, and shows zones from the snapshot the day was scored with.

## 4. Read-only replay on real data

Run with `Tools/strain_replay` on a copy of the device database: 12 days, one person, one device, HRmax 204 declared.

| Day type | Old → new | Reading |
|---|---|---|
| Hard days (7 scored) | Within 0.34 (e.g. 19.42 → 19.42, 18.75 → 18.79, 14.99 → 15.33) | Almost all load already sat in sessions. |
| Rest days | 4.56 → 7.61, 4.39 → 6.64 | Floor replaced by 3–4 AU of measured incidental HR. This is the visible change. |
| Early in the day | 1.38 → 0.22 | The floor no longer accrues with time. |
| Day with a gap | 19.59 unchanged, now `partial` (35 % observed) | Previously looked complete. |

Sleep and recovery fields were identical on all 12 days. Of 14 stored sessions, 12 kept their edges within seconds. Two changed: 206 min became 157 + 20 min, and 44 min became 18 min, because stretches hovering at the Zone 1 floor (97–104 bpm) no longer count as active on wall-clock span. That HR stays in the day's load as incidental. On the first session, mean HR moved from 144 to a more representative 157.

Agreement with the previous version is a compatibility check, not validation. No vendor comparison exists either: no day has both a WHOOP strain and strap data (imported workouts end 13 Oct, strap data starts 15 Oct, and the imported 15 Oct row has no strain). Expect rest days to sit above WHOOP's: the fit reached about 4.3 on them through a constant, and NOOP does not tune toward that.

**Worth knowing:** five of the 11 scored days index above 18. The fitted curve saturates quickly, so compare raw load between hard days: days at 104 and 121 AU show as 19.4 and 19.6.

Eleven of 15 sessions read `heartRateStillWrist`, including the hardest ones. The 0.25 moving-fraction cut-off is an unvalidated choice on a 1 Hz orientation signal, so treat that label as a description of the signal, not of the activity.

## 5. Method and version choices

| Item | Choice | Status |
|---|---|---|
| Support | 1 s measured, bounded hold to 5 s labelled estimated, last reading gets its own second | Contract from data: 804,460 of 804,555 gaps were 1 s. Hold is an engineering choice. |
| Zones | One %HRmax system (`HRZones`), half-open bands, 100 % inclusive, above max scored as Zone 5 and flagged | Convention |
| Daily load | Fitted zone weights | Compatibility fit to one person's export. Not a physiological finding. Edwards AU stored beside it. |
| Index | `noop-strain-index-1`: 4.67/4.56 · ln(1 + load) with soft ceiling | Presentation choice, not validated |
| Banister | Integrated and session-mean both implemented, coefficients always explicit | Not computed in production: NOOP will not infer coefficients from gender, and there is no setting yet |
| Thresholds | Unchanged from before, plus 80 % coverage, 5 min unknown bridge, 0.25 moving fraction | Untuned. No labelled data exists. |

Evidence is categorical on purpose: no calibration study exists to support a probability. Stored versions: `cardio-load-2026.10`, `episode-detector-2026.10`, `hr-calibration-1`, `hr-support-1hz-hold5-v1`.

## 6. Tests

Analytics 282 passed, WhoopStore 92 passed, macOS app and its test target compile. `CardioLoadTests.swift` covers the ten required properties. **`StrandTests` were built but not run:** the test host launches the app, which would trigger the migration and re-score on the real database.

## 7. Compatibility and migration

- Store migration **v12** adds `loadRecord`. It was applied cleanly to a copy of the real database.
- `scoringVersion` is now **4**, so the next launch of a build runs one full re-score. It is atomic and archives current rows to `<device>-noop-v3`. Raw samples and imports are untouched. The bump is the safe option: without it, the routine 21-day run would overwrite recent rows with no archive.
- Rest-day scores will visibly rise. Imported WHOOP days are unaffected; imports still win per field.
- Baselines do not change: strain does not feed them.

## 8. Not done

- **Session RPE and strength logging: now done.** The workout sheet takes an optional CR10 response and logged sets (exercise, reps, external kg, optional RIR), stored by migration **v13** in `sessionEffort` and `strengthSet`. Session RPE load and per-exercise volume appear as their own fields beside cardio strain and feed nothing else: no score, baseline or trend reads them. Missing RPE is no row, shown as "Not reported". Each row stores its collection time and provenance; effort also stores its scale.
  - **Re-scores cannot reach these rows.** They have no `deviceId` and are not derived tables, and tests cover a full re-score, a partial replay and `deleteDerived`.
  - **Session minutes** are the workout's elapsed time when the response was saved, including pauses, and stay stored with it. A later re-score does not change an existing load until the answer is changed.
  - **A moved session keeps its entry by overlap.** Entries stay keyed to the start they were logged under, and a workout with no exact match shows the logged entry it overlaps most, with a note. So a session split by a re-score can show the same entry on both parts, and in a merge the other entries stay stored but are not shown.
  - **Limits:** whole CR10 points only, though half points can be stored. Editing a set means removing and re-adding it. Exercise names are free text, so "Bench" and "bench" count as separate exercises. A set's load is what was typed, with no dumbbell, unilateral or assistance conventions. There are no trends yet, and the sheet is the only place these values appear.
- **Power metrics** are registered as unavailable because no power input exists.
- **Cross-midnight sessions** still appear as two rows. Load is exact; only the presentation splits.
- **Session onset** lags true start by about 30 s (trailing median).
- **Trends** do not yet mark partial days.
- **Evaluation:** `DetectionEvaluation` is built and tested but has scored nothing.

## 9. Claims still unsupported, and the data they need

| Claim | Status | Needed |
|---|---|---|
| Detection accuracy | Unknown | Independently annotated sessions plus ordinary negative days (commuting, chores, stress, sensor removal), across several people. Fix matching criteria first. |
| Activity labels | None made | Labelled data on this motion representation; check its sample rate and synchronization against a reference. |
| HR accuracy on this strap | Unknown | Synchronized ECG by activity, reported as bias and limits of agreement. |
| Load as "true strain" | Not established | Nothing can establish this directly. Arithmetic is verified; the construct is not. |
| Index comparability between people | Not established | Multi-person data. The fit is one person. |
| Perceived effort, strength | Not collected | Real RPE and exercise logs. |
| Recovery or injury prediction | Not claimed | A prospective outcome study. |

## 10. Awake-time strain (scoring v5)

Strain now means accumulated awake-time load. `summary`, the index and the Strain screen's "Awake-time heart-rate zones" read one interval set, so they cannot disagree. The Home chart, its statistics and total-day calories still use full-day data. Versions: `cardio-load-awake-2026.10`, `scoringVersion` 5. Imports and user entries are untouched.

**Does excluding sleep change the score? On this data, no.** Replay of 12 days on a copy of the device database, comparing stored v4 rows with v5:

| Trace | Result |
|---|---|
| Change in day index | 0.00 on all 12 days |
| Load inside excluded sleep | 0.00 AU on every day (7.0–8.7 h excluded on full days) |
| Why | Sleep HR stayed below 102 bpm (Zone 1 at HRmax 204), and Zone 0 weighs nothing. Zone 0 duration never added strain; v4's only time-based constant, the floor, was already gone. |
| What did change | Zone table: sleep hours leave Zone 0. Coverage denominator: awake time, not the day, so a day in progress with 12.8 h of HR reads 35 % of awake time rather than 53 % of the day. |
| Sleep and recovery fields | Identical on all 12 days |

The score would move only for sleep HR at or above 50 % of HRmax, such as a low declared HRmax, fever or misclassified sleep.

**A defect the acceptance test found:** a sleep reading's 5 s hold ran past the end of sleep into awake time, so adding sleep-only HR moved awake totals by 4 s. A reading inside an excluded span now carries nothing out of it.

**"0m recorded":** not a data contradiction. Both figures read the same 24 h. The energy caption held "24h 0m", and its two-line tile wrapped at that space, leaving "0m recorded" on a line of its own. The cause was found by reading the layout, not by rendering it. The formatter now uses a non-breaking space. Separately, energy used a 60 s gap cap while coverage used 5 s, so they could really differ on gappy days; both now use supported seconds.

**Remaining uncertainty:** sleep classification is itself an unvalidated estimate, and every exclusion inherits its errors. A nap or night it misses stays in as awake time. A finished day can change when later data arrives, because sleep starting before midnight only shows then; days with no later data stay provisional. Sessions crossing into sleep lose those seconds from their own load only. Trends do not yet mark provisional days.

## 11. Labels, score colors, performance and incremental scoring

### Workout labels

Activity type lives in `workoutLabel`, source data outside everything a re-score replaces. Order: user-selected, then imported, then inferred. NOOP has no validated classifier, so nothing is inferred and a detected session reads Unknown until someone sets it. A label finds its workout by overlap, so it survives detection moving, splitting or merging a session. No load method reads a label, so changing one recalculates nothing.

### Score colors

Recovery runs red, yellow, green and strain runs green, yellow, red, sharing three hues so the scales are exact mirrors. A missing score uses a neutral tint; `w.strain ?? 8` used to paint a missing score as a real one. Score text uses `scoreInk`, because the app supports light mode, where pure yellow on white is about 1.2:1. All score text now reaches 4.5:1 in both appearances. High strain carries a line saying it means high load, not a bad day.

### Measured performance

`Tools/perf_probe` on a copy of one person's database, release build, one machine, median of repeated runs. Representative, not a benchmark.

| Step | Before | After |
|---|---|---|
| Read, 144k HR rows | 51.9 ms | 15.6 ms |
| Read, 144k gravity rows | 79.2 ms | 20.7 ms |
| Read, 75k R-R rows | 41.1 ms | 22.2 ms |
| `WorkoutDetector.detect` | 72.7 ms | 5.5 ms |
| `analyzeDay` with following data | 172 ms | 102 ms |
| Full scoring pass, every run (12 days) | 4,198 ms | 2,149 ms |
| Scoring pass with nothing changed (21 days) | 4,198 ms or more | **66 ms** |
| Scoring pass after one late hour | 4,198 ms or more | 532 ms |

Causes: reads decoded columns by name, and the detector sorted a 60-sample window for every sample. The largest cost was repeating the whole pass with nothing changed.

**Left alone:** every screen query took 0.1–2 ms and already used an index. No index was added: the only extra sort is on `rrInterval`, whose order needs `rowid`, which SQLite cannot index. Sleep staging (64 ms) was not rewritten, because it is the riskiest code and the cache avoids it. The day summary behind Today and Strain took about 8 ms on the main actor; it now runs off-main and validates HR once. That change was not re-timed in the app.

### Incremental scoring

`IncrementalScorer` reuses a stored day while its algorithm key, day range, input data, imported sessions and baselines are unchanged. Streams are insert-only, so rows past saved high-water marks are exactly the new data, and each lands in the days that read it (-16 h to +12 h). Baselines are re-derived during the walk, so a late night touches only days whose baselines really moved. Finalized days ignore profile edits; only an algorithm change or the Settings recompute rewrites them. Results, day states and marks commit together. A re-score runs in 30-day atomic batches, archives once, and resumes where it stopped.

Real-data check: one hour of a day was removed from a copy and scored, then restored as late data. Exactly 2 of 21 days recomputed, and every stored result was byte-identical to scoring all the data at once. Results against the previous code also matched the earlier replay day for day.

### Limits

- Late data relies on streams staying insert-only. A future writer that updates or deletes rows would bypass the marks and must also touch them.
- Profile edits do not reach finalized days, including weight in stored calories. That is deliberate, and the Settings recompute applies them.
- Detection, labels and colors were not exercised in the running app: launching a build starts the re-score on the real database.
- `perf_probe` timings cover one person and 12 days of data, so long-history behaviour is projected, not measured.


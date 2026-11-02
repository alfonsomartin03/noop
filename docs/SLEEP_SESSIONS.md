# Sleep sessions, naps and interrupted sleep

## Audit (before this change)

| Problem | Where | Effect |
|---|---|---|
| Classification decided detection | `SleepStager.classifyCandidate` used stricter "nap" bars for any span 10:00–18:00 shorter than 4 h | A shift worker's 3.5-h day sleep could be rejected as sleep, not just mislabelled |
| Rigid clock window | same, `siestaStartHour…siestaEndHour` | Long day sleep = nap; no notion of the wearer's own schedule |
| Long awakenings split nights | `canBridge`: never across > 90 min | Waking 5:00, asleep again 7:00 → a night plus a "nap" (or the second part rejected by nap bars) |
| No short naps | `napMinMin` 30 | 20–30 min naps invisible |
| Any `.main` span fed recovery | `AnalyticsEngine.analyzeDay` used every main session ending that day | A long daytime sleep + a night both entered HRV/RHR |
| One row per day on screen | `Repository.mergeSleep` kept the longest row | An interrupted night showed only its longest fragment |
| Latent crash | `convolveReflect` padding for series shorter than the 10-min HR kernel | Any < 30-min session crashed staging (exposed by 20-min candidates; fixed) |

## Architecture (now)

| Layer | Code | Output |
|---|---|---|
| A epochs | `SleepStager` (stillness minutes, Cole–Kripke epochs, HR dip) | per-minute / per-epoch evidence |
| B episodes | `SleepStager.detectSleep` | `SleepSession` spans; accepted on their own evidence and LENGTH only (never clock time); 20–30 min spans kept as candidates |
| C sessions | `SleepSessionClassifier.group` | episodes joined when the gap ≤ 50 min, or ≤ 150 min with both sides in the habitual sleep window; gaps kept |
| D labels | `SleepSessionClassifier.classify` + corrections | `primary`, `interruptedPrimary`, `nap`, `uncertain`, with confidence and a reason |
| E metrics | `AnalyticsEngine.analyzeDay` | recovery/HRV/RHR/night totals from the primary only; naps in 24-h sleep; uncertain counted nowhere |

### Nap / primary rules (heuristics, to validate)

- **Habit** (`SleepHabit.learn`): circular mean of the last ≤ 21 primary midpoints (local clock) and median length;
  fallback 03:30 / 7.5 h until 3 nights exist. Learned from the wearer, so shift work and travel adapt.
- **Primary per wake day** (`dayString(end)`): among sessions with ≥ 3 h asleep, or ≥ 40 % of the typical night when
  centred in the habitual window, the one with the highest `asleep_h × circadian weight` (1.0 at the habitual
  midpoint → 0.5 twelve hours away). A long day sleep wins over a short night nap; a short night sleep can be a nap.
- **Nap**: any other session with ≥ 20 min asleep and an episode ≥ 30 min. **Uncertain**: shorter / weaker
  (detection resolution is ~15 min); excluded from totals until confirmed.
- **Provisional**: sessions still being recorded keep confidence ≤ 0.5; every sync re-labels them.

### Corrections (`SleepCorrection`, table `sleepCorrection`, migration v15)

Mark nap / mark main sleep (demotes the other primary that day) / confirm / reject (quiet rest) / merge / split
(between episodes only) / adjust times (clips metrics, episodes untouched). Stored as source data, matched to
sessions by ≥ 50 % time overlap so they survive regrouping and late data, newest wins, never overridden
automatically. A correction re-scores only the days whose window it touches (it is part of that day's score key).

### Recovery rules

One primary per wake day → one recovery. Naps never replace it and never enter HRV/RHR. The wake day is the local
day of the primary's last episode end, so a night crossing midnight (or DST) is one cycle. Daily totals: primary
episodes (awake gaps excluded); 24-h sleep: primary + naps, overlaps counted once.

## Staging limitations

Signals available: stored 1 Hz HR, R-R, and a 1 Hz gravity vector (no raw accelerometer stream, no PPG/temperature
decoded). Staging stays the existing retrospective heuristic (`heuristic-quota-v1`, labelled approximate); it uses
the whole night, so it is not a realtime algorithm. Smart wake uses a separate causal heuristic on realtime HR only
(`WakeEvidence`), never future samples. Deep/REM are estimates, not EEG stages.

## Validation evidence

- 25 scenario tests (`SleepSessionClassifierTests`): normal night, short/long/20-min naps, brief and 75-min
  awakenings, 5:00→7:00 return, multiple awakenings, night shift, long day sleep, short night nap, split/biphasic,
  two nights in one window, DST fall-back, travel shift, provisional, missing data inside a night, every correction.
- Full analytics regression suite: 350 tests pass, including the existing staging/strain scenarios.
- **No accuracy figures exist yet**: there is no annotated reference (diary or PSG). Nap detection accuracy is
  unmeasured. Next step: a sleep/nap diary for 2–3 weeks to compute precision/recall and boundary error.

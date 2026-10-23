# Sleep / strain / recovery: lineage, algorithms, limits

All scores are **NOOP estimates** (WHOOP-*like*, fitted to a WHOOP export; not WHOOP's proprietary algorithm, not clinical).

## Data lineage

| Metric | Source signal | Code path | Kind |
|---|---|---|---|
| HR, RR intervals, gravity (accel-derived), resp | Strap over BLE, 1 Hz, UTC unix seconds | `BLE/*` → `WhoopStore` (PK `(deviceId, ts)`: duplicates impossible) | measured |
| Sleep sessions / stages | gravity + HR + RR (+resp if present) | `SleepStager.detectSleep` | estimated (stages: weakest) |
| Resting HR, avg HRV | HR / RR inside the night | `SleepStager.sessionRestingHR/AvgHRV` | calculated |
| Recovery | HRV, RHR vs personal baseline, sleep efficiency | `RecoveryScorer` | estimated; nil without baseline or a ≥3 h night |
| Strain | HR only | `StrainScorer` | estimated cardiovascular load (no muscular load) |
| Imported WHOOP days | CSV export | `WhoopImporter` (device `my-whoop`) | imported; wins over NOOP per field in `Repository.mergeDaily` |
| Not available | raw PPG, SpO₂/skin temp, user bedtime | — | never fabricated |

Computed rows live under `<device>-noop`; every sync re-scores the last 21 days (`IntelligenceEngine.analyzeRecent`), replacing that span's computed sleep rows.

## Day boundary
A "day" is the **local calendar day** in the zone in force then (`ZoneTimeline`). A night belongs to the day it **ends** on. Day windows are real calendar days (DST days are 23/25 h). Strain and workouts use only the day's own `[from, to)`; sleep reads from 16 h earlier so a night that began yesterday evening is complete.

## Sleep (`SleepStager`)
1. 60 s bins: quiet when max |Δgravity| < 0.02 g. A minute is sleep-like when ≥80 % of a centred 15-min window is quiet.
2. Runs ≥30 min with ≥85 % quiet minutes and (when waking-motion HR exists) median HR ≥8 % below it become fragments.
3. Fragments are one session when the gap (eroded by the window) is ≤50 min (WHOOP benchmark, tunable), or ≤90 min **and** the wearer stayed in bed (≤35 % moving minutes). A gap with <50 % data coverage is never bridged: missing data is not sleep.
4. Edges: lying-awake time is trimmed when the 5-min mean HR stays above sleeping level + max(12 bpm, 25 %) (loose on purpose).
5. Kind: ≥180 min → main, 30–180 → nap, daytime (10–18 h) <4 h → nap. A nap must also have HR near the wearer's own sleeping HR (this window's night, else the resting-HR baseline, else a ≥18 % dip).
6. `isProvisional` while the recording ends <60 min after the final wake; the day is recomputed on every sync so boundaries are revised when later data arrives.
7. Stages: epochs without gravity data are *wake/unscored*; HR/RMSSD are detrended (±45 min) before ranking; deep ≤17 % (first half of night), REM ≤22 % (≥30 min after onset) — population priors, margin-gated.

Sources: Marino 2013 (actigraphy sens 0.97 / spec 0.33), Walch 2019 (HR+motion ~60 % wake specificity, ~72 % 3-class), Trinder 2001 and Boudreau 2013 (autonomic change with stage and circadian phase). Thresholds above are engineering choices, not published constants.

## Strain (`StrainScorer`)
Zone load = Σ (zone weight × minutes), zones = 50/60/70/80/90 % of HRmax (Tanaka), weights 0.105/0.110/0.347/0.749/1.875. **Each sample is credited the time to the next sample, capped at 5 s**, so gaps, duplicates and sampling rate cannot create load. Day strain = 4.67·ln(1 + 1.66·coverage + Σ workout loads) with a soft ceiling <21, where `coverage` = recorded HR seconds in the day ÷ 86 400. HR is first passed through `HRQuality` (dedupe, 30–230 bpm, isolated ≤3-sample spikes >30 bpm from agreeing neighbours).

## Known limitations
- Quiet wakefulness *inside* a night (lying awake mid-night) is not separated from sleep; only the ends are trimmed.
- No user-correction store: manual sleep edits and their provenance are **not implemented**. Imported/other-device rows are never touched by re-scoring.
- Muscular load (lifting, yoga) is not modelled; HR-only.
- Zone-time fit is to one person's WHOOP export; no PSG or labelled bedtime data exists here, so no onset/wake error figures can be reported.
- Past nights before the zone log existed are read in the first zone logged.

## Resting HR, HRV and recovery (audit of the recovery inputs)
Units/decoding were verified: standard-HR RR is converted 1/1024 s → ms; stored RR averages 972 ms, and per-window beat counts match HR × time (coverage ≈ 1.0). No HRV is derived from HR.

Confirmed defects (found on real nights Oct 22–23):
1. HRV was the **mean of unfiltered 5-min RMSSD windows over the whole in-bed span** (range filter only, ≥2 intervals/window): 74 ms with a 265 ms artifact window, where the median of coverage- and artifact-checked windows is ~51 ms.
2. RMSSD differenced beats across rejected beats and data gaps.
3. "Resting HR" was the single lowest 5-min mean (a floor): 47–48 bpm vs 52.6 (10th pct) / 56.7 (median) of the same night.

Now (`SleepVitals.swift`): windows must lie inside the detected session, outside the first 10 / last 5 min, ≥90 % non-wake, with enough HR/RR coverage and ≥80 % of intervals surviving artifact rejection. **HRV = median of valid windows; resting HR = mean of the lowest quartile of valid windows.** Fewer than 6 valid windows → unavailable. `minSampleHR`, `minWindowHR`, `avgSleepHR` are exposed separately. Developer view: Settings → Advanced → Recovery diagnostics.

Recovery weights (HRV 0.86, RHR 0.04, resp 0.07, sleep 0.03) are the earlier fit to one WHOOP export; they are not independently validated. Baselines mix imported WHOOP nights and NOOP-measured nights, which use different methods, so a persistent offset between them shifts every z-score.

# What a WHOOP export reveals about its scoring

Fitted from one user's export (628 days, Jan 2025 → Oct 2026: `physiological_cycles.csv`, `sleeps.csv`,
`workouts.csv`). Reproduce with `python Tools/reverse_engineer/analyze_export.py <export_dir>`.

**Limits.** The export holds daily outputs only. There is no heart-rate, R-R or accelerometer
time series, so everything below is *input-summary → output* regression. Anything that needs the raw
signal (sleep staging, HRV/RHR extraction, the day-long strain integral) cannot be recovered from it.
These are fits to one person's data, not WHOOP's algorithm. "MAE" is in score points / minutes.

## Sleep: arithmetic that is exact

| Relation | Result |
|---|---|
| light + deep + REM = asleep | exact (0 error, 628/628) |
| asleep + awake = in bed | exact |
| efficiency = asleep / in bed | MAE 0.47 pts (rounding) |

Typical architecture here: light 47 %, deep 31 %, REM 22 % of asleep time; deep ≈ 77 + 0.13·asleep min,
REM ≈ −34 + 0.30·asleep min (REM scales with sleep length, deep barely does).

## Sleep performance (MAE 3.0)

`performance ≈ 3.5 + 32.4·min(1, asleep/need) + 0.28·consistency + 0.35·efficiency`

Three roughly equal components (about a third each): hours vs. need (capped at 100 %), consistency,
efficiency. WHOOP also lists a "sleep stress" term; it is not in the export, and explains the remaining error.
Stage durations and strain add nothing.

## Sleep need and debt

- `need ≈ debt + 454 + 4.0 × (previous day's strain)` minutes. Median error is 6 min; a few outliers
  (probably naps) are far off.
- `debt ≈ 0.45 × (previous night's shortfall, i.e. max(0, need − asleep)) + 0.05 × previous debt + 5` (MAE 7 min).
  Only about 45 % of a missed night carries over, and it decays.
- Consistency tracks how much sleep onset and wake time vary over the last ~3 days (R² 0.38). Window length
  and exact formula are not pinned down.

## Recovery (R² 0.89, MAE 5.0)

`recovery ≈ 100 / (1 + exp(−(0.85·zHRV + 0.13·zRHR + 0.40)))`

- `zHRV` = z-score of **ln(HRV)** against an exponentially weighted baseline with span ≈ 20 nights
  (a 10–30 night span works; 45+ is clearly worse).
- `zRHR` = same for resting HR, sign flipped. `z` = deviation / (1.253 × EWMA abs deviation).
- HRV carries about 85 % of the weight. Adding respiratory rate, sleep performance, skin temp or SpO2
  moves MAE by under 0.5 pt (R² 0.90). Prior-day strain and sleep efficiency add nothing.
- The intercept puts an average night at ~60 %, close to WHOOP's quoted population mean of 58.
- A gradient-boosted model on every column reaches only R² 0.88, so most of the remaining error is
  not recoverable from the export. Likely causes: HRV/RHR taken at different sleep windows than the
  exported values, and the unexported sleep-stress term.

## Strain (workouts MAE 0.7, days MAE 0.9)

`activity strain ≈ 4.56 · ln(1 + 0.105·(1·m1 + 1.05·m2 + 3.3·m3 + 7.1·m4 + 17.9·m5))`
where `mZ` is minutes in HR zone Z (the zone percentages WHOOP reports times duration).

- It is a logarithm of a weighted zone-minutes total, and the weights climb steeply: a minute in zone 5 is
  worth ~18 zone-1 minutes, zone 4 ~7. Zones 1 and 2 are nearly equal. Plain Edwards weights (1–5)
  fit worse (MAE 1.25).
- Day strain follows the same shape with a floor: `4.67·ln(1 + T + 1.66)`. The 1.66 explains why a
  rest day sits at ~4.3 and why strain rarely drops near zero.
- 21 corresponds to a weighted total of roughly 100.
- Calories alone: `strain ≈ 17.5·ln(calories) − …` (R² 0.90) — a weaker proxy than the zones.
- Calories ≈ 6.8·(workout minutes) + 33·(avg HR) − 359 (R² 0.90).

## What was applied to NOOP

- **Recovery** (`RecoveryScorer`, `Baselines`): weights are now 0.86 / 0.04 / 0.07 / 0.03 (HRV / RHR / resp / sleep),
  logistic k = 1.1, z0 = −0.39, and the HRV, resting-HR and respiration baselines use a 7-night half-life
  (was 0.60 / 0.20 / 0.05 / 0.15, k 1.6, z0 −0.2, 14 nights). On the export the old form scored MAE ≈ 5.8, the refit 4.5.
  An average night now scores ~60 instead of 58.
- **Strain** (`StrainScorer`, `AnalyticsEngine`): new `.whoop` method, now the default, using %HRmax zones and the fitted
  weights; day strain is `dayStrain(workoutLoads:)` over the detected workouts only, with the 1.66 floor.
  `.edwards` and `.banister` remain available.
- **Not validated end to end.** The fits used WHOOP's own zone minutes. The app's workout detection and HRmax
  (Tanaka age estimate) differ from WHOOP's, so check day strain against WHOOP once the strap has recorded
  several days. Counting all-day zone minutes instead of workouts only would overshoot, because the floor already
  stands in for non-workout load.
- **Sleep staging** cannot be fitted from this export. To calibrate the stager, compare its output with WHOOP's on
  nights where the strap's own HR/R-R/motion was also recorded.

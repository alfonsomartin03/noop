#!/usr/bin/env python3
"""Fit relationships between the metrics in a WHOOP data export (physiological_cycles.csv,
sleeps.csv, workouts.csv). Usage:  python analyze_export.py <export_dir>
Needs: pandas numpy scipy scikit-learn. Results are summarised in docs/WHOOP_REVERSE_ENGINEERING.md."""
import sys, warnings, numpy as np, pandas as pd
from scipy.optimize import least_squares
from sklearn.linear_model import HuberRegressor
warnings.filterwarnings("ignore")
D = sys.argv[1].rstrip("/") + "/"

c = pd.read_csv(D + "physiological_cycles.csv").rename(columns={
    "Cycle start time": "cs", "Recovery score %": "rec", "Resting heart rate (bpm)": "rhr",
    "Heart rate variability (ms)": "hrv", "Day Strain": "strain", "Energy burned (cal)": "cal",
    "Sleep performance %": "perf", "Respiratory rate (rpm)": "resp", "Asleep duration (min)": "asleep",
    "In bed duration (min)": "inbed", "Sleep need (min)": "need", "Sleep debt (min)": "debt",
    "Sleep efficiency %": "eff", "Sleep consistency %": "cons"})
c["cs"] = pd.to_datetime(c["cs"]); c = c.sort_values("cs").reset_index(drop=True)
c["prev_strain"] = c.strain.shift(1)

# Robust z-score vs a trailing EWMA baseline, mirroring the baselines used on-device.
def z(series, span=20):
    dev = series - series.ewm(span=span, min_periods=7, adjust=False).mean().shift(1)
    sd = dev.abs().shift(1).ewm(span=span, min_periods=7, adjust=False).mean() * 1.253
    return dev / sd

def mae(a, b): return float(np.nanmean(np.abs(a - b)))

# Section 1: how sleep efficiency / performance / need / debt relate to each other.
print("== Sleep arithmetic")
print(" efficiency = asleep/in-bed        MAE %.2f pts" % mae(c.eff, 100 * c.asleep / c.inbed))
c["hvn"] = np.minimum(1, c.asleep / c.need)
d = c[["perf", "hvn", "cons", "eff"]].dropna()
h = HuberRegressor().fit(d[["hvn", "cons", "eff"]], d.perf)
print(" performance = %.1f + %.1f*min(1,asleep/need) + %.3f*consistency + %.3f*efficiency   MAE %.2f"
      % (h.intercept_, h.coef_[0], h.coef_[1], h.coef_[2], mae(d.perf, h.predict(d[["hvn", "cons", "eff"]]))))
d = c[["need", "debt", "prev_strain"]].dropna()
h = HuberRegressor().fit(d[["prev_strain"]], d.need - d.debt)
print(" need = debt + %.0f + %.2f*prev-day strain   median abs err %.1f min"
      % (h.intercept_, h.coef_[0], np.median(np.abs(d.need - d.debt - h.predict(d[["prev_strain"]])))))
c["sf"] = (c.need - c.asleep).clip(lower=0)
d = pd.DataFrame({"debt": c.debt, "dp": c.debt.shift(1), "sp": c.sf.shift(1)}).dropna()
A = np.c_[d.dp, d.sp, np.ones(len(d))]; k = np.linalg.lstsq(A, d.debt, rcond=None)[0]
print(" debt = %.2f*prev debt + %.2f*prev shortfall + %.1f   MAE %.1f min" % (*k, mae(d.debt, A @ k)))

# Section 2: fit recovery as a logistic of HRV and resting-HR z-scores.
print("== Recovery = logistic(a*z(ln HRV) + b*z(-RHR) + c), EWMA span-20 baselines")
c["lnhrv"] = np.log(c.hrv)
X = np.c_[z(c.lnhrv), z(-c.rhr)]; y = c.rec.values; ok = ~np.isnan(X).any(1) & ~np.isnan(y)
f = lambda p: 100 / (1 + np.exp(-(X[ok] @ p[:2] + p[2]))) - y[ok]
r = least_squares(f, [.5, .2, 0]); res = f(r.x)
print(" a=%.3f b=%.3f c=%.3f  MAE %.2f  R2 %.3f" % (*r.x, np.abs(res).mean(), 1 - (res**2).sum() / ((y[ok] - y[ok].mean())**2).sum()))

# Section 3: fit activity strain as k * ln(1 + weighted zone minutes).
print("== Strain = k*ln(1 + sum_z w_z * minutes_in_zone_z)")
w = pd.read_csv(D + "workouts.csv")
for i in range(1, 6): w[f"m{i}"] = w["Duration (min)"] * w[f"HR Zone {i} %"] / 100
w = w[w["Activity Strain"] > 0]; M = w[[f"m{i}" for i in range(1, 6)]].values; ys = w["Activity Strain"].values
g = lambda p: p[0] * np.log1p(M @ np.abs(p[1:])) - ys
r = least_squares(g, [4.5, .1, .1, .3, .7, 1.8])
print(" k=%.2f zone weights=%s  MAE %.2f" % (r.x[0], np.abs(r.x[1:]).round(3), np.abs(r.fun).mean()))

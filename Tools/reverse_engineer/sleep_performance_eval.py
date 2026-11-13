#!/usr/bin/env python3
"""Held-out evaluation of sleep-performance hypotheses against a WHOOP export (issue #16).

Usage:  python3 sleep_performance_eval.py <export_dir> [--train 0.7]

Reads physiological_cycles.csv and sleeps.csv (either or both; joined per sleep, naps dropped), reports eligible and
excluded counts and, splitting the scored nights by time (first 70 % to fit, last 30 % held out), held-out MAE for:
  H1  100 * min(1, asleep / need)                         (NOOP v1 structure, using WHOOP's own need)
  H2  a + b*min(1, asleep/need) + c*consistency + d*eff   (fit on the training nights; see WHOOP_REVERSE_ENGINEERING.md)
H1 and H2 are compared on the same held-out nights. Stdlib only. Export research, not BLE decoding. Results are only as general as the export they were run on.
"""
import csv, os, sys


def _f(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


FILES = ("physiological_cycles.csv", "sleeps.csv")
FIELDS = (("perf", "Sleep performance %"), ("asleep", "Asleep duration (min)"), ("need", "Sleep need (min)"),
          ("cons", "Sleep consistency %"), ("eff", "Sleep efficiency %"))


def load(export_dir):
    """Main-sleep rows with perf, asleep, need, consistency, efficiency (None where missing), oldest first.

    Both export files are read when present and joined on the sleep's identity (cycle start + sleep onset): a value
    missing or blank in one file is taken from the other, so an incomplete physiological_cycles.csv no longer hides a
    complete sleeps.csv. Naps (sleeps.csv "Nap" = true) are dropped, including a cycles row for the same sleep.
    Conflicting non-blank values keep the first file's value and are counted in load.stats["conflicts"].
    """
    merged, naps, stats = {}, set(), {"files": [], "naps": 0, "conflicts": 0, "duplicates": 0}
    for name in FILES:
        path = os.path.join(export_dir, name)
        if not os.path.exists(path):
            continue
        stats["files"].append(name)
        with open(path, newline="", encoding="utf-8-sig") as fh:
            seen = set()
            for r in csv.DictReader(fh):
                cycle, onset = (r.get("Cycle start time") or "").strip(), (r.get("Sleep onset") or "").strip()
                if not (cycle or onset):
                    continue
                key = (cycle, onset)
                if str(r.get("Nap", "false")).strip().lower() == "true":
                    naps.add(key)
                    continue
                if key in seen:
                    stats["duplicates"] += 1
                    continue
                seen.add(key)
                row = merged.setdefault(key, {"t": onset or cycle, **{k: None for k, _ in FIELDS}})
                for k, col in FIELDS:
                    v = _f(r.get(col))
                    if v is None:
                        continue
                    if row[k] is None:
                        row[k] = v
                    elif abs(row[k] - v) > 1e-6:
                        stats["conflicts"] += 1
    if not stats["files"]:
        raise FileNotFoundError("no physiological_cycles.csv or sleeps.csv in " + export_dir)
    stats["naps"] = len(naps)
    rows = sorted((r for k, r in merged.items() if k not in naps), key=lambda r: r["t"])
    load.stats = stats
    return rows


load.stats = {}


def eligibility(rows):
    """How many rows each hypothesis can use, and why the rest are excluded (a row is counted under its first gap)."""
    out = {"rows": len(rows), "h1": 0, "h2": 0, "noPerformance": 0, "noAsleepOrNeed": 0, "noConsistencyOrEfficiency": 0}
    for r in rows:
        if r["perf"] is None:
            out["noPerformance"] += 1
        elif r["asleep"] is None or not r["need"]:
            out["noAsleepOrNeed"] += 1
        else:
            out["h1"] += 1
            if r["cons"] is None or r["eff"] is None:
                out["noConsistencyOrEfficiency"] += 1
            else:
                out["h2"] += 1
    return out


def h1(r):
    if r["asleep"] is None or not r["need"]:
        return None
    return 100.0 * min(1.0, r["asleep"] / r["need"])


def _solve(a, b):
    """Gaussian elimination for a small dense system a x = b."""
    n = len(b)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(n):
        p = max(range(c, n), key=lambda i: abs(m[i][c]))
        if abs(m[p][c]) < 1e-12:
            raise ValueError("singular")
        m[c], m[p] = m[p], m[c]
        for i in range(n):
            if i != c:
                f = m[i][c] / m[c][c]
                m[i] = [x - f * y for x, y in zip(m[i], m[c])]
    return [m[i][n] / m[i][i] for i in range(n)]


def _features(r):
    if None in (r["asleep"], r["need"], r["cons"], r["eff"]) or not r["need"]:
        return None
    return [1.0, min(1.0, r["asleep"] / r["need"]), r["cons"], r["eff"]]


def fit_h2(rows):
    xs, ys = [], []
    for r in rows:
        x = _features(r)
        if x is not None and r["perf"] is not None:
            xs.append(x); ys.append(r["perf"])
    k = 4
    ata = [[sum(x[i] * x[j] for x in xs) for j in range(k)] for i in range(k)]
    aty = [sum(x[i] * y for x, y in zip(xs, ys)) for i in range(k)]
    return _solve(ata, aty)


def mae(pairs):
    pairs = [(a, b) for a, b in pairs if a is not None and b is not None]
    return (sum(abs(a - b) for a, b in pairs) / len(pairs), len(pairs)) if pairs else (None, 0)


def evaluate(rows, train=0.7):
    """Chronological split of the rows that carry a reported performance. H1 and H2 are compared on the same held-out
    nights (those with every H2 input: "comparable"); H1 is also reported on all its own eligible held-out nights."""
    scored = [r for r in rows if r["perf"] is not None]
    cut = int(len(scored) * train)
    fit, held = scored[:cut], scored[cut:]
    out = {"nights": len(rows), "scored": len(scored), "train": len(fit), "heldOut": len(held),
           "eligibility": eligibility(rows), "heldOutEligibility": eligibility(held)}
    out["h1"] = mae((h1(r), r["perf"]) for r in held)
    comparable = [r for r in held if _features(r) is not None]
    out["h1_comparable"] = mae((h1(r), r["perf"]) for r in comparable)
    try:
        w = fit_h2(fit)
        out["h2_coef"] = w
        out["h2"] = mae((sum(a * b for a, b in zip(w, _features(r))), r["perf"]) for r in comparable)
    except (ValueError, ZeroDivisionError):
        out["h2"] = (None, 0)
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__); return 2
    train = float(argv[argv.index("--train") + 1]) if "--train" in argv else 0.7
    res = evaluate(load(argv[1]), train)
    st, el, he = load.stats, res["eligibility"], res["heldOutEligibility"]
    print("files: %s; naps dropped %d, duplicate rows %d, conflicting values %d"
          % (", ".join(st["files"]), st["naps"], st["duplicates"], st["conflicts"]))
    print("main sleeps %d: eligible H1 %d, H2 %d; excluded: no performance %d, no asleep/need %d; H2 only: no consistency/efficiency %d"
          % (el["rows"], el["h1"], el["h2"], el["noPerformance"], el["noAsleepOrNeed"], el["noConsistencyOrEfficiency"]))
    print("chronological split of %d scored nights: fit %d, held out %d (held-out eligible H1 %d, H2 %d)"
          % (res["scored"], res["train"], res["heldOut"], he["h1"], he["h2"]))
    fmt = lambda m: "%.2f" % m if m is not None else "n/a"
    print("%-36s held-out MAE %s over %d nights" % ("H1 100*min(1, asleep/need)", fmt(res["h1"][0]), res["h1"][1]))
    print("%-36s held-out MAE %s over %d nights" % ("H1 on the nights H2 can score", fmt(res["h1_comparable"][0]), res["h1_comparable"][1]))
    print("%-36s held-out MAE %s over %d nights" % ("H2 fitted 3-term", fmt(res["h2"][0]), res["h2"][1]))
    if "h2_coef" in res:
        print("H2 coefficients (intercept, hours-vs-need, consistency, efficiency):", ["%.3f" % c for c in res["h2_coef"]])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

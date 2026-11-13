import os, random, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(__file__))
import sleep_performance_eval as spe


class SleepPerformanceEvalTests(unittest.TestCase):
    def _export(self, n=60, seed=1):
        rnd = random.Random(seed)
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "sleeps.csv"), "w") as fh:
            fh.write("Cycle start time,Nap,Sleep performance %,Asleep duration (min),Sleep need (min),Sleep consistency %,Sleep efficiency %\n")
            for i in range(n):
                asleep, need = rnd.uniform(300, 540), rnd.uniform(420, 540)
                cons, eff = rnd.uniform(50, 95), rnd.uniform(80, 98)
                perf = 3.5 + 32.4 * min(1, asleep / need) + 0.28 * cons + 0.35 * eff
                fh.write("2026-01-%02d 07:00:00,false,%.1f,%.0f,%.0f,%.1f,%.1f\n" % (i % 28 + 1, perf, asleep, need, cons, eff) if i < 28 else
                         "2026-02-%02d 07:00:00,false,%.1f,%.0f,%.0f,%.1f,%.1f\n" % (i - 27, perf, asleep, need, cons, eff))
            fh.write("2026-03-01 13:00:00,true,50,30,0,0,0\n")   # nap rows are ignored
        return d

    def test_recovers_synthetic_three_term_model_on_held_out_nights(self):
        res = spe.evaluate(spe.load(self._export()))
        self.assertEqual(res["nights"], 60)
        self.assertLess(res["h2"][0], 0.2)
        self.assertGreater(res["h1"][0], res["h2"][0])

    HEAD = "Cycle start time,Sleep onset,Nap,Sleep performance %,Asleep duration (min),Sleep need (min),Sleep consistency %,Sleep efficiency %\n"

    def _write(self, d, name, lines, head=None):
        with open(os.path.join(d, name), "w") as fh:
            fh.write(head or self.HEAD)
            fh.writelines(l + "\n" for l in lines)

    def _nights(self, n=40, seed=3):
        rnd = random.Random(seed)
        out = []
        for i in range(n):
            asleep, need = rnd.uniform(300, 540), rnd.uniform(420, 540)
            cons, eff = rnd.uniform(50, 95), rnd.uniform(80, 98)
            perf = 3.5 + 32.4 * min(1, asleep / need) + 0.28 * cons + 0.35 * eff
            day = "2026-%02d-%02d" % (1 + i // 28, 1 + i % 28)
            out.append((day + " 07:00:00", day + " 00:10:00", perf, asleep, need, cons, eff))
        return out

    def test_incomplete_cycles_file_falls_back_to_complete_sleeps_file(self):
        d, nights = tempfile.mkdtemp(), self._nights()
        # physiological_cycles.csv exists but carries only the score; sleeps.csv has every input.
        self._write(d, "physiological_cycles.csv", ["%s,%s,%.1f" % (c, o, p) for c, o, p, *_ in nights],
                    head="Cycle start time,Sleep onset,Sleep performance %\n")
        self._write(d, "sleeps.csv", ["%s,%s,false,%.1f,%.0f,%.0f,%.1f,%.1f" % n for n in nights]
                    + ["2026-01-05 07:00:00,2026-01-05 14:00:00,true,,25,,,"])
        rows = spe.load(d)
        self.assertEqual(len(rows), 40)
        self.assertEqual(spe.load.stats["files"], ["physiological_cycles.csv", "sleeps.csv"])
        self.assertEqual(spe.load.stats["naps"], 1)
        self.assertEqual(spe.load.stats["conflicts"], 0)
        res = spe.evaluate(rows)
        self.assertEqual(res["eligibility"]["h2"], 40)
        self.assertEqual(res["heldOut"], 12)
        self.assertEqual(res["h2"][1], 12)
        self.assertEqual(res["h1_comparable"][1], 12)
        self.assertLess(res["h2"][0], 0.2)

    def test_both_files_join_per_sleep_without_double_counting(self):
        d, nights = tempfile.mkdtemp(), self._nights(30)
        full = ["%s,%s,false,%.1f,%.0f,%.0f,%.1f,%.1f" % n for n in nights]
        self._write(d, "physiological_cycles.csv", [l.replace(",false,", ",", 1) for l in full],
                    head=self.HEAD.replace("Nap,", ""))
        self._write(d, "sleeps.csv", full + [full[0]])               # same sleeps again, plus one duplicated row
        rows = spe.load(d)
        self.assertEqual(len(rows), 30)
        self.assertEqual(spe.load.stats["duplicates"], 1)
        self.assertEqual([r["t"] for r in rows], sorted(r["t"] for r in rows))

    def test_exclusions_are_counted_and_never_scored_as_zero(self):
        d, nights = tempfile.mkdtemp(), self._nights(20)
        lines = ["%s,%s,false,%.1f,%.0f,%.0f,%.1f,%.1f" % n for n in nights]
        lines[17] = "%s,%s,false,,400,480,80,90" % nights[17][:2]     # no reported performance
        lines[18] = "%s,%s,false,70,400,,80,90" % nights[18][:2]      # no need
        lines[19] = "%s,%s,false,70,400,480,,90" % nights[19][:2]     # no consistency: H1 only
        self._write(d, "sleeps.csv", lines)
        res = spe.evaluate(spe.load(d))
        el = res["eligibility"]
        self.assertEqual((el["rows"], el["h1"], el["h2"]), (20, 18, 17))
        self.assertEqual((el["noPerformance"], el["noAsleepOrNeed"], el["noConsistencyOrEfficiency"]), (1, 1, 1))
        self.assertEqual(res["scored"], 19)
        self.assertEqual(res["h1"][1], res["heldOutEligibility"]["h1"])
        self.assertEqual(res["h2"][1], res["heldOutEligibility"]["h2"])
        self.assertEqual(res["h1_comparable"][1], res["h2"][1])

    def test_missing_need_is_skipped_not_zero(self):
        self.assertIsNone(spe.h1({"asleep": 400.0, "need": None}))


if __name__ == "__main__":
    unittest.main()

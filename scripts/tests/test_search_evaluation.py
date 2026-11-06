"""Arithmetic/validation tests only, not a retrieval quality benchmark."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('evaluate_search', Path(__file__).parents[1] / 'evaluate-search.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class EvaluationTests(unittest.TestCase):
    def case(self, relevant=None, exhaustive=True):
        return dict(id='q1', query='查询', relevant_ids=['a', 'b'] if relevant is None else relevant, exhaustive=exhaustive)

    def run_row(self, hits=None):
        return dict(id='q1', query='查询', result_ids=['a', 'x'] if hits is None else hits, latency_ms=12)

    def test_metrics_and_short_result_denominator(self):
        report = module.evaluate([self.case()], [self.run_row()])['summary']
        self.assertEqual(report['precision_at_10'], .1)
        self.assertEqual(report['recall_at_50'], .5)
        self.assertEqual(report['latency_p95_ms'], 12)

    def test_incomplete_judgments_do_not_claim_recall(self):
        report = module.evaluate([self.case(exhaustive=False)], [self.run_row()])['summary']
        self.assertIsNone(report['recall_at_50'])
        self.assertIsNone(report['precision_at_10'])
        self.assertEqual(report['unjudged_queries'], 1)

    def test_no_answer_is_separate_from_recall(self):
        for hits, expected in [([], 0), (['x'], 1)]:
            report = module.evaluate([self.case([])], [self.run_row(hits)])['summary']
            self.assertEqual(report['no_answer_false_positive'], expected)
            self.assertIsNone(report['recall_at_50'])

    def test_reject_duplicate_hits_missing_cases_wrong_scope_and_nan(self):
        for changes in [dict(result_ids=['a', 'a']), dict(id='unknown'), dict(filters={'session': 'other'}), dict(latency_ms=float('nan'))]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                module.evaluate([self.case()], [self.run_row() | changes])
        with self.assertRaises(ValueError):
            module.evaluate([self.case(), self.case() | {'id': 'q2'}], [self.run_row()])

    def test_rank_cutoff_and_nearest_rank_p95(self):
        cases, runs = [], []
        for i in range(20):
            cases.append(self.case(['target']) | {'id': str(i)})
            runs.append(self.run_row([str(j) for j in range(50)] + ['target']) | {'id': str(i), 'latency_ms': i + 1})
        report = module.evaluate(cases, runs)['summary']
        self.assertEqual(report['recall_at_50'], 0)
        self.assertEqual(report['latency_p95_ms'], 19)


if __name__ == '__main__':
    unittest.main()

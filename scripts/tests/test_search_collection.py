import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('collector', Path(__file__).parents[1] / 'collect-search.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class CollectionTests(unittest.TestCase):
    def test_scope_must_not_be_ignored(self):
        for filters in ({'session': 'private'}, {'since': '2026-01-01'}, {'kind': 'bad'}):
            with self.assertRaises(ValueError):
                collector.command_for('/helper', '/index', dict(query='hello', filters=filters))

    def test_query_is_one_argument_and_limit_is_fifty(self):
        command = collector.command_for('/helper', '/index', dict(query='你好 世界', filters={'kind': 'doc'}))
        self.assertEqual(command[2], '你好 世界')
        self.assertEqual(command[command.index('-n') + 1], '50')
        with self.assertRaises(ValueError):
            collector.command_for('/helper', '/index', dict(query='--index /other'))

    def test_outside_corpus_and_duplicates_fail(self):
        root = Path('/tmp/corpus').resolve()
        self.assertEqual(collector.result_ids([{'path': str(root / 'a.md')}], root), ['a.md'])
        for rows in ([{'path': '/other/a.md'}], [{'path': str(root / 'a')}] * 2):
            with self.assertRaises(ValueError):
                collector.result_ids(rows, root)


if __name__ == '__main__':
    unittest.main()

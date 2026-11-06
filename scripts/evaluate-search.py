#!/usr/bin/env python3
"""Score saved real search runs against human judgments; never generate search hits."""
import argparse
import json
import math
from pathlib import Path


def evaluate(cases, runs):
    if not isinstance(cases, list) or not isinstance(runs, list):
        raise ValueError('cases and runs must be arrays')
    if not cases or not runs:
        raise ValueError('cases and runs must not be empty')
    by_id = {}
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError('case must be an object')
        key = case['id']
        if key in by_id:
            raise ValueError(f'duplicate case: {key}')
        if not isinstance(case.get('query'), str) or not case['query'].strip():
            raise ValueError(f'missing query: {key}')
        relevant = case['relevant_ids']
        if not isinstance(relevant, list) or not all(isinstance(x, str) and x for x in relevant):
            raise ValueError(f'invalid relevant_ids: {key}')
        if len(set(relevant)) != len(relevant):
            raise ValueError(f'duplicate relevant_ids: {key}')
        if not isinstance(case.get('exhaustive'), bool):
            raise ValueError(f'exhaustive must be boolean: {key}')
        by_id[key] = case
    seen, rows, latencies = set(), [], []
    for run in runs:
        if not isinstance(run, dict):
            raise ValueError('run must be an object')
        key = run['id']
        if key in seen or key not in by_id:
            raise ValueError(f'duplicate or unknown run: {key}')
        seen.add(key)
        case = by_id[key]
        if run['query'] != case['query'] or run.get('filters', {}) != case.get('filters', {}):
            raise ValueError(f'query/filters mismatch: {key}')
        hits = run['result_ids']
        if not isinstance(hits, list) or not all(isinstance(x, str) and x for x in hits):
            raise ValueError(f'invalid result_ids: {key}')
        if len(set(hits)) != len(hits):
            raise ValueError(f'duplicate hits: {key}')
        latency = run['latency_ms']
        if isinstance(latency, bool) or not isinstance(latency, (int, float)) or not math.isfinite(latency) or latency < 0:
            raise ValueError(f'invalid latency: {key}')
        latencies.append(latency)
        relevant = set(case['relevant_ids'])
        complete = case['exhaustive']
        # Unknown relevance must not silently count as irrelevant or inflate recall.
        rows.append({
            'id': key, 'category': case.get('category', 'uncategorized'),
            'precision_at_10': len(relevant.intersection(hits[:10])) / 10 if complete and relevant else None,
            'recall_at_50': len(relevant.intersection(hits[:50])) / len(relevant) if complete and relevant else None,
            'no_answer_false_positive': bool(hits) if complete and not relevant else None,
            'returned': len(hits), 'latency_ms': latency,
        })
    if seen != set(by_id):
        raise ValueError(f'missing runs: {sorted(set(by_id) - seen)}')
    def aggregate(items):
        result = {'queries': len(items)}
        for field in ('precision_at_10', 'recall_at_50', 'no_answer_false_positive'):
            values = [row[field] for row in items if row[field] is not None]
            result[field] = sum(values) / len(values) if values else None
            result[field + '_queries'] = len(values)
        return result
    summary = aggregate(rows)
    summary['latency_p95_ms'] = sorted(latencies)[math.ceil(len(latencies) * .95) - 1]
    summary['unjudged_queries'] = sum(not case['exhaustive'] for case in cases)
    return {'summary': summary, 'categories': {
        name: aggregate([row for row in rows if row['category'] == name])
        for name in sorted({row['category'] for row in rows})
    }, 'queries': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cases', required=True, type=Path)
    parser.add_argument('--runs', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        cases = json.loads(args.cases.read_text(encoding='utf-8'))
        run_file = json.loads(args.runs.read_text(encoding='utf-8'))
        if not isinstance(run_file, dict):
            raise ValueError('run file must be an object')
        metadata = run_file['metadata']
        if not isinstance(metadata, dict):
            raise ValueError('metadata must be an object')
        for field in ('commit', 'model', 'corpus_revision', 'measured_at', 'timing'):
            if not isinstance(metadata.get(field), str) or not metadata[field].strip():
                raise ValueError(f'missing metadata: {field}')
        report = evaluate(cases, run_file['runs'])
        report['metadata'] = metadata
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(2, f'evaluation failed: {error}\n')


if __name__ == '__main__':
    main()

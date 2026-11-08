#!/usr/bin/env python3
"""Collect real DigUp CLI file searches for evaluate-search.py; explicit index only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
from datetime import datetime, timezone


def command_for(helper, index, case):
    query = case['query']
    if not isinstance(query, str) or not query.strip() or query.lstrip().startswith('-'):
        raise ValueError('query must be nonempty and must not start with -')
    filters = case.get('filters', {})
    if not isinstance(filters, dict) or set(filters) - {'kind'}:
        raise ValueError('only the file kind filter is supported; session/time filters must not be silently ignored')
    command = [str(helper), 'search', query, '--json', '-n', '50', '--index', str(index)]
    if filters:
        kind = filters['kind']
        if kind not in ('screenshot', 'image', 'pdf', 'doc', 'audio', 'video'):
            raise ValueError('invalid kind')
        command += ['--kind', kind]
    return command


def result_ids(rows, root):
    if not isinstance(rows, list):
        raise ValueError('helper response must be an array')
    ids = []
    for row in rows:
        # Fail on out-of-corpus hits rather than post-filtering and inflating precision.
        path = Path(row['path']).resolve()
        identifier = path.relative_to(root).as_posix()
        if identifier in ids:
            raise ValueError('duplicate file result')
        ids.append(identifier)
    return ids


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('helper', 'index', 'corpus', 'cases', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    for name in ('commit', 'model', 'corpus-revision'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--timeout', type=float, default=120)
    args = parser.parse_args()
    try:
        helper, index, corpus = (p.expanduser().resolve() for p in (args.helper, args.index, args.corpus))
        if not (index / 'index.sqlite').is_file() or not corpus.is_dir():
            raise ValueError('existing explicit index and corpus directory required')
        if args.timeout <= 0:
            raise ValueError('timeout must be positive')
        cases = json.loads(args.cases.read_text(encoding='utf-8'))
        if not isinstance(cases, list) or not cases:
            raise ValueError('cases must be a nonempty array')
        commands = [command_for(helper, index, case) for case in cases]
        if len({case['id'] for case in cases}) != len(cases):
            raise ValueError('duplicate case ids')
        runs, raw = [], []
        for case, command in zip(cases, commands):
            start = time.perf_counter()
            reply = subprocess.run(command, capture_output=True, text=True, timeout=args.timeout, check=True)
            duration = (time.perf_counter() - start) * 1000
            rows = json.loads(reply.stdout)
            ids = result_ids(rows, corpus)
            runs.append(dict(id=case['id'], query=case['query'], filters=case.get('filters', {}),
                             result_ids=ids, latency_ms=duration))
            raw.append(dict(id=case['id'], results=rows, stderr=reply.stderr))
        metadata = dict(commit=args.commit, model=args.model, corpus_revision=args.corpus_revision,
                        measured_at=datetime.now(timezone.utc).isoformat(),
                        timing='CLI wall time including process/model startup; serial queries; OS caches may be warm',
                        helper_sha256=hashlib.sha256(helper.read_bytes()).hexdigest(), limit=50)
        # Exclusive creation avoids destroying an earlier measurement. Private permissions cover raw excerpts.
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(dict(metadata=metadata, runs=runs, raw=raw), stream, ensure_ascii=False, indent=2)
            stream.write('\n')
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        parser.exit(2, f'collection failed: {error}\n')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Small companion to the installed DigUp helper; no independent service."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path)
    parser.add_argument('--index', type=Path)
    parser.add_argument('--helper', type=Path, help='Explicit development helper override')
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('doctor', 'status', 'start'):
        commands.add_parser(name)
    wechat = commands.add_parser('wechat')
    wechat.add_argument('arguments', nargs=argparse.REMAINDER)
    search = commands.add_parser('search')
    search.add_argument('query')
    search.add_argument('--limit', type=int, choices=range(1, 51), default=5)
    search.add_argument('--kind', choices=['screenshot', 'image', 'pdf', 'doc', 'audio', 'video'])
    args = parser.parse_args()
    choices = [args.app.expanduser()] if args.app else [Path('/Applications/DigUp.app'), Path.home() / 'Applications/DigUp.app']
    app = next((p for p in choices if p.is_dir()), None)
    if app is None:
        parser.exit(2, 'DigUp 未安装；请先安装应用并完成目录与模型设置。\n')
    helper = args.helper.expanduser().resolve() if args.helper else app / 'Contents/Helpers/digup'
    companion = Path(__file__).resolve().parent.parent / 'bin/digup'
    if not args.helper and args.command == 'wechat' and companion.is_file():
        helper = companion
    if not os.access(helper, os.X_OK):
        parser.exit(2, '应用缺少可执行的 digup helper。\n')
    if args.command == 'doctor':
        with (app / 'Contents/Info.plist').open('rb') as f:
            info = plistlib.load(f)
        print(json.dumps({'app': str(app), 'helper': str(helper),
            'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
            'index': str(args.index.expanduser()) if args.index else 'CLI default',
            'wechat_companion': companion.is_file()}, ensure_ascii=False))
        return 0
    if args.command == 'start':
        return subprocess.run(['open', str(app)], check=False).returncode
    command = [str(helper), args.command]
    if args.command == 'wechat':
        command += args.arguments
    if args.command == 'search':
        # The upstream parser treats leading -- as options, even inside one argv value.
        if not args.query.strip() or args.query.lstrip().startswith('-'):
            parser.exit(2, '查询不能为空或以 - 开头。\n')
        command += [args.query, '--json', '-n', str(args.limit)]
        if args.kind:
            command += ['--kind', args.kind]
    if args.index and args.command != 'wechat':
        command += ['--index', str(args.index.expanduser())]
    try:
        return subprocess.run(command, timeout=120, check=False).returncode
    except subprocess.TimeoutExpired:
        parser.exit(2, '查询超时；请检查应用中的模型和索引状态。\n')


if __name__ == '__main__':
    sys.exit(main())

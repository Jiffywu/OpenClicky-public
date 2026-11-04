#!/usr/bin/env python3
"""Verify the clean public import without fetching the private development history."""
import json
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]


def git(*arguments):
    return subprocess.check_output(['git', *arguments], cwd=root)


if sys.argv[1:] == ['--index']:
    records = json.loads((root / 'docs/public-source.json').read_text())
    entries = git('ls-files', '--stage', '-z').split(b'\0')
    files = {path.decode(): info.split()[1].decode()
             for entry in entries if entry for info, path in [entry.split(b'\t', 1)]}
elif not sys.argv[1:]:
    if git('rev-parse', '--is-shallow-repository').strip() == b'true':
        raise SystemExit('Use a full public clone to verify the initial import.')
    roots = git('rev-list', '--max-parents=0', 'HEAD').decode().splitlines()
    if len(roots) != 1:
        raise SystemExit('Expected one public import root; inspect the repository history.')
    initial = roots[0]
    records = json.loads(git('show', initial + ':docs/public-source.json'))
    entries = git('ls-tree', '-r', '-z', initial).split(b'\0')
    files = {path.decode(): info.split()[2].decode()
             for entry in entries if entry for info, path in [entry.split(b'\t', 1)]}
else:
    raise SystemExit('Usage: check-stack-provenance.py [--index]')

original = {entry['path']: entry['blob'] for entry in records['source_files']}
if len(original) != len(records['source_files']):
    raise SystemExit('The source manifest has duplicate file paths.')
adapted = records['public_adjustments']
expected = set(original) | set(records['added_files'])
if set(files) != expected:
    raise SystemExit('The import file list differs from the reviewed snapshot.')
mismatched = [name for name, digest in original.items() if name not in adapted and files.get(name) != digest]
if mismatched:
    raise SystemExit('Unexpected source changes: ' + ', '.join(mismatched))
print(f'Clean public import verified: {len(files)} files, {len(original) - len(adapted)} unchanged source files.')
print('Original feature references are attribution metadata; private history was not fetched.')

#!/usr/bin/env python3
"""Reject tracked files that the repository's ignore rules say must stay local."""
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root)
result = subprocess.run(
    ['git', 'check-ignore', '--no-index', '-z', '--stdin'],
    input=tracked, cwd=root, capture_output=True, check=False,
)
if result.returncode not in (0, 1):
    raise SystemExit(result.stderr.decode(errors='replace'))
ignored = [path.decode(errors='replace') for path in result.stdout.split(b'\0') if path]
if ignored:
    print('Remove these ignored files from Git tracking before publishing:')
    for path in ignored:
        print(f'  {path}')
    raise SystemExit(1)
print('No ignored private or generated files are tracked.')

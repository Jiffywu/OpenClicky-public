#!/usr/bin/env python3
"""Provide scripted terminal decisions only for the isolated browser e2e server."""
import codecs
import json
import os
import pty
import select
import signal
import subprocess
import sys

master, slave = pty.openpty()
child = subprocess.Popen(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)


def forward(sig, _frame):
    if child.poll() is None:
        child.send_signal(sig)


for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGUSR1, signal.SIGUSR2):
    signal.signal(sig, forward)

decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
pending = ''
try:
    while child.poll() is None:
        if not select.select([master], [], [], 0.25)[0]:
            continue
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        pending += decoder.decode(data)
        while '\n' in pending:
            line, pending = pending.split('\n', 1)
            if not line.startswith('[browser-approval] '):
                continue
            request = json.loads(line[len('[browser-approval] '):])
            if request.get('job_id') not in (None, 'e2e-job'):
                raise RuntimeError('Refusing to approve a non-fixture job')

            def check_urls(value):
                if isinstance(value, dict):
                    for key, item in value.items():
                        if key == 'url' and isinstance(item, str) and not (
                            item.startswith('http://127.0.0.1:') or item == 'about:blank'
                        ):
                            raise RuntimeError('Refusing to approve a non-fixture URL')
                        check_urls(item)
                elif isinstance(value, list):
                    for item in value:
                        check_urls(item)

            check_urls(request['arguments'])
            os.write(master, ('ALLOW ' + request['id'] + '\n').encode())
finally:
    os.close(master)
    if child.poll() is None:
        child.terminate()
    try:
        code = child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        child.kill()
        code = child.wait()
raise SystemExit(code if code >= 0 else 128 - code)

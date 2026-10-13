#!/usr/bin/env python3
"""Isolated bridge/API failure fixtures. Never connects to a real Herdr service."""
import base64
import json
import os
import signal
import socket
import sys
import time


if sys.argv[1] == 'api':
    path = sys.argv[2]
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(path)
    listener.listen()
    subscribed = None
    snapshots = 0
    while True:
        connection, _ = listener.accept()
        request = json.loads(connection.makefile('rb').readline())
        method = request['method']
        if method == 'events.subscribe':
            subscribed = connection
            result = dict(type='subscription_started')
        elif method == 'ping':
            result = dict(type='pong', version='0.9.3', protocol=22)
        else:
            snapshots += 1
            if len(sys.argv) > 3 and sys.argv[3] == 'slow':
                with open(path + '.reading', 'w') as marker:
                    marker.write('snapshot')
                time.sleep(0.3)
            result = dict(type='session_snapshot', snapshot=dict(version='0.9.3', protocol=22,
                          panes=[dict(pane_id='fixture:p1', terminal_id=f'term_{snapshots}')]))
        try:
            connection.sendall((json.dumps(dict(id=request['id'], result=result)) + '\n').encode())
        except BrokenPipeError:
            connection.close()
            continue
        if method != 'events.subscribe':
            connection.close()
        if method == 'session.snapshot' and snapshots == 1:
            # Split + batch an unknown event and a real invalidation.
            data = b'{"type":"future.message","data":{}}\n{"event":"pane.updated","data":{}}\n'
            subscribed.sendall(data[:7])
            subscribed.sendall(data[7:])
else:
    raise SystemExit('Only the management API fixture is supported')

#!/usr/bin/env python3
"""Capture generation-1 codecs from an isolated installed Herdr server for XCTest replay.
Usage: python3 Scripts/herdr-codec-capture.py /absolute/path/herdr /tmp/capture.json
Never attaches to a user's service; only the child server is terminated.
"""
import base64
import collections
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time


def integer(n):
    if n < 251:
        return bytes([n])
    return b'\xfb' + struct.pack('<H', n) if n <= 65535 else b'\xfc' + struct.pack('<I', n)


def string(text):
    raw = text.encode()
    return integer(len(raw)) + raw


def take_integer(raw, offset):
    n = raw[offset]
    if n < 251:
        return n, offset + 1
    size = {251: 2, 252: 4, 253: 8}[n]
    return int.from_bytes(raw[offset + 1:offset + 1 + size], 'little'), offset + 1 + size


def take_string(raw, offset):
    n, offset = take_integer(raw, offset)
    return raw[offset:offset + n].decode(), offset + n


def exact(peer, n):
    result = bytearray()
    while len(result) < n:
        chunk = peer.recv(n - len(result))
        if not chunk:
            raise EOFError('child endpoint closed')
        result.extend(chunk)
    return bytes(result)


def send(peer, raw):
    peer.sendall(struct.pack('<I', len(raw)) + raw)


def rpc(path, method, params):
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(5)
        peer.connect(str(path))
        peer.sendall((json.dumps(dict(id='capture', method=method, params=params)) + '\n').encode())
        result = json.loads(peer.makefile('rb').readline())
        assert 'error' not in result, result
        return result['result']


def capture(binary, directory):
    path = directory / 'herdr.sock'
    config = directory / 'config.toml'
    workload = Path(__file__).resolve().with_name('herdr-performance-workload.py')
    config.write_text('[terminal]\ndefault_shell = ' + json.dumps(str(workload)) + '\nshell_mode = "non_login"\n[update]\nversion_check = false\nmanifest_check = false\n')
    env = dict(os.environ, HERDR_SOCKET_PATH=str(path), HERDR_CONFIG_PATH=str(config),
               XDG_CONFIG_HOME=str(directory / 'config'), XDG_STATE_HOME=str(directory / 'state'))
    with (directory / 'server.log').open('wb') as log:
        child = subprocess.Popen([binary, 'server'], cwd=directory, env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while not path.exists():
                assert child.poll() is None and time.monotonic() < deadline, 'child server did not start'
                time.sleep(.01)
            profiles = []
            for name, requested in [('legacy', []), ('reuse', ['reuse']), ('scroll', ['scroll']), ('delta', ['delta']), ('all', ['reuse', 'scroll', 'delta'])]:
                created = rpc(path, 'workspace.create', dict(label=name, cwd=str(directory), focus=True))
                pane = created.get('root_pane', created.get('pane'))
                assert pane, created
                with socket.socket(socket.AF_UNIX) as peer:
                    peer.settimeout(5)
                    peer.connect(str(directory / 'herdr-client.sock'))
                    hello = dict(generation=1, cell_width_px=8, cell_height_px=16, surface_size=dict(cols=120, rows=30),
                                 pixel_mouse=True, direct_graphics=False, endpoint_keybindings=False, mouse_capture=True, surface_active=True,
                                 snapshot_codecs=['shell.snapshot.v1'], surface_codecs=['shell.surface.v1'], input_codecs=['shell.input.semantic.v1'], blob_codecs=['shell.blob.v1'])
                    hello.update({f'surface_{codec}': codec in requested for codec in ['reuse', 'scroll', 'delta']})
                    send(peer, b'\x14' + string('endpoint.hello.v1') + string(json.dumps(hello)))
                    packets = []; counts = collections.Counter(); sizes = collections.Counter(); boot = None; capabilities = []
                    def drain(duration=.08):
                        nonlocal boot, capabilities
                        deadline = time.monotonic() + duration
                        while time.monotonic() < deadline:
                            if not select.select([peer], [], [], max(0, deadline - time.monotonic()))[0]:
                                break
                            n = struct.unpack('<I', exact(peer, 4))[0]
                            assert 0 < n <= 64 * 1024 * 1024
                            raw = exact(peer, n)
                            packets.append(base64.b64encode(raw).decode())
                            kind = str(raw[0])
                            if raw[0] == 20:
                                kind, offset = take_string(raw, 1)
                                text, _ = take_string(raw, offset)
                                if kind == 'endpoint.welcome.v1':
                                    capabilities = json.loads(text)['capabilities']
                                if kind == 'shell.snapshot.v1':
                                    boot = json.loads(text)['boot_id']
                            counts[kind] += 1; sizes[kind] += n
                    drain(.3)
                    assert boot, 'no endpoint snapshot'
                    send(peer, b'\x0f' + string(boot) + string(json.dumps(dict(id='focus', method='workspace.focus', params=dict(workspace_id=pane['workspace_id'])))))
                    drain(.2)
                    for i in range(10):
                        rpc(path, 'workspace.rename', dict(workspace_id=pane['workspace_id'], label=f'{name}-{i}'))
                        drain()
                    for _ in range(70):
                        send(peer, b'\x0d' + string(pane['pane_id']) + b'\x01\x01' + string('L'))
                        drain(.035)
                    send(peer, b'\x0c' + integer(8) + integer(16) + integer(140) + integer(35) + b'\x01')
                    drain(.2)
                    send(peer, b'\x0d' + string(pane['pane_id']) + b'\x01\x01' + string('X'))
                    drain(.2)
                    if name == 'all':
                        rpc(path, 'pane.split', dict(target_pane_id=pane['pane_id'], direction='right', cwd=str(directory), focus=False))
                        drain(.3)
                        for _ in range(40):
                            send(peer, b'\x0d' + string(pane['pane_id']) + b'\x01\x01' + string('L'))
                            drain(.035)
                        send(peer, b'\x0d' + string(pane['pane_id']) + b'\x01\x01' + string('X'))
                        drain(.2)
                    expected = 'endpoint.surface-' + name + '.v1'
                    if name in ['reuse', 'scroll', 'delta'] and 'surface_' + name in capabilities:
                        assert counts[expected] > 0, dict(name=name, counts=counts)
                    for codec in ['reuse', 'scroll', 'delta']:
                        if codec not in requested:
                            assert counts['endpoint.surface-' + codec + '.v1'] == 0, (name, codec, counts)
                    if name == 'all':
                        assert counts['endpoint.surface-delta.v1'] > 0 and counts['endpoint.surface-scroll.v1'] > 0
                    assert counts['13'] >= 2, 'resize must replace the full baseline'
                    print(json.dumps(dict(profile=name, capabilities=capabilities, counts=counts, payloadBytes=sizes)), flush=True)
                    profiles.append(dict(name=name, requested=requested, packets=packets))
            return profiles
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()


if __name__ == '__main__':
    binary = str(Path(sys.argv[1]).resolve(strict=True))
    output = Path(sys.argv[2])
    with tempfile.TemporaryDirectory(prefix='santty-codecs-', dir='/tmp') as directory:
        profiles = capture(binary, Path(directory))
    output.write_text(json.dumps(profiles))

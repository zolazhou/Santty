#!/usr/bin/env python3
"""Isolated ClientShell endpoint fixture. Never connects to a Herdr service."""
import json
from pathlib import Path
import socket
import struct
import sys
import time
import threading

if len(sys.argv) == 2 and sys.argv[1] == "--version":
    print("herdr 0.9.3")
    sys.exit(0)


def integer(n):
    if n < 251:
        return bytes([n])
    if n <= 65535:
        return b'\xfb' + struct.pack('<H', n)
    return b'\xfc' + struct.pack('<I', n)


def string(s):
    data = s.encode()
    return integer(len(data)) + data


def read_exact(s, n):
    data = b''
    while len(data) < n:
        part = s.recv(n - len(data))
        if not part:
            raise EOFError()
        data += part
    return data


def read_message(s):
    n = struct.unpack('<I', read_exact(s, 4))[0]
    assert n <= 2 * 1024 * 1024
    return read_exact(s, n)


def take_string(data, i):
    n = data[i]
    i += 1
    if n == 251:
        n = struct.unpack_from('<H', data, i)[0]
        i += 2
    elif n == 252:
        n = struct.unpack_from('<I', data, i)[0]
        i += 4
    assert i + n <= len(data)
    return data[i:i + n].decode(), i + n


def send(s, payload):
    frame = struct.pack('<I', len(payload)) + payload
    if scenario.startswith('window-typing'):
        s.sendall(frame)
        return
    for begin in range(0, len(frame), 17):
        s.sendall(frame[begin:begin + 17])


def control(s, kind, value):
    send(s, b'\x14' + string(kind) + string(json.dumps(value) if not isinstance(value, str) else value))


root = Path(__file__).resolve().parent.parent
api_path, scenario = sys.argv[1:3]
window_scenario = scenario in ('window-agents', 'window', 'window-borders', 'window-popup', 'window-drop', 'window-no-runtime', 'window-floating-cursor', 'window-workspace-create') or scenario.startswith(('window-tabs', 'window-split', 'window-typing'))
popup_live = scenario == 'window-popup'
client_path = str(Path(api_path).with_name(Path(api_path).stem + '-client.sock'))
golden = json.loads((root / 'Santty/Tests/Fixtures/herdr-clientshell-wire-v1.json').read_text())['payloads']
snapshot = json.loads((root / 'Santty/Tests/Fixtures/herdr-clientshell-snapshot-v1.json').read_text()
                      .replace('w1:p1', 'w5:pA').replace('w1:t1', 'w5:t4').replace('w1', 'w5'))
snapshot.update(boot_id='boot', revision=251)
if scenario == 'navigation' or scenario.startswith('window-tabs'):
    tab = dict(snapshot['tabs'][0], tab_id='w5:t5', focused=False)
    pane = dict(snapshot['panes'][0], pane_id='w5:pB', tab_id='w5:t5', focused=False)
    snapshot['tabs'].append(tab)
    snapshot['panes'].append(pane)
if scenario.startswith('window-tabs-reorder'):
    snapshot['tabs'].append(dict(snapshot['tabs'][0], tab_id='w5:t6', number=6, focused=False))
    snapshot['panes'].append(dict(snapshot['panes'][0], pane_id='w5:pC', tab_id='w5:t6', focused=False))
if scenario == 'window-tabs-palette':
    snapshot['panes'][1]['label'] = 'Secondary shell'
    snapshot['workspaces'].append(dict(snapshot['workspaces'][0], workspace_id='w6', active_tab_id='w6:t1', number=6, label='Other', focused=False))
    snapshot['tabs'].append(dict(snapshot['tabs'][0], workspace_id='w6', tab_id='w6:t1', number=1, label='Other tab', focused=False))
    snapshot['panes'].append(dict(snapshot['panes'][0], workspace_id='w6', tab_id='w6:t1', pane_id='w6:pC', label='Remote logs', focused=False))
    snapshot['agents'].append(dict(snapshot['agents'][0], workspace_id='w6', tab_id='w6:t1', pane_id='w6:pC', agent='opencode', display_agent='OpenCode', focused=False))
if scenario in ('mouse-focus', 'window-typing-split', 'window-typing-full-split', 'window-borders'):
    snapshot['panes'].append(dict(snapshot['panes'][0], pane_id='w5:pB', focused=False))
trace = []
connection_number = 0
window_size = (2, 1)
window_cells = (8, 16)
window_serial = 65535
window_active = False
window_assets_sent = False
window_split_ratio = 0.5
window_typing_symbol = None
api_listener = None
api_subscribers = []


def take_integer(data, i):
    n = data[i]
    i += 1
    if n == 251:
        return struct.unpack_from('<H', data, i)[0], i + 2
    if n == 252:
        return struct.unpack_from('<I', data, i)[0], i + 4
    return n, i


def mouse_focus_frame():
    global window_serial
    window_serial += 1
    cells = b''.join(string(symbol) + b'\x00' * 5 for symbol in ('A', 'B'))
    frame = integer(2) + cells + b'\x02\x01\x00\x00\x00'
    panes = []
    for x, pane_id in enumerate(('w5:pA', 'w5:pB')):
        rect = bytes([x, 0, 1, 1])
        panes.append(string(pane_id) + integer(1) + rect + rect + b'\x00\x00'
                     + bytes([pane_id == snapshot['focused_pane_id'], 1, 0, 0, 8, 16]))
    return (b'\x0d' + string('boot') + integer(snapshot['revision']) + integer(window_serial)
            + frame + integer(2) + b''.join(panes) + b'\x00\x00\x00\x00\x00')


def window_frame():
    global window_serial, window_assets_sent
    cols, rows = window_size
    cw, ch = window_cells
    assert 0 < cols <= 1024 and 0 < rows <= 256 and cols * rows <= 100000
    window_serial += 1
    pane = snapshot['focused_pane_id']
    text = 'ClientShell native image' if pane == 'w5:pA' else 'ClientShell second tab image'
    symbols = [text[i] if i < min(cols, len(text)) else ' ' for i in range(cols * rows)]
    if scenario in ('window-typing-split', 'window-typing-full-split'):
        start = max(1, min(cols - 2, int((cols - 1) * window_split_ratio))) + 1
        label = 'Unchanged sibling'[:cols - start]
        symbols[start:start + len(label)] = label
    if window_typing_symbol is not None:
        symbols[0] = window_typing_symbol
    cells = b''.join(string(symbol) + b'\x00' * 5 for symbol in symbols)
    rect = b'\x00\x00' + integer(cols) + integer(rows)
    cursor_x, cursor_y = 0, 0
    if scenario == 'window-floating-cursor' and snapshot['panes'][0]['label'] != 'cursor-home':
        cursor_x, cursor_y = max(0, cols - 2), rows - 1
    frame = (integer(cols * rows) + cells + integer(cols) + integer(rows)
             + b'\x01' + integer(cursor_x) + integer(cursor_y) + b'\x01\x02\x00\x00')
    visible = [p for p in snapshot['panes'] if p['tab_id'] == snapshot['focused_tab_id']]
    metadata = integer(len(visible))
    left = max(1, min(cols - 2, int((cols - 1) * window_split_ratio)))
    for index, item in enumerate(visible):
        x = 0 if index == 0 else left + 1
        width = cols if len(visible) == 1 else left if index == 0 else cols - left - 1
        pane_rect = integer(x) + b'\x00' + integer(width) + integer(rows)
        inset = 1 if scenario == 'window-borders' else 0
        inner_rect = integer(x + inset) + integer(inset) + integer(width - inset * 2) + integer(rows - inset * 2)
        metadata += (string(item['pane_id']) + integer(9) + pane_rect + inner_rect + b'\x00\x00'
                     + bytes([item['pane_id'] == pane, 1, 0, 0]) + integer((width - inset * 2) * cw) + integer((rows - inset * 2) * ch))
    key = b'\x00\x00' + string(pane) + integer(7) + b'\x01\x01\x01\x04' + integer(1234)
    assets = [(key, b'\xff\x00\x00\xff')]
    placement = key + integer(3) + integer(min(1, cols - 1)) + integer(min(1, rows - 1)) + b'\x01\x01\x00\x00\x01\x01\x00\x00\x01\x00'
    placements = [placement]
    popup = b'\x00'
    if popup_live:
        pc, pr = min(40, cols), min(8, rows)
        label = 'Herdr popup'
        content = b''.join(string(label[i] if i < min(pc, len(label)) else ' ') + b'\x00' * 5 for i in range(pc * pr))
        pf = integer(pc * pr) + content + integer(pc) + integer(pr) + b'\x01\x00\x00\x01\x02\x00\x00'
        popup = b'\x01' + string('fixture-popup') + string(label) + b'\x00\x00' + pf + b'\x01\x00' + integer(pc * cw) + integer(pr * ch)
        pk = b'\x00\x01' + string('fixture-popup') + integer(7) + b'\x01\x01\x01\x04' + integer(5678)
        assets.append((pk, b'\x00\x00\xff\xff'))
        placements.append(pk + integer(3) + b'\x00\x00\x01\x01\x00\x00\x01\x01\x00\x00\x01\x00')
    delivered = b'\x00' if window_assets_sent else integer(len(assets)) + b''.join(k + integer(len(data)) + data for k, data in assets)
    scene = delivered + integer(len(placements)) + b''.join(placements) + integer(len(assets)) + b''.join(k for k, _ in assets)
    if scenario == 'window-tabs-patch-content' or scenario.startswith('window-typing'):
        scene = b'\x00\x00\x00'
    window_assets_sent = True
    return b'\x0d' + string('boot') + integer(snapshot['revision']) + integer(window_serial) + frame + metadata + b'\x00' + popup + scene


def stable_content_patch(symbol=None):
    global window_serial
    cols, rows = window_size
    cw, ch = window_cells
    if scenario == 'window-typing-split':
        cols = max(1, min(cols - 2, int((cols - 1) * window_split_ratio)))
    rect = b'\x00\x00' + integer(cols) + integer(rows)
    pane = (string(snapshot['focused_pane_id']) + integer(8) + rect + rect + b'\x00\x00'
            + b'\x01\x01\x00\x00' + integer(cols * cw) + integer(rows * ch))
    base = window_serial
    window_serial += 1
    changed = b'\x00' if symbol is None else b'\x01\x00\x00\x01' + string(symbol) + b'\x00' * 5
    return (b'\x13' + string('boot') + integer(snapshot['revision']) + integer(base) + integer(window_serial)
            + changed + b'\x01' + pane + b'\x01' + integer(1 if symbol else 0) + b'\x00\x01\x02')



def create_workspace():
    workspace_id = 'wNew' + str(len(snapshot['workspaces']))
    pane = dict(snapshot['panes'][0], workspace_id=workspace_id, tab_id=workspace_id + ':t1',
                pane_id=workspace_id + ':p1', label='New shell', focused=True)
    for item in snapshot['workspaces'] + snapshot['tabs'] + snapshot['panes']:
        item['focused'] = False
    snapshot['workspaces'].append(dict(snapshot['workspaces'][0], workspace_id=workspace_id,
        active_tab_id=pane['tab_id'], label='Santty', focused=True))
    snapshot['tabs'].append(dict(snapshot['tabs'][0], workspace_id=workspace_id,
        tab_id=pane['tab_id'], label='New tab', focused=True))
    snapshot['panes'].append(pane)
    snapshot.update(focused_workspace_id=workspace_id, focused_tab_id=pane['tab_id'],
                    focused_pane_id=pane['pane_id'], revision=snapshot['revision'] + 1)
    return pane


def api_handle(connection):
    subscribed = False
    try:
        connection.settimeout(5)
        request = json.loads(connection.makefile('rb').readline(16384))
        method = request['method']
        if method == 'workspace.create' and scenario == 'window-workspace-create':
            trace.append(dict(method=method, params=request['params']))
            record_trace()
            result = dict(type='workspace_created', root_pane=create_workspace())
        elif method == 'ping':
            result = dict(type='pong', version='0.9.3', protocol=22)
        elif method == 'session.snapshot':
            panes = [dict(p, terminal_id=('fixture-runtime-' + p['pane_id'] if scenario.startswith('window-tabs') else 'fixture-runtime'), title='ClientShell') for p in snapshot['panes']]
            if scenario == 'window-no-runtime':
                for pane in panes:
                    pane.pop('terminal_id')
            result = dict(type='session_snapshot', snapshot=dict(version='0.9.3', protocol=22, panes=panes,
                workspaces=snapshot['workspaces'], tabs=snapshot['tabs'], focused_workspace_id=snapshot['focused_workspace_id']))
        elif method == 'layout.export':
            if scenario == 'window-split-queries':
                trace.append(dict(method=method, params=request['params']))
                record_trace()
            tab_id = request['params']['tab_id']
            panes = [p['pane_id'] for p in snapshot['panes'] if p['tab_id'] == tab_id]
            pane = panes[0]
            root = dict(type='pane', pane_id=pane)
            if len(panes) == 2:
                root = dict(type='split', direction='right', ratio=0.5, first=root, second=dict(type='pane', pane_id=panes[1]))
            result = dict(type='layout_export', layout=dict(workspace_id=next(p['workspace_id'] for p in snapshot['panes'] if p['tab_id'] == tab_id), tab_id=tab_id, zoomed=False,
                focused_pane_id=pane, root=root))
        elif method == 'pane.read':
            pane_id = request['params']['pane_id']
            pane = next(p for p in snapshot['panes'] if p['pane_id'] == pane_id)
            result = dict(type='pane_read', read=dict(pane_id=pane_id, workspace_id=pane['workspace_id'],
                tab_id=pane['tab_id'], source='recent', format='text', text='first\n中文🙂\nLast line', revision=42, truncated=True))
        elif method == 'pane.process_info':
            result = dict(type='pane_process_info', process_info=dict(pane_id=request['params']['pane_id'],
                foreground_process_group_id=12345, foreground_processes=[dict(pid=12346, name='fixture')]))
        elif method == 'agent.list':
            result = dict(type='agent_list', agents=[])
        elif method == 'events.subscribe':
            subscribed = True
            api_subscribers.append(connection)
            result = dict(type='subscription_started')
        else:
            connection.sendall((json.dumps(dict(id=request['id'], error=dict(code='no_global_mutation', message=method))) + '\n').encode())
            return
        connection.sendall((json.dumps(dict(id=request['id'], result=result)) + '\n').encode())
    except (OSError, ValueError):
        pass
    finally:
        if not subscribed:
            connection.close()


def api_loop():
    while True:
        connection, _ = api_listener.accept()
        threading.Thread(target=api_handle, args=(connection,), daemon=True).start()


if window_scenario:
    api_listener = socket.socket(socket.AF_UNIX)
    api_listener.bind(api_path)
    api_listener.listen(16)
    threading.Thread(target=api_loop, daemon=True).start()


def record_trace():
    temporary = Path(api_path + '.trace.tmp')
    temporary.write_text(json.dumps(trace))
    temporary.replace(Path(api_path + '.trace'))


def client_welcome():
    welcome = dict(generation=1, server_version='fixture-future', snapshot_codec='shell.snapshot.v1',
                   surface_codec='shell.surface.v1', input_codec='shell.input.semantic.v1', blob_codec='shell.blob.v1',
                   methods=['client_shell.surface.set', 'pane.rename', 'tab.rename', 'workspace.rename', 'pane.focus', 'workspace.focus'],
                   capabilities=['surface_interest', 'health_check', 'presentation_effects_fence'])
    if scenario == 'creation':
        welcome['methods'].extend(['workspace.create', 'tab.create', 'pane.split'])
    if scenario.startswith('window-tabs-reorder'):
        welcome['methods'].append('tab.move')
    if scenario.startswith('window-split'):
        welcome['methods'].append('layout.set_split_ratio')
    if scenario == 'window-workspace-create':
        welcome['methods'].extend(['workspace.create', 'workspace.close'])
    if scenario in ('mouse-focus', 'window-tabs-palette'):
        welcome['methods'].append('tab.focus')
    return welcome


def serve_client(connection, hello=None, handshaken=False, first_message=None):
    global window_active, window_assets_sent, window_cells, window_size, connection_number, popup_live, window_typing_symbol
    window_active = False
    window_assets_sent = False  # Delivery cache belongs to this connection, not the service.
    connection_number += 1
    trace.append(dict(connection=connection_number))
    record_trace()
    connection.settimeout(10)
    hello = hello or read_message(connection)
    assert hello[0] == 20
    kind, i = take_string(hello, 1)
    value, i = take_string(hello, i)
    assert i == len(hello) and kind == 'endpoint.hello.v1'
    assert json.loads(value)['surface_active'] is False
    if not handshaken:
        control(connection, 'endpoint.welcome.v1', client_welcome())
    if scenario == 'malformed':
        send(connection, bytes([8, 2, 0]))
    else:
        if not handshaken:
            control(connection, 'shell.snapshot.v1', snapshot)
        while True:
            message = first_message or read_message(connection)
            first_message = None
            tag = message[0]
            trace.append(dict(tag=tag))
            if tag in (13, 14, 17):
                trace[-1]['payload'] = message.hex()
            if not (tag == 13 and scenario.startswith('window-typing')):
                record_trace()
            if tag == 13 and scenario.startswith('window-typing'):
                target, i = take_string(message, 1)
                # Background AppKit windows can still receive incidental pointer motion.
                if message[i:i + 3] == b'\x01\x02\x03':
                    assert any(p['pane_id'] == target and p['tab_id'] == snapshot['focused_tab_id'] for p in snapshot['panes']), message.hex()
                    record_trace()
                    continue
                assert target == snapshot['focused_pane_id'], message.hex()
                assert message[i:i + 2] == b'\x01\x01', message.hex()
                symbol, i = take_string(message, i + 2)
                assert i == len(message) and len(symbol) == 1
                trace[-1]['text_input'] = True
                record_trace()
                if scenario == 'window-typing-full-split':
                    window_typing_symbol = symbol
                    send(connection, window_frame())
                else:
                    send(connection, stable_content_patch(symbol))
            if tag == 13 and scenario == 'snapshot-gap' and snapshot['revision'] == 251:
                snapshot['revision'] += 1
                control(connection, 'shell.snapshot.v1', snapshot)
            if tag == 4:
                break
            if tag == 14 and window_scenario and popup_live:
                popup_live = False
                send(connection, window_frame())
            if tag == 12 and window_scenario:
                values = []
                i = 1
                for _ in range(4):
                    value, i = take_integer(message, i)
                    values.append(value)
                window_cells = tuple(values[:2])
                window_size = tuple(values[2:])
                trace[-1]['resize'] = dict(cols=window_size[0], rows=window_size[1])
                record_trace()
                if window_active:
                    send(connection, window_frame())
            if tag == 15:
                boot, i = take_string(message, 1)
                request, i = take_string(message, i)
                assert i == len(message) and boot == 'boot'
                request = json.loads(request)
                trace[-1]['method'] = request['method']
                trace[-1]['params'] = request['params']
                record_trace()
                if request['method'] == 'client_shell.surface.set':
                    active = request['params']['active']
                    assert isinstance(active, bool)
                    result = dict(type='client_shell_surface_set', active=active, projection_revision=snapshot['revision'])
                else:
                    if scenario == 'stalled':
                        time.sleep(10)
                        break
                    result = dict(type='ok')
                    if scenario == 'window-workspace-create' and request['method'] == 'workspace.create':
                        result['root_pane'] = create_workspace()
                    if scenario == 'window-workspace-create' and request['method'] == 'workspace.close':
                        for collection in ('workspaces', 'tabs', 'panes', 'agents'):
                            snapshot[collection] = [item for item in snapshot[collection]
                                if item['workspace_id'] != request['params']['workspace_id']]
                        target = snapshot['panes'][-1] if snapshot['panes'] else None
                        snapshot.update(focused_workspace_id=target['workspace_id'] if target else None,
                            focused_tab_id=target['tab_id'] if target else None,
                            focused_pane_id=target['pane_id'] if target else None)
                        for collection, key, value in [('workspaces', 'workspace_id', snapshot['focused_workspace_id']),
                                ('tabs', 'tab_id', snapshot['focused_tab_id']), ('panes', 'pane_id', snapshot['focused_pane_id'])]:
                            for item in snapshot[collection]:
                                item['focused'] = item[key] == value

                    if scenario == 'creation' and request['method'] in ('workspace.create', 'tab.create', 'pane.split'):
                        workspace = 'wNew' if request['method'] == 'workspace.create' else 'w5'
                        result['root_pane'] = dict(pane_id=workspace + ':pNew', workspace_id=workspace,
                                                   tab_id=workspace + ':tNew', cwd='/tmp')
                if scenario in ('slow-focus', 'window-tabs-slow') and request['method'] == 'pane.focus':
                    time.sleep(0.25)
                response_value = dict(id=request['id'], result=result)
                if scenario in ('window-split-slow', 'window-split-rejected') and request['method'] == 'layout.set_split_ratio':
                    snapshot['revision'] += 1
                    control(connection, 'shell.snapshot.v1', snapshot)
                    send(connection, window_frame())
                    time.sleep(0.25)
                    if scenario == 'window-split-rejected':
                        response_value = dict(id=request['id'], error=dict(code='resize_denied', message='Fixture rejected resizing'))
                if scenario in ('window-tabs-reorder-slow', 'window-tabs-reorder-rejected') and request['method'] == 'tab.move':
                    snapshot['tabs'][0]['label'] = 'Updated while waiting'
                    snapshot['revision'] += 1
                    control(connection, 'shell.snapshot.v1', snapshot)
                    send(connection, window_frame())
                    time.sleep(0.6)
                    if scenario == 'window-tabs-reorder-rejected':
                        response_value = dict(id=request['id'], error=dict(code='reorder_denied', message='Fixture rejected reordering'))
                if window_scenario and not window_active and request['method'] != 'client_shell.surface.set':
                    response_value = dict(id=request['id'], error=dict(code='surface_inactive', message='Surface is inactive'))
                response = json.dumps(response_value).encode()
                half = len(response) // 2
                for final, data in [(False, response[:half]), (True, response[half:])]:
                    send(connection, b'\x12' + string('boot') + string(request['id']) + bytes([final]) + integer(len(data)) + data)
                if request['method'] == 'client_shell.surface.set':
                    if not request['params']['active']:
                        window_active = False
                        continue
                    if window_scenario:
                        window_active = True
                        send(connection, window_frame())
                    elif scenario == 'mouse-focus':
                        send(connection, mouse_focus_frame())
                    else:
                        send(connection, bytes.fromhex(golden['surface_image']))
                elif window_scenario:
                    if not window_active:
                        continue
                    if not snapshot['panes']:
                        snapshot['revision'] += 1
                        control(connection, 'shell.snapshot.v1', snapshot)
                        continue
                    if scenario == 'window-tabs-failure' and request['method'] == 'pane.focus':
                        send(connection, bytes([8, 2, 0]))
                        continue
                    if scenario == 'window-tabs-rejection' and request['method'] == 'pane.focus':
                        send(connection, b'\x0f' + string('Paste rejected: fixture'))
                    if scenario.startswith('window-tabs') and request['method'] == 'pane.focus':
                        pane_id = request['params']['pane_id']
                        target = next(p for p in snapshot['panes'] if p['pane_id'] == pane_id)
                        snapshot.update(focused_workspace_id=target['workspace_id'], focused_tab_id=target['tab_id'], focused_pane_id=pane_id)
                        snapshot['workspaces'][0]['active_tab_id'] = target['tab_id']
                        for tab in snapshot['tabs']:
                            tab['focused'] = tab['tab_id'] == target['tab_id']
                        for pane in snapshot['panes']:
                            pane['focused'] = pane['pane_id'] == pane_id
                        window_assets_sent = False
                        popup_live = scenario == 'window-tabs' and pane_id == 'w5:pB'
                    if scenario == 'window-tabs-palette' and request['method'] in ('workspace.focus', 'tab.focus'):
                        params = request['params']
                        if request['method'] == 'workspace.focus':
                            target_tab = next(w['active_tab_id'] for w in snapshot['workspaces'] if w['workspace_id'] == params['workspace_id'])
                        else:
                            target_tab = params['tab_id']
                        target = next(p for p in snapshot['panes'] if p['tab_id'] == target_tab)
                        snapshot.update(focused_workspace_id=target['workspace_id'], focused_tab_id=target_tab, focused_pane_id=target['pane_id'])
                        for space in snapshot['workspaces']:
                            space['focused'] = space['workspace_id'] == target['workspace_id']
                            if space['focused']:
                                space['active_tab_id'] = target_tab
                        for tab in snapshot['tabs']:
                            tab['focused'] = tab['tab_id'] == target_tab
                        for pane in snapshot['panes']:
                            pane['focused'] = pane['pane_id'] == target['pane_id']
                        window_assets_sent = False
                    if request['method'] == 'pane.rename':
                        snapshot['panes'][0]['label'] = request['params']['label']
                        if scenario.startswith('window-split') and len(snapshot['panes']) == 1:
                            snapshot['panes'].append(dict(snapshot['panes'][0], pane_id='w5:pC', focused=False))
                    if request['method'] == 'layout.set_split_ratio' and 'error' not in response_value:
                        window_split_ratio = request['params']['ratio']
                    if scenario.startswith('window-tabs-reorder') and scenario != 'window-tabs-reorder-rejected' and request['method'] == 'tab.move':
                        source = next(i for i, tab in enumerate(snapshot['tabs']) if tab['tab_id'] == request['params']['tab_id'])
                        insertion = request['params']['insert_index']
                        assert 0 <= insertion <= len(snapshot['tabs'])
                        destination = insertion - 1 if source < insertion else insertion
                        tab = snapshot['tabs'].pop(source)
                        snapshot['tabs'].insert(min(destination, len(snapshot['tabs'])), tab)
                    if request['method'] == 'workspace.rename':
                        target = next(w for w in snapshot['workspaces'] if w['workspace_id'] == request['params']['workspace_id'])
                        target['label'] = request['params']['label']
                    if request['method'] == 'tab.rename':
                        target = next(t for t in snapshot['tabs'] if t['tab_id'] == request['params']['tab_id'])
                        target['label'] = request['params']['label']
                    snapshot['revision'] += 1
                    control(connection, 'shell.snapshot.v1', snapshot)
                    if window_active:
                        send(connection, window_frame())
                    if window_active and scenario == 'window-tabs-patch-content':
                        send(connection, stable_content_patch())
                elif scenario == 'mouse-focus' and request['method'] == 'pane.focus':
                    target = request['params']['pane_id']
                    assert target in ('w5:pA', 'w5:pB')
                    snapshot['focused_pane_id'] = target
                    for pane in snapshot['panes']:
                        pane['focused'] = pane['pane_id'] == target
                    snapshot['revision'] += 1
                    control(connection, 'shell.snapshot.v1', snapshot)
                    send(connection, mouse_focus_frame())
                elif scenario == 'navigation' and request['method'] == 'pane.focus':
                    assert request['params']['pane_id'] == 'w5:pB'
                    time.sleep(1)
                    snapshot.update(revision=252, focused_tab_id='w5:t5', focused_pane_id='w5:pB')
                    snapshot['workspaces'][0]['active_tab_id'] = 'w5:t5'
                    for tab in snapshot['tabs']:
                        tab['focused'] = tab['tab_id'] == 'w5:t5'
                    for pane in snapshot['panes']:
                        pane['focused'] = pane['pane_id'] == 'w5:pB'
                    control(connection, 'shell.snapshot.v1', snapshot)
                    payload = bytes.fromhex(golden['surface_image']).replace(b'w5:pA', b'w5:pB')
                    payload = payload.replace(b'\xfb\xfb\x00\xfc\x00\x00\x01\x00',
                                              b'\xfb\xfc\x00\xfc\x01\x00\x01\x00', 1)
                    send(connection, payload)
            elif tag == 20:
                kind, i = take_string(message, 1)
                value, i = take_string(message, i)
                if kind == 'endpoint.presentation.sync.v1':
                    control(connection, 'endpoint.presentation.ready.v1', value)
                    if scenario == 'window-drop' and connection_number == 1:
                        time.sleep(0.4)
                        return  # Lose only this client; the same service keeps accepting connections.
                    if scenario in ('presentation', 'effects', 'effects-in-flight'):
                        time.sleep(0.4)
                        payload = bytes.fromhex(golden['surface_image']).replace(
                            b'\xfc\x00\x00\x01\x00', b'\xfc\x01\x00\x01\x00', 1)
                        send(connection, payload)
                    if scenario == 'effects':
                        send(connection, b'\x05' + string('fixture clipboard'))
                        send(connection, b'\x09' + integer(1))
                    if scenario == 'effects-in-flight':
                        time.sleep(0.25)
                        payload = bytes.fromhex(golden['surface_image']).replace(
                            b'\xfc\x00\x00\x01\x00', b'\xfc\x02\x00\x01\x00', 1)
                        send(connection, payload)
                        send(connection, b'\x05' + string('future clipboard'))
                        send(connection, b'\x09' + integer(1))
                elif kind == 'endpoint.health.ping.v1':
                    control(connection, 'endpoint.health.pong.v1', value)


def serve_metadata(connection, hello):
    """Inactive observers receive metadata, never claim a terminal surface."""
    try:
        welcome = client_welcome()
        welcome['capabilities'].append('agent_completions')
        control(connection, 'endpoint.welcome.v1', welcome)
        control(connection, 'endpoint.agent-completions.v1', dict(boot_id=snapshot['boot_id'], revision=snapshot['revision'], completions={}))
        control(connection, 'shell.snapshot.v1', snapshot)
        if scenario == 'window-agents':
            update = json.loads(json.dumps(snapshot))
            update['revision'] += 1
            update['agents'][0].update(agent_status='working', state_change_seq=10)
            control(connection, 'shell.snapshot.v1', update)
            update['revision'] += 1
            update['agents'][0].update(agent_status='idle', state_change_seq=11)
            control(connection, 'endpoint.agent-completions.v1', dict(boot_id=update['boot_id'], revision=update['revision'], completions={'w5:pA': 11}))
            control(connection, 'shell.snapshot.v1', update)
            snapshot.update(update)
            notice = (b'\x0e' + integer(1) + string('Review finished') + b'\x01' + string('Ready to review')
                + b'\x01' + integer(0) + b'\x01' + string('claude') + b'\x01' + string('w5')
                + b'\x01' + string('w5:t4') + b'\x01' + string('w5:pA') + b'\x00')
            send(connection, notice)
            send(connection, notice)  # Duplicate delivery must not duplicate unread messages.
        while True:
            message = read_message(connection)
            if message[0] in (0, 12, 15, 17):
                serve_client(connection, hello, handshaken=True, first_message=message)
                return
            if message[0] == 4:
                return
            assert message[0] == 20, 'Metadata observer sent terminal input'
            kind, i = take_string(message, 1)
            value, i = take_string(message, i)
            assert kind == 'endpoint.health.ping.v1', 'Metadata observer claimed or resized a surface'
            control(connection, 'endpoint.health.pong.v1', value)
    except (EOFError, BrokenPipeError, ConnectionResetError, TimeoutError):
        pass
    finally:
        connection.close()


try:
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(client_path)
        listener.listen(8)
        listener.settimeout(None if window_scenario else 10)
        while True:
            connection = listener.accept()[0]
            connection.settimeout(10)
            hello = read_message(connection)
            _, i = take_string(hello, 1)
            raw, _ = take_string(hello, i)
            value = json.loads(raw)
            if value['surface_size'] == dict(cols=1, rows=1) and value['cell_width_px'] == 0:
                threading.Thread(target=serve_metadata, args=(connection, hello), daemon=True).start()
                continue
            with connection:
                try:
                    serve_client(connection, hello)
                except (EOFError, BrokenPipeError, ConnectionResetError):
                    pass
            if not window_scenario:
                break
finally:
    Path(client_path).unlink(missing_ok=True)

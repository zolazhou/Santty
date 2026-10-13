#!/usr/bin/env python3
"""External-service fixture for workspace mutations; never touches real Herdr."""
import base64
import json
import os
import socket
import sys
import threading
import time

if sys.argv[1] == '--version':
    print('herdr 0.9.3')
    sys.exit(0)

if sys.argv[1] != 'api':
    raise SystemExit('Only the management API fixture is supported')

path, scenario = sys.argv[2:4]
lock = threading.RLock()
state = dict(panes=[], tabs=[], requests=[], request_params=[], pulse=0)
subscribers = []
if scenario in ('mirror', 'mirror_reject_focus', 'mirror_slow_focus'):
    state['tabs'] = [dict(tab_id='w1:t2', workspace_id='w1', label='Second'), dict(tab_id='w1:t1', workspace_id='w1', label='First'), dict(tab_id='w2:t1', workspace_id='w2', label='Remote')]
    state['panes'] = [dict(pane_id=f'w1:p{i}', terminal_id=f'term_{i}', workspace_id='w1', tab_id='w1:t1' if i < 4 else 'w1:t2', title='Shell') for i in range(1, 5)] + [dict(pane_id='w2:p1', terminal_id='term_other', workspace_id='w2', tab_id='w2:t1', title='Other')]
    state['active_tabs'] = {'w1': 'w1:t1', 'w2': 'w2:t1'}
    state['focused_panes'] = {'w1:t1': 'w1:p3'}
    state['layouts'] = {'w1:t1': dict(type='split', direction='right', ratio=.6, first=dict(type='pane', pane_id='w1:p1'), second=dict(type='split', direction='down', ratio=.25, first=dict(type='pane', pane_id='w1:p2'), second=dict(type='pane', pane_id='w1:p3')))}


def workspaces():
    ids = list(dict.fromkeys(tab['workspace_id'] for tab in state['tabs']))
    return [dict(workspace_id=id, label='Workspace ' + id, active_tab_id=state.get('active_tabs', {}).get(id, next(tab['tab_id'] for tab in state['tabs'] if tab['workspace_id'] == id))) for id in ids]


def export_layout(tab_id):
    panes = [pane for pane in state['panes'] if pane['tab_id'] == tab_id]
    def tree(values):
        if len(values) == 1:
            return dict(type='pane', pane_id=values[0]['pane_id'])
        return dict(type='split', direction='right', ratio=.5, first=tree(values[:1]), second=tree(values[1:]))
    return dict(workspace_id=panes[0]['workspace_id'], tab_id=tab_id, zoomed=state.get('zoomed', {}).get(tab_id, False), focused_pane_id=state.get('focused_panes', {}).get(tab_id, panes[0]['pane_id']), root=state.get('layouts', {}).get(tab_id, tree(panes)))

def persist():
    with open(path + '.json.tmp', 'w') as result:
        json.dump(state, result)
    os.replace(path + '.json.tmp', path + '.json')


def publish(event='pane.updated'):
    for subscriber in subscribers[:]:
        try:
            subscriber.sendall((json.dumps(dict(event=event, data={})) + '\n').encode())
        except OSError:
            subscribers.remove(subscriber)


def handle(connection):
    try:
        request = json.loads(connection.makefile('rb').readline())
        method, params = request['method'], request['params']
        with lock:
            state['requests'].append(method)
            state['request_params'].append(dict(method=method, params=params))
            persist()
            if scenario == 'mirror_reject_focus' and method in ('pane.focus', 'tab.focus'):
                connection.sendall((json.dumps(dict(id=request['id'], error=dict(code='denied', message='fixture rejected focus'))) + '\n').encode())
                return
            if scenario == 'reject_edit' and method in ('pane.rename', 'tab.rename', 'tab.move', 'pane.close'):
                connection.sendall((json.dumps(dict(id=request['id'], error=dict(code='denied', message='fixture rejected mutation'))) + '\n').encode())
                return
            if method == 'ping':
                result = dict(type='pong', version='0.9.3', protocol=22)
            elif method == 'events.subscribe':
                subscribers.append(connection)
                result = dict(type='subscription_started')
            elif method == 'session.snapshot':
                result = dict(type='session_snapshot', snapshot=dict(version='0.9.3', protocol=22,
                              panes=state['panes'][:], tabs=state['tabs'][:], workspaces=workspaces(), focused_workspace_id=state.get('focused_workspace', 'w1')))
            elif method == 'layout.export':
                result = dict(type='layout_export', layout=export_layout(params['tab_id']))
            elif method == 'layout.set_split_ratio':
                root = export_layout(params['tab_id'])['root']
                node = root
                for second in params['path']:
                    node = node['second' if second else 'first']
                node['ratio'] = params['ratio']
                state.setdefault('layouts', {})[params['tab_id']] = root
                result = dict(type='ok')
                publish('layout.updated')
            elif method == 'workspace.focus':
                state['focused_workspace'] = params['workspace_id']
                result = dict(type='ok')
                publish('workspace.focused')
            elif method == 'tab.focus':
                tab = next(tab for tab in state['tabs'] if tab['tab_id'] == params['tab_id'])
                state.setdefault('active_tabs', {})[tab['workspace_id']] = tab['tab_id']
                result = dict(type='ok')
                publish('tab.focused')
            elif method == 'pane.focus':
                pane = next(pane for pane in state['panes'] if pane['pane_id'] == params['pane_id'])
                state.setdefault('focused_panes', {})[pane['tab_id']] = pane['pane_id']
                state.setdefault('active_tabs', {})[pane['workspace_id']] = pane['tab_id']
                state['focused_workspace'] = pane['workspace_id']
                result = dict(type='ok')
                publish('pane.focused')
            elif method == 'fixture.zoom':
                state.setdefault('zoomed', {})[params['tab_id']] = True
                result = dict(type='ok')
                publish('layout.updated')
            elif method == 'fixture.bad_layout':
                state.setdefault('layouts', {})[params['tab_id']] = dict(type='pane', pane_id='missing')
                result = dict(type='ok')
                publish('layout.updated')
            elif method == 'agent.list':
                result = dict(type='agent_list', agents=state.get('agents', []))
            elif method == 'pane.read':
                pane = next(pane for pane in state['panes'] if pane['pane_id'] == params['pane_id'])
                result = dict(type='pane_read', read=dict(pane_id=pane['pane_id'], workspace_id=pane['workspace_id'], tab_id=pane['tab_id'],
                              source='recent', format='text', text='first\n中文🙂\nLast line\n', revision=42, truncated=True))
                if scenario == 'bad_read':
                    result['read']['pane_id'] = 'another-pane'
            elif method == 'pane.process_info':
                result = dict(type='pane_process_info', process_info=dict(pane_id=params['pane_id'], foreground_process_group_id=12345,
                              foreground_processes=[dict(pid=12346, name='codex', cmdline='codex --test', cwd='/tmp/backend-cwd')]))
                if scenario == 'bad_process':
                    result['process_info']['foreground_processes'][0]['pid'] = -1
            elif method in ('workspace.create', 'tab.create', 'pane.split'):
                if scenario == 'reject':
                    connection.sendall((json.dumps(dict(id=request['id'], error=dict(code='denied', message='fixture rejected'))) + '\n').encode())
                    return
                number = len(state['panes']) + 1
                target = next((pane for pane in state['panes'] if pane['pane_id'] == params.get('target_pane_id')), None)
                tab_id = target['tab_id'] if target else f'w1:t{len(state["tabs"])+1}'
                pane = dict(pane_id=f'w1:p{number}', terminal_id=f'term_{number}', workspace_id='w1', tab_id=tab_id, title='Shell')
                if scenario == 'capabilities':
                    pane.update(cwd='/tmp/backend-shell', foreground_cwd='/tmp/backend-foreground')
                state['panes'].append(pane)
                if target and scenario == 'mirror':
                    root = export_layout(tab_id)['root']
                    def insert(node):
                        if node['type'] == 'pane':
                            if node['pane_id'] == target['pane_id']:
                                return dict(type='split', direction=params['direction'], ratio=.5, first=node, second=dict(type='pane', pane_id=pane['pane_id']))
                            return node
                        return dict(node, first=insert(node['first']), second=insert(node['second']))
                    state['layouts'][tab_id] = insert(root)
                if not target:
                    state['tabs'].append(dict(tab_id=tab_id, workspace_id='w1', label='Shell'))
                result = dict(type='pane_created', pane=pane) if target else dict(type='tab_created', root_pane=pane)
                persist()
                if scenario == 'unknown':
                    return  # Applied, acknowledgement lost.
                if scenario == 'slow':
                    time.sleep(0.3)
                publish('pane.created')
            elif method == 'pane.rename':
                pane = next(pane for pane in state['panes'] if pane['pane_id'] == params['pane_id'])
                pane['label'] = params.get('label')
                result = dict(type='ok')
                publish()
            elif method == 'tab.rename':
                tab = next(tab for tab in state['tabs'] if tab['tab_id'] == params['tab_id'])
                tab['label'] = params['label']
                result = dict(type='ok')
                publish('tab.renamed')
            elif method == 'tab.close':
                state['panes'] = [pane for pane in state['panes'] if pane['tab_id'] != params['tab_id']]
                state['tabs'] = [tab for tab in state['tabs'] if tab['tab_id'] != params['tab_id']]
                for workspace_id, active in list(state.get('active_tabs', {}).items()):
                    if active == params['tab_id']:
                        remaining = [tab for tab in state['tabs'] if tab['workspace_id'] == workspace_id]
                        if remaining:
                            state['active_tabs'][workspace_id] = remaining[0]['tab_id']
                        else:
                            del state['active_tabs'][workspace_id]
                result = dict(type='ok')
                publish('tab.closed')
            elif method == 'tab.move':
                tab = next(tab for tab in state['tabs'] if tab['tab_id'] == params['tab_id'])
                state['tabs'].remove(tab)
                state['tabs'].insert(params['insert_index'], tab)
                publish('tab.moved')
                result = dict(type='ok')
            elif method == 'fixture.replace_runtime':
                pane = next(pane for pane in state['panes'] if pane['pane_id'] == params['pane_id'])
                pane['terminal_id'] = 'different-runtime'
                result = dict(type='ok')
                publish()
            elif method in ('pane.close', 'fixture.external_close'):
                state['panes'] = [pane for pane in state['panes'] if pane['pane_id'] != params['pane_id']]
                result = dict(type='ok')
                publish('pane.closed')
            else:
                raise ValueError(method)
            persist()
            if scenario == 'mirror_slow_focus' and method == 'pane.focus':
                time.sleep(0.25)
            if scenario == 'slow_snapshot' and method == 'session.snapshot':
                time.sleep(0.25)
            connection.sendall((json.dumps(dict(id=request['id'], result=result)) + '\n').encode())
    except (OSError, ValueError, StopIteration):
        pass
    finally:
        if connection not in subscribers:
            connection.close()


def pulse():
    while True:
        with lock:
            state['pulse'] += 1
            persist()
        time.sleep(0.05)

threading.Thread(target=pulse, daemon=True).start()
listener = socket.socket(socket.AF_UNIX)
listener.bind(path)
listener.listen()
while True:
    connection, _ = listener.accept()
    threading.Thread(target=handle, args=(connection,), daemon=True).start()

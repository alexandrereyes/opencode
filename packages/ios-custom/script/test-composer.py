#!/usr/bin/env python3
"""Dedicated composer simulator; explicit sandbox credentials and opt-in disposable send tests."""
import base64
import atexit
import json
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time
import uuid
import urllib.request
import urllib.error

root = Path('/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode')
derived = root / 'ios-composer-derived'
evidence = root / 'ios-composer-prints'
evidence.mkdir(parents=True, exist_ok=True)
label = os.environ.get('COMPOSER_LABEL', 'verification')
password = (root / 'custom-sandbox-4177/password').read_text().strip()
environment = {'OPENCODE_TEST_PASSWORD': password, 'OPENCODE_SERVER_PASSWORD': password,
               'OPENCODE_TEST_THEME': os.environ.get('OPENCODE_TEST_THEME', 'openchamber-dark'),
               'OPENCODE_PROFILE_COMPOSER': os.environ.get('COMPOSER_PROFILE', '0')}
created = []
new_prompt = None
before = set()
def api(path, body=None, method='POST'):
    request = urllib.request.Request('http://127.0.0.1:4177' + path,
        data=json.dumps(body).encode() if body is not None else None, method=method,
        headers={'Authorization': 'Basic ' + base64.b64encode(('opencode:' + password).encode()).decode(),
                 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

def prepare_regressions():
    home = root / 'custom-sandbox-4177'
    manifest = json.loads((home / 'seed-conversation.json').read_text())
    directory = Path(manifest['directory'])
    assert directory.is_relative_to(home / 'repos')
    for key, role in [('A', 'working'), ('B', 'permission'), ('C', 'history'), ('CHILD', 'child-1')]:
        environment['OPENCODE_TEST_' + key] = next(s['id'] for s in manifest['sessions'] if s['role'] == role)
    for role in ['OWN', 'COMMENT', 'SESSION_ACTIONS', 'SESSION_MISSING']:
        session = 'ses_' + uuid.uuid4().hex
        path = directory / ('composer-missing-' + uuid.uuid4().hex) if role == 'SESSION_MISSING' else directory
        if role == 'SESSION_MISSING':
            path.mkdir()
        now = int(time.time() * 1000)
        model = {'providerID': 'llm-proxy', 'id': 'gpt-6-luna', 'variant': 'low'}
        messages = [] if role == 'OWN' else [
            {'id': 'msg_' + uuid.uuid4().hex, 'type': 'user', 'text': 'Confira este trecho.', 'time': {'created': now - 1000}},
            {'id': 'msg_' + uuid.uuid4().hex, 'type': 'assistant', 'agent': 'build', 'model': model,
             'time': {'created': now - 900, 'completed': now - 800}, 'finish': 'stop',
             'content': [{'type': 'text', 'text': 'Trecho para conferir os comentários.' if role == 'COMMENT'
                          else 'Histórico preservado para conferir os controles nativos.'}]}]
        api('/api/experimental/session/import', {
            'info': {'id': session, 'title': 'Onda 5 — ações' if role == 'SESSION_ACTIONS' else 'Composer — ' + role,
                     'projectID': 'global', 'location': {'directory': str(path)}, 'agent': 'build', 'model': model,
                     'cost': 0, 'tokens': {'input': 0, 'output': 0, 'reasoning': 0, 'cache': {'read': 0, 'write': 0}},
                     'outcome': 'succeeded', 'time': {'created': now, 'updated': now, 'idle': now, 'viewed': now}},
            'location': {'directory': str(path)}, 'messages': messages})
        created.append(session)
        environment['OPENCODE_TEST_' + role] = session
        if role == 'SESSION_MISSING':
            path.rmdir()

def cleanup():
    if new_prompt:
        for session in api('/api/session?limit=500', method='GET')['data']:
            if session['id'] in before:
                continue
            messages = api('/api/session/' + session['id'] + '/message?limit=20', method='GET')['data']
            if any(m.get('text') == new_prompt or (m.get('metadata') or {}).get('displayText') == new_prompt for m in messages):
                created.append(session['id'])
    for session in created:
        try:
            api('/api/session/' + session, method='DELETE')
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
    (evidence / (label + '-cleanup.json')).write_text(json.dumps({'deleted': created}, indent=2))
atexit.register(cleanup)
if os.environ.get('COMPOSER_SANDBOX_REGRESSIONS') == '1':
    prepare_regressions()
if os.environ.get('COMPOSER_COLLAPSE') == '1':
    before = {s['id'] for s in api('/api/session?limit=500', method='GET')['data']}
    new_prompt = 'Responda apenas OK, sem ferramentas. composer-collapse-' + uuid.uuid4().hex
    environment['OPENCODE_TEST_NEW_PROMPT'] = new_prompt
    subprocess.run(['xcrun', 'simctl', 'terminate', '8A5B01F4-0114-43FB-A1E4-0E8F2679473B', 'br.com.alexandrem.opencode'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', '8A5B01F4-0114-43FB-A1E4-0E8F2679473B', 'br.com.alexandrem.opencode', 'data'], text=True).strip())
    project = next(p for p in api('/api/project', method='GET') if p['canonical'] == str(root / 'custom-sandbox-4177/repos/abacato-v2'))
    snapshot = {'document': {'text': '', 'tokens': []}, 'attachments': [], 'cursor': 0,
                'model': {'providerID': 'llm-proxy', 'id': 'gpt-6-luna', 'variant': 'low'}, 'agent': 'build',
                'newSession': {'projectID': project['id'], 'destination': {'root': {}}, 'mcp': {}}}
    path = container / 'Library/Application Support/OpenCode/Drafts' / hashlib.sha256(b'http://127.0.0.1:4177').hexdigest() / 'new-session/draft.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(snapshot))
run = plistlib.loads(next(derived.glob('Build/Products/OpenCode_*.xctestrun')).read_bytes())
targets = ([t for c in run['TestConfigurations'] for t in c['TestTargets']]
           if 'TestConfigurations' in run else [v for k, v in run.items() if k != '__xctestrun_metadata__'])
for target in targets:
    target.setdefault('EnvironmentVariables', {}).update(environment)
    target['CommandLineArguments'] = ['-OpenCodeServerURL', 'http://127.0.0.1:4177']
    if os.environ.get('COMPOSER_SCROLL_FIXTURE'):
        target['CommandLineArguments'] += ['-OpenCodeScrollFixture', os.environ['COMPOSER_SCROLL_FIXTURE']]
configured = derived / ('Build/Products/Composer-' + uuid.uuid4().hex + '.xctestrun')
configured.write_bytes(plistlib.dumps(run))
configured.chmod(0o600)
try:
    video = subprocess.Popen(['xcrun', 'simctl', 'io', '8A5B01F4-0114-43FB-A1E4-0E8F2679473B',
                              'recordVideo', '--codec=h264', str(evidence / (label + '.mp4'))],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    command = ['xcodebuild', 'test-without-building', '-xctestrun', str(configured),
        '-destination', 'platform=iOS Simulator,name=OpenCode Composer',
        '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
        '-resultBundlePath', str(evidence / (label + '-' + uuid.uuid4().hex + '.xcresult'))]
    command += ['-only-testing:' + t for t in (sys.argv[1:] or ['OpenCodeTests/ComposerEditingTests'])]
    with (evidence / (label + '.log')).open('w') as log:
        result = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        if os.environ.get('COMPOSER_PROFILE') == '1':
            deadline = time.monotonic() + 45
            while result.poll() is None and time.monotonic() < deadline:
                ready = re.search(r'COMPOSER_PROFILE_READY pid=(\d+)', (evidence / (label + '.log')).read_text())
                if ready:
                    with (evidence / (label + '-profile.log')).open('w') as profile_log:
                        profile = subprocess.Popen(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler',
                            '--device', '8A5B01F4-0114-43FB-A1E4-0E8F2679473B',
                            '--attach', ready.group(1), '--time-limit', '30s', '--output', str(evidence / (label + '.trace'))],
                            stdout=profile_log, stderr=subprocess.STDOUT)
                        try:
                            profile.wait(timeout=60)
                        except subprocess.TimeoutExpired:
                            profile.terminate()
                            try:
                                profile.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                profile.kill()
                                profile.wait()
                    break
                time.sleep(0.2)
        result.wait()
    print('Result:', result.returncode, 'Log:', evidence / (label + '.log'))
    sys.exit(result.returncode)
finally:
    video.send_signal(2)
    video.wait(timeout=30)
    configured.unlink(missing_ok=True)

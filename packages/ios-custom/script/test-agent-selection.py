#!/usr/bin/env python3
"""Run selection regressions against disposable sandbox sessions on OpenCode Agente."""
import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import uuid
import urllib.request

root = Path('/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode')
derived = root / 'ios-agente-derived'
home = root / 'custom-sandbox-4177'
password = (home / 'password').read_text().strip()
evidence = root / 'ios-agente-prints'
evidence.mkdir(exist_ok=True)

def api(path, body=None, method='GET'):
    request = urllib.request.Request('http://127.0.0.1:4177' + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': 'Basic ' + base64.b64encode(('opencode:' + password).encode()).decode(),
                 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

for theme in ['openchamber-dark', 'openchamber-light']:
    session = api('/api/session', {
        'location': {'directory': str(home / 'repos/abacato-v2')},
        'title': 'Agent selection regression ' + uuid.uuid4().hex,
        'agent': 'build', 'model': {'id': 'gpt-6-luna', 'providerID': 'llm-proxy', 'variant': 'low'},
    }, 'POST')['data']['id']
    configured = derived / ('Build/Products/Agent-' + uuid.uuid4().hex + '.xctestrun')
    try:
        run = plistlib.loads(next(derived.glob('Build/Products/OpenCode_*.xctestrun')).read_bytes())
        targets = ([t for c in run['TestConfigurations'] for t in c['TestTargets']]
            if 'TestConfigurations' in run else [v for k, v in run.items() if k != '__xctestrun_metadata__'])
        for target in targets:
            target.setdefault('EnvironmentVariables', {}).update({
                'OPENCODE_TEST_PASSWORD': password, 'OPENCODE_SERVER_PASSWORD': password,
                'OPENCODE_TEST_THEME': theme, 'OPENCODE_TEST_AGENT_SESSION': session})
            target['CommandLineArguments'] = ['-OpenCodeServerURL', 'http://127.0.0.1:4177']
        configured.write_bytes(plistlib.dumps(run))
        configured.chmod(0o600)
        with (evidence / (theme + '.log')).open('w') as log:
            result = subprocess.run(['xcodebuild', 'test-without-building', '-xctestrun', str(configured),
                '-destination', 'platform=iOS Simulator,name=OpenCode Agente',
                '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
                '-only-testing:OpenCodeUITests/AgentSelectionTests',
                '-resultBundlePath', str(evidence / (theme + '-' + uuid.uuid4().hex + '.xcresult'))],
                stdout=log, stderr=subprocess.STDOUT)
        messages = api('/api/session/' + session + '/message?limit=100')['data']
        switches = [m for m in messages if m['type'] in ['agent-switched', 'model-switched']]
        (evidence / (theme + '-switches.json')).write_text(json.dumps(switches, indent=2))
        print(theme, 'exit:', result.returncode, 'switches:', len(switches))
        if result.returncode:
            raise SystemExit(result.returncode)
    finally:
        configured.unlink(missing_ok=True)
        api('/api/session/' + session, method='DELETE')

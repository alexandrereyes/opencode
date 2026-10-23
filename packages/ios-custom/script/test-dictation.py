#!/usr/bin/env python3
"""Offline recording fixtures; one simulator per invocation, no server operations."""
import argparse
from pathlib import Path
import os
import plistlib
import signal
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--simulator', default='0C2C8A7F-CD76-43D5-88F5-A880D5A80B78')
parser.add_argument('--theme', default='openchamber-dark')
parser.add_argument('--label', default='dictation')
parser.add_argument('tests', nargs='*')
args = parser.parse_args()
root = Path('/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode')
derived = root / 'ios-gravacao-derived'
evidence = root / 'ios-gravacao-prints'
evidence.mkdir(parents=True, exist_ok=True)
password = (root / 'custom-sandbox-4177/password').read_text().strip()
run = plistlib.loads(next(derived.glob('Build/Products/OpenCode_*.xctestrun')).read_bytes())
targets = ([t for c in run['TestConfigurations'] for t in c['TestTargets']]
           if 'TestConfigurations' in run else [v for k, v in run.items() if k != '__xctestrun_metadata__'])
for target in targets:
    target.setdefault('EnvironmentVariables', {}).update({
        'OPENCODE_TEST_PASSWORD': password, 'OPENCODE_SERVER_PASSWORD': password,
        'OPENCODE_TEST_THEME': args.theme})
    target['CommandLineArguments'] = ['-OpenCodeServerURL', 'http://127.0.0.1:4177']
configured = derived / ('Build/Products/Dictation-' + uuid.uuid4().hex + '.xctestrun')
configured.write_bytes(plistlib.dumps(run))
configured.chmod(0o600)
video = None
try:
    subprocess.run(['xcrun', 'simctl', 'boot', args.simulator], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', args.simulator, '-b'], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['xcrun', 'simctl', 'status_bar', args.simulator, 'override', '--time', '10:58',
                    '--batteryState', 'charged', '--batteryLevel', '100'], check=True)
    video = subprocess.Popen(['xcrun', 'simctl', 'io', args.simulator, 'recordVideo', '--codec=h264',
                              str(evidence / (args.label + '.mp4'))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = evidence / (args.label + '-' + uuid.uuid4().hex + '.xcresult')
    command = ['xcodebuild', 'test-without-building', '-xctestrun', str(configured),
               '-destination', 'platform=iOS Simulator,id=' + args.simulator,
               '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never', '-resultBundlePath', str(result)]
    command += ['-only-testing:' + test for test in (args.tests or ['OpenCodeTests/DictationPipelineTests', 'OpenCodeUITests/DictationUITests'])]
    with (evidence / (args.label + '.log')).open('w') as log:
        completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result),
                    '--output-path', str(evidence / (args.label + '-attachments'))], stdout=subprocess.DEVNULL)
    print('Result:', completed.returncode, 'Evidence:', result)
    raise SystemExit(completed.returncode)
finally:
    if video:
        video.send_signal(signal.SIGINT)
        video.wait(timeout=30)
    configured.unlink(missing_ok=True)
    subprocess.run(['xcrun', 'simctl', 'terminate', args.simulator, 'br.com.alexandrem.opencode'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['xcrun', 'simctl', 'shutdown', args.simulator], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

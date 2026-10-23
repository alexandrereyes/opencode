#!/usr/bin/env python3
"""Leased iPhone 14 only, after the real model download: deterministic local inference, no server."""
from pathlib import Path
import hashlib
import json
import os
import subprocess

root = Path('/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode')
evidence = root / 'ios-gravacao-prints'
evidence.mkdir(parents=True, exist_ok=True)
device = '00008110-00065DA13A78401E'
bundle = 'br.com.alexandrem.opencode'
lease = [str(Path.home() / '.agents/skills/aparelhos-fisicos/scripts/device-lease'), 'exec', 'iphone14', '--']
environment = dict(os.environ, AGENT_DEVICE_STATE_DIR=str(root / 'ios-gravacao-agent-device'),
                   AGENT_DEVICE_IOS_TEAM_ID='ERRYZ68LX5', AGENT_DEVICE_IOS_BUNDLE_ID='app.abacato.agentdevice.runner')
def run(command):
    return subprocess.run(lease + command, env=environment, check=True, capture_output=True, text=True, timeout=180).stdout
def agent(*arguments):
    return run(['npx', '-y', 'agent-device@0.21.23', *arguments, '--session', 'gravacao-clean'])

audio = evidence / 'device-clean-10s.caf'
subprocess.run(['swift', '-e', '''import AVFoundation; import Foundation
let input = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 480000)!
try input.read(into: buffer)
let count = buffer.frameLength
buffer.frameLength = 480000
for index in Int(count)..<480000 { buffer.floatChannelData![0][index] = 0 }
let output = try AVAudioFile(forWriting: URL(fileURLWithPath: CommandLine.arguments[2]), settings: input.processingFormat.settings)
try output.write(from: buffer)
''', 'packages/ios-custom/OpenCode/Fixtures/dictation-fixture.caf', str(audio)], check=True)
draft = evidence / 'device-clean-draft.json'
draft.write_text(json.dumps({'document': {'text': '', 'tokens': []}, 'attachments': [], 'cursor': 0, 'dictationPending': True}))
directory = 'Library/Application Support/OpenCode/Drafts/' + hashlib.sha256(b'dictation-fixture').hexdigest() + '/device/'
run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device,
     str(root / 'ios-gravacao-device-derived/Build/Products/Debug-iphoneos/OpenCode.app')])
pid = None
try:
    for theme in ['dark', 'light']:
        for source, name in [(audio, 'dictation.caf'), (draft, 'draft.json')]:
            run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', device,
                 '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                 '--source', str(source), '--destination', directory + name])
        environment['DEVICECTL_CHILD_OPENCODE_SERVER_PASSWORD'] = (root / 'custom-sandbox-4177/password').read_text().strip()
        launch = json.loads(run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', device,
            '--terminate-existing', '--json-output', '-', bundle, '--', '-OpenCodeServerURL', 'http://127.0.0.1:4177',
            '-OpenCodeDictationFixture', 'device', '-OpenCodeTheme', 'openchamber-' + theme]))
        pid = launch['result']['process']['processIdentifier']
        environment.pop('DEVICECTL_CHILD_OPENCODE_SERVER_PASSWORD')
        agent('open', bundle, '--foreground', '--platform', 'ios', '--udid', device)
        agent('wait', 'id=composer-send', '90000')
        agent('wait', 'text', 'Recolher', '10000')
        transcript = agent('get', 'text', 'id=conversation-composer')
        (evidence / ('device-clean-' + theme + '.txt')).write_text(transcript)
        assert 'resumo das alterações' in transcript.casefold(), transcript
        assert 'revisão' in transcript.casefold(), transcript
        target = evidence / ('device-clean-' + theme + '.json')
        run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device,
             '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
             '--source', 'Library/Application Support/OpenCode/dictation-fixture-metrics.json', '--destination', str(target)])
        metrics = json.loads(target.read_text())
        assert abs(metrics['audioSeconds'] - 10) < 0.01, metrics
        assert metrics['expanded'] and not metrics['reviewPending'], metrics
        agent('screenshot', str(evidence / ('device-clean-' + theme + '.png')))
        run(['xcrun', 'devicectl', 'device', 'process', 'terminate', '--device', device, '--pid', str(pid)])
        pid = None
        agent('close')
        print(theme, metrics)
finally:
    subprocess.run(lease + ['npx', '-y', 'agent-device@0.21.23', 'close', '--session', 'gravacao-clean'],
                   env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if pid:
        subprocess.run(lease + ['xcrun', 'devicectl', 'device', 'process', 'terminate', '--device', device, '--pid', str(pid)],
                       env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

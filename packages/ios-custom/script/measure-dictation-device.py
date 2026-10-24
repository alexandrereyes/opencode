#!/usr/bin/env python3
"""Leased iPhone 14 only: time touch → recording, release → text and pause → preview with the device fixture.

Installs an optimized DEBUG build (`-OpenCodeDictationFixture device`, real microphone and Parakeet, no server),
drives the microphone with agent-device and reads the app's own uptime marks (`-OpenCodeDictationTimeline`).
The Mac speaks a short Portuguese phrase during each hold so the transcription has text; that audio is a test
stimulus, not an accuracy check.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True, help="Debug-iphoneos/OpenCode.app built with optimization")
parser.add_argument("--label", required=True)
parser.add_argument("--iterations", type=int, default=5)
args = parser.parse_args()

root = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
evidence = root / "ios-ditado-medidas"
evidence.mkdir(parents=True, exist_ok=True)
device = "00008110-00065DA13A78401E"
bundle = "br.com.alexandrem.opencode"
container = "Library/Application Support/OpenCode/"
draft_directory = container + "Drafts/" + hashlib.sha256(b"dictation-fixture").hexdigest() + "/device/"
device_lease = str(Path.home() / ".agents/skills/aparelhos-fisicos/scripts/device-lease")
lease = [device_lease, "exec", "iphone14", "--"]
environment = dict(os.environ, AGENT_DEVICE_STATE_DIR=str(root / "ios-ditado-agent-device"),
                   AGENT_DEVICE_IOS_TEAM_ID="ERRYZ68LX5", AGENT_DEVICE_IOS_BUNDLE_ID="app.abacato.agentdevice.runner")
password = (root / "custom-sandbox-4177/password").read_text().strip()


def run(command, timeout=180, check=True):
    return subprocess.run(lease + command, env=environment, check=check, capture_output=True, text=True, timeout=timeout)


def agent(*arguments, check=True, timeout=180):
    return run(["npx", "-y", "agent-device@0.21.23", *arguments, "--session", "ditado-medidas"], timeout, check)


def copy_to(source, destination):
    run(["xcrun", "devicectl", "device", "copy", "to", "--device", device, "--domain-type", "appDataContainer",
         "--domain-identifier", bundle, "--source", str(source), "--destination", destination])


def launch():
    """Fresh empty draft and timeline, then the fixture in the foreground."""
    copy_to(empty_draft, draft_directory + "draft.json")
    copy_to(empty_timeline, container + "dictation-timeline.json")
    global pid
    child = dict(environment, DEVICECTL_CHILD_OPENCODE_SERVER_PASSWORD=password)
    launched = subprocess.run(lease + ["xcrun", "devicectl", "device", "process", "launch", "--device", device,
                                       "--terminate-existing", "--json-output", "-", bundle, "--",
                                       "-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeDictationFixture", "device",
                                       "-OpenCodeDictationTimeline", "-OpenCodeTheme", "openchamber-dark"],
                              env=child, check=True, capture_output=True, text=True, timeout=120)
    pid = json.loads(launched.stdout)["result"]["process"]["processIdentifier"]
    agent("open", bundle, "--foreground", "--platform", "ios", "--udid", device)
    agent("wait", "id=dictation-microphone", "30000")


def marks():
    target = evidence / (args.label + "-timeline.json")
    run(["xcrun", "devicectl", "device", "copy", "from", "--device", device, "--domain-type", "appDataContainer",
         "--domain-identifier", bundle, "--source", container + "dictation-timeline.json", "--destination", str(target)])
    return json.loads(target.read_text())


def after(timeline, start, end, since=0):
    """Milliseconds from the first `start` mark at or after `since` to the first `end` mark after it."""
    first = next(mark for mark in timeline[since:] if mark["name"] == start)
    last = next(mark for mark in timeline[timeline.index(first):] if mark["name"] == end)
    return round((last["uptime"] - first["uptime"]) * 1000, 1)


empty_draft = evidence / "empty-draft.json"
empty_draft.write_text(json.dumps({"document": {"text": "", "tokens": []}, "attachments": [], "cursor": 0}))
empty_timeline = evidence / "empty-timeline.json"
empty_timeline.write_text("[]")
pid = None
results = {"label": args.label, "tap": [], "hold": [], "release": [], "preview": [], "failures": []}
subprocess.run([device_lease, "acquire", "iphone14", "--owner", "ios-custom: medidas do ditado", "--pid", str(os.getpid())], check=True)
try:
    run(["xcrun", "devicectl", "device", "install", "app", "--device", device, str(args.app)], timeout=600)
    # A new bundle path recompiles Parakeet for the Neural Engine once (~15 s); wait for it before timing.
    launch()
    agent("wait", "id=dictation-load-time", "120000")
    for _ in range(args.iterations):
        seen = len(marks())
        agent("press", "id=dictation-microphone")
        time.sleep(1.5)
        agent("press", "id=dictation-pause-resume")
        time.sleep(1.5)
        agent("press", "id=dictation-discard")
        agent("wait", "id=dictation-microphone", "10000")
        timeline = marks()
        results["tap"].append(after(timeline, "touch", "recording", seen))
        results["preview"].append(after(timeline, "pause", "preview", seen))
    for _ in range(args.iterations):
        launch()
        speech = subprocess.Popen(["say", "-v", "Luciana", "Confira as sessões em andamento e prepare um resumo."])
        agent("longpress", "id=dictation-microphone", "4500")
        speech.wait(timeout=30)
        transcribed = agent("wait", "text", "Recolher", "60000", check=False).returncode == 0
        timeline = marks()
        results["hold"].append(after(timeline, "touch", "recording"))
        if transcribed:
            results["release"].append(after(timeline, "release", "text"))
        else:
            results["failures"].append(timeline)
    agent("close")
finally:
    subprocess.run(lease + ["npx", "-y", "agent-device@0.21.23", "close", "--session", "ditado-medidas"],
                   env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if pid:
        subprocess.run(lease + ["xcrun", "devicectl", "device", "process", "terminate", "--device", device, "--pid", str(pid)],
                       env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([device_lease, "release", "iphone14", "--pid", str(os.getpid())], stdout=subprocess.DEVNULL)
summary = {key: {"samples": value, "median": statistics.median(value)} for key, value in results.items()
           if key not in ("label", "failures") and value}
(evidence / (args.label + ".json")).write_text(json.dumps(dict(results, summary=summary), indent=2))
print(json.dumps(summary, indent=2), "failures:", len(results["failures"]))

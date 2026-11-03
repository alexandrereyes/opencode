#!/usr/bin/env python3
"""Sessões' server title on the iPhone (OpenCodeUITests/ServerHeaderTests) against an isolated sandbox.

Imports one finished session ("Rascunho entre servidores", no model call) into the sandbox, runs the tests on the
given simulator with a fresh app, copies the captures to --evidence and deletes the session. The tests' other
servers are the app's in-memory fixture (`-OpenCodeFixtureServers`): unreachable loopback addresses, never saved
in the app's defaults or Keychain.

  python3 packages/ios-custom/script/test-server-header.py --server-url http://127.0.0.1:<port> \\
    --home <custom-sandbox home> --derived <DerivedData> --device-file <file with the UDID> --evidence <dir> \\
    [--theme openchamber-light] [OpenCodeUITests/ServerHeaderTests/testName ...]
"""
import argparse
import base64
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--server-url", required=True)
parser.add_argument("--home", type=Path, required=True)
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--device-file", type=Path, required=True)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--theme", default="openchamber-dark")
parser.add_argument("tests", nargs="*")
args = parser.parse_args()

port = int(args.server_url.rsplit(":", 1)[1].rstrip("/"))
if port in (4096, 4177, 4178, 4179) or not args.server_url.startswith("http://127.0.0.1:"):
    parser.error("Use an isolated loopback sandbox, never 4096, 4177, 4178 or 4179")
owner = json.loads((args.home / "sandbox.json").read_text())
assert owner["port"] == port and Path(owner["home"]).resolve() == args.home.resolve(), "Sandbox ownership mismatch"
password = (args.home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
    "Content-Type": "application/json"}


def api(path, body=None, method="POST"):
    request = urllib.request.Request(args.server_url + path, data=json.dumps(body).encode() if body is not None else None,
        headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None


fixture = Path(tempfile.mkdtemp(prefix="ios-server-header-"))
now = int(time.time() * 1000)
session = "ses_" + uuid.uuid4().hex
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
title = "Rascunho entre servidores"
api("/api/experimental/session/import", {
    "info": {"id": session, "title": title, "projectID": "global", "location": {"directory": str(fixture)},
        "agent": "general", "model": model, "cost": 0,
        "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": "succeeded", "time": {"created": now - 60_000, "updated": now, "idle": now, "viewed": now}},
    "location": {"directory": str(fixture)},
    "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": title + ".", "time": {"created": now - 60_000}},
        {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "general", "model": model,
         "time": {"created": now - 59_000, "completed": now}, "finish": "stop",
         "content": [{"type": "text", "text": "Pronto."}]}]})

device = args.device_file.read_text().strip()
token = uuid.uuid4().hex[:10]
run = plistlib.loads(next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run
    else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": args.theme,
    "OPENCODE_TEST_SERVER_URL": args.server_url}
for target in targets:
    target.setdefault("EnvironmentVariables", {}).update(environment)
    target["CommandLineArguments"] = ["-OpenCodeServerURL", args.server_url, "-OpenCodeTheme", args.theme]
configured = args.derived / ("Build/Products/ServerHeader-" + token + ".xctestrun")
configured.write_bytes(plistlib.dumps(run))
configured.chmod(0o600)
args.evidence.mkdir(parents=True, exist_ok=True)
result = args.evidence / ("server-header-" + token + ".xcresult")
try:
    # A fresh app container every run: no server registry, Keychain item, draft or reading place of the last one.
    subprocess.run(["xcrun", "simctl", "uninstall", device, "br.com.alexandrem.opencode"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--dataNetwork", "wifi",
        "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
        "--batteryState", "charged", "--batteryLevel", "100"], check=True)
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured),
        "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
        "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
        "-maximum-test-execution-time-allowance", "420", "-resultBundlePath", str(result)]
    command += ["-only-testing:" + test for test in args.tests or ["OpenCodeUITests/ServerHeaderTests"]]
    with (args.evidence / ("xcodebuild-" + token + ".log")).open("w") as log:
        status = subprocess.call(command, stdout=log, stderr=subprocess.STDOUT)
finally:
    configured.unlink(missing_ok=True)
    api("/api/session/" + session, method="DELETE")
    shutil.rmtree(fixture, ignore_errors=True)
exported = Path(tempfile.mkdtemp(prefix="server-header-attachments-"))
subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(exported)],
    check=True, stdout=subprocess.DEVNULL)
for test in json.loads((exported / "manifest.json").read_text()):
    for attachment in test["attachments"]:
        source = exported / attachment["exportedFileName"]
        if source.suffix == ".png":
            name = attachment["suggestedHumanReadableName"].split("_0_")[0]
            shutil.copyfile(source, args.evidence / (("falha-" if attachment["isAssociatedWithFailure"] else "") + name + ".png"))
shutil.rmtree(exported)
if status == 0:
    shutil.rmtree(result)
print(json.dumps({"status": status, "theme": args.theme}))
sys.exit(status)

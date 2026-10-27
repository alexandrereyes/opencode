#!/usr/bin/env python3
"""Wave 10: isolated simulator, sandbox reads and disposable owned regression histories only."""
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import urllib.request
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
# Overrides let an isolated worker use its own sandbox, build and simulator (never 4096/4178).
server = os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4177")
home = Path(os.environ.get("OPENCODE_TEST_HOME", str(temporary / "custom-sandbox-4177")))
derived = Path(os.environ.get("OPENCODE_TEST_DERIVED", str(temporary / "ios-linhas-derived")))
evidence = Path(os.environ.get("OPENCODE_TEST_EVIDENCE", str(temporary / "ios-onda10-prints")))
evidence.mkdir(parents=True, exist_ok=True)
device = os.environ.get("OPENCODE_TEST_DEVICE", "5212D3A2-53B3-42DF-826B-338FC95E1AED")
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}

def api(path, body=None, method="GET"):
    request = urllib.request.Request(server + path, headers=headers,
        data=json.dumps(body).encode() if body is not None else None, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

token = uuid.uuid4().hex[:10]
configured = derived / ("Build/Products/SessionRows-" + token + ".xctestrun")
owned = []
manifest = json.loads((home / "seed-conversation.json").read_text())
environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme,
    "OPENCODE_TEST_SERVER_URL": server}
for key, role in [("A", "working"), ("C", "history"), ("CHILD", "child-1")]:
    environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
tests = sys.argv[1:] or ["OpenCodeUITests/SessionRowsTests", "OpenCodeTests/SessionRowLayoutTests"]
try:
    if any("SessionReadingTests" in test for test in tests):
        now = int(time.time() * 1000)
        for role, title, directory in [
            ("SESSION_ACTIONS", "Onda 5 — ações", manifest["directory"]),
            ("SESSION_MISSING", "Onda 5 — diretório ausente", str(home / ("missing-onda10-" + token))),
        ]:
            session = "ses_" + uuid.uuid4().hex
            owned.append(session)
            environment["OPENCODE_TEST_" + role] = session
            api("/api/experimental/session/import", {
                "info": {"id": session, "title": title, "projectID": "global", "location": {"directory": directory},
                    "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                    "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                    "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
                "location": {"directory": directory}, "messages": [
                    {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Uma sessão de verificação isolada.", "time": {"created": now - 1000}},
                    {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build",
                     "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                     "time": {"created": now - 900, "completed": now - 800}, "finish": "stop",
                     "content": [{"type": "text", "text": "Histórico preservado para conferir os controles nativos."}]}]}, method="POST")
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
               if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["CommandLineArguments"] = ["-OpenCodeServerURL", server]
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi",
        "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
        "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    result = evidence / (theme + "-" + token + ".xcresult")
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination",
        "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
        "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "240", "-resultBundlePath", str(result)]
    status = subprocess.call(command + ["-only-testing:" + test for test in tests])
    exported = evidence / ("attachments-" + token)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(exported)], check=True)
    for test in json.loads((exported / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = exported / attachment["exportedFileName"]
            if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                name = attachment["suggestedHumanReadableName"].split("_0_")[0]
                shutil.copyfile(source, evidence / (name + ".png"))
    print(json.dumps({"status": status, "result": str(result), "screenshots": str(evidence)}))
    sys.exit(status)
finally:
    configured.unlink(missing_ok=True)
    for session in owned:
        api("/api/session/" + session, method="DELETE")
    subprocess.run(["xcrun", "simctl", "terminate", device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

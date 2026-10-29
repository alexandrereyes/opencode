#!/usr/bin/env python3
"""Wave 8: dedicated Simulator, sandbox-only servers/pairing, no model or seed mutations."""
import base64
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
# Overrides let an isolated worker use its own sandbox (never 4096/4178).
server = os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4177")
home = Path(os.environ.get("OPENCODE_TEST_HOME", temporary / "custom-sandbox-4177"))
address = urllib.parse.urlparse(server)
assert address.hostname in ("127.0.0.1", "localhost") and address.port not in (None, 4096, 4178), "Use an isolated loopback sandbox"
derived = Path(os.environ.get("OPENCODE_SETTINGS_DERIVED", os.environ.get("OPENCODE_TEST_DERIVED", temporary / "ios-sessoes-derived")))
evidence = Path(os.environ.get("OPENCODE_SETTINGS_EVIDENCE", os.environ.get("OPENCODE_TEST_EVIDENCE", temporary / "ios-onda8-prints")))
device_name = os.environ.get("OPENCODE_SETTINGS_SIMULATOR", "OpenCode Sessoes")
device_hint = os.environ.get("OPENCODE_TEST_DEVICE", device_name)
lease = (temporary / ("ios-sessoes-test.lock" if device_hint == "OpenCode Sessoes"
    else device_hint.replace(" ", "-") + "-settings-test.lock")).open("a")
fcntl.flock(lease, fcntl.LOCK_EX)
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
token = uuid.uuid4().hex
configured = derived / ("Build/Products/Settings-" + token + ".xctestrun")
result = temporary / ("onda8-" + token + ".xcresult")
sessions = []

def api(path, body=None, method="POST"):
    request = urllib.request.Request(server + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

try:
    now = int(time.time() * 1000)
    root, child = ["ses_" + uuid.uuid4().hex for _ in range(2)]
    directory = json.loads((home / "seed-conversation.json").read_text())["directory"]
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    for session, is_child in [(root, False), (child, True)]:
        info = {"id": session, "title": "Onda 8 — subagente" if is_child else "Onda 8 — leitura e temas",
                "projectID": "global", "location": {"directory": directory}, "agent": "general" if is_child else "build",
                "model": model, "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                "time": {"created": now, "updated": now, "idle": now, "viewed": now}}
        if is_child:
            info["parentID"] = root
        text = "You are a subagent spawned by another session.\nConfira apenas o texto autoral do subagente." if is_child else "Confira a aparência desta conversa."
        api("/api/experimental/session/import", {"info": info, "location": {"directory": directory}, "messages": [
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": text, "time": {"created": now - 1000}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": info["agent"], "model": model,
             "time": {"created": now - 900, "completed": now - 800}, "finish": "stop",
             "content": [{"type": "text", "text": "## Aparência nativa\n\nO tema muda ao vivo, sem reiniciar a conversa.\n\n- Cores semânticas\n- Rascunhos preservados\n\n```swift\nlet app = OpenCode()\n```"}]}]})
        sessions.append(session)
    pairing = api("/api/pair")
    payload = (server + "/auth/connect/" + pairing["code"] if theme.endswith("light")
               else json.dumps({"code": pairing["code"], "urls": [server]}))
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
                   "OPENCODE_TEST_THEME": theme, "OPENCODE_TEST_CHILD": child, "OPENCODE_TEST_RUN_ID": token[:5],
                   "OPENCODE_TEST_PAIRING": payload, "OPENCODE_TEST_SERVER_URL": server}
    targets = [t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"]
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["CommandLineArguments"] = ["-OpenCodeServerURL", server]
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    device = os.environ.get("OPENCODE_TEST_DEVICE") or next(d["udid"] for group in devices["devices"].values() for d in group if d["name"] == device_name)
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "300", "-resultBundlePath", str(result)]
    for test in sys.argv[1:] or ["OpenCodeUITests/SettingsTests"]:
        command.append("-only-testing:" + test)
    status = subprocess.call(command)
    evidence.mkdir(parents=True, exist_ok=True)
    export = evidence / ("attachments-" + token)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(export)], check=True)
    for test in json.loads((export / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = export / attachment["exportedFileName"]
            if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                shutil.copyfile(source, evidence / (attachment["suggestedHumanReadableName"].split("_0_")[0] + ".png"))
    (evidence / ("verification-" + token + ".json")).write_text(json.dumps({"status": status, "result": str(result), "theme": theme, "production": "never selected; loopback-only launch guard", "sessions": sessions}, indent=2))
    sys.exit(status)
finally:
    configured.unlink(missing_ok=True)
    for session in reversed(sessions):
        api("/api/session/" + session, method="DELETE")

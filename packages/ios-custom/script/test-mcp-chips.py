#!/usr/bin/env python3
"""Dedicated Chips simulator. Stub mutations by default; opt-in live Safari only."""
import argparse
import base64
import json
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import urllib.parse
import urllib.error
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--live", action="store_true")
parser.add_argument("--label", default="verification")
parser.add_argument("tests", nargs="*")
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
# Overrides let a separate agent use its own sandbox, simulator and build.
server = os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4177")
home = Path(os.environ.get("OPENCODE_TEST_HOME", temporary / "custom-sandbox-4177"))
derived = Path(os.environ.get("OPENCODE_TEST_DERIVED", temporary / "ios-chips-derived"))
evidence = Path(os.environ.get("OPENCODE_TEST_EVIDENCE", temporary / "ios-chips-prints"))
evidence.mkdir(parents=True, exist_ok=True)
device = os.environ.get("OPENCODE_TEST_DEVICE", "9C92A4EB-5CD9-4F31-9A79-707A18D27976")
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme,
    "OPENCODE_TEST_SERVER_URL": server}
owned = []
folders = []
report = {"theme": theme, "created": owned, "production": "never used", "liveMutation": "safari-devtools only" if args.live else "none"}

def api(path, body=None, method="GET"):
    request = urllib.request.Request(server + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
        return json.loads(data) if data else None

def create(title, messages, path, model, parent=None):
    assert Path(path).is_relative_to(home / "repos")
    session = "ses_" + uuid.uuid4().hex
    now = int(time.time() * 1000)
    info = {"id": session, "title": title, "projectID": "global", "location": {"directory": path},
        "agent": "build", "model": model, "outcome": "succeeded", "cost": 0,
        "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "time": {"created": now, "updated": now, "idle": now, "viewed": now}}
    if parent:
        info["parentID"] = parent
    owned.append(session)
    api("/api/experimental/session/import", {"info": info, "location": {"directory": path},
        "messages": [{**message, "id": "msg_" + uuid.uuid4().hex} for message in messages]}, "POST")
    return session

token = args.label + "-" + uuid.uuid4().hex[:8]
configured = derived / ("Build/Products/MCP-" + token + ".xctestrun")
query = None
before = None
try:
    if any("NewSessionTests/test04" in test for test in args.tests):
        subprocess.run(["xcrun", "simctl", "terminate", device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, "br.com.alexandrem.opencode", "data"], text=True).strip())
        draft = container / "Library/Application Support/OpenCode/Drafts" / hashlib.sha256(server.encode()).hexdigest() / "new-session/draft.json"
        draft.unlink(missing_ok=True)
    manifest = json.loads((home / "seed-conversation.json").read_text())
    directory = manifest["directory"]
    assert Path(directory).is_relative_to(home / "repos")
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    now = int(time.time() * 1000)
    messages = [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Confira os MCPs deste diretório.", "time": {"created": now - 1000}},
        {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
         "time": {"created": now - 900, "completed": now - 800}, "finish": "stop",
         "content": [{"type": "text", "text": "Os chips usam os servidores da própria localização da sessão."}]}]
    if args.live:
        query = urllib.parse.urlencode({"location[directory]": directory})
        before = api("/api/mcp?" + query)["data"]
        assert next(s for s in before if s["name"] == "safari-devtools")["status"]["status"] == "connected"
        report["before"] = before
        environment["OPENCODE_MCP_LIVE_SESSION"] = create("MCPs — verificação isolada", messages, directory, model)
    for key, role in [("A", "working"), ("B", "permission"), ("C", "history"), ("CHILD", "child-1")]:
        environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
    if any("SessionReadingTests" in test for test in args.tests):
        history = [*messages[:-1], {**messages[-1], "content": [{"type": "text", "text": "Histórico preservado para conferir os controles nativos."}]}]
        environment["OPENCODE_TEST_SESSION_ACTIONS"] = create("Onda 5 — ações", history, directory, model)
        missing = Path(directory) / ("chips-missing-" + uuid.uuid4().hex)
        missing.mkdir()
        folders.append(missing)
        environment["OPENCODE_TEST_SESSION_MISSING"] = create("MCPs — diretório ausente", history, str(missing), model)
        missing.rmdir()
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
        if "TestConfigurations" in run else [value for key, value in run.items() if key != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["CommandLineArguments"] = ["-OpenCodeServerURL", server]
        target["UITargetAppCommandLineArguments"] = ["-OpenCodeServerURL", server]
        target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    tests = args.tests or ["OpenCodeTests/ConversationMCPTests",
        "OpenCodeUITests/ConversationMCPTests/testPanelTogglesPendingAndPreservesComposerFocusTextAndHeight",
        "OpenCodeUITests/ConversationMCPTests/testLoginFailureAndReopenOrdering",
        "OpenCodeUITests/ConversationMCPTests/testNoPillForEmptyOrUnsupportedLocations",
        "OpenCodeUITests/ConversationMCPTests/testNewSessionUsesTheSameStableOrdering"]
    if args.live:
        tests.append("OpenCodeUITests/ConversationMCPTests/testLiveOnlySafariDisconnectAndReconnect")
    result = evidence / (token + ".xcresult")
    with (evidence / (token + ".log")).open("w") as log:
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "240",
            "-resultBundlePath", str(result)] + ["-only-testing:" + test for test in tests], stdout=log, stderr=subprocess.STDOUT)
    report.update(status=status, result=str(result))
    attachments = evidence / (token + "-attachments")
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(attachments)], check=True, stdout=subprocess.DEVNULL)
    for test in json.loads((attachments / "manifest.json").read_text()):
        for item in test["attachments"]:
            source = attachments / item["exportedFileName"]
            if source.suffix == ".png" and not item["isAssociatedWithFailure"]:
                shutil.copyfile(source, evidence / (item["suggestedHumanReadableName"].split("_0_")[0] + ".png"))
    (evidence / (token + "-summary.json")).write_bytes(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)]))
    print(token, "status", status)
    raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    if query and before and next(s for s in before if s["name"] == "safari-devtools")["status"]["status"] == "connected":
        after = api("/api/mcp?" + query)["data"]
        safari = next(s for s in after if s["name"] == "safari-devtools")
        if safari["status"]["status"] == "disabled":
            api("/api/experimental/mcp/safari-devtools/connect?" + query, method="POST")
            after = api("/api/mcp?" + query)["data"]
        report["after"] = after
        assert next(s for s in after if s["name"] == "safari-devtools")["status"]["status"] == "connected"
        assert {s["name"]: s["status"] for s in before if s["name"] != "safari-devtools"} == {s["name"]: s["status"] for s in after if s["name"] != "safari-devtools"}
    for session in owned:
        try:
            api("/api/session/" + session, method="DELETE")
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
    for folder in folders:
        if folder.exists():
            folder.rmdir()
    report["deleted"] = list(owned)
    (evidence / (token + "-verification.json")).write_text(json.dumps(report, indent=2))
    subprocess.run(["xcrun", "simctl", "terminate", device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

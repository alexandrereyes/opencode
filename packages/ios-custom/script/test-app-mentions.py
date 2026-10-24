#!/usr/bin/env python3
"""Composer app mentions against an isolated sandbox: one disposable Session whose Location gets
codex-computer-use connected (only list_apps runs), restored and deleted afterwards. Nothing is sent."""
import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
url = os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4177")
assert urllib.parse.urlparse(url).port not in (None, 4096, 4178), "use an isolated sandbox"
home = Path(os.environ.get("OPENCODE_TEST_HOME", temporary / "custom-sandbox-4177"))
derived = Path(os.environ.get("OPENCODE_TEST_DERIVED", temporary / "ios-mentions-derived"))
device = os.environ["OPENCODE_TEST_SIMULATOR"]
evidence = Path(os.environ.get("OPENCODE_TEST_EVIDENCE", temporary / "ios-mentions-prints"))
evidence.mkdir(parents=True, exist_ok=True)
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
label = os.environ.get("OPENCODE_TEST_LABEL", theme)
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
           "Content-Type": "application/json"}


def api(path, body=None, method="GET"):
    request = urllib.request.Request(url + path, data=json.dumps(body).encode() if body is not None else None,
                                     headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
        return json.loads(data) if data else None


directory = home / "repos" / "app-mentions"
directory.mkdir(parents=True, exist_ok=True)
query = urllib.parse.urlencode({"location[directory]": str(directory)})
status = lambda: {s["name"]: s["status"]["status"] for s in api("/api/mcp?" + query)["data"]}
before = status()
assert "codex-computer-use" in before, "the sandbox has no codex-computer-use MCP"
session = "ses_" + uuid.uuid4().hex
now = int(time.time() * 1000)
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
api("/api/experimental/session/import", {
    "info": {"id": session, "title": "Menções de apps", "projectID": "global", "location": {"directory": str(directory)},
             "agent": "build", "model": model, "outcome": "succeeded", "cost": 0,
             "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
             "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
    "location": {"directory": str(directory)},
    "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Mencione um app.", "time": {"created": now - 1000}}]},
    "POST")
report = {"theme": theme, "session": session, "directory": str(directory), "before": before}
configured = derived / ("Build/Products/Mentions-" + uuid.uuid4().hex + ".xctestrun")
try:
    if before["codex-computer-use"] != "connected":
        api("/api/experimental/mcp/codex-computer-use/connect?" + query, method="POST")
    report["connected"] = status()
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
               if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update({
            "OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme,
            "OPENCODE_TEST_SERVER_URL": url, "OPENCODE_APPS_SESSION": session})
        target["CommandLineArguments"] = ["-OpenCodeServerURL", url]
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    video = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo", "--codec=h264",
                              str(evidence / (label + ".mp4"))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", "id=" + device,
               "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
               "-resultBundlePath", str(evidence / (label + "-" + uuid.uuid4().hex[:8] + ".xcresult"))]
    command += ["-only-testing:" + t for t in (sys.argv[1:] or ["OpenCodeUITests/ComposerAppMentionsUITests"])]
    with (evidence / (label + ".log")).open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    video.send_signal(2)
    video.wait(timeout=30)
    report["result"] = result.returncode
    print("Result:", result.returncode, "Log:", evidence / (label + ".log"))
finally:
    configured.unlink(missing_ok=True)
    if before["codex-computer-use"] != "connected":
        api("/api/experimental/mcp/codex-computer-use/disconnect?" + query, method="POST")
    api("/api/session/" + session, method="DELETE")
    report["after"] = status()
    (evidence / (label + "-ledger.json")).write_text(json.dumps(report, indent=2))
sys.exit(report.get("result", 1))

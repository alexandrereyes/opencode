#!/usr/bin/env python3
"""The composer dictation outside its composer against an isolated sandbox: seeds two disposable conversations (no
model call), runs BackgroundDictationUITests with the fake microphone, engine and reviewer, checks that neither
conversation sent a message, and removes them.

  OPENCODE_TEST_SERVER_URL=http://127.0.0.1:4355 OPENCODE_TEST_HOME=… OPENCODE_TEST_DERIVED=… OPENCODE_TEST_SIMULATOR=… \
    OPENCODE_TEST_EVIDENCE=… python3 packages/ios-custom/script/test-background-dictation.py
"""
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
url = os.environ["OPENCODE_TEST_SERVER_URL"]
address = urllib.parse.urlparse(url)
assert address.hostname in ("127.0.0.1", "localhost") and address.port not in (None, 4096, 4177, 4178, 4179), \
    "use an isolated loopback sandbox"
home = Path(os.environ["OPENCODE_TEST_HOME"])
derived = Path(os.environ["OPENCODE_TEST_DERIVED"])
device = os.environ["OPENCODE_TEST_SIMULATOR"]
evidence = Path(os.environ.get("OPENCODE_TEST_EVIDENCE", temporary / "ios-background-dictation"))
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


directory = home / "repos" / "background-dictation"
directory.mkdir(parents=True, exist_ok=True)
if not (directory / ".git").exists():
    subprocess.run(["git", "init", "-q", str(directory)], check=True)
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
created = []


def session(title):
    now = int(time.time() * 1000)
    id = "ses_" + uuid.uuid4().hex
    api("/api/experimental/session/import", {
        "info": {"id": id, "title": title, "projectID": "global", "location": {"directory": str(directory)},
                 "agent": "build", "model": model, "outcome": "succeeded", "cost": 0,
                 "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                 "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": str(directory)},
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Início de " + title,
                      "time": {"created": now - 1000}}]}, "POST")
    created.append(id)
    return id


report = {"theme": theme}
configured = derived / ("Background-" + uuid.uuid4().hex + ".xctestrun")
status = 1
try:
    owner = session("Ditado de origem")
    other = session("Outra conversa")
    report.update({"owner": owner, "other": other})
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
               if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update({
            "OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme,
            "OPENCODE_TEST_SERVER_URL": url, "OPENCODE_BGD_OWNER": owner, "OPENCODE_BGD_OWNER_TITLE": "Ditado de origem",
            "OPENCODE_BGD_OTHER_TITLE": "Outra conversa"})
        target["CommandLineArguments"] = ["-OpenCodeServerURL", url]
    configured = derived / "Build/Products" / configured.name
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    with (evidence / (label + ".log")).open("w") as log:
        status = subprocess.run(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "id=" + device, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "300",
            "-resultBundlePath", str(evidence / (label + "-" + uuid.uuid4().hex[:8] + ".xcresult")),
            "-only-testing:OpenCodeUITests/BackgroundDictationUITests"], stdout=log, stderr=subprocess.STDOUT).returncode
    # The dictation fills a draft; nothing may have been sent from either conversation.
    for id in (owner, other):
        users = [m for m in api("/api/session/" + id + "/message?limit=20&order=desc")["data"] if m["type"] == "user"]
        report[id] = len(users)
        if len(users) != 1:
            status = 1
            print("A message was sent from", id)
    report["result"] = status
    print("Result:", status, "Log:", evidence / (label + ".log"))
finally:
    configured.unlink(missing_ok=True)
    for id in created:
        api("/api/session/" + id, method="DELETE")
    (evidence / (label + "-ledger.json")).write_text(json.dumps(report, indent=2))
sys.exit(status)

#!/usr/bin/env python3
"""Run sandbox-only XCUITests. Credentials stay in the generated, private xctestrun file."""
import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import urllib.request
import uuid

temporary = Path(os.environ.get("TMPDIR", "/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T")).resolve() / "opencode"
home = temporary / "custom-sandbox-4177"
derived = temporary / "ios-sessoes-derived"
password = (home / "password").read_text().strip()
manifest = json.loads((home / "seed-conversation.json").read_text())
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
           "Content-Type": "application/json"}

def api(path, body=None, method="POST"):
    request = urllib.request.Request("http://127.0.0.1:4177" + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        response.read()

own = "ses_" + uuid.uuid4().hex
hardware = "ses_" + uuid.uuid4().hex
created = []
now = int(time.time() * 1000)
try:
    for session in [own, hardware]:
        api("/api/experimental/session/import", {
            "info": {"id": session, "title": "Onda 6 — teclado", "projectID": "global",
                "location": {"directory": manifest["directory"]}, "agent": "build",
                "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
            "location": {"directory": manifest["directory"]}, "messages": []})
        created.append(session)
    source = next(derived.glob("Build/Products/OpenCode_*.xctestrun"))
    run = plistlib.loads(source.read_bytes())
    environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_TEST_OWN": own,
                   "OPENCODE_TEST_HARDWARE": hardware,
                   "OPENCODE_TEST_THEME": os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")}
    for key, role in [("A", "working"), ("B", "permission"), ("C", "history")]:
        environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
    targets = [target for configuration in run.get("TestConfigurations", [])
               for target in configuration["TestTargets"]] if "TestConfigurations" in run else [run["OpenCodeUITests"]]
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
    configured = derived / "Build/Products/ReadingContinuity.xctestrun"
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured),
        "-destination", "platform=iOS Simulator,name=OpenCode Sessoes", "-parallel-testing-enabled", "NO",
        "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
        "-maximum-test-execution-time-allowance", "180",
        "-resultBundlePath", str(temporary / ("onda6-" + str(now) + ".xcresult"))]
    for method in sys.argv[1:]:
        command += ["-only-testing:OpenCodeUITests/ReadingContinuityTests/" + method]
    sys.exit(subprocess.call(command))
finally:
    if "configured" in locals():
        configured.unlink(missing_ok=True)
    for session in created:
        api("/api/session/" + session + "/interrupt", {})
        api("/api/session/" + session, method="DELETE")

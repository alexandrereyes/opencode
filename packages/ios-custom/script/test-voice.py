#!/usr/bin/env python3
"""Owned sandbox history and fake voice only. Never calls GPT Live or a model."""
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
import urllib.error
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
home = temporary / "custom-sandbox-4177"
derived = Path(os.environ.get("OPENCODE_VOICE_DERIVED", temporary / "ios-voz-derived"))
evidence = Path(os.environ.get("OPENCODE_VOICE_EVIDENCE", temporary / "ios-voz-prints"))
device = os.environ.get("OPENCODE_VOICE_DEVICE", "04E24A66-5B1F-4231-BC0B-07AEE991CD10")
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}

def api(path, body=None, method="POST"):
    request = urllib.request.Request("http://127.0.0.1:4177" + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        # This runner sends only its own synthetic fixture; never log request headers.
        print(error.read().decode()[:4000], file=sys.stderr)
        raise

manifest = json.loads((home / "seed-conversation.json").read_text())
root = Path(manifest["directory"]).resolve()
assert root.is_relative_to((home / "repos").resolve())
session = "ses_" + uuid.uuid4().hex
created = False
configured = derived / ("Build/Products/Voice-" + uuid.uuid4().hex + ".xctestrun")
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
now = int(time.time() * 1000)
try:
    api("/api/experimental/session/import", {"info": {"id": session, "title": "Voz · demonstração isolada",
        "projectID": "global", "location": {"directory": str(root)}, "agent": "build",
        "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
        "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": str(root)}, "messages": [
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Demonstração sem inferência.", "time": {"created": now - 1000}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build",
             "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
             "time": {"created": now - 900, "completed": now - 500},
             "finish": "stop", "content": [{"type": "text", "text": "A barra de voz continua disponível durante a navegação."}]}]})
    created = True
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([target for config in run["TestConfigurations"] for target in config["TestTargets"]]
        if "TestConfigurations" in run else [value for key, value in run.items() if key != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update({"OPENCODE_TEST_PASSWORD": password,
            "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme, "OPENCODE_VOICE_SESSION": session})
        for fixture in manifest["sessions"]:
            role = "CHILD" if fixture["role"] == "child-1" else fixture["role"].upper()
            target["EnvironmentVariables"]["OPENCODE_TEST_" + role] = fixture["id"]
        target["CommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", theme]
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    result = evidence / ("voice-" + theme + "-" + uuid.uuid4().hex[:8] + ".xcresult")
    command = ["xcodebuild", "-quiet", "test-without-building", "-xctestrun", str(configured),
        "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
        "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)]
    for test in sys.argv[1:] or ["OpenCodeUITests/VoiceUITests", "OpenCodeTests/VoiceControllerTests"]:
        command.append("-only-testing:" + test)
    status = subprocess.call(command)
    attachments = evidence / (result.stem + "-attachments")
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(attachments)], check=True)
    for test in json.loads((attachments / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = attachments / attachment["exportedFileName"]
            if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                shutil.copyfile(source, evidence / (theme + "-" + attachment["suggestedHumanReadableName"].split("_0_")[0] + ".png"))
    print(json.dumps({"status": status, "result": str(result), "modelCalls": 0}))
    sys.exit(status)
finally:
    configured.unlink(missing_ok=True)
    if created:
        api("/api/session/" + session, method="DELETE")
    (evidence / ("cleanup-" + theme + ".json")).write_text(json.dumps({"session": session, "deleted": created}))

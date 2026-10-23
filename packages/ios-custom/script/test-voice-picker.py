#!/usr/bin/env python3
"""Voice/settings-only checks on the dedicated simulator; no sandbox lifecycle operations."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
derived = temporary / "ios-vozescolha-derived"
evidence = temporary / "ios-vozescolha-prints"
evidence.mkdir(parents=True, exist_ok=True)
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
device = next(d["udid"] for group in devices["devices"].values() for d in group if d["name"] == "OpenCode Voz Escolha")
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
password = (temporary / "custom-sandbox-4177/password").read_text().strip()
run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run
    else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
for target in targets:
    target.setdefault("EnvironmentVariables", {}).update({"OPENCODE_TEST_PASSWORD": password,
        "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme,
        "OPENCODE_TEST_SERVER_URL": "http://127.0.0.1:4177",
        "OPENCODE_TEST_LIVE_VOICE_CATALOG": os.environ.get("OPENCODE_TEST_LIVE_VOICE_CATALOG", "0")})
    target["CommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", theme]
token = uuid.uuid4().hex[:8]
configured = derived / ("Build/Products/VoicePicker-" + token + ".xctestrun")
result = evidence / (theme + "-" + token + ".xcresult")
try:
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi",
        "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
        "--batteryState", "charged", "--batteryLevel", "100"], check=True)
    command = ["xcodebuild", "-quiet", "test-without-building", "-xctestrun", str(configured),
        "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
        "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)]
    for test in sys.argv[1:] or ["OpenCodeUITests/VoicePickerTests", "OpenCodeTests/VoiceControllerTests",
            "OpenCodeTests/VoiceMasterTests", "OpenCodeTests/VoiceActivityTests"]:
        command.append("-only-testing:" + test)
    status = subprocess.call(command)
    attachments = evidence / (result.stem + "-attachments")
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
        "--output-path", str(attachments)], check=True)
    for test in json.loads((attachments / "manifest.json").read_text()):
        for item in test["attachments"]:
            source = attachments / item["exportedFileName"]
            name = item["suggestedHumanReadableName"].split("_0_")[0]
            if source.suffix == ".png" and not item["isAssociatedWithFailure"]:
                shutil.copyfile(source, evidence / (theme + "-" + name + ".png"))
            if "voice-catalog-live" in name:
                destination = evidence / "voice-catalog-live.json"
                if not destination.exists() or len(json.loads(source.read_bytes())) > len(json.loads(destination.read_bytes())):
                    shutil.copyfile(source, destination)
    print(json.dumps({"status": status, "result": str(result), "theme": theme}))
    sys.exit(status)
finally:
    configured.unlink(missing_ok=True)

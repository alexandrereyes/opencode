#!/usr/bin/env python3
"""Wave 11: dedicated simulator; real quota reads, fake-client-only confirmed actions."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
# Overrides let a separate agent use its own sandbox, simulator and build.
server = os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4177")
home = Path(os.environ.get("OPENCODE_TEST_HOME", temporary / "custom-sandbox-4177"))
derived = Path(os.environ.get("OPENCODE_TEST_DERIVED", temporary / "ios-proxy-derived"))
evidence = Path(os.environ.get("OPENCODE_TEST_EVIDENCE", temporary / "ios-onda11-prints"))
device = os.environ.get("OPENCODE_TEST_DEVICE", "83335951-0D45-4D53-9884-55047D7F78CA")
password = (home / "password").read_text().strip()
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
token = uuid.uuid4().hex
configured = derived / ("Build/Products/Proxy-" + token + ".xctestrun")
result = evidence / ("proxy-" + token + ".xcresult")
run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
targets = [t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"]
for target in targets:
    target.setdefault("EnvironmentVariables", {}).update({"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme, "OPENCODE_TEST_SERVER_URL": server})
    target["CommandLineArguments"] = ["-OpenCodeServerURL", server, "-OpenCodeTheme", theme]
configured.write_bytes(plistlib.dumps(run))
configured.chmod(0o600)
evidence.mkdir(parents=True, exist_ok=True)
try:
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)]
    for test in sys.argv[1:] or ["OpenCodeUITests/SubscriptionTests", "OpenCodeTests/ComposerKeyCommandTests", "OpenCodeTests/ReadingGeometryTests", "OpenCodeTests/SessionNoticeTests"]:
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
    (evidence / ("verification-" + token + ".json")).write_text(json.dumps({"status": status, "theme": theme, "result": str(result), "proxyMutations": "fake client only; real confirmation cancelled"}, indent=2))
    sys.exit(status)
finally:
    configured.unlink(missing_ok=True)

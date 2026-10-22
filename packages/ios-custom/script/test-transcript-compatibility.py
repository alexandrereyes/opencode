#!/usr/bin/env python3
"""Compare existing sandbox histories through RPC/native reads; no seed or service mutations."""
import fcntl
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
home = temporary / "custom-sandbox-4177"
derived = temporary / "ios-sessoes-derived"
lease = (temporary / "ios-sessoes-test.lock").open("a")
fcntl.flock(lease, fcntl.LOCK_EX)
manifest = json.loads((home / "seed-conversation.json").read_text())
password = (home / "password").read_text().strip()
evidence = temporary / ("ios-native-transcript-" + uuid.uuid4().hex[:8])
evidence.mkdir(mode=0o700)
configured = derived / ("Build/Products/TranscriptCompatibility-" + evidence.name + ".xctestrun")
try:
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password}
    for key, role in [("WORKING", "working"), ("HISTORY", "history"), ("CHILD", "child-1"),
                      ("PERMISSION", "permission"), ("QUESTION", "question")]:
        environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
               if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["CommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    device = "DFC4DC6D-A116-4B17-982F-FA2033D85997"
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi",
                    "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
                    "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    result = evidence / "tests.xcresult"
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination",
               "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
               "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "300", "-resultBundlePath", str(result)]
    for test in sys.argv[1:] or ["OpenCodeUITests/TranscriptCompatibilityTests"]:
        command.append("-only-testing:" + test)
    status = subprocess.call(command)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                    "--output-path", str(evidence / "screenshots")], check=True)
    for test in json.loads((evidence / "screenshots/manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = evidence / "screenshots" / attachment["exportedFileName"]
            if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                name = attachment["suggestedHumanReadableName"].split("_0_")[0]
                shutil.copyfile(source, evidence / (name + ".png"))
    print(json.dumps({"status": status, "evidence": str(evidence)}))
    sys.exit(status)
finally:
    configured.unlink(missing_ok=True)

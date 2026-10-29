#!/usr/bin/env python3
"""Run an existing test build on one explicit device, with private sandbox launch configuration."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True)
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--label", required=True)
parser.add_argument("--physical", action="store_true")
parser.add_argument("--dictation-fixture", action="store_true", help="Use the offline fake transcription engine for the hosted launch")
parser.add_argument("--theme", default="openchamber-dark")
parser.add_argument("--server-url", default="http://127.0.0.1:4177")
parser.add_argument("--home", type=Path)
parser.add_argument("--environment", type=Path, help="Private JSON with prepared test fixture IDs")
parser.add_argument("--attempts", type=int, default=int(os.environ.get("OPENCODE_TEST_ATTEMPTS", "1")),
    help="Retry failed tests up to this many attempts (the first simulator launch can ignore its arguments)")
parser.add_argument("--location", metavar="LAT,LON", help="Simulator only: install the app, grant it location and set this position (DeviceDataTests)")
parser.add_argument("tests", nargs="+")
args = parser.parse_args()
if args.dictation_fixture and any(test.startswith("OpenCodeUITests/") and not test.startswith("OpenCodeUITests/DictationUITests") for test in args.tests):
    parser.error("--dictation-fixture is for hosted tests or DictationUITests, not another UI fixture root")
offline = {
    "OpenCodeUITests/MarkdownRenderingTests",
    "OpenCodeUITests/ScrollComparisonTests",
    "OpenCodeUITests/ComposerEditingUITests",
    "OpenCodeUITests/ConversationMenuTests",
    "OpenCodeUITests/ConversationFollowTests/testEmptyTailRestorationCompletes",
    "OpenCodeUITests/ConversationFollowTests/testHistoryJumpToLatestInBothThemes",
    "OpenCodeUITests/ConversationFollowTests/testHeightChangesFollowMonotonicallyInBothThemes",
}
if args.location and args.physical:
    parser.error("--location sets a simulator's position")
if args.physical and (args.device != "00008110-00065DA13A78401E" or any(test not in offline for test in args.tests)):
    parser.error("The physical worker is restricted to the iPhone 14 and server-free fixtures")
if not args.physical:
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    if not any(device["udid"] == args.device for group in devices["devices"].values() for device in group):
        parser.error("Use an available simulator UUID, or --physical for the offline iPhone worker")

args.evidence.mkdir(parents=True, exist_ok=True)
lease = (args.evidence.parent / ("ios-test-" + args.device + ".lock")).open("a")
fcntl.flock(lease, fcntl.LOCK_EX)
device_lease = Path.home() / ".agents/skills/aparelhos-fisicos/scripts/device-lease"
prefix = [str(device_lease), "exec", "iphone14", "--"] if args.physical else []
token = args.label + "-" + uuid.uuid4().hex[:8]
configured = args.derived / ("Build/Products/Isolated-" + token + ".xctestrun")
result = args.evidence / (token + ".xcresult")
started = time.time()
if args.physical:
    subprocess.run([str(device_lease), "acquire", "iphone14", "--owner", "ios-custom: offline fixtures", "--pid", str(os.getpid())], check=True)
try:
    password = "offline-fixtures-only" if args.physical else ((args.home or Path(
        "/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/custom-sandbox-4177")) / "password").read_text().strip()
    run = plistlib.loads(next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([target for config in run["TestConfigurations"] for target in config["TestTargets"]]
        if "TestConfigurations" in run else [value for key, value in run.items() if key != "__xctestrun_metadata__"])
    for target in targets:
        if args.environment:
            target.setdefault("EnvironmentVariables", {}).update(json.loads(args.environment.read_text()))
        target.setdefault("EnvironmentVariables", {}).update(OPENCODE_TEST_PASSWORD=password,
            OPENCODE_SERVER_PASSWORD=password, OPENCODE_TEST_THEME=args.theme, OPENCODE_TEST_SERVER_URL=args.server_url)
        # Tests choose their own theme (OPENCODE_TEST_THEME); app arguments appended here would override it.
        arguments = ["-OpenCodeServerURL", args.server_url]
        if args.physical:
            arguments += ["-OpenCodeScrollFixture", "conversation"]
        if args.dictation_fixture:
            arguments += ["-OpenCodeDictationFixture", "fake"]
        target["CommandLineArguments"] = arguments + ["-OpenCodeTheme", args.theme]
        target["UITargetAppCommandLineArguments"] = arguments
        target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    if args.location:
        # Granted before the run (a fresh simulator would otherwise ask), with the position set right before it: one
        # set long before may yield no fix within the app's 3-second limit.
        subprocess.run(["xcrun", "simctl", "install", args.device,
            str(args.derived / "Build/Products/Debug-iphonesimulator/OpenCode.app")], check=True)
        subprocess.run(["xcrun", "simctl", "privacy", args.device, "grant", "location", "br.com.alexandrem.opencode"], check=True)
        subprocess.run(["xcrun", "simctl", "location", args.device, "set", args.location], check=True)
    with (args.evidence / (token + ".log")).open("w") as log:
        status = subprocess.call(prefix + ["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", ("platform=iOS,id=" if args.physical else "platform=iOS Simulator,id=") + args.device,
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
            "-maximum-test-execution-time-allowance", "600" if args.physical else "300", "-resultBundlePath", str(result)]
            + (["-retry-tests-on-failure", "-test-iterations", str(args.attempts)] if args.attempts > 1 else [])
            + ["-only-testing:" + test for test in args.tests], stdout=log, stderr=subprocess.STDOUT)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
        "--output-path", str(args.evidence / (token + "-attachments"))], check=True, stdout=subprocess.DEVNULL)
    (args.evidence / (token + ".json")).write_text(json.dumps({"status": status, "device": args.device,
        "tests": args.tests, "result": str(result), "start": started, "seconds": time.time() - started}, indent=2))
    raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    if args.physical:
        subprocess.run([str(device_lease), "release", "iphone14", "--pid", str(os.getpid())], check=True)

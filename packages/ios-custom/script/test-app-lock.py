#!/usr/bin/env python3
"""Exigir Face ID on a fresh simulator: AppLockTests (scripted Face ID) and AppLockRealFaceIDTests (LocalAuthentication).

After `build-for-testing` with its own DerivedData:

    python3 packages/ios-custom/script/test-app-lock.py --derived <DerivedData> [--evidence <folder>]

Creates its own iPhone simulator (headless; Simulator.app is never opened), enrolls a face, keeps matching it while
the tests run and deletes the simulator at the end. Server-free: the app runs the offline catalog.
"""
import argparse
import json
import os
import pathlib
import subprocess
import tempfile
import threading
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--derived", type=pathlib.Path, required=True)
parser.add_argument("--evidence", type=pathlib.Path,
                    default=pathlib.Path(tempfile.gettempdir()) / "opencode" / "app-lock-evidence")
parser.add_argument("tests", nargs="*", default=["OpenCodeUITests/AppLockTests", "OpenCodeUITests/AppLockRealFaceIDTests"])
args = parser.parse_args()

xctestrun = next(args.derived.glob("Build/Products/OpenCode_*.xctestrun"))
listing = json.loads(subprocess.run(["xcrun", "simctl", "list", "-j", "runtimes"], check=True,
                                    capture_output=True, text=True).stdout)
runtime = max((r for r in listing["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]),
              key=lambda r: [int(part) for part in r["version"].split(".")])["identifier"]
udid = subprocess.run(["xcrun", "simctl", "create", "OpenCode Face ID " + uuid.uuid4().hex[:8],
                       "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime],
                      check=True, capture_output=True, text=True).stdout.strip()


def notify(*arguments):
    subprocess.run(["xcrun", "simctl", "spawn", udid, "notifyutil", *arguments], check=False, capture_output=True)


stop = threading.Event()


def match():
    while not stop.wait(1.5):
        notify("-p", "com.apple.BiometricKit_Sim.pearl.match")


args.evidence.mkdir(parents=True, exist_ok=True)
result = args.evidence / ("app-lock-" + uuid.uuid4().hex[:8] + ".xcresult")
try:
    subprocess.run(["xcrun", "simctl", "boot", udid], check=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, capture_output=True)
    notify("-s", "com.apple.BiometricKit.enrollmentChanged", "1")
    notify("-p", "com.apple.BiometricKit.enrollmentChanged")
    threading.Thread(target=match, daemon=True).start()
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "-destination", "id=" + udid,
               # The face is matched on this simulator only: never on clones.
               "-parallel-testing-enabled", "NO",
               "-resultBundlePath", str(result)] + ["-only-testing:" + test for test in args.tests]
    status = subprocess.run(command, env={**os.environ, "TEST_RUNNER_OPENCODE_REAL_FACEID": "1"}).returncode
    print("Result bundle:", result)
    raise SystemExit(status)
finally:
    stop.set()
    subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False, capture_output=True)
    subprocess.run(["xcrun", "simctl", "delete", udid], check=False, capture_output=True)

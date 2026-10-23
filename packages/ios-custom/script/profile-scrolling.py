#!/usr/bin/env python3
"""Capture deterministic, server-free scroll traces/screenshots on OpenCode Fluidez."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--label", required=True)
parser.add_argument("--mode", choices=["conversation", "sessions"], default="conversation")
parser.add_argument("--template", choices=["Time Profiler", "SwiftUI", "Animation Hitches"])
parser.add_argument("--theme", default="openchamber-dark")
parser.add_argument("--updates", action="store_true")
parser.add_argument("--markdown", action="store_true", help="Profile the server-free comprehensive Markdown fixture")
parser.add_argument("--frames", action="store_true", help="Measure the display-link driver without Instruments")
parser.add_argument("--simulator", default="C960B2FA-F2AB-4E39-BF82-50050DF20A27")
parser.add_argument("--derived", type=Path)
parser.add_argument("--evidence", type=Path)
args = parser.parse_args()
run_id = uuid.uuid4().hex
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
derived = args.derived or temporary / "ios-fluidez-derived"
evidence = args.evidence or temporary / "ios-fluidez-prints"
evidence.mkdir(exist_ok=True)
device = args.simulator
bundle = "br.com.alexandrem.opencode"
root = Path(__file__).resolve().parents[1]
state = {"head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
         "fixtureSHA256": hashlib.sha256((root / "OpenCode/Fixtures/scroll-fixture.json").read_bytes()).hexdigest(),
         "binarySHA256": hashlib.sha256((derived / "Build/Products/Debug-iphonesimulator/OpenCode.app/OpenCode.debug.dylib").read_bytes()).hexdigest(),
          "mode": args.mode, "theme": args.theme, "template": args.template, "runID": run_id,
          "codeWrap": True, "tableWrap": True,
          "files": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in sorted(root.rglob("*.swift")) if not any(part.startswith(".") for part in p.relative_to(root).parts)}}
if args.markdown:
    state["markdownSHA256"] = hashlib.sha256((root / "OpenCode/Fixtures/markdown-fixture.md").read_bytes()).hexdigest()
(evidence / (args.label + "-state.json")).write_text(json.dumps(state, indent=2) + "\n")
subprocess.run(["xcrun", "simctl", "install", device, str(derived / "Build/Products/Debug-iphonesimulator/OpenCode.app")], check=True)
container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, bundle, "data"], text=True).strip())
if args.template or args.frames:
    (container / "Documents/scroll-fixture-metrics.json").unlink(missing_ok=True)
subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
arguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeScrollFixture", args.mode, "-OpenCodeFixturePosition", "middle", "-OpenCodeTheme", args.theme]
arguments += ["-OpenCodeFixtureRunID", run_id]
arguments += ["-OpenCodeMarkdownCodeWrap", "YES", "-OpenCodeMarkdownTableWrap", "YES"]
if args.markdown:
    arguments.append("-OpenCodeMarkdownFixture")
if args.updates:
    arguments.append("-OpenCodeFixtureUpdates")
if args.template or args.frames:
    arguments.append("-OpenCodeFixtureAutoScroll")
try:
    environment = os.environ | {"SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD": (temporary / "custom-sandbox-4177/password").read_text().strip()}
    launch = subprocess.check_output(["xcrun", "simctl", "launch", "--terminate-running-process", device, bundle] + arguments, text=True, env=environment)
    pid = launch.strip().split(": ")[-1]
    if args.template:
        trace = evidence / (args.label + ".trace")
        subprocess.run(["xcrun", "xctrace", "record", "--template", args.template, "--device", device,
                        "--attach", pid, "--time-limit", "20s", "--output", str(trace), "--no-prompt"], check=True)
    elif args.frames:
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, bundle, "data"], text=True).strip())
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            report = container / "Documents/scroll-fixture-metrics.json"
            if report.exists() and json.loads(report.read_text()).get("runID") == run_id:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("Fixture scroll did not complete within 40 seconds")
    else:
        # Screenshots must include the asynchronous Markdown and native reading restoration.
        time.sleep(5)
    if args.template or args.frames:
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, bundle, "data"], text=True).strip())
        report = json.loads((container / "Documents/scroll-fixture-metrics.json").read_text())
        if report["mode"] != args.mode or report.get("runID") != run_id:
            raise RuntimeError("Unexpected fixture metrics mode")
        shutil.copyfile(container / "Documents/scroll-fixture-metrics.json", evidence / (args.label + "-frames.json"))
    subprocess.run(["xcrun", "simctl", "io", device, "screenshot", str(evidence / (args.label + ".png"))], check=True)
finally:
    subprocess.run(["xcrun", "simctl", "terminate", device, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

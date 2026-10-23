#!/usr/bin/env python3
"""Capture matching, offline production-screen fixtures on the dedicated polish simulator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--label", required=True)
parser.add_argument("--live", action="store_true", help="Read the sandbox Sessões list instead of offline fixtures")
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
evidence = temporary / "ios-polimento-prints"
evidence.mkdir(exist_ok=True)
device = "4FB557F1-6CF3-4478-B33F-CBAB25F04A24"
app = temporary / "ios-polimento-derived/Build/Products/Debug-iphonesimulator/OpenCode.app"
bundle = "br.com.alexandrem.opencode"
environment = os.environ | {"SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD": (temporary / "custom-sandbox-4177/password").read_text().strip()}
subprocess.run(["xcrun", "simctl", "install", device, str(app)], check=True)
subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi",
    "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
    "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
captures = []
try:
    for theme, size in [("openchamber-dark", "large"), ("openchamber-light", "large"),
                        ("dracula-dark", "large"), ("github-light", "large"),
                        ("openchamber-dark", "accessibility-large")]:
        subprocess.run(["xcrun", "simctl", "ui", device, "content_size", size], check=True)
        for mode in (["sessions"] if args.live else ["sessions", "conversation"]):
            arguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", theme]
            if not args.live:
                arguments += ["-OpenCodeScrollFixture", mode, "-OpenCodeFixturePosition", "top"]
            if mode == "conversation" and not args.live:
                arguments.append("-OpenCodeMarkdownFixture")
            subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", device, bundle] + arguments,
                env=environment, check=True, stdout=subprocess.DEVNULL)
            time.sleep(6)
            path = evidence / f"{args.label}-{mode}-{theme}-{size}.png"
            subprocess.run(["xcrun", "simctl", "io", device, "screenshot", str(path)], check=True)
            captures.append(str(path))
            subprocess.run(["xcrun", "simctl", "terminate", device, bundle], check=True)
finally:
    subprocess.run(["xcrun", "simctl", "ui", device, "content_size", "large"], check=True)
    subprocess.run(["xcrun", "simctl", "terminate", device, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
(evidence / f"{args.label}-captures.json").write_text(json.dumps({
    "binarySHA256": hashlib.sha256((app / "OpenCode.debug.dylib").read_bytes()).hexdigest(), "captures": captures,
}, indent=2) + "\n")

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
parser.add_argument("--simulator", default="4FB557F1-6CF3-4478-B33F-CBAB25F04A24")
parser.add_argument("--derived", type=Path)
parser.add_argument("--evidence", type=Path)
parser.add_argument("--home", type=Path)
parser.add_argument("--server-url", default="http://127.0.0.1:4177")
parser.add_argument("--sizes", nargs="+", default=["large", "extra-extra-extra-large", "accessibility-large"])
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
evidence = args.evidence or temporary / "ios-polimento-prints"
evidence.mkdir(exist_ok=True)
device = args.simulator
app = (args.derived or temporary / "ios-polimento-derived") / "Build/Products/Debug-iphonesimulator/OpenCode.app"
bundle = "br.com.alexandrem.opencode"
environment = os.environ | {"SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD": ((args.home or temporary / "custom-sandbox-4177") / "password").read_text().strip()}
subprocess.run(["xcrun", "simctl", "install", device, str(app)], check=True)
subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi",
    "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
    "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
captures = []
try:
    for theme, size in [(theme, size) for theme in ["openchamber-dark", "openchamber-light"] for size in args.sizes]:
        subprocess.run(["xcrun", "simctl", "ui", device, "content_size", size], check=True)
        for mode in (["sessions"] if args.live else ["sessions", "conversation"]):
            arguments = ["-OpenCodeServerURL", args.server_url, "-OpenCodeTheme", theme,
                "-OpenCodeCollapsibleUserMessages", "YES"]
            if not args.live:
                arguments += ["-OpenCodeScrollFixture", mode, "-OpenCodeFixturePosition", "top"]
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

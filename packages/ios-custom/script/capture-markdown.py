#!/usr/bin/env python3
"""Capture the real native reader after DEBUG geometry settles; no server requests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--simulator", default="7C70FB07-A886-43BD-8A39-42D92E0C9937")
parser.add_argument("--themes", nargs="+", default=["dark", "light"])
parser.add_argument("--sections", type=int, nargs="+", default=list(range(17)))
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
root = Path(__file__).resolve().parents[1]
app = temporary / "ios-formatacao-derived/Build/Products/Debug-iphonesimulator/OpenCode.app"
evidence = temporary / "ios-formatacao-prints"
bundle = "br.com.alexandrem.opencode"
environment = os.environ | {"SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD": (temporary / "custom-sandbox-4177/password").read_text().strip()}
source = (root / "OpenCode/Fixtures/markdown-fixture.md").read_bytes()
assert hashlib.sha256(next(app.rglob("markdown-fixture.md")).read_bytes()).digest() == hashlib.sha256(source).digest()
subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True)
container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator, bundle, "data"], text=True).strip())
(container / "Documents").mkdir(exist_ok=True)
ready = container / "Documents/markdown-capture-ready.json"
manifest_path = evidence / "native-capture-verification.json"
manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {"captures": []}
binary = hashlib.sha256((app / "OpenCode.debug.dylib").read_bytes()).hexdigest()
if manifest.get("binarySHA256") != binary:
    manifest["captures"] = []
manifest["markdownSHA256"] = hashlib.sha256(source).hexdigest()
manifest["binarySHA256"] = binary
subprocess.run(["xcrun", "simctl", "status_bar", args.simulator, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
try:
    for theme in args.themes:
        assert theme in ["dark", "light"]
        for section in args.sections:
            assert 0 <= section <= 16
            run = uuid.uuid4().hex
            ready.unlink(missing_ok=True)
            arguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", "openchamber-" + theme,
                "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "top", "-OpenCodeMarkdownFixture",
                "-OpenCodeMarkdownExpandDetails", "-OpenCodeMarkdownSection", str(section), "-OpenCodeFixtureRunID", run,
                "-OpenCodeMarkdownCodeWrap", "YES", "-OpenCodeMarkdownTableWrap", "YES"]
            subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", args.simulator, bundle] + arguments,
                env=environment, check=True, stdout=subprocess.DEVNULL)
            deadline = time.monotonic() + 75
            while time.monotonic() < deadline:
                if ready.exists():
                    report = json.loads(ready.read_text())
                    if report["runID"] == run:
                        if report.get("error"):
                            subprocess.run(["xcrun", "simctl", "io", args.simulator, "screenshot", str(evidence / f"capture-error-{theme}-{section}.png")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        assert not report.get("error"), report
                        break
                time.sleep(0.1)
            else:
                raise RuntimeError("Native Markdown capture did not stabilize")
            time.sleep(0.7)
            if section == 13:
                # Cold simulator WebKit/GPU/Networking process launches measured 7–9s each.
                # This is screenshot warmup only; frame benchmarks do not use this driver.
                time.sleep(20)
            filename = f"native-openchamber-{theme}-section-{section:02}.png"
            subprocess.run(["xcrun", "simctl", "io", args.simulator, "screenshot", str(evidence / filename)], check=True,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            manifest["captures"] = [item for item in manifest["captures"] if (item["theme"], item["section"]) != (theme, section)]
            manifest["captures"].append({"theme": theme, "section": section, "file": filename, "geometry": report})
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
            print(theme, section, "headingTop", report.get("headingTop"), flush=True)
finally:
    subprocess.run(["xcrun", "simctl", "terminate", args.simulator, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

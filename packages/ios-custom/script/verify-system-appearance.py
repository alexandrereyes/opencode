#!/usr/bin/env python3
"""Verify live Sistema following with real simulator appearance changes, never a theme override."""
import fcntl
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import time

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
lease = (temporary / "ios-sessoes-test.lock").open("a")
fcntl.flock(lease, fcntl.LOCK_EX)
evidence = temporary / "ios-onda8-prints"
evidence.mkdir(parents=True, exist_ok=True)
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
device = next(d["udid"] for group in devices["devices"].values() for d in group if d["name"] == "OpenCode Sessoes")
container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, "br.com.alexandrem.opencode", "data"], text=True).strip())
preferences = plistlib.loads((container / "Library/Preferences/br.com.alexandrem.opencode.plist").read_bytes())
assert preferences.get("OpenCodeThemeFamily") == "openchamber" and preferences.get("OpenCodeAppearance") == "system", "Run the live-theme UI test first; it leaves OpenChamber/Sistema selected."
previous = subprocess.check_output(["xcrun", "simctl", "ui", device, "appearance"], text=True).strip().split()[-1]
environment = {**os.environ, "SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD": (temporary / "custom-sandbox-4177/password").read_text().strip()}
report = []

def terminate():
    subprocess.run(["xcrun", "simctl", "terminate", device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def sample(png):
    bmp = evidence / "system-sample.bmp"
    subprocess.run(["sips", "-s", "format", "bmp", str(png), "--out", str(bmp)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    data = bmp.read_bytes()
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bits = struct.unpack_from("<H", data, 28)[0]
    assert bits in (24, 32)
    stride = ((width * bits + 31) // 32) * 4
    pixel = offset + (abs(height) // 2) * stride + 2 * (bits // 8)
    blue, green, red = data[pixel:pixel + 3]
    bmp.unlink()
    return (red, green, blue)

try:
    terminate()
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    subprocess.run(["xcrun", "simctl", "launch", device, "br.com.alexandrem.opencode", "-OpenCodeServerURL", "http://127.0.0.1:4177"], env=environment, check=True, stdout=subprocess.DEVNULL)
    for mode in ["light", "dark", "light"]:
        subprocess.run(["xcrun", "simctl", "ui", device, "appearance", mode], check=True)
        theme = json.loads((Path(__file__).resolve().parents[1] / ("OpenCode/Resources/Themes/openchamber-" + mode + ".json")).read_text())
        hex_color = theme["colors"]["background"].lstrip("#")
        expected = tuple(int(hex_color[i:i+2], 16) for i in (0, 2, 4))
        screenshot = evidence / ("system-live-" + mode + ".png")
        for attempt in range(30):
            subprocess.run(["xcrun", "simctl", "io", device, "screenshot", str(screenshot)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            actual = sample(screenshot)
            if max(abs(a-b) for a, b in zip(actual, expected)) <= 3:
                break
            time.sleep(0.25)
        assert max(abs(a-b) for a, b in zip(actual, expected)) <= 3, (mode, actual, expected)
        report.append({"appearance": mode, "background": actual, "expected": expected, "sameProcess": True})
    (evidence / "system-appearance-verification.json").write_text(json.dumps(report, indent=2))
    print("Sistema followed light → dark → light in one sandbox-only app process.")
finally:
    terminate()
    if previous in {"light", "dark"}:
        subprocess.run(["xcrun", "simctl", "ui", device, "appearance", previous], check=True)

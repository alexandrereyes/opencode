#!/usr/bin/env python3
"""Regenerate the offline iOS mockup references on a disposable iPhone 17 Pro."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid
import zlib


def run(*command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def compress_png(path):
    """Recompress IDAT losslessly, retaining color profiles and the native pixel filters."""
    original = path.read_bytes()
    chunks = []
    offset = 8
    while offset < len(original):
        length = int.from_bytes(original[offset:offset + 4], "big")
        chunks.append((original[offset + 4:offset + 8], original[offset + 8:offset + 8 + length]))
        offset += length + 12
    pixels = zlib.decompress(b"".join(data for kind, data in chunks if kind == b"IDAT"))
    compressed = zlib.compress(pixels, 9)
    result = bytearray(original[:8])
    written = False
    for kind, data in chunks:
        # sips retains the original screenshot's EXIF dimensions after resizing.
        if kind in (b"eXIf", b"iTXt", b"tEXt", b"zTXt", b"tIME"):
            continue
        if kind == b"IDAT":
            if written:
                continue
            data = compressed
            written = True
        result += len(data).to_bytes(4, "big") + kind + data + zlib.crc32(kind + data).to_bytes(4, "big")
    if len(result) < len(original):
        path.write_bytes(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--themes", nargs="+", choices=["dark", "light"], default=["dark", "light"])
    parser.add_argument("--derived", type=Path, help="Reuse a build-for-testing directory; it is not deleted")
    parser.add_argument("--simulator", help="Reuse an explicitly owned simulator; it is not deleted")
    parser.add_argument("--only", nargs="+", help="Only these ScreenCatalogTests methods (development)")
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[1]
    output = (args.output or package / "docs/screens").resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Honor the harness's approved temporary directory, or the user's normal macOS TMPDIR.
    base = Path(tempfile.gettempdir())
    if base.name != "opencode":
        base = base / "opencode"
    base.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="opencode-screen-catalog-", dir=base) as temporary:
        temporary = Path(temporary)
        derived = args.derived.resolve() if args.derived else temporary / "build"
        device = args.simulator or subprocess.check_output([
            "xcrun", "simctl", "create", "OpenCode Screens " + uuid.uuid4().hex[:8],
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0"], text=True).strip()
        try:
            state = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))
            booted = any(d["udid"] == device and d["state"] == "Booted"
                         for devices in state["devices"].values() for d in devices)
            if not booted:
                run("xcrun", "simctl", "boot", device)
            run("xcrun", "simctl", "bootstatus", device, "-b")
            run("xcrun", "simctl", "ui", device, "content_size", "large")
            run("xcrun", "simctl", "status_bar", device, "override", "--time", "9:41",
                "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
                "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "charged",
                "--batteryLevel", "100")
            if not args.derived:
                with (temporary / "build.log").open("w") as log:
                    run("xcodebuild", "build-for-testing", "-project", str(package / "OpenCode.xcodeproj"),
                        "-scheme", "OpenCode", "-configuration", "Debug", "-destination",
                        "platform=iOS Simulator,id=" + device, "-derivedDataPath", str(derived),
                        "CODE_SIGNING_ALLOWED=NO", stdout=log, stderr=subprocess.STDOUT)
            original = next(derived.glob("Build/Products/OpenCode_*.xctestrun"))
            captures = []
            for theme in args.themes:
                # Fresh app container: no draft, permission or preference from another theme/run.
                subprocess.run(["xcrun", "simctl", "uninstall", device, "br.com.alexandrem.opencode"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                plan = plistlib.loads(original.read_bytes())
                targets = ([t for c in plan["TestConfigurations"] for t in c["TestTargets"]]
                           if "TestConfigurations" in plan else
                           [v for k, v in plan.items() if k != "__xctestrun_metadata__"])
                for target in targets:
                    target.setdefault("EnvironmentVariables", {})["OPENCODE_CATALOG_THEME"] = theme
                configured = derived / "Build/Products" / ("Catalog-" + theme + ".xctestrun")
                configured.write_bytes(plistlib.dumps(plan))
                result = temporary / (theme + ".xcresult")
                command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured),
                           "-destination", "platform=iOS Simulator,id=" + device,
                           "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                           "-resultBundlePath", str(result)]
                selected = args.only or (["testTabs", "testUnreadChips", "testConversation", "testNewSession", "testZComposer", "testShortPrompt"]
                                         if theme == "light" else [""])
                command += ["-only-testing:OpenCodeUITests/ScreenCatalogTests" + ("/" + t if t else "")
                            for t in selected]
                try:
                    with (temporary / (theme + ".log")).open("w") as log:
                        status = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
                    exported = temporary / (theme + "-attachments")
                    run("xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                        "--output-path", str(exported))
                    for test in json.loads((exported / "manifest.json").read_text()):
                        for attachment in test["attachments"]:
                            name = attachment["suggestedHumanReadableName"].split("_0_")[0]
                            source = exported / attachment["exportedFileName"]
                            if (attachment["isAssociatedWithFailure"] or source.suffix != ".png"
                                    or not re.fullmatch(r"[a-z][a-z0-9-]+-" + theme, name)):
                                continue
                            destination = output / (name + ".png")
                            shutil.copyfile(source, destination)
                            # Native 3x -> 2x: retain readable text while avoiding multi-MB references.
                            run("sips", "-Z", "1748", str(destination), stdout=subprocess.DEVNULL)
                            compress_png(destination)
                            captures.append(destination.name)
                    if status:
                        content = (temporary / (theme + ".log")).read_text()
                        print("\n".join(line for line in content.splitlines()
                                        if "error:" in line or "failed (" in line) or content[-16000:])
                        raise RuntimeError(f"Catalog UI capture failed for {theme} (exit {status})")
                finally:
                    configured.unlink(missing_ok=True)
            print(json.dumps({"captures": sorted(captures), "bytes": sum((output / f).stat().st_size for f in captures)}, indent=2))
        finally:
            if not args.simulator:
                subprocess.run(["xcrun", "simctl", "shutdown", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                run("xcrun", "simctl", "delete", device)


if __name__ == "__main__":
    main()

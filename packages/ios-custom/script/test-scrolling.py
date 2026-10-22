#!/usr/bin/env python3
"""Server-free XCTest scroll metrics on the dedicated OpenCode Fluidez simulator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--label", default="current")
parser.add_argument("--device", choices=["simulator", "iphone14"], default="simulator")
parser.add_argument("--sandbox", action="store_true", help="Run existing simulator regressions with explicit sandbox credentials")
parser.add_argument("tests", nargs="*", default=["OpenCodeUITests/ScrollingPerformanceTests"])
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
derived = temporary / "ios-fluidez-derived"
evidence = temporary / "ios-fluidez-prints"
evidence.mkdir(exist_ok=True)
physical = args.device == "iphone14"
if physical and args.sandbox:
    parser.error("Physical-device verification is fixture-only")
if physical and any(not test.startswith("OpenCodeUITests/ScrollingPerformanceTests") for test in args.tests):
    parser.error("iPhone 14 runs only the offline scrolling fixture tests")
device = "00008110-00065DA13A78401E" if physical else "C960B2FA-F2AB-4E39-BF82-50050DF20A27"
lease = [str(Path.home() / ".agents/skills/aparelhos-fisicos/scripts/device-lease"), "exec", "iphone14", "--"] if physical else []
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
root = Path(__file__).resolve().parents[1]
state = {"head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
         "fixtureSHA256": hashlib.sha256((root / "OpenCode/Fixtures/scroll-fixture.json").read_bytes()).hexdigest(),
         "binarySHA256": hashlib.sha256((derived / ("Build/Products/Debug-" + ("iphoneos" if physical else "iphonesimulator") + "/OpenCode.app/OpenCode.debug.dylib")).read_bytes()).hexdigest(),
         "theme": theme, "files": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in sorted(root.rglob("*.swift")) if not any(part.startswith(".") for part in p.relative_to(root).parts)}}
(evidence / (args.label + "-state.json")).write_text(json.dumps(state, indent=2) + "\n")
run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_" + ("iphoneos" if physical else "iphonesimulator") + "*.xctestrun")).read_bytes())
targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
           if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
for target in targets:
    target.setdefault("EnvironmentVariables", {})["OPENCODE_TEST_THEME"] = theme
    target["CommandLineArguments"] = ["-OpenCodeScrollFixture", "sessions"]
    if args.sandbox:
        home = temporary / "custom-sandbox-4177"
        manifest = json.loads((home / "seed-conversation.json").read_text())
        environment = target["EnvironmentVariables"]
        environment["OPENCODE_TEST_PASSWORD"] = (home / "password").read_text().strip()
        environment["OPENCODE_SERVER_PASSWORD"] = environment["OPENCODE_TEST_PASSWORD"]
        for key, role in [("A", "working"), ("C", "history"), ("CHILD", "child-1")]:
            environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
        target["CommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
configured = derived / ("Build/Products/Scroll-" + args.label + ".xctestrun")
configured.write_bytes(plistlib.dumps(run))
configured.chmod(0o600)
result = evidence / (args.label + ".xcresult")
try:
    command = lease + ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination",
               "platform=" + ("iOS" if physical else "iOS Simulator") + ",id=" + device, "-parallel-testing-enabled", "NO",
               "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)]
    status = subprocess.call(command + ["-only-testing:" + test for test in args.tests])
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                    "--output-path", str(evidence / (args.label + "-attachments"))], check=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "metrics", "--path", str(result),
                    "--output-path", str(evidence / (args.label + "-metrics"))], check=True)
    raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    if not physical:
        subprocess.run(["xcrun", "simctl", "terminate", device, "br.com.alexandrem.opencode"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

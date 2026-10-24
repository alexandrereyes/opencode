#!/usr/bin/env python3
"""Offline iPhone 14 measurements. Acquire its device lease before running."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import time
import uuid
import urllib.parse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--label", required=True)
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument("--frames-only", action="store_true")
parser.add_argument("--growth-trace-only", action="store_true", help="Capture the entire growth signpost with an 8-second launch lead-in")
parser.add_argument("--no-trace", action="store_true", help="Collect frame reports without attaching Instruments")
parser.add_argument("--trace-all-processes", action="store_true", help="Avoid CoreDevice's stale single-process discovery; filter exported hitches by app PID")
parser.add_argument("--derived", type=Path)
parser.add_argument("--evidence", type=Path)
parser.add_argument("--server-url", default="http://127.0.0.1:4177")
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
url = urllib.parse.urlparse(args.server_url)
if url.scheme != "http" or url.hostname not in ["127.0.0.1", "localhost"] or url.port in [None, 4096, 4178]:
    parser.error("Physical verification requires an explicit isolated loopback URL")
products = (args.derived or temporary / "ios-fluidez-derived") / "Build/Products"
evidence = args.evidence or temporary / "ios-fluidez-review"
evidence.mkdir(exist_ok=True)
device = "00008110-00065DA13A78401E"
lease = [str(Path.home() / ".agents/skills/aparelhos-fisicos/scripts/device-lease"), "exec", "iphone14", "--"]
bundle = "br.com.alexandrem.opencode"
binary = products / "Debug-iphoneos/OpenCode.app"
(evidence / (args.label + "-state.json")).write_text(json.dumps({
    "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.source, text=True).strip(),
    "binarySHA256": hashlib.sha256((binary / "OpenCode.debug.dylib").read_bytes()).hexdigest(),
    "files": {str(p.relative_to(args.source)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(args.source.rglob("*.swift")) if not any(s.startswith(".") for s in p.relative_to(args.source).parts)},
}, indent=2) + "\n")

if not args.frames_only and not args.growth_trace_only:
    run = plistlib.loads(next(products.glob("OpenCode_iphoneos*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
               if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for target in targets:
        target["CommandLineArguments"] = ["-OpenCodeServerURL", args.server_url, "-OpenCodeScrollFixture", "sessions"]
        target.setdefault("EnvironmentVariables", {}).update(OPENCODE_TEST_SERVER_URL=args.server_url,
            OPENCODE_TEST_PASSWORD="offline-fixtures-only", OPENCODE_SERVER_PASSWORD="offline-fixtures-only")
    configured = products / ("Comparison-" + args.label + ".xctestrun")
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    result = evidence / (args.label + ".xcresult")
    try:
        with (evidence / (args.label + "-test.log")).open("w") as output:
            status = subprocess.call(lease + ["xcodebuild", "test-without-building", "-xctestrun", str(configured),
                "-destination", "platform=iOS,id=" + device + ",arch=arm64", "-parallel-testing-enabled", "NO",
                "-collect-test-diagnostics", "never", "-resultBundlePath", str(result),
                "-only-testing:OpenCodeUITests/ScrollingPerformanceTests/testConversationScrolling",
                "-only-testing:OpenCodeUITests/ScrollComparisonTests/testGrowingTailPerformance"], stdout=output, stderr=subprocess.STDOUT)
        for kind in ["metrics", "attachments"]:
            subprocess.run(["xcrun", "xcresulttool", "export", kind, "--path", str(result),
                            "--output-path", str(evidence / (args.label + "-" + kind))], check=True)
        if status:
            raise SystemExit(status)
    finally:
        configured.unlink(missing_ok=True)

subprocess.run(lease + ["xcrun", "devicectl", "device", "install", "app", "--device", device, str(binary)], check=True)
for mode in (["growth"] if args.growth_trace_only else ["conversation", "growth"]):
    for iteration in range(1 if args.growth_trace_only else 3):
        label = f"{args.label}-{mode}-{iteration}"
        launch = evidence / (label + "-launch.json")
        arguments = ["-OpenCodeServerURL", args.server_url, "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "middle" if mode == "conversation" else "tail",
                     "-OpenCodeTheme", "openchamber-dark", "-OpenCodeFixtureRunID", uuid.uuid4().hex]
        arguments += (["-OpenCodeFixtureAutoScroll"] if mode == "conversation" else
                       ["-OpenCodeFixtureFollow", "-OpenCodeFixtureMeasureGrowth", "-OpenCodeFixtureAutoGrowth"])
        arguments += ["-OpenCodeCollapsibleUserMessages", "YES", "-OpenCodeMarkdownCodeWrap", "YES", "-OpenCodeMarkdownTableWrap", "YES"]
        if args.growth_trace_only:
            arguments += ["-OpenCodeFixtureGrowthDelay", "8"]
        subprocess.run(lease + ["xcrun", "devicectl", "device", "process", "launch", "--device", device,
                       "--terminate-existing", "--json-output", str(launch), bundle, "--"] + arguments, check=True)
        pid = json.loads(launch.read_text())["result"]["process"]["processIdentifier"]
        try:
            if iteration == 0 and not args.no_trace:
                subprocess.run(lease + ["xcrun", "xctrace", "record", "--template", "Animation Hitches", "--instrument", "Points of Interest", "--device", device,
                               "--time-limit", "20s", "--output", str(evidence / (label + ".trace")), "--no-prompt"]
                               + (["--all-processes"] if args.trace_all_processes else ["--attach", str(pid)]), check=True)
            else:
                time.sleep(18)
            filename = "scroll-fixture-metrics.json" if mode == "conversation" else "scroll-growth-metrics.json"
            subprocess.run(lease + ["xcrun", "devicectl", "device", "copy", "from", "--device", device,
                           "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                           "--source", "Documents/" + filename, "--destination", str(evidence / (label + "-frames.json"))], check=True)
            if mode == "conversation":
                report = json.loads((evidence / (label + "-frames.json")).read_text())
                if report["runID"] != arguments[arguments.index("-OpenCodeFixtureRunID") + 1]:
                    raise RuntimeError("Stale frame report: the launched fixture did not finish")
        finally:
            subprocess.run(lease + ["xcrun", "devicectl", "device", "process", "terminate", "--device", device, "--pid", str(pid)], check=True)

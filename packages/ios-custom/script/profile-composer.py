#!/usr/bin/env python3
"""Server-free composer typing benchmark (DEBUG `-OpenCodeFixtureAutoType`).

Simulator: pass `--simulator <udid>`. Physical iPhone 14: pass `--physical` after acquiring its
`aparelhos-fisicos` lease; every device command goes through `device-lease exec`.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--label", required=True)
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--simulator")
parser.add_argument("--physical", action="store_true")
parser.add_argument("--configuration", default="Debug")
parser.add_argument("--scenarios", default="idle,plain,mentions,suggestions,long")
parser.add_argument("--iterations", type=int, default=3)
parser.add_argument("--trace", help="xctrace template for the first iteration, e.g. 'Time Profiler'")
parser.add_argument("--no-install", action="store_true")
args = parser.parse_args()
if bool(args.simulator) == args.physical:
    parser.error("Choose exactly one of --simulator or --physical")

device = "00008110-00065DA13A78401E"
bundle = "br.com.alexandrem.opencode"
lease = [str(Path.home() / ".agents/skills/aparelhos-fisicos/scripts/device-lease"), "exec", "iphone14", "--"]
platform = "iphoneos" if args.physical else "iphonesimulator"
app = args.derived / f"Build/Products/{args.configuration}-{platform}/OpenCode.app"
args.evidence.mkdir(parents=True, exist_ok=True)


def run(command, **kwargs):
    return subprocess.run((lease if args.physical else []) + command, check=True, **kwargs)


if not args.no_install:
    run(["xcrun", "devicectl", "device", "install", "app", "--device", device, str(app)] if args.physical
        else ["xcrun", "simctl", "install", args.simulator, str(app)])

results = []
for scenario in args.scenarios.split(","):
    for iteration in range(args.iterations):
        label = f"{args.label}-{scenario}-{iteration}"
        run_id = uuid.uuid4().hex
        arguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeScrollFixture", "conversation",
                     "-OpenCodeFixturePosition", "tail", "-OpenCodeTheme", "openchamber-dark",
                     "-OpenCodeFixtureAutoType", scenario, "-OpenCodeFixtureRunID", run_id]
        if args.physical:
            launch = args.evidence / (label + "-launch.json")
            run(["xcrun", "devicectl", "device", "process", "launch", "--device", device, "--terminate-existing",
                 "--json-output", str(launch), bundle, "--"] + arguments, stdout=subprocess.DEVNULL)
            pid = json.loads(launch.read_text())["result"]["process"]["processIdentifier"]
        else:
            output = run(["xcrun", "simctl", "launch", "--terminate-running-process", args.simulator, bundle] + arguments,
                         capture_output=True, text=True).stdout
            pid = int(output.strip().split(": ")[-1])
        try:
            if iteration == 0 and args.trace:
                target = ["--device", device] if args.physical else ["--device", args.simulator]
                run(["xcrun", "xctrace", "record", "--template", args.trace, *target, "--attach", str(pid),
                     "--time-limit", "30s", "--output", str(args.evidence / (label + ".trace")), "--no-prompt"],
                    stdout=subprocess.DEVNULL)
            else:
                time.sleep(30)
            report = args.evidence / (label + ".json")
            if args.physical:
                run(["xcrun", "devicectl", "device", "copy", "from", "--device", device, "--domain-type", "appDataContainer",
                     "--domain-identifier", bundle, "--source", "Documents/composer-typing-metrics.json",
                     "--destination", str(report)], stdout=subprocess.DEVNULL)
            else:
                container = subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator, bundle, "data"],
                                                    text=True).strip()
                report.write_bytes((Path(container) / "Documents/composer-typing-metrics.json").read_bytes())
            value = json.loads(report.read_text())
            if value["runID"] != run_id:
                raise RuntimeError(f"Stale report for {label}: the driver did not finish")
            results.append(value)
            print(json.dumps({k: value[k] for k in ["scenario", "keystrokeBusyP50MS", "keystrokeBusyP95MS", "keystrokeBusyMaxMS",
                                                   "mainThreadCPU_MS", "hitches", "hitchTimeMSPerS", "frameP95MS"]}))
        finally:
            if args.physical:
                run(["xcrun", "devicectl", "device", "process", "terminate", "--device", device, "--pid", str(pid)],
                    stdout=subprocess.DEVNULL)
            else:
                subprocess.run(["xcrun", "simctl", "terminate", args.simulator, bundle])

(args.evidence / (args.label + "-summary.json")).write_text(json.dumps(results, indent=2) + "\n")

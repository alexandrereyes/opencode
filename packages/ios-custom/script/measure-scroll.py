#!/usr/bin/env python3
"""Server-free conversation scroll scenarios, alternating builds, on a simulator or the leased iPhone 14.

Each scenario launches the offline fixture with the DEBUG display-link driver and collects its 12-second
report (frame intervals, frames over 33/50/100 ms, main-thread CPU, unrequested row movement, backward
steps while following). Build Debug with SWIFT_OPTIMIZATION_LEVEL=-O for representative numbers. Physical
runs go through `device-lease exec iphone14`; acquire the lease from this worktree before starting.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import time
import uuid

SCENARIOS = {
    # S1: already measured middle region, absolute down/up replay.
    "read": ["-OpenCodeFixturePosition", "middle"],
    # S2: finger-like upward movement through history that was never measured.
    "history-up": ["-OpenCodeFixturePosition", "nearTail", "-OpenCodeFixtureScrollUp"],
    # S3: token stream at the event batch cadence while reading the middle.
    "stream-reading": ["-OpenCodeFixturePosition", "middle", "-OpenCodeFixtureStream", "32"],
    # S4: the same stream while following the tail, without any driver movement.
    "stream-follow": ["-OpenCodeFixturePosition", "tail", "-OpenCodeFixtureHold", "-OpenCodeFixtureStream", "32"],
    # S5: upward flings with rests into cursor-paged history (400 ms per page).
    "paged-up": ["-OpenCodeFixturePosition", "nearTail", "-OpenCodeFixtureFlings", "-OpenCodeFixturePaged"],
}
KEYS = ["frames", "p50FrameMS", "p95FrameMS", "maxFrameMS", "over33", "over50", "over100",
        "mainThreadCPU_MS", "jumpMaxPoints", "jumpTotalPoints", "replacedFrames", "backwardPoints", "tailGapPoints"]

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", choices=["simulator", "iphone14"], default="simulator")
parser.add_argument("--simulator", help="Simulator UDID (required with --device simulator)")
parser.add_argument("--app", action="append", required=True, metavar="LABEL=PATH",
                    help="Built OpenCode.app; repeat to alternate builds within each iteration")
parser.add_argument("--iterations", type=int, default=3)
parser.add_argument("--scenarios", nargs="*", default=list(SCENARIOS))
parser.add_argument("--output", type=Path, required=True, help="JSON lines file with every report")
args = parser.parse_args()

bundle = "br.com.alexandrem.opencode"
physical = args.device == "iphone14"
udid = "00008110-00065DA13A78401E" if physical else args.simulator
if not udid:
    parser.error("--simulator is required for simulator runs")
lease = [str(Path.home() / ".agents/skills/aparelhos-fisicos/scripts/device-lease"), "exec", "iphone14", "--"] if physical else []
apps = [entry.split("=", 1) for entry in args.app]
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")


def run(command, **options):
    return subprocess.run(lease + command, check=True, **options)


def install(path):
    if physical:
        run(["xcrun", "devicectl", "device", "install", "app", "--device", udid, path], stdout=subprocess.DEVNULL)
    else:
        run(["xcrun", "simctl", "install", udid, path])


def measure(arguments, run_id):
    launch = temporary / f"measure-scroll-{run_id}.json"
    common = ["-OpenCodeServerURL", "http://127.0.0.1:9", "-OpenCodeScrollFixture", "conversation",
              "-OpenCodeTheme", "openchamber-dark", "-OpenCodeMarkdownCodeWrap", "YES",
              "-OpenCodeMarkdownTableWrap", "YES", "-OpenCodeCollapsibleUserMessages", "YES",
              "-OpenCodeFixtureAutoScroll", "-OpenCodeFixtureRunID", run_id] + arguments
    if physical:
        run(["xcrun", "devicectl", "device", "process", "launch", "--device", udid, "--terminate-existing",
             "--json-output", str(launch), bundle, "--"] + common, stdout=subprocess.DEVNULL)
        pid = json.loads(launch.read_text())["result"]["process"]["processIdentifier"]
        launch.unlink()
        time.sleep(16)
        try:
            for _ in range(20):
                target = temporary / f"measure-scroll-{run_id}-metrics.json"
                subprocess.run(lease + ["xcrun", "devicectl", "device", "copy", "from", "--device", udid,
                                        "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                                        "--source", "Documents/scroll-fixture-metrics.json", "--destination", str(target)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if target.exists():
                    report = json.loads(target.read_text())
                    target.unlink()
                    if report.get("runID") == run_id:
                        return report
                time.sleep(1)
            raise RuntimeError("the fixture driver did not finish")
        finally:
            subprocess.run(lease + ["xcrun", "devicectl", "device", "process", "terminate", "--device", udid,
                                    "--pid", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", udid, bundle, "data"], text=True).strip())
    report_path = container / "Documents/scroll-fixture-metrics.json"
    report_path.unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, bundle] + common,
                   check=True, stdout=subprocess.DEVNULL,
                   env=os.environ | {"SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD": "offline-fixtures-only"})
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if report_path.exists():
                report = json.loads(report_path.read_text())
                if report.get("runID") == run_id:
                    return report
            time.sleep(0.2)
        raise RuntimeError("the fixture driver did not finish")
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", udid, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


results = {}
with args.output.open("a") as output:
    for iteration in range(args.iterations):
        for label, path in apps:
            install(path)
            for scenario in args.scenarios:
                report = measure(SCENARIOS[scenario], uuid.uuid4().hex)
                record = {"app": label, "scenario": scenario, "iteration": iteration, **report}
                output.write(json.dumps(record) + "\n")
                output.flush()
                results.setdefault((scenario, label), []).append(report)
                print(label, scenario, iteration, {key: round(report.get(key, 0), 1) for key in KEYS}, flush=True)

print("\nmedians")
for (scenario, label), reports in sorted(results.items()):
    print(f"{scenario:15} {label:10}", "  ".join(f"{key}={statistics.median(r.get(key, 0) for r in reports):.1f}" for key in KEYS))

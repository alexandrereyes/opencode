#!/usr/bin/env python3
"""Server-free conversation scroll scenarios, alternating builds, on a simulator or the leased iPhone 14.

Driver scenarios launch the offline fixture with the DEBUG display-link driver and collect its 12-second
report (frame intervals, frames over 33/50/100 ms, main-thread CPU, unrequested row movement including the
row that grows, backward steps, text views created/destroyed and whole-text replacements).

Trajectory scenarios record every displayed frame from an event (opening, leaving and reopening, covering
with another screen, returning from the background) until the transcript settles, and count the frames that
show another passage than the one the reader left (`exitWrongFrames`) or than the final one (`wrongFrames`).
`background-*` hides the app behind Settings for three seconds while two messages arrive.

Build Debug with SWIFT_OPTIMIZATION_LEVEL=-O for representative numbers. Physical runs go through
`device-lease exec iphone14`; acquire the lease from this worktree before starting.
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
    # S3b: the same stream while the reader holds still in the middle: nothing on screen may move.
    "stream-still": ["-OpenCodeFixturePosition", "middle", "-OpenCodeFixtureHold", "-OpenCodeFixtureStream", "32"],
    # S4: the same stream with the newest response on screen, without any driver movement.
    "stream-follow": ["-OpenCodeFixturePosition", "tail", "-OpenCodeFixtureHold", "-OpenCodeFixtureStream", "32"],
    # S5: upward flings with rests into cursor-paged history (400 ms per page).
    "paged-up": ["-OpenCodeFixturePosition", "nearTail", "-OpenCodeFixtureFlings", "-OpenCodeFixturePaged"],
}
TRAJECTORIES = {
    # Cold opening at a saved message or at the end: frames before the final passage.
    "open-middle": (["-OpenCodeFixturePosition", "middle"], 1, False),
    "open-tail": (["-OpenCodeFixturePosition", "tail"], 1, False),
    # Leave the conversation and open it again (three times).
    "reentry-middle": (["-OpenCodeFixturePosition", "middle", "-OpenCodeFixtureReentry", "pop"], 4, False),
    "reentry-tail": (["-OpenCodeFixturePosition", "tail", "-OpenCodeFixtureReentry", "pop"], 4, False),
    # Cover the conversation with another screen and come back (three times).
    "child-middle": (["-OpenCodeFixturePosition", "middle", "-OpenCodeFixtureReentry", "child"], 4, False),
    # Hide the app while two messages arrive, then return.
    "background-middle": (["-OpenCodeFixturePosition", "middle", "-OpenCodeFixtureBackgroundArrivals"], 2, True),
    "background-tail": (["-OpenCodeFixturePosition", "tail", "-OpenCodeFixtureBackgroundArrivals"], 2, True),
}
KEYS = ["frames", "p50FrameMS", "p95FrameMS", "maxFrameMS", "over33", "over50", "over100",
        "mainThreadCPU_MS", "jumpMaxPoints", "jumpTotalPoints", "movedFrames", "growingShiftMaxPoints",
        "replacedFrames", "backwardPoints", "tailGapPoints", "textViewsCreated", "textViewsDestroyed",
        "textReplacements", "textAppends"]
EPISODE_KEYS = ["blankFrames", "contentFrames", "wrongFrames", "exitWrongFrames", "firstExitDeviation",
                "finalExitDeviation", "maxStepPoints", "firstContentMS", "settledMS"]

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", choices=["simulator", "iphone14"], default="simulator")
parser.add_argument("--simulator", help="Simulator UDID (required with --device simulator)")
parser.add_argument("--app", action="append", required=True, metavar="LABEL=PATH",
                    help="Built OpenCode.app; repeat to alternate builds within each iteration")
parser.add_argument("--iterations", type=int, default=3)
parser.add_argument("--scenarios", nargs="*", default=list(SCENARIOS) + list(TRAJECTORIES))
parser.add_argument("--theme", default="openchamber-dark")
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


def common(run_id, arguments):
    return ["-OpenCodeServerURL", "http://127.0.0.1:9", "-OpenCodeScrollFixture", "conversation",
            "-OpenCodeTheme", args.theme, "-OpenCodeMarkdownCodeWrap", "YES",
            "-OpenCodeMarkdownTableWrap", "YES", "-OpenCodeCollapsibleUserMessages", "YES",
            "-OpenCodeFixtureRunID", run_id] + arguments


def launch(arguments):
    """Starts a fresh process; returns its pid on a device."""
    if physical:
        output = temporary / f"measure-scroll-launch-{uuid.uuid4().hex}.json"
        run(["xcrun", "devicectl", "device", "process", "launch", "--device", udid, "--terminate-existing",
             "--json-output", str(output), bundle, "--"] + arguments, stdout=subprocess.DEVNULL)
        pid = json.loads(output.read_text())["result"]["process"]["processIdentifier"]
        output.unlink()
        return pid
    subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, bundle] + arguments,
                   check=True, stdout=subprocess.DEVNULL,
                   env=os.environ | {"SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD": "offline-fixtures-only"})
    return None


def terminate(pid):
    if physical:
        subprocess.run(lease + ["xcrun", "devicectl", "device", "process", "terminate", "--device", udid,
                                "--pid", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        subprocess.run(["xcrun", "simctl", "terminate", udid, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def read(name, run_id):
    """The app's report from its Documents directory, if it belongs to this run."""
    if physical:
        target = temporary / f"measure-scroll-{run_id}-{name}"
        subprocess.run(lease + ["xcrun", "devicectl", "device", "copy", "from", "--device", udid,
                                "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                                "--source", f"Documents/{name}", "--destination", str(target)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not target.exists():
            return None
        report = json.loads(target.read_text())
        target.unlink()
    else:
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", udid, bundle, "data"], text=True).strip())
        path = container / "Documents" / name
        if not path.exists():
            return None
        try:
            report = json.loads(path.read_text())
        except json.JSONDecodeError:
            return None
    return report if report.get("runID") == run_id else None


def hide_and_return():
    """Puts Settings in front for three seconds, then brings the same process back."""
    if physical:
        run(["xcrun", "devicectl", "device", "process", "launch", "--device", udid, "com.apple.Preferences"],
            stdout=subprocess.DEVNULL)
        time.sleep(3)
        run(["xcrun", "devicectl", "device", "process", "launch", "--device", udid, bundle], stdout=subprocess.DEVNULL)
    else:
        subprocess.run(["xcrun", "simctl", "launch", udid, "com.apple.Preferences"], check=True, stdout=subprocess.DEVNULL)
        time.sleep(3)
        subprocess.run(["xcrun", "simctl", "launch", udid, bundle], check=True, stdout=subprocess.DEVNULL)


def measure(arguments, run_id):
    pid = launch(common(run_id, ["-OpenCodeFixtureAutoScroll"] + arguments))
    try:
        deadline = time.monotonic() + 60
        time.sleep(15 if physical else 1)
        while time.monotonic() < deadline:
            report = read("scroll-fixture-metrics.json", run_id)
            if report:
                return report
            time.sleep(1 if physical else 0.2)
        raise RuntimeError("the fixture driver did not finish")
    finally:
        terminate(pid)


def trajectory(arguments, run_id, expected, background):
    pid = launch(common(run_id, ["-OpenCodeTrajectory"] + arguments))
    try:
        deadline = time.monotonic() + 90
        hidden = False
        while time.monotonic() < deadline:
            report = read("transcript-trajectory.json", run_id)
            episodes = report["episodes"] if report else []
            if background and not hidden and len(episodes) >= 1:
                hide_and_return()
                hidden = True
            if len(episodes) >= expected:
                return episodes
            time.sleep(1 if physical else 0.3)
        raise RuntimeError(f"only {len(episodes)} of {expected} episodes were reported")
    finally:
        terminate(pid)


def summary(episodes):
    """Sums over the return episodes (all but the opening one, unless it is the only one)."""
    returns = episodes[1:] or episodes
    result = {}
    for key in EPISODE_KEYS:
        values = [episode[key] for episode in returns if key in episode]
        if not values:
            continue
        result[key] = sum(values) if key.endswith("Frames") else max(values)
    return result


results = {}
with args.output.open("a") as output:
    for iteration in range(args.iterations):
        for label, path in apps:
            install(path)
            for scenario in args.scenarios:
                run_id = uuid.uuid4().hex
                if scenario in TRAJECTORIES:
                    arguments, expected, background = TRAJECTORIES[scenario]
                    episodes = trajectory(arguments, run_id, expected, background)
                    report = summary(episodes)
                    record = {"app": label, "scenario": scenario, "iteration": iteration, "episodes": episodes, **report}
                    keys = EPISODE_KEYS
                else:
                    report = measure(SCENARIOS[scenario], run_id)
                    record = {"app": label, "scenario": scenario, "iteration": iteration, **report}
                    keys = KEYS
                output.write(json.dumps(record) + "\n")
                output.flush()
                results.setdefault((scenario, label), []).append(report)
                print(label, scenario, iteration, {key: round(report.get(key, 0), 1) for key in keys if key in report}, flush=True)

print("\nmedians")
for (scenario, label), reports in sorted(results.items()):
    keys = EPISODE_KEYS if scenario in TRAJECTORIES else KEYS
    print(f"{scenario:18} {label:10}", "  ".join(
        f"{key}={statistics.median(r.get(key, 0) for r in reports):.1f}" for key in keys if any(key in r for r in reports)))

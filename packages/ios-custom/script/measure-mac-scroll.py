#!/usr/bin/env python3
"""Server-free scroll scenarios on the Mac transcript, like `measure-scroll.py` on the iPhone.

Each run launches the DEBUG OpenCodeMac with the bundled 300-message scroll fixture and the frame driver
(`MacScrollDriver`), which moves the transcript for 12 seconds and writes its report (frame intervals, frames over
33/50/100 ms, main-thread CPU, unrequested on-screen movement, replaced frames, backward steps, the final distance
from the end). While the screen is locked the display link never fires; the driver then uses a 60 Hz timer that
draws the window on every tick (`"clock": "timer"`), so frame times are an upper bound of the main thread's work.

    python3 packages/ios-custom/script/measure-mac-scroll.py --app <OpenCodeMac.app> --output <report.jsonl>
"""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import tempfile

SCENARIOS = {
    "read": ["-OpenCodeFixturePosition", "middle"],
    "history-up": ["-OpenCodeFixturePosition", "nearTail", "-OpenCodeFixtureScrollUp"],
    "stream-reading": ["-OpenCodeFixturePosition", "middle", "-OpenCodeFixtureStream", "32"],
    "stream-still": ["-OpenCodeFixturePosition", "middle", "-OpenCodeFixtureHold", "-OpenCodeFixtureStream", "32"],
    "stream-follow": ["-OpenCodeFixturePosition", "tail", "-OpenCodeFixtureHold", "-OpenCodeFixtureStream", "32"],
    "paged-up": ["-OpenCodeFixturePosition", "nearTail", "-OpenCodeFixtureFlings", "-OpenCodeFixturePaged"],
}
KEYS = ["frames", "p50FrameMS", "p95FrameMS", "maxFrameMS", "over33", "over50", "over100", "mainThreadCPU_MS",
        "jumpMaxPoints", "movedFrames", "growingShiftMaxPoints", "replacedFrames", "backwardPoints", "tailGapPoints"]

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--app", required=True, help="Debug OpenCodeMac.app")
parser.add_argument("--iterations", type=int, default=3)
parser.add_argument("--scenarios", nargs="*", default=list(SCENARIOS))
parser.add_argument("--theme", default="openchamber-dark")
parser.add_argument("--size", default="1269x794")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()

binary = Path(args.app) / "Contents/MacOS/OpenCodeMac"
results: dict[str, list[dict]] = {name: [] for name in args.scenarios}
with tempfile.TemporaryDirectory(prefix="mac-scroll-") as folder, args.output.open("a") as log:
    for iteration in range(args.iterations):
        for name in args.scenarios:
            report = Path(folder) / f"{name}-{iteration}.json"
            # The driver moves the window off-screen at this size; no picture is written.
            command = [str(binary), "-OpenCodeScrollFixture", "conversation", "-OpenCodeTheme", args.theme,
                       *SCENARIOS[name], "-OpenCodeMacCaptureSize", args.size, "-OpenCodeMacScrollReport", str(report)]
            subprocess.run(command, timeout=90, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if not report.exists():
                print(f"{name} #{iteration}: no report")
                continue
            value = json.loads(report.read_text())
            value["scenario"] = name
            value["iteration"] = iteration
            log.write(json.dumps(value) + "\n")
            results[name].append(value)
            print(f"{name} #{iteration}: " + ", ".join(f"{key}={value.get(key, 0):.1f}" for key in KEYS[:8]))

print("\nMedians")
for name, values in results.items():
    if not values:
        continue
    medians = {key: statistics.median(value.get(key, 0) for value in values) for key in KEYS}
    print(f"{name}: " + ", ".join(f"{key}={medians[key]:.1f}" for key in KEYS))

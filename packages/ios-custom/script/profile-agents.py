#!/usr/bin/env python3
"""Frame and main-thread measures of "Agentes e tarefas" on the in-memory family (`AgentsFixture`): no server, no
model. Each run launches the installed fixture build on one simulator, opens the root's agents screen over its
conversation and lets `ScrollFixtureDriver` measure 12 s (scrolling, or `--hold` still), then copies its report.
Scenarios run interleaved, `--rounds` times, so warm-up and a busy Mac spread over all of them.

    python3 packages/ios-custom/script/profile-agents.py --derived <DerivedData> --simulator <UDID> --evidence <dir> \\
        --label <name> [--rounds 3] scenario …
    python3 … --app before=<A.app> --app after=<B.app> … 'a:count=244,app=before' 'b:count=244,app=after'

A scenario is `name:key=value,…` with keys `count` (244), `active` (5), `events` per second (20), `expanded`,
`hold`, `noshimmer` and `noclock` (diagnostics) and `app`, for example `base:count=244` or `still:count=244,hold`.
"""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--derived", type=Path)
parser.add_argument("--app", action="append", default=[], metavar="LABEL=PATH",
    help="a fixture build by label, for scenarios with app=LABEL (interleaved A/B); the first is the default")
parser.add_argument("--simulator", required=True)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--label", required=True)
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--no-install", action="store_true")
parser.add_argument("scenarios", nargs="+")
args = parser.parse_args()
args.evidence.mkdir(parents=True, exist_ok=True)
bundle = "br.com.alexandrem.opencode"
apps = dict(item.split("=", 1) for item in args.app) or {"build": str(args.derived / "Build/Products/Debug-iphonesimulator/OpenCode.app")}


def scenario(text):
    name, _, spec = text.partition(":")
    values = dict(item.partition("=")[::2] for item in spec.split(",") if item)
    launch = ["-OpenCodeAgentsFixture", values.get("count", "244"), "-OpenCodeAgentsFixtureActive", values.get("active", "5"),
        "-OpenCodeAgentsFixtureEvents", values.get("events", "20")]
    launch += ["-OpenCodeAgentsFixtureExpanded"] if "expanded" in values else []
    launch += ["-OpenCodeFixtureHold"] if "hold" in values else []
    launch += ["-OpenCodeFixtureNoShimmer"] if "noshimmer" in values else []
    launch += ["-OpenCodeFixtureNoClock"] if "noclock" in values else []
    return name, launch, values.get("app", next(iter(apps)))


scenarios = [scenario(text) for text in args.scenarios]
subprocess.run(["xcrun", "simctl", "boot", args.simulator], stderr=subprocess.DEVNULL)
subprocess.run(["xcrun", "simctl", "bootstatus", args.simulator, "-b"], check=True, stdout=subprocess.DEVNULL)
installed = None
if args.no_install:
    installed = next(iter(apps))
subprocess.run(["xcrun", "simctl", "status_bar", args.simulator, "override", "--time", "10:58", "--batteryState",
    "discharging", "--batteryLevel", "100"], check=True)
results = []
for round_ in range(args.rounds):
    for name, launch, app in scenarios:
        if app != installed:
            subprocess.run(["xcrun", "simctl", "install", args.simulator, apps[app]], check=True)
            installed = app
        run = uuid.uuid4().hex
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator, bundle, "data"],
            text=True).strip())
        report = container / "Documents/scroll-fixture-metrics.json"
        report.unlink(missing_ok=True)
        subprocess.check_output(["xcrun", "simctl", "launch", "--terminate-running-process", args.simulator, bundle,
            "-OpenCodeServerURL", "http://127.0.0.1:1", "-OpenCodeTheme", "openchamber-dark",
            "-OpenCodeOpenSession", "ses_agents_root", "-OpenCodeOpenAgents", "-OpenCodeFixtureAutoScroll",
            "-OpenCodeFixtureRunID", run] + launch,
            env={"SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD": "agents-fixture", "PATH": "/usr/bin:/bin"})
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if report.exists():
                try:
                    data = json.loads(report.read_text())
                except json.JSONDecodeError:
                    data = {}
                if data.get("runID") == run:
                    break
            time.sleep(0.2)
        else:
            subprocess.run(["xcrun", "simctl", "io", args.simulator, "screenshot", str(args.evidence / f"{args.label}-{name}-timeout.png")])
            raise SystemExit(f"{name}: the driver did not report within 60 s")
        if round_ == 0:
            subprocess.run(["xcrun", "simctl", "io", args.simulator, "screenshot", str(args.evidence / f"{args.label}-{name}.png")],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["xcrun", "simctl", "terminate", args.simulator, bundle], stderr=subprocess.DEVNULL)
        data |= {"scenario": name, "round": round_, "app": app}
        results.append(data)
        print(f"{name} r{round_}: p50 {data['p50FrameMS']:.1f} p95 {data['p95FrameMS']:.1f} max {data['maxFrameMS']:.1f} "
            f">33 {data['over33']} >50 {data['over50']} main {data['mainThreadCPU_MS']:.0f} ms "
            f"proj {data.get('agentsProjections', 0)}×/{data.get('agentsProjectionMicros', 0) / 1000:.0f} ms "
            f"bodies {data.get('agentsBodies', 0)} dist {data['distancePoints']:.0f}", flush=True)
(args.evidence / f"{args.label}.json").write_text(json.dumps(results, indent=1))

print("\nscenario | runs | p50 | p95 | max | >33 ms | >50 ms | main CPU ms | projections | projection ms | bodies")
for name, _, _ in scenarios:
    rows = [row for row in results if row["scenario"] == name]
    def cell(key, scale=1, digits=1):
        values = [row.get(key, 0) / scale for row in rows]
        mean = statistics.mean(values)
        spread = statistics.pstdev(values) if len(values) > 1 else 0
        return f"{mean:.{digits}f} ±{spread:.{digits}f}"
    print(" | ".join([name, str(len(rows)), cell("p50FrameMS"), cell("p95FrameMS"), cell("maxFrameMS"), cell("over33", digits=0),
        cell("over50", digits=0), cell("mainThreadCPU_MS", digits=0), cell("agentsProjections", digits=0),
        cell("agentsProjectionMicros", 1000, 0), cell("agentsBodies", digits=0)]))

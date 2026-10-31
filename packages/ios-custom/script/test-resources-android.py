#!/usr/bin/env python3
"""Android Emulator resource: hub stream and input latency, viewer UI test, and what the inputs did, against an
isolated sandbox.

Registers a running emulator of yours (`--serial`, never one another session uses) in the sandbox's resources hub,
owned by an imported disposable session, then:
  1. measures the stream over the hub WebSocket for 8 seconds while scrolling Settings (frames per second, emulator
     capture → receipt age, same Mac clock) and, with a control ticket, 10 drags: input sent → first new frame;
  2. opens a blank contact form and runs `OpenCodeUITests/AndroidEmulatorViewerTests` (unless `--skip-ui`), while
     watching the emulator over adb: the typed text must reach the form, then Início shows the launcher and Recentes
     the overview;
  3. samples the CPU of the emulator, of the hub and of the app's simulator process during the UI run.
Removes the resource and the session afterwards and goes back to the launcher. Run after `build-for-testing`:
  python3 packages/ios-custom/script/test-resources-android.py --device <app-sim> --serial emulator-5590 \\
    --derived <DerivedData> --home <sandbox-home> --server-url http://127.0.0.1:<port> --evidence <prints-dir> \\
    [--theme openchamber-light]
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--device", required=True, help="simulator that runs the app")
parser.add_argument("--serial", required=True, help="adb serial of the running emulator registered as the resource")
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--home", type=Path, required=True, help="custom-sandbox.ts home")
parser.add_argument("--server-url", required=True)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--theme", default=os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark"))
parser.add_argument("--skip-ui", action="store_true")
args = parser.parse_args()
port = int(args.server_url.rsplit(":", 1)[1].rstrip("/"))
if port in (4096, 4177, 4178) or not args.server_url.startswith(("http://127.0.0.1:", "http://localhost:")):
    parser.error("Use an isolated loopback sandbox, never 4096, 4177 or 4178")

sdk = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or Path.home() / "Library/Android/sdk")
adb_path = shutil.which("adb") or str(sdk / "platform-tools/adb")
def adb(*command, check=True):
    return subprocess.run([adb_path, "-s", args.serial, *command], check=check, capture_output=True, text=True).stdout

password = (args.home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
    "Content-Type": "application/json"}
def api(path, body=None, method="POST"):
    request = urllib.request.Request(args.server_url + path, data=json.dumps(body).encode() if body is not None else None,
        headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
        return json.loads(data) if data else None
def rpc(method, value):
    return api("/api/rpc/custom.resources/" + method, {"input": value})["output"]
rpc("list", {})
# The sandbox's own hub (on the Mac when the sandbox runs on the OrbStack Linux machine), never production's.
hub = json.loads(Path(subprocess.check_output(["bun", str(Path(__file__).resolve().parents[3] / "packages/cli/script/custom-sandbox.ts"),
    "hub", "--port", str(port), "--home", str(args.home)], text=True).strip()).read_text())
def admin(path, body=None, method="GET"):
    request = urllib.request.Request("http://%s:%d%s" % (hub["host"], hub["port"], path),
        data=json.dumps(body).encode() if body is not None else None, method=method,
        headers={"Authorization": "Bearer " + hub["secret"], "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read())

def cpu_seconds(pid):
    output = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not output:
        return None
    parts = [float(part) for part in output.replace("-", ":").split(":")]
    return sum(value * 60 ** index for index, value in enumerate(reversed(parts)))
def pid_of(pattern):
    output = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout.split()
    return int(output[0]) if output else None

token = uuid.uuid4().hex[:10]
fixture = Path(tempfile.mkdtemp(prefix="android-resources-" + token + "-")).resolve()
root = fixture / "repo"
args.evidence.mkdir(parents=True, exist_ok=True)
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
session = None
resource = None
configured = None
report = {"theme": args.theme, "serial": args.serial}
typed = "Olá João 123"
try:
    root.mkdir()
    (root / "README.md").write_text("# Recursos Android\n", encoding="utf8")
    git = ["git", "-C", str(root), "-c", "user.email=fixture@example.invalid", "-c", "user.name=Fixture"]
    subprocess.run(git[:3] + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-qm", "fixture"], check=True)
    now = int(time.time() * 1000)
    session = "ses_" + uuid.uuid4().hex
    api("/api/experimental/session/import", {"info": {"id": session, "title": "Recursos Android " + token,
        "projectID": "global", "location": {"directory": str(root)}, "agent": "build", "model": model, "cost": 0,
        "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}, "outcome": "succeeded",
        "time": {"created": now, "updated": now, "idle": now, "viewed": now}}, "location": {"directory": str(root)},
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Recursos.", "time": {"created": now}}]})
    resource = admin("/admin/resources", {"kind": "android-emulator",
        "meta": {"kind": "android-emulator", "serial": args.serial},
        "owner": {"sessionID": session, "rootSessionID": session, "agent": "opushigh"}, "used": True}, "PUT")["id"]
    report["resource"] = resource

    # 1. Stream and input latency through the hub, as the iPhone sees them minus the network.
    adb("shell", "am", "start", "-W", "-a", "android.settings.SETTINGS")
    time.sleep(1.5)
    view = rpc("ticket", {"id": resource})
    taken = rpc("control", {"id": resource, "action": "take"})
    control = taken["ticket"]
    probe = fixture / "probe.ts"
    probe.write_text("""
const [viewURL, controlURL] = process.argv.slice(2)
const ages: number[] = []
let first = 0
let bytes = 0
const watcher = new WebSocket(viewURL!)
watcher.binaryType = "arraybuffer"
// Acknowledges every frame, as the app does with hubs that list `ack` in `features`.
watcher.onmessage = (event) => {
  if (typeof event.data === "string") return
  ages.push(Date.now() - new DataView(event.data as ArrayBuffer).getFloat64(2))
  bytes += (event.data as ArrayBuffer).byteLength
  first ||= Date.now()
  watcher.send(JSON.stringify({ type: "ack", n: ages.length }))
}
const scroll = Bun.spawn(["sh", "-c", process.env.SCROLL!])
await Bun.sleep(8000)
scroll.kill()
watcher.close()
const sorted = ages.toSorted((a, b) => a - b)
const stream = { frames: ages.length, fps: +(ages.length / ((Date.now() - first) / 1000)).toFixed(1),
  ageMedian: Math.round(sorted[Math.floor(sorted.length / 2)] ?? 0), ageP95: Math.round(sorted[Math.floor(sorted.length * 0.95)] ?? 0),
  kbPerFrame: +(bytes / 1024 / Math.max(1, ages.length)).toFixed(1) }

const socket = new WebSocket(controlURL!)
socket.binaryType = "arraybuffer"
let frames = 0
socket.onmessage = (event) => {
  if (typeof event.data === "string") return
  frames++
  socket.send(JSON.stringify({ type: "ack", n: frames }))
}
await new Promise((resolve) => (socket.onopen = resolve))
await Bun.sleep(1500)
const send = (events: unknown[]) => socket.send(JSON.stringify({ type: "input", events }))
// Waits until the screen settles (no frame for 400 ms), so a fling from the last drag is not taken as the answer.
const quiet = async () => {
  const deadline = Date.now() + 4000
  let last = frames
  let since = Date.now()
  while (Date.now() - since < 400 && Date.now() < deadline) {
    await Bun.sleep(20)
    if (frames !== last) { last = frames; since = Date.now() }
  }
}
const drags: number[] = []
for (let index = 0; index < 10; index++) {
  const direction = index % 2 === 0 ? -1 : 1
  await quiet()
  send([{ type: "touch", phase: "began", x: 0.5, y: 0.6 }])
  await Bun.sleep(150)
  await quiet()
  const seen = frames
  const sent = Date.now()
  send(Array.from({ length: 6 }, (_, step) => ({ type: "touch", phase: "moved", x: 0.5, y: 0.6 + direction * 0.04 * (step + 1) })))
  while (frames === seen && Date.now() - sent < 2000) await Bun.sleep(1)
  if (frames > seen) drags.push(Date.now() - sent)
  send([{ type: "touch", phase: "ended", x: 0.5, y: 0.6 + direction * 0.24 }])
  await Bun.sleep(900)
}
const buttons: number[] = []
for (const button of ["home", "recents", "back", "home"]) {
  await Bun.sleep(600)
  await quiet()
  const seen = frames
  const sent = Date.now()
  send([{ type: "button", button }])
  while (frames === seen && Date.now() - sent < 3000) await Bun.sleep(1)
  if (frames > seen) buttons.push(Date.now() - sent)
}
socket.close()
const median = (values: number[]) => values.toSorted((a, b) => a - b)[Math.floor(values.length / 2)]
console.log(JSON.stringify({ stream, dragToFrame: { median: median(drags), all: drags },
  buttonToFrame: { median: median(buttons), all: buttons } }))
""")
    def url(ticket):
        return "ws://%s:%d%s/stream?ticket=%s" % (hub["host"], ticket["loopbackPort"], ticket["path"], ticket["ticket"])
    scroll = "for i in 1 2 3 4 5 6; do %s -s %s shell input swipe 360 1300 360 400 300; %s -s %s shell input swipe 360 400 360 1300 300; done" % (
        adb_path, args.serial, adb_path, args.serial)
    hub_pid = hub.get("pid")
    hub_cpu = cpu_seconds(hub_pid) if hub_pid else None
    started = time.time()
    report["hub"] = json.loads(subprocess.check_output(["bun", str(probe), url(view), url(control)], text=True,
        env={**os.environ, "SCROLL": scroll}).strip())
    if hub_cpu is not None:
        report["hub"]["hubCpuPercent"] = round((cpu_seconds(hub_pid) - hub_cpu) / (time.time() - started) * 100, 1)
    rpc("control", {"id": resource, "action": "release"})
    started = time.time()
    rpc("snapshot", {"id": resource, "maxWidth": 240})
    report["thumbnailSeconds"] = round(time.time() - started, 3)

    status = 0
    if not args.skip_ui:
        # 2. A fresh contact form; its first field is at 59.5 % of the frame's height on a 720×1600 Pixel-like AVD.
        adb("shell", "input", "keyevent", "KEYCODE_HOME")
        adb("shell", "am", "start", "-W", "-a", "android.intent.action.INSERT", "-t", "vnd.android.cursor.dir/contact")
        time.sleep(2)
        seen = {}
        stop = threading.Event()
        def watch():
            while not stop.is_set():
                focus = adb("shell", "dumpsys window | grep -m1 mCurrentFocus", check=False).lower()
                dump = adb("exec-out", "uiautomator dump /dev/tty", check=False)
                if typed in dump:
                    seen.setdefault("text", time.time())
                # The Pixel launcher hosts the overview itself, so only its panel tells Recentes from Início.
                overview = "id/overview_panel" in dump or "recents" in focus
                if overview:
                    seen.setdefault("overview", time.time())
                if "launcher" in focus and not overview:
                    seen.setdefault("launcher", time.time())
                time.sleep(0.3)
        watcher = threading.Thread(target=watch, daemon=True)
        watcher.start()
        environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
            "OPENCODE_TEST_THEME": args.theme, "OPENCODE_TEST_SERVER_URL": args.server_url, "OPENCODE_TEST_RESOURCE": resource,
            "OPENCODE_TEST_ANDROID_TEXT": typed, "OPENCODE_TEST_ANDROID_TAP": "0.5,0.595"}
        run = plistlib.loads(next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
        targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run
            else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
        arguments = ["-OpenCodeServerURL", args.server_url, "-OpenCodeTheme", args.theme]
        for target in targets:
            target.setdefault("EnvironmentVariables", {}).update(environment)
            target["CommandLineArguments"] = arguments
            target["UITargetAppCommandLineArguments"] = arguments
            target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
        configured = next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).with_name("Android-" + token + ".xctestrun")
        configured.write_bytes(plistlib.dumps(run))
        configured.chmod(0o600)
        result = args.evidence / ("android-" + args.theme + "-" + token + ".xcresult")
        emulator_pid = pid_of("qemu-system.*-ports %s," % args.serial.split("-")[1]) or pid_of("qemu-system")
        samples = {"emulator": emulator_pid, "hub": hub_pid}
        before = {name: cpu_seconds(pid) for name, pid in samples.items() if pid}
        started = time.time()
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=" + args.device, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
            "-maximum-test-execution-time-allowance", "300", "-resultBundlePath", str(result),
            "-only-testing:OpenCodeUITests/AndroidEmulatorViewerTests"], stdout=subprocess.DEVNULL)
        elapsed = time.time() - started
        report["uiCpuPercent"] = {name: round((cpu_seconds(samples[name]) - value) / elapsed * 100, 1)
            for name, value in before.items() if cpu_seconds(samples[name]) is not None}
        stop.set()
        watcher.join()
        report["observed"] = sorted(seen, key=seen.get)
        exported = args.evidence / ("attachments-" + token)
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path",
            str(exported)], check=True, stdout=subprocess.DEVNULL)
        for test in json.loads((exported / "manifest.json").read_text()):
            for attachment in test["attachments"]:
                source = exported / attachment["exportedFileName"]
                if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                    shutil.copyfile(source, args.evidence / (attachment["suggestedHumanReadableName"].split("_0_")[0] + ".png"))
        shutil.rmtree(exported)
        if status == 0:
            shutil.rmtree(result)
        report["ui"] = status
        missing = [step for step in ("text", "launcher", "overview") if step not in seen]
        if status == 0 and missing:
            report["missing"] = missing
            status = 1
    print(json.dumps(report, ensure_ascii=False))
    sys.exit(status)
finally:
    if configured:
        configured.unlink(missing_ok=True)
    if resource:
        try:
            rpc("control", {"id": resource, "action": "release"})
            rpc("dismiss", {"id": resource})
        except Exception as error:
            print("cleanup:", error, file=sys.stderr)
    if session:
        try:
            api("/api/session/" + session, method="DELETE")
        except Exception as error:
            print("cleanup:", error, file=sys.stderr)
    adb("shell", "input", "keyevent", "KEYCODE_HOME", check=False)
    shutil.rmtree(fixture, ignore_errors=True)

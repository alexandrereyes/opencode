#!/usr/bin/env python3
"""iOS Simulator resource (serve-sim): latency through the hub and the viewer's controls, against an isolated sandbox.

Registers an existing, booted simulator of yours (`--target`, never one another session uses) in the sandbox's
resources hub, owned by an imported disposable session, and opens a local test page in its Safari: a text field and
a tap zone that changes color on every touch. Then:
  1. takes control through the RPC and measures, through the hub's own WebSocket (the path the iPhone uses, minus
     the network), the time from sending a touch to receiving the frame that shows it; gives control back;
  2. runs `OpenCodeUITests/IOSSimulatorResourceTests` (unless `--skip-ui`): watch live, take control, tap the field,
     type with the iPhone keyboard (keys and paste), Enter, Início, Girar, Captura, give back. The page reports what
     arrived to this script's HTTP server, which the test reads.
Removes the resource, the session and the page server afterwards. Run after `build-for-testing`:
  python3 packages/ios-custom/script/test-ios-simulator-resource.py --device <app-sim> --target <target-sim> \\
    --derived <DerivedData> --home <sandbox-home> --server-url http://127.0.0.1:<port> --evidence <prints-dir> \\
    [--theme openchamber-light]
"""
import argparse
import base64
import http.server
import json
import os
from pathlib import Path
import plistlib
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
parser.add_argument("--target", required=True, help="booted simulator registered as the resource")
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--home", type=Path, required=True, help="custom-sandbox.ts home")
parser.add_argument("--server-url", required=True)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--theme", default=os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark"))
parser.add_argument("--taps", type=int, default=20)
parser.add_argument("--skip-ui", action="store_true")
args = parser.parse_args()
port = int(args.server_url.rsplit(":", 1)[1].rstrip("/"))
if port in (4096, 4177, 4178) or not args.server_url.startswith(("http://127.0.0.1:", "http://localhost:")):
    parser.error("Use an isolated loopback sandbox, never 4096, 4177 or 4178")

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
hub = json.loads((args.home / "xdg/state/opencode/resources-hub/hub.json").read_text())
def admin(path, body=None, method="GET"):
    request = urllib.request.Request("http://127.0.0.1:%d%s" % (hub["port"], path),
        data=json.dumps(body).encode() if body is not None else None, method=method,
        headers={"Authorization": "Bearer " + hub["secret"], "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read())

PAGE = """<!doctype html><meta name=viewport content="width=device-width,initial-scale=1,user-scalable=no">
<style>body{margin:0;font:22px -apple-system;background:#fafafa}form{height:42vh;display:flex;padding:56px 12px 12px}
input{flex:1;font-size:30px;padding:12px;border:3px solid #888;border-radius:16px}
#tap{height:40vh;margin:0 12px;border-radius:24px;background:#1e88e5;color:#fff;display:flex;align-items:center;
justify-content:center;font-size:30px}</style>
<form id=f><input id=i autocomplete=off autocapitalize=off autocorrect=off spellcheck=false placeholder="Digite aqui"></form>
<div id=tap>Toque aqui</div>
<script>
let n = 0
tap.addEventListener("touchstart", () => { n++; tap.style.background = n % 2 ? "#e53935" : "#1e88e5"; tap.textContent = "Toques: " + n })
f.onsubmit = (e) => { e.preventDefault(); fetch("/got", { method: "POST", body: i.value }) }
</script>"""
received = []
class Page(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        body = json.dumps(received).encode() if self.path == "/received" else PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json" if self.path == "/received" else "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        received.append(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf8"))
        self.send_response(204)
        self.end_headers()
page = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=page.serve_forever, daemon=True).start()
page_url = "http://127.0.0.1:%d/" % page.server_address[1]

token = uuid.uuid4().hex[:10]
fixture = Path(tempfile.mkdtemp(prefix="ios-sim-resource-" + token + "-")).resolve()
root = fixture / "repo"
args.evidence.mkdir(parents=True, exist_ok=True)
session = None
resource = None
configured = None
report = {"theme": args.theme}
try:
    root.mkdir()
    (root / "README.md").write_text("# Simulador\n", encoding="utf8")
    git = ["git", "-C", str(root), "-c", "user.email=fixture@example.invalid", "-c", "user.name=Fixture"]
    subprocess.run(git[:3] + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-qm", "fixture"], check=True)
    now = int(time.time() * 1000)
    session = "ses_" + uuid.uuid4().hex
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    api("/api/experimental/session/import", {"info": {"id": session, "title": "Simulador " + token, "projectID": "global",
        "location": {"directory": str(root)}, "agent": "build", "model": model, "cost": 0,
        "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}, "outcome": "succeeded",
        "time": {"created": now, "updated": now, "idle": now, "viewed": now}}, "location": {"directory": str(root)},
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Simulador.", "time": {"created": now}}]})
    resource = admin("/admin/resources", {"kind": "ios-simulator", "meta": {"kind": "ios-simulator", "udid": args.target},
        "owner": {"sessionID": session, "rootSessionID": session, "agent": "opushigh"}, "used": True}, "PUT")["id"]
    report["resource"] = resource
    subprocess.run(["xcrun", "simctl", "openurl", args.target, page_url], check=True)
    time.sleep(3)

    # Touch → frame through the hub, in control, on the tap zone (each touch flips its color).
    taken = rpc("control", {"id": resource, "action": "take"})
    ticket = taken["ticket"]
    probe = fixture / "probe.ts"
    probe.write_text("""
const ws = new WebSocket(process.argv[2]); ws.binaryType = "arraybuffer"
const taps = Number(process.argv[3]); let opened = 0; let hello: unknown; let meta: unknown
const waiters: ((t: number) => void)[] = []; let frames = 0; let bytes = 0
ws.onmessage = (event) => {
  if (typeof event.data === "string") { const m = JSON.parse(event.data); if (m.type === "hello") hello = m; if (m.type === "meta") meta = m.value; return }
  frames++; bytes += (event.data as ArrayBuffer).byteLength
  const now = performance.now(); waiters.splice(0).forEach((resolve) => resolve(now))
}
await new Promise((resolve) => (ws.onopen = () => { opened = performance.now(); resolve(0) }))
const first = await new Promise<number>((resolve) => waiters.push(resolve))
const firstFrame = first - opened
await Bun.sleep(1500)
const send = (events: unknown[]) => ws.send(JSON.stringify({ type: "input", events }))
// A previous run may have left the simulator sideways; turn it back to portrait.
for (let turn = 0; turn < 3 && (meta as { rotation?: number } | undefined)?.rotation; turn++) {
  send([{ type: "button", button: "rotate-right" }])
  await Bun.sleep(1500)
}
const samples: number[] = []
for (let i = 0; i < taps; i++) {
  await Bun.sleep(350)
  const next = Promise.race([new Promise<number>((resolve) => waiters.push(resolve)), Bun.sleep(2000).then(() => -1)])
  const sent = performance.now()
  send([{ type: "touch", phase: "began", x: 0.5, y: 0.7 }])
  const at = await next
  send([{ type: "touch", phase: "ended", x: 0.5, y: 0.7 }])
  if (at > 0) samples.push(at - sent)
}
const sorted = samples.toSorted((a, b) => a - b)
const pick = (p: number) => +sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))].toFixed(1)
ws.close()
console.log(JSON.stringify({ hello, meta, firstFrameMs: +firstFrame.toFixed(1), taps: samples.length,
  tapToFrameMs: { p50: pick(0.5), p90: pick(0.9), min: +sorted[0].toFixed(1), max: +sorted.at(-1).toFixed(1) },
  frames, averageKB: +(bytes / Math.max(1, frames) / 1024).toFixed(1) }))
process.exit(0)
""")
    url = "ws://127.0.0.1:%d%s/stream?ticket=%s" % (ticket["loopbackPort"], ticket["path"], ticket["ticket"])
    report["latency"] = json.loads(subprocess.check_output(["bun", str(probe), url, str(args.taps)], text=True).strip())
    rpc("control", {"id": resource, "action": "release"})

    status = 0
    if not args.skip_ui:
        expected = "Ola acao 42 á"
        environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
            "OPENCODE_TEST_THEME": args.theme, "OPENCODE_TEST_SERVER_URL": args.server_url,
            "OPENCODE_TEST_RESOURCE": resource, "OPENCODE_TEST_PAGE": page_url, "OPENCODE_TEST_TYPED": expected}
        run = plistlib.loads(next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
        targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run
            else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
        arguments = ["-OpenCodeServerURL", args.server_url, "-OpenCodeTheme", args.theme]
        for target in targets:
            target.setdefault("EnvironmentVariables", {}).update(environment)
            target["CommandLineArguments"] = arguments
            target["UITargetAppCommandLineArguments"] = arguments
            target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
        configured = next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).with_name("IOSSim-" + token + ".xctestrun")
        configured.write_bytes(plistlib.dumps(run))
        configured.chmod(0o600)
        result = args.evidence / ("ios-sim-" + args.theme + "-" + token + ".xcresult")
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=" + args.device, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
            "-maximum-test-execution-time-allowance", "400", "-resultBundlePath", str(result),
            "-only-testing:OpenCodeUITests/IOSSimulatorResourceTests"], stdout=subprocess.DEVNULL)
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
        report["received"] = received
    print(json.dumps(report, ensure_ascii=False))
    sys.exit(status)
finally:
    page.shutdown()
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
    subprocess.run(["xcrun", "simctl", "terminate", args.target, "com.apple.mobilesafari"], stderr=subprocess.DEVNULL)
    shutil.rmtree(fixture, ignore_errors=True)

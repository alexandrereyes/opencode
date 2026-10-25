#!/usr/bin/env python3
"""Session resources: viewer shell UI test, stream latency and the agent lock, against an isolated sandbox.

Registers an existing, booted simulator of yours (`--target`, never one another session uses) in the sandbox's
resources hub, owned by an imported disposable session, then:
  1. measures the stream (frames per second and capture-to-receipt age, same Mac clock) with a view ticket;
  2. runs `OpenCodeUITests/ResourceViewerTests` (unless `--skip-ui`);
  3. with `--lock`, takes control through the RPC, asks the session (Luna 6 / low, one tiny shell call) to touch the
     simulator, expects the call refused with "Alexandre está usando", gives control back and expects the
     "Alexandre interagiu" notice in the session.
Removes the resource and the session afterwards. Run after `build-for-testing`:
  python3 packages/ios-custom/script/test-resources.py --device <app-sim> --target <target-sim> --derived <DerivedData> \\
    --home <sandbox-home> --server-url http://127.0.0.1:<port> --evidence <prints-dir> [--theme openchamber-light] [--lock]
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
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
parser.add_argument("--skip-ui", action="store_true")
parser.add_argument("--lock", action="store_true", help="also check the agent lock with one real model call")
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

token = uuid.uuid4().hex[:10]
fixture = Path(tempfile.mkdtemp(prefix="ios-resources-" + token + "-")).resolve()
root = fixture / "repo"
args.evidence.mkdir(parents=True, exist_ok=True)
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
session = None
resource = None
configured = None
report = {"theme": args.theme}
try:
    root.mkdir()
    (root / "README.md").write_text("# Recursos\n", encoding="utf8")
    git = ["git", "-C", str(root), "-c", "user.email=fixture@example.invalid", "-c", "user.name=Fixture"]
    subprocess.run(git[:3] + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-qm", "fixture"], check=True)
    now = int(time.time() * 1000)
    session = "ses_" + uuid.uuid4().hex
    api("/api/experimental/session/import", {"info": {"id": session, "title": "Recursos " + token, "projectID": "global",
        "location": {"directory": str(root)}, "agent": "build", "model": model, "cost": 0,
        "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}, "outcome": "succeeded",
        "time": {"created": now, "updated": now, "idle": now, "viewed": now}}, "location": {"directory": str(root)},
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Recursos.", "time": {"created": now}}]})
    resource = admin("/admin/resources", {"kind": "ios-simulator", "meta": {"kind": "ios-simulator", "udid": args.target},
        "owner": {"sessionID": session, "rootSessionID": session, "agent": "opushigh"}, "used": True}, "PUT")["id"]
    report["resource"] = resource

    # Stream: frames per second and capture-to-receipt age over 8 seconds, from a view ticket.
    ticket = rpc("ticket", {"id": resource})
    probe = fixture / "probe.ts"
    probe.write_text("""
const ws = new WebSocket(process.argv[2]); ws.binaryType = "arraybuffer"
const ages: number[] = []; let first = 0
ws.onmessage = (event) => {
  if (typeof event.data === "string") return
  const view = new DataView(event.data as ArrayBuffer)
  ages.push(Date.now() - view.getFloat64(2)); first ||= Date.now()
}
await Bun.sleep(8000); ws.close()
const sorted = ages.toSorted((a, b) => a - b)
console.log(JSON.stringify({ frames: ages.length, fps: +(ages.length / ((Date.now() - first) / 1000)).toFixed(2),
  ageMedian: sorted[Math.floor(sorted.length / 2)], ageP95: sorted[Math.floor(sorted.length * 0.95)] }))
""")
    url = "ws://127.0.0.1:%d%s/stream?ticket=%s" % (ticket["loopbackPort"], ticket["path"], ticket["ticket"])
    report["stream"] = json.loads(subprocess.check_output(["bun", str(probe), url], text=True).strip())
    started = time.time()
    rpc("snapshot", {"id": resource, "maxWidth": 240})
    report["thumbnailSeconds"] = round(time.time() - started, 3)

    status = 0
    if not args.skip_ui:
        environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
            "OPENCODE_TEST_THEME": args.theme, "OPENCODE_TEST_SERVER_URL": args.server_url, "OPENCODE_TEST_RESOURCE": resource}
        run = plistlib.loads(next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
        targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run
            else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
        arguments = ["-OpenCodeServerURL", args.server_url, "-OpenCodeTheme", args.theme]
        for target in targets:
            target.setdefault("EnvironmentVariables", {}).update(environment)
            target["CommandLineArguments"] = arguments
            target["UITargetAppCommandLineArguments"] = arguments
            target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
        configured = next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).with_name("Resources-" + token + ".xctestrun")
        configured.write_bytes(plistlib.dumps(run))
        configured.chmod(0o600)
        result = args.evidence / ("resources-" + args.theme + "-" + token + ".xcresult")
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=" + args.device, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
            "-maximum-test-execution-time-allowance", "300", "-resultBundlePath", str(result),
            "-only-testing:OpenCodeUITests/ResourceViewerTests"], stdout=subprocess.DEVNULL)
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

    if args.lock:
        taken = rpc("control", {"id": resource, "action": "take"})
        assert taken["resource"]["state"] == "user" and taken.get("ticket"), taken
        # The simulator's name is a lock token too, and short models copy it more faithfully than a UDID.
        name = next(device["name"] for group in json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices",
            "-j"]))["devices"].values() for device in group if device["udid"] == args.target)
        command = 'xcrun simctl spawn "%s" launchctl print system' % name
        api("/api/session/" + session + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "delivery": "steer",
            "text": "Use a ferramenta shell uma única vez para executar exatamente `%s`. Não tente de novo nem contorne "
                "qualquer erro. Depois responda apenas: OK." % command})
        deadline = time.time() + 180
        refused = None
        while time.time() < deadline and refused is None:
            time.sleep(2)
            page = api("/api/session/" + session + "/message?limit=20&order=desc", method="GET")["data"]
            calls = [part for message in page if message["type"] == "assistant" for part in message.get("content", [])
                if part.get("type") == "tool" and part.get("name") == "shell"]
            done = [call for call in calls if call["state"]["status"] in ("error", "completed")]
            if done:
                refused = done[0]
        if refused is None:
            raise SystemExit("The agent made no shell call")
        text = json.dumps(refused["state"], ensure_ascii=False)
        report["refusal"] = refused["state"]["status"]
        if refused["state"]["status"] != "error" or "Alexandre está usando" not in text:
            raise SystemExit("The shell call was not refused: " + text[:400])
        rpc("control", {"id": resource, "action": "release"})
        deadline = time.time() + 30
        notice = None
        while time.time() < deadline and notice is None:
            time.sleep(1)
            page = api("/api/session/" + session + "/message?limit=20&order=desc", method="GET")["data"]
            notice = next((message for message in page if "Alexandre interagiu" in json.dumps(message, ensure_ascii=False)), None)
        if notice is None:
            raise SystemExit("The session was not told about the hand-back")
        report["notice"] = notice["type"]
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
            api("/api/session/" + session + "/interrupt", {})
            time.sleep(1)
            api("/api/session/" + session, method="DELETE")
        except Exception as error:
            print("cleanup:", error, file=sys.stderr)
    shutil.rmtree(fixture, ignore_errors=True)

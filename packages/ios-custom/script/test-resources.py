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
parser.add_argument("--android", help="with --discovery: serial of your own running emulator (emulator-NNNN)")
parser.add_argument("--discovery", action="store_true",
    help="register through real agent commands (Luna 6 / low): the target by name in the session, and a headless "
    "playwright-cli browser in a subagent; then run OpenCodeUITests/ResourceListTests")
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
# The sandbox's own hub (on the Mac when the sandbox runs on the OrbStack Linux machine), never production's.
hub = json.loads(Path(subprocess.check_output(["bun", str(Path(__file__).resolve().parents[3] / "packages/cli/script/custom-sandbox.ts"),
    "hub", "--port", str(port), "--home", str(args.home)], text=True).strip()).read_text())
def admin(path, body=None, method="GET"):
    request = urllib.request.Request("http://%s:%d%s" % (hub["host"], hub["port"], path),
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
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Recursos.", "time": {"created": now}}] + [
            # One link per message: UIKit's per-line accessibility of a multi-paragraph text view can hide a link.
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
             "time": {"created": now + 1000 + index, "completed": now + 2000 + index}, "finish": "stop",
             "content": [{"type": "text", "text": text}]}
            for index, text in enumerate(["Abra o [simulador de teste](opencode-resource:ios-simulator%%3A%s)." % args.target.upper(),
                "E o [navegador de teste](opencode-resource:chrome%%3Ars-%s)." % token]
                + (["Também o [emulador de teste](opencode-resource:android-emulator%%3A%s)." % args.android] if args.android else []))]})
    name = next(device["name"] for group in json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices",
        "-j"]))["devices"].values() for device in group if device["udid"] == args.target)
    browser = None
    if args.discovery:
        def run_prompt(text, done, timeout=240):
            api("/api/session/" + session + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "delivery": "steer", "text": text})
            deadline = time.time() + timeout
            while time.time() < deadline:
                time.sleep(2)
                value = done()
                if value:
                    return value
            raise SystemExit("Timed out: " + text[:80])
        def find(kind):
            return next((r for r in rpc("list", {"sessionID": session})["resources"] if r["kind"] == kind), None)
        found = run_prompt("Use a ferramenta shell uma única vez para executar exatamente "
            "`xcrun simctl spawn \"%s\" launchctl print system | head -1`. Depois responda apenas: OK." % name,
            lambda: find("ios-simulator"))
        assert found["owner"] == {"sessionID": session, "rootSessionID": session, "agent": "build"}, found
        assert found["meta"]["udid"] == args.target.upper(), found
        resource = found["id"]
        page = api("/api/session/" + session + "/message?limit=20&order=desc", method="GET")["data"]
        shell = next(part for message in page if message["type"] == "assistant" for part in message.get("content", [])
            if part.get("type") == "tool" and part.get("name") == "shell")
        assert "opencode-resource:" in json.dumps(shell["state"].get("content")), shell["state"]
        assert shell["state"]["metadata"]["resources"][0]["id"] == resource, shell["state"]["metadata"]
        report["discovered"] = resource
        if args.android:
            emulator = run_prompt("Use a ferramenta shell uma única vez para executar exatamente "
                "`adb -s %s shell getprop ro.product.model`. Depois responda apenas: OK." % args.android,
                lambda: find("android-emulator"))
            assert emulator["owner"]["sessionID"] == session and emulator["meta"]["serial"] == args.android, emulator
            report["android"] = {"id": emulator["id"], "label": emulator["label"], "state": emulator["state"]}
        browser = "rs-" + token
        child_browser = run_prompt('Chame a ferramenta subagent uma única vez com agent="general", description='
            '"Abrir navegador de teste", model="llm-proxy/gpt-6-luna#low", prompt="Use a ferramenta shell uma única vez '
            'para executar exatamente `playwright-cli -s=%s open about:blank --browser=chrome`. Depois responda apenas: OK.", '
            'background=false. Depois responda apenas: OK.' % browser, lambda: find("chrome"), 300)
        assert child_browser["owner"]["sessionID"] != session and child_browser["owner"]["rootSessionID"] == session, child_browser
        assert child_browser["meta"]["session"] == browser, child_browser
        report["child"] = {"id": child_browser["id"], "state": child_browser["state"], "agent": child_browser["owner"].get("agent")}
        # A finished subagent without resources: nothing may appear below its row.
        plain = "ses_" + uuid.uuid4().hex
        created = int(time.time() * 1000) - 60_000
        api("/api/experimental/session/import", {"info": {"id": plain, "parentID": session, "title": "Sem recursos de teste",
            "projectID": "global", "location": {"directory": str(root)}, "agent": "explore", "model": model, "cost": 0,
            "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}, "outcome": "succeeded",
            "time": {"created": created, "updated": created + 1000, "idle": created + 1000, "viewed": created + 1000}},
            "location": {"directory": str(root)}, "messages": []})
        report["plain"] = plain
    else:
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
    url = "ws://%s:%d%s/stream?ticket=%s" % (hub["host"], ticket["loopbackPort"], ticket["path"], ticket["ticket"])
    report["stream"] = json.loads(subprocess.check_output(["bun", str(probe), url], text=True).strip())
    started = time.time()
    rpc("snapshot", {"id": resource, "maxWidth": 240})
    report["thumbnailSeconds"] = round(time.time() - started, 3)

    status = 0
    if not args.skip_ui:
        environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
            "OPENCODE_TEST_THEME": args.theme, "OPENCODE_TEST_SERVER_URL": args.server_url, "OPENCODE_TEST_RESOURCE": resource,
            "OPENCODE_TEST_SESSION": session}
        if args.discovery:
            environment["OPENCODE_TEST_CHILD_RESOURCE"] = report["child"]["id"]
            environment["OPENCODE_TEST_PLAIN_CHILD"] = report["plain"]
            if args.android:
                environment["OPENCODE_TEST_ANDROID_RESOURCE"] = report["android"]["id"]
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
            "-only-testing:OpenCodeUITests/" + ("ResourceListTests" if args.discovery else "ResourceViewerTests")],
            stdout=subprocess.DEVNULL)
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
    if args.android and session:
        try:
            emulator = next((r["id"] for r in rpc("list", {"sessionID": session})["resources"] if r["kind"] == "android-emulator"), None)
            if emulator:
                rpc("dismiss", {"id": emulator})
        except Exception as error:
            print("cleanup:", error, file=sys.stderr)
    if browser:
        subprocess.run(["playwright-cli", "-s=" + browser, "close"], cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            child = next((r["id"] for r in rpc("list", {"sessionID": session})["resources"] if r["kind"] == "chrome"), None)
            if child:
                rpc("dismiss", {"id": child})
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

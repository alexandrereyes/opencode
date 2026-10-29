#!/usr/bin/env python3
""""Avisar ao terminar" in the Sessões screen, on a freshly created simulator against an owned sandbox: imports two
owned sessions (no model calls), mutes TARGET the old way (`sidebar.mute`) and turns the bell on for OTHER through the
server, leaves a third one (long history) waiting on a shell permission after a real Luna 6 / low run, runs
SessionNotifyTests, and serves it a control endpoint that opens the notification deep link (`AgentsDeepLink`, the same
route a tap on the alert takes; `request` opens at the pending request) with `xcrun simctl openurl`. Afterwards it checks the stored
preferences, then deletes its sessions, keys, repository and simulator.

The alert payload itself is covered end to end by `plugin-app-custom/script/e2e-session-notifications.ts`; presenting
an alert needs the simulator's notification service, which fresh iOS 27 simulators on this Mac do not start (see the
README)."""
import argparse
import base64
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--server-url", required=True)
parser.add_argument("--home", type=Path, required=True)
parser.add_argument("--evidence", type=Path, default=temporary / "ios-notify-prints")
parser.add_argument("--theme", default=os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark"))
parser.add_argument("--label", default="notify")
args = parser.parse_args()
if any(port in args.server_url for port in [":4096", ":4178"]) or not (args.home / "sandbox.json").exists():
    parser.error("Use an owned sandbox, never production")
password = (args.home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
server_url = urllib.parse.urlparse(args.server_url)
# AgentsActivityAgent.serverKey for the built-in server replaced by a launch override.
server_key = "launch-%s-%d" % (server_url.hostname, server_url.port or 80)


def api(path, body=None, method="GET"):
    request = urllib.request.Request(args.server_url + path, headers=headers,
        data=json.dumps(body).encode() if body is not None else None, method=method)
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
        return json.loads(data) if data else None


def rpc(name, body):
    return api("/api/rpc/" + name, {"input": body}, "POST")["output"]


def key(session):
    return json.dumps(["http://localhost:4096", session], separators=(",", ":"))


token = uuid.uuid4().hex[:10]
args.evidence.mkdir(parents=True, exist_ok=True)
environment = args.evidence / ("environment-" + token + ".json")
owned = []
ids = {}
device = None
server = None
repo = args.home / "repos" / ("ios-notify-" + token)
try:
    device = subprocess.check_output(["xcrun", "simctl", "create", "OpenCode Aviso " + args.label,
        "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"], text=True).strip()
    subprocess.run(["xcrun", "simctl", "boot", device], check=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True, stdout=subprocess.DEVNULL)
    repo.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=OpenCode Test", "-c", "user.email=test@example.invalid",
        "commit", "--allow-empty", "-qm", "Owned notify fixture"], check=True)
    now = int(time.time() * 1000)
    # TARGET finished and was never opened (unread); OTHER is read.
    for role, title, at, viewed in [("OTHER", "Aviso — sessão com sino", now - 120_000, True),
                                    ("TARGET", "Aviso — antes silenciada", now - 60_000, False)]:
        session = "ses_" + uuid.uuid4().hex
        owned.append(session)
        ids[role] = session
        api("/api/experimental/session/import", {
            "info": {"id": session, "title": title, "projectID": "global", "location": {"directory": str(repo)},
                "agent": "build", "model": model,
                "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                "outcome": "succeeded", "time": {"created": at, "updated": at, "idle": at, **({"viewed": at} if viewed else {})}},
            "location": {"directory": str(repo)}, "messages": [
                {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Teste do aviso ao terminar.", "time": {"created": at - 1000}},
                {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
                 "time": {"created": at - 900, "completed": at - 800}, "finish": "stop",
                 "content": [{"type": "text", "text": "Histórico sintético."}]}]}, "POST")
        time.sleep(1)
    # REQUEST: a long history, then a real Luna 6 / low run left waiting on a shell permission.
    request = "ses_" + uuid.uuid4().hex
    owned.append(request)
    ids["REQUEST"] = request
    history = []
    for index in range(40):
        at = now - 600_000 + index * 2_000
        history.append({"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Pergunta longa número %d." % index,
            "time": {"created": at}})
        history.append({"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
            "time": {"created": at + 500, "completed": at + 900}, "finish": "stop",
            "content": [{"type": "text", "text": ("Resposta sintética longa %d. " % index) * 12}]})
    api("/api/experimental/session/import", {
        "info": {"id": request, "title": "Aviso — pedido pendente", "projectID": "global",
            "location": {"directory": str(repo)}, "agent": "build", "model": model,
            "permissions": [{"action": "shell", "resource": "*", "effect": "ask"}],
            "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": now - 600_000, "updated": now - 500_000, "idle": now - 500_000,
                "viewed": now - 500_000}},
        "location": {"directory": str(repo)}, "messages": history}, "POST")
    api("/api/session/" + request + "/prompt", {"text": "Use a ferramenta shell para rodar exatamente: echo aviso"}, "POST")
    deadline = time.time() + 180
    while time.time() < deadline and not api("/api/session/" + request + "/permission")["data"]:
        time.sleep(1)
    permissions = api("/api/session/" + request + "/permission")["data"]
    if not permissions:
        raise RuntimeError("The request session never asked for permission")
    ids["PERMISSION"] = permissions[0]["id"]
    rpc("custom.preferences/mutate", {"type": "sidebar.mute", "session": key(ids["TARGET"]), "muted": True})
    rpc("custom.preferences/mutate", {"type": "sidebar.notify", "session": key(ids["OTHER"]), "notify": True})

    class Control(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            status = 200
            try:
                if self.path not in ("/open", "/open-request"):
                    raise ValueError(self.path)
                query = {"server": server_key, "id": ids["TARGET"], "directory": str(repo)}
                if self.path == "/open-request":
                    query = {"server": server_key, "id": ids["REQUEST"], "directory": str(repo),
                        "request": ids["PERMISSION"]}
                link = "br.com.alexandrem.opencode://session?" + urllib.parse.urlencode(query)
                subprocess.run(["xcrun", "simctl", "openurl", device, link], check=True, timeout=30)
                body = json.dumps({"link": link}).encode()
            except Exception as error:
                status = 500
                body = json.dumps({"error": str(error)}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Control)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    environment.write_text(json.dumps({"OPENCODE_NOTIFY_TARGET": ids["TARGET"], "OPENCODE_NOTIFY_OTHER": ids["OTHER"],
        "OPENCODE_NOTIFY_TITLE": "Aviso — antes silenciada",
        "OPENCODE_NOTIFY_REQUEST": ids["REQUEST"], "OPENCODE_NOTIFY_REQUEST_TITLE": "Aviso — pedido pendente",
        "OPENCODE_NOTIFY_CONTROL": "http://127.0.0.1:%d" % server.server_address[1]}))
    environment.chmod(0o600)
    status = subprocess.call([sys.executable, str(Path(__file__).with_name("test-isolated.py")), "--device", device,
        "--derived", str(args.derived), "--evidence", str(args.evidence), "--label", args.label, "--theme", args.theme,
        "--server-url", args.server_url, "--home", str(args.home), "--environment", str(environment),
        "OpenCodeUITests/SessionNotifyTests"])
    data = rpc("custom.preferences/get", {})["data"]
    report = {"status": status, "theme": args.theme, "simulator": device,
        # The swipe turned OTHER's bell off; TARGET's old mute stays stored and ignored, and never became a bell.
        "otherBellOff": key(ids["OTHER"]) not in data.get("notifySessions", []),
        "targetMuteKept": key(ids["TARGET"]) in data.get("mutedSessions", []),
        "targetNoBell": key(ids["TARGET"]) not in data.get("notifySessions", [])}
    (args.evidence / ("verification-" + args.label + ".json")).write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps(report, ensure_ascii=False))
    sys.exit(status or (0 if report["otherBellOff"] and report["targetMuteKept"] and report["targetNoBell"] else 1))
finally:
    if server:
        server.shutdown()
    environment.unlink(missing_ok=True)
    for session in owned:
        for intent in [{"type": "sidebar.notify", "session": key(session), "notify": False},
                       {"type": "sidebar.mute", "session": key(session), "muted": False}]:
            try:
                rpc("custom.preferences/mutate", intent)
            except Exception:
                pass
        try:
            api("/api/session/" + session + "/interrupt?resume=false", {}, "POST")
        except Exception:
            pass
        try:
            api("/api/session/" + session, method="DELETE")
        except Exception:
            pass
    subprocess.run(["rm", "-rf", str(repo)])
    if device:
        subprocess.run(["xcrun", "simctl", "shutdown", device], stderr=subprocess.DEVNULL)
        subprocess.run(["xcrun", "simctl", "delete", device])

#!/usr/bin/env python3
"""Answers are read only while their conversation is seen (`ReadVisibility`), against an owned sandbox started with
`bun packages/cli/script/custom-sandbox.ts up --port <port> --home <home>`. A local fake model answers "ok", so no
real model is called. The run registers that model in the sandbox's config, imports and pins owned sessions, and
removes the sessions, pins, model and config entry afterwards.

    python3 packages/ios-custom/script/test-read-visibility.py mac --home <home> --port <port> --app <copy.app> --evidence <dir>
    python3 packages/ios-custom/script/test-read-visibility.py ios --home <home> --port <port> --derived <DerivedData> \\
        --device <simulator UDID> --evidence <dir>

mac: a test copy of the Debug OpenCodeMac (its own bundle identifier, ad hoc signed, see `MacLaunch.testCopy`) opened
in the background with `-OpenCodeMacReadCheck`. It tells the copy the app, window and system states through
`<bundle id>.read-check` (`MacRuntime.readCheck`), so the Mac itself never loses its focus, sleeps or locks; AppKit's
own activation, hide, minimize, occlusion, screen sleep and lock notifications need a check by hand.
ios: `OpenCodeUITests/ReadVisibilityTests` through `test-isolated.py` on the given simulator.
"""
import argparse
import base64
import http.server
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import threading
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("platform", choices=["mac", "ios"])
parser.add_argument("--home", type=Path, required=True)
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--app", type=Path, help="mac: the test copy")
parser.add_argument("--derived", type=Path, help="ios: DerivedData with the test build")
parser.add_argument("--device", help="ios: simulator UDID")
args = parser.parse_args()
if args.port in (4096, 4177, 4178, 4179):
    parser.error("Use an owned sandbox port")
if args.platform == "mac" and not args.app:
    parser.error("mac needs --app")
if args.platform == "ios" and not (args.derived and args.device):
    parser.error("ios needs --derived and --device")
args.evidence.mkdir(parents=True, exist_ok=True)

SERVER = f"http://127.0.0.1:{args.port}"
PASSWORD = (args.home / "password").read_text().strip()
AUTH = "Basic " + base64.b64encode(("opencode:" + PASSWORD).encode()).decode()
CONFIG = args.home / "config/opencode/opencode.json"
DIRECTORY = args.home / "repos/read-visibility"
PROVIDER = "fakeread"
MODEL = {"providerID": PROVIDER, "id": "ok"}


class FakeModel(http.server.BaseHTTPRequestHandler):
    """An OpenAI-compatible endpoint that streams "ok" after a short pause."""

    def do_GET(self):
        self.reply("application/json", json.dumps({"data": [{"id": "ok", "object": "model"}]}))

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        time.sleep(1.5)
        base = {"id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": 0, "model": "ok"}
        chunks = [{**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": "ok"}, "finish_reason": None}]},
            {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}]
        self.reply("text/event-stream", "".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks) + "data: [DONE]\n\n")

    def reply(self, kind, text):
        body = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def call(path, body=None, method=None):
    request = urllib.request.Request(SERVER + path, data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": AUTH, "Content-Type": "application/json"},
        method=method or ("GET" if body is None else "POST"))
    data = urllib.request.urlopen(request, timeout=60).read()
    return json.loads(data) if data else None


def create(title):
    sid = "ses_" + uuid.uuid4().hex
    now = int(time.time() * 1000) - 60_000
    call("/api/experimental/session/import", {"info": {"id": sid, "title": title, "projectID": "global",
        "location": {"directory": str(DIRECTORY)}, "agent": "build", "model": MODEL, "cost": 0,
        "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}, "outcome": "succeeded",
        "time": {"created": now, "updated": now, "idle": now, "viewed": now}}, "location": {"directory": str(DIRECTORY)},
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "oi", "time": {"created": now - 10}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": MODEL,
             "time": {"created": now - 5, "completed": now}, "finish": "stop", "content": [{"type": "text", "text": "olá"}]}]})
    owned.append(sid)
    call("/api/session/" + sid + "/agent", {"agent": "build"})
    call("/api/session/" + sid + "/model", {"model": MODEL})
    return sid


def pin(sid, pinned):
    call("/api/rpc/custom.preferences/mutate", {"input": {"type": "sidebar.pin", "session": "local:" + sid, "pinned": pinned}})


def times(sid):
    return call("/api/session/" + sid)["data"]["time"]


def read(sid):
    time_ = times(sid)
    return time_.get("idle") is not None and time_.get("idle") == time_.get("viewed")


def answer(*ids):
    before = {sid: times(sid).get("idle") or 0 for sid in ids}
    for sid in ids:
        call("/api/session/" + sid + "/prompt", {"text": "Responda apenas: ok", "agent": "build", "model": MODEL})
    deadline = time.time() + 90
    while time.time() < deadline:
        active = call("/api/session/active")["data"]
        if all(sid not in active and (times(sid).get("idle") or 0) > before[sid] for sid in ids):
            return
        time.sleep(0.25)
    raise SystemExit("The fake answers did not finish")


def expect(step, wanted):
    """Read answers are acknowledged within 10 s; unread ones are judged after 3 s without acknowledgement."""
    deadline = time.time() + (10 if any(wanted.values()) else 3)
    while True:
        actual = {name: read(sid) for name, sid in wanted_ids(wanted)}
        if actual == wanted or time.time() > deadline:
            break
        time.sleep(0.25)
    if not any(wanted.values()):
        time.sleep(max(0, deadline - time.time()))
        actual = {name: read(sid) for name, sid in wanted_ids(wanted)}
    ok = actual == wanted
    results.append({"step": step, "ok": ok, "expected": wanted, "actual": actual})
    print(("ok   " if ok else "FAIL ") + step + " " + json.dumps(actual), flush=True)


def wanted_ids(wanted):
    return [(name, sessions[name]) for name in wanted]


def run_mac():
    bundle = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    if bundle in ("br.com.alexandrem.opencode.mac", "br.com.alexandrem.opencode.mac.debug"):
        raise SystemExit("Use a test copy with its own bundle identifier")
    sessions.update({"A_fixada_aberta": create("Leitura A fixada aberta"), "B_comum_fechada": create("Leitura B comum"),
        "C_fixada_fechada": create("Leitura C fixada fechada"), "D_segunda_janela": create("Leitura D segunda janela")})
    pin(sessions["A_fixada_aberta"], True)
    pin(sessions["C_fixada_fechada"], True)
    a, d = sessions["A_fixada_aberta"], sessions["D_segunda_janela"]

    def tell(command):
        script = ("ObjC.import('Foundation'); $.NSDistributedNotificationCenter.defaultCenter"
            f".postNotificationNameObjectUserInfoDeliverImmediately($('{bundle}.read-check'), $('{command}'), $(), true)")
        subprocess.run(["osascript", "-l", "JavaScript", "-e", script], check=True, capture_output=True, timeout=30)
        time.sleep(1)

    binary = args.app / "Contents/MacOS/OpenCodeMac"
    # A fresh copy: no window restored from an earlier run.
    subprocess.run(["defaults", "delete", bundle], capture_output=True)
    subprocess.run(["rm", "-rf", str(Path.home() / f"Library/Saved Application State/{bundle}.savedState")])
    output = args.evidence / "mac.out"
    # In the background (`open -g`): the copy never takes the focus.
    subprocess.run(["open", "-g", "-n", "-a", str(args.app), "--env", "OPENCODE_SERVER_PASSWORD=" + PASSWORD,
        "--stdout", str(output), "--stderr", str(output), "--args", "-OpenCodeServerURL", SERVER,
        "-OpenCodeTheme", "openchamber-dark", "-OpenCodeMacSession", a, "-OpenCodeMacReadCheck"], check=True)
    try:
        deadline = time.time() + 40
        while " readable true " not in (output.read_text() if output.exists() else ""):
            if time.time() > deadline:
                raise SystemExit("The copy did not open its window")
            time.sleep(0.5)
        # The session is selected once the list has loaded (`-OpenCodeMacSession`).
        time.sleep(5)
        closed = {"B_comum_fechada": False, "C_fixada_fechada": False}

        answer(a)
        expect("visível e ativa: resposta lida", {"A_fixada_aberta": True})
        answer(a)
        expect("nova resposta enquanto visível: lida", {"A_fixada_aberta": True})

        tell("hidden:1")
        tell("active:0")
        answer(a, sessions["B_comum_fechada"], sessions["C_fixada_fechada"])
        expect("app oculto: fixada aberta, comum e fixada fechadas não lidas", {"A_fixada_aberta": False, **closed})
        tell("hidden:0")
        tell("active:1")
        expect("volta ao app: só a aberta é lida", {"A_fixada_aberta": True, **closed})

        tell("active:0")
        answer(a)
        expect("outro app em foco: não lida", {"A_fixada_aberta": False})
        tell("active:1")
        expect("app em foco de novo: lida", {"A_fixada_aberta": True})

        tell(f"minimized:{a}:1")
        answer(a)
        expect("janela minimizada: não lida", {"A_fixada_aberta": False})
        tell(f"minimized:{a}:0")
        expect("janela restaurada: lida", {"A_fixada_aberta": True})

        for state, label in [("asleep", "telas apagadas"), ("locked", "tela bloqueada"), ("switchedOut", "outra sessão do sistema")]:
            tell(state + ":1")
            answer(a)
            expect(f"{label}: não lida", {"A_fixada_aberta": False})
            tell(state + ":0")
            expect(f"{label} terminou: lida", {"A_fixada_aberta": True})

        tell("window:" + d)
        deadline = time.time() + 30
        while f"MacRead {d} readable true" not in output.read_text():
            if time.time() > deadline:
                raise SystemExit("The second window did not show its session")
            time.sleep(0.5)
        tell(f"minimized:{a}:1")
        answer(a, d)
        expect("duas janelas: a minimizada não lê, a visível lê a sua", {"A_fixada_aberta": False, "D_segunda_janela": True})
        tell(f"minimized:{a}:0")
        expect("duas janelas: a restaurada lê a sua", {"A_fixada_aberta": True, "D_segunda_janela": True})
        tell(f"minimized:{d}:1")
        answer(a, d)
        expect("duas janelas: a outra minimizada não invalida a visível", {"A_fixada_aberta": True, "D_segunda_janela": False})
        expect("fechadas continuam não lidas", closed)
    finally:
        subprocess.run(["pkill", "-f", str(binary)], check=False)
        (args.evidence / "mac-trace.txt").write_text(
            "".join(line for line in output.read_text().splitlines(keepends=True) if line.startswith("MacRead"))
            if output.exists() else "")


def run_ios():
    sessions["A_aberta_no_iphone"] = create("Leitura iPhone")
    environment = args.evidence / "read-environment.json"
    environment.write_text(json.dumps({"OPENCODE_READ_SESSION": sessions["A_aberta_no_iphone"],
        "OPENCODE_READ_PROVIDER": MODEL["providerID"], "OPENCODE_READ_MODEL": MODEL["id"]}))
    environment.chmod(0o600)
    status = subprocess.call([sys.executable, str(Path(__file__).with_name("test-isolated.py")), "--device", args.device,
        "--derived", str(args.derived), "--evidence", str(args.evidence), "--label", "read-visibility",
        "--home", str(args.home), "--server-url", SERVER, "--environment", str(environment),
        "OpenCodeUITests/ReadVisibilityTests"])
    results.append({"step": "OpenCodeUITests/ReadVisibilityTests", "ok": status == 0})
    print(("ok   " if status == 0 else "FAIL ") + "OpenCodeUITests/ReadVisibilityTests", flush=True)


owned = []
sessions = {}
results = []
original = CONFIG.read_text()
model = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeModel)
threading.Thread(target=model.serve_forever, daemon=True).start()
try:
    config = json.loads(original)
    config.setdefault("providers", {})[PROVIDER] = {"name": "Leitura (falso, local)",
        "package": "@opencode/ai/providers/openai-compatible",
        "settings": {"baseURL": f"http://127.0.0.1:{model.server_address[1]}/v1"},
        "models": {"ok": {"name": "Ok", "capabilities": {"tools": True, "input": ["text"], "output": ["text"]},
            "limit": {"context": 65536, "output": 4096}}}}
    CONFIG.write_text(json.dumps(config, indent=1))
    time.sleep(3)
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    run_mac() if args.platform == "mac" else run_ios()
finally:
    for sid in owned:
        try:
            pin(sid, False)
            call("/api/session/" + sid + "/interrupt", {})
            call("/api/session/" + sid, method="DELETE")
        except Exception as error:
            print("cleanup", sid, error)
    CONFIG.write_text(original)
    model.shutdown()
    (args.evidence / f"{args.platform}-results.json").write_text(json.dumps(results, indent=1, ensure_ascii=False))
failed = [result["step"] for result in results if not result["ok"]]
print("READ VISIBILITY", "FAIL " + ", ".join(failed) if failed else "ok")
sys.exit(1 if failed or not results else 0)

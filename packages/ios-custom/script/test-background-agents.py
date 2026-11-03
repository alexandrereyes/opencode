#!/usr/bin/env python3
"""A finished subagent whose shells still run, against an owned sandbox started with
`bun packages/cli/script/custom-sandbox.ts up --port <port> --home <home>`, then `OpenCodeUITests/BackgroundAgentsTests`
on the given simulator. A local fake model answers "ok", or asks for one background `sleep` when a prompt carries
`BG:<seconds>`, so no real model is called and the only processes are those sleeps.

    python3 packages/ios-custom/script/test-background-agents.py --home <home> --port <port> \\
        --derived <DerivedData> --device <simulator UDID> --evidence <dir>

It imports a root with eight finished children: `c0` runs one background sleep itself, `c1` has a child in another
folder (another worktree) that runs a longer one, and six more answer after them, so by their last run `c0` and
`c1` would sit behind "+N concluídos". It answers the shell permissions of its own sessions if the sandbox asks,
registers the fake model in the sandbox's config, and removes the sessions, the model and the config entry afterwards.
"""
import argparse
import base64
import http.server
import json
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--home", type=Path, required=True)
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--device", required=True)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--seconds", type=int, default=150, help="c0's sleep; the grandchild's lasts 40 s longer")
args = parser.parse_args()
if args.port in (4096, 4177, 4178, 4179):
    parser.error("Use an owned sandbox port")
args.evidence.mkdir(parents=True, exist_ok=True)

SERVER = f"http://127.0.0.1:{args.port}"
PASSWORD = (args.home / "password").read_text().strip()
AUTH = "Basic " + base64.b64encode(("opencode:" + PASSWORD).encode()).decode()
CONFIG = args.home / "config/opencode/opencode.json"
DIRECTORY = args.home / "repos/background-agents"
OTHER = args.home / "repos/background-agents-other"
PROVIDER = "fakebackground"
MODEL = {"providerID": PROVIDER, "id": "ok"}


def text(message):
    content = message.get("content")
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content if isinstance(part, dict))
    return content or ""


class FakeModel(http.server.BaseHTTPRequestHandler):
    """OpenAI-compatible: a background `sleep` for a `BG:<seconds>` prompt, otherwise "ok"."""

    def do_GET(self):
        self.reply("application/json", json.dumps({"data": [{"id": "ok", "object": "model"}]}))

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        messages = body.get("messages") or []
        last = messages[-1] if messages else {}
        marker = re.search(r"BG:(\d+)", text(last)) if last.get("role") == "user" else None
        tools = [tool["function"]["name"] for tool in body.get("tools") or [] if tool.get("type") == "function"]
        shell = "shell" if "shell" in tools else next((name for name in tools if "shell" in name), None)
        base = {"id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": 0, "model": "ok"}
        if marker and shell:
            arguments = json.dumps({"command": f"sleep {marker.group(1)}", "background": True})
            chunks = [{**base, "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [{"index": 0,
                    "id": "call_" + uuid.uuid4().hex[:12], "type": "function", "function": {"name": shell, "arguments": ""}}]},
                    "finish_reason": None}]},
                {**base, "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": arguments}}]},
                    "finish_reason": None}]},
                {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}]
        else:
            time.sleep(0.5)
            chunks = [{**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": "ok"}, "finish_reason": None}]},
                {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}]
        self.reply("text/event-stream", "".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks) + "data: [DONE]\n\n")

    def reply(self, kind, text_):
        data = text_.encode()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def call(path, body=None, method=None):
    request = urllib.request.Request(SERVER + path, data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": AUTH, "Content-Type": "application/json"},
        method=method or ("GET" if body is None else "POST"))
    data = urllib.request.urlopen(request, timeout=60).read()
    return json.loads(data) if data else None


def create(title, parent=None, directory=DIRECTORY, offset=0):
    sid = "ses_" + uuid.uuid4().hex
    now = int(time.time() * 1000) - 600_000 + offset
    info = {"id": sid, "title": title, "projectID": "global", "location": {"directory": str(directory)}, "agent": "build",
        "model": MODEL, "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}}
    if parent:
        info["parentID"] = parent
    call("/api/experimental/session/import", {"info": info, "location": {"directory": str(directory)},
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "oi", "time": {"created": now - 10}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": MODEL,
             "time": {"created": now - 5, "completed": now}, "finish": "stop", "content": [{"type": "text", "text": "olá"}]}]})
    owned.append(sid)
    call("/api/session/" + sid + "/model", {"model": MODEL})
    return sid


def prompt(sid, text_):
    call("/api/session/" + sid + "/prompt", {"text": text_, "agent": "build", "model": MODEL})


def background(sid):
    rows = call("/api/rpc/custom.navigation/list", {"input": {"sessionID": sid, "limit": 5}})["output"]["data"]
    return next((row.get("backgroundCount") or 0 for row in rows if row["session"]["id"] == sid), 0)


def settle(ids, until, label, timeout=90):
    """Answers the sandbox's shell permissions of `ids` while waiting for `until()`."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for permission in call("/api/rpc/custom.requests/permissions", {"input": {}})["output"]:
            if permission["sessionID"] in ids:
                call(f"/api/session/{permission['sessionID']}/permission/{permission['id']}/reply", {"decision": "once"})
        if until():
            return
        time.sleep(0.5)
    raise SystemExit("Timed out: " + label)


def idle(ids):
    active = call("/api/session/active")["data"]
    return all(sid not in active for sid in ids)


owned = []
original = CONFIG.read_text()
model = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeModel)
threading.Thread(target=model.serve_forever, daemon=True).start()
status = 1
try:
    config = json.loads(original)
    config.setdefault("providers", {})[PROVIDER] = {"name": "Segundo plano (falso, local)",
        "package": "@opencode/ai/providers/openai-compatible",
        "settings": {"baseURL": f"http://127.0.0.1:{model.server_address[1]}/v1"},
        "models": {"ok": {"name": "Ok", "capabilities": {"tools": True, "input": ["text"], "output": ["text"]},
            "limit": {"context": 65536, "output": 4096}}}}
    CONFIG.write_text(json.dumps(config, indent=1))
    time.sleep(3)
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    OTHER.mkdir(parents=True, exist_ok=True)
    root = create("Fundo: raiz")
    c0 = create("Fundo: filho com script", root, offset=1_000)
    c1 = create("Fundo: filho com neto noutra pasta", root, offset=2_000)
    g1 = create("Fundo: neto noutra worktree", c1, OTHER, offset=3_000)
    rest = [create(f"Fundo: concluído {index}", root, offset=4_000 + index) for index in range(1, 7)]

    started = time.time()
    prompt(c0, f"BG:{args.seconds}")
    prompt(g1, f"BG:{args.seconds + 40}")
    settle({c0, g1}, lambda: background(c0) == 1 and background(g1) == 1 and idle([c0, g1]), "background shells")
    c0_ends, c1_ends = (started + args.seconds) * 1000, (started + args.seconds + 40) * 1000
    for sid in rest:
        prompt(sid, "oi")
    settle(set(rest), lambda: idle(rest), "finished children")
    print("root", root, "c0", c0, "c1", c1, "g1", g1, flush=True)

    environment = args.evidence / "background-environment.json"
    environment.write_text(json.dumps({"OPENCODE_BG_ROOT": root, "OPENCODE_BG_C0": c0, "OPENCODE_BG_C1": c1,
        "OPENCODE_BG_C0_ENDS": str(int(c0_ends)), "OPENCODE_BG_C1_ENDS": str(int(c1_ends))}))
    environment.chmod(0o600)
    status = subprocess.call([sys.executable, str(Path(__file__).with_name("test-isolated.py")), "--device", args.device,
        "--derived", str(args.derived), "--evidence", str(args.evidence), "--label", "background-agents",
        "--home", str(args.home), "--server-url", SERVER, "--environment", str(environment),
        "OpenCodeUITests/BackgroundAgentsTests"])
    # The sleeps end on their own; wait for them so nothing of this run outlives it.
    settle(set(owned), lambda: background(c0) == 0 and background(g1) == 0 and idle(owned), "shells ended",
        timeout=max(60, (c1_ends / 1000) - time.time() + 60))
finally:
    for sid in reversed(owned):
        try:
            call("/api/session/" + sid + "/interrupt", {})
            call("/api/session/" + sid, method="DELETE")
        except Exception as error:
            print("cleanup", sid, error)
    CONFIG.write_text(original)
    model.shutdown()
print("BACKGROUND AGENTS", "ok" if status == 0 else "FAIL")
sys.exit(status)

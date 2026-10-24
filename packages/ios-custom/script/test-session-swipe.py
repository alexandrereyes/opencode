#!/usr/bin/env python3
"""Swipe pin/unpin: imports two owned sessions (no model calls), runs SessionSwipeTests and deletes them."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True)
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--evidence", type=Path, default=temporary / "ios-swipe-prints")
parser.add_argument("--server-url", default="http://127.0.0.1:4177")
parser.add_argument("--home", type=Path, default=temporary / "custom-sandbox-4177")
parser.add_argument("--theme", default=os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark"))
parser.add_argument("--label", default="swipe")
args = parser.parse_args()
password = (args.home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}


def api(path, body=None, method="GET"):
    request = urllib.request.Request(args.server_url + path, headers=headers,
        data=json.dumps(body).encode() if body is not None else None, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None


def rpc(name, method, body):
    return api("/api/rpc/" + name + "/" + method, {"input": body}, "POST")["output"]


token = uuid.uuid4().hex[:10]
args.evidence.mkdir(parents=True, exist_ok=True)
environment = args.evidence / ("environment-" + token + ".json")
owned = []
try:
    repo = args.home / "repos" / ("ios-swipe-" + token)
    repo.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=OpenCode Test", "-c", "user.email=test@example.invalid",
        "commit", "--allow-empty", "-qm", "Owned swipe fixture"], check=True)
    now = int(time.time() * 1000)
    ids = {}
    # The anchor is newer, both by its times and by import order, so the unpinned target sits right below it.
    for role, title, at in [("TARGET", "Deslize — fixar", now - 60_000), ("ANCHOR", "Deslize — âncora", now)]:
        session = "ses_" + uuid.uuid4().hex
        owned.append(session)
        ids["OPENCODE_SWIPE_" + role] = session
        api("/api/experimental/session/import", {
            "info": {"id": session, "title": title, "projectID": "global", "location": {"directory": str(repo)},
                "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                "outcome": "succeeded", "time": {"created": at, "updated": at, "idle": at, "viewed": at}},
            "location": {"directory": str(repo)}, "messages": [
                {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Teste isolado do deslize.", "time": {"created": at - 1000}},
                {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build",
                 "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                 "time": {"created": at - 900, "completed": at - 800}, "finish": "stop",
                 "content": [{"type": "text", "text": "Histórico sintético."}]}]}, "POST")
        time.sleep(1)
    environment.write_text(json.dumps(ids))
    environment.chmod(0o600)
    status = subprocess.call([sys.executable, str(Path(__file__).with_name("test-isolated.py")), "--device", args.device,
        "--derived", str(args.derived), "--evidence", str(args.evidence), "--label", args.label, "--theme", args.theme,
        "--server-url", args.server_url, "--home", str(args.home), "--environment", str(environment),
        "OpenCodeUITests/SessionSwipeTests"])
    sys.exit(status)
finally:
    environment.unlink(missing_ok=True)
    prefs = rpc("custom.preferences", "get", {})["data"]
    for key in prefs.get("pinnedSessions", []):
        if any(session in key for session in owned):
            rpc("custom.preferences", "mutate", {"type": "sidebar.pin", "session": key, "pinned": False})
    for session in owned:
        api("/api/session/" + session, method="DELETE")

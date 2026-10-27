#!/usr/bin/env python3
"""SessionChipsTests on an owned sandbox seeded by seed-sessions.ts; never 4096/4178.

Interrupts every live execution of the owned sandbox (so no chip is running and seeded requests are dropped), marks
every root session read, completes one tiny Luna 6 / low prompt in a seeded session of the second and third saved
repositories so exactly those chips are unread, prepares a session of the fourth to run briefly during the test, and
runs the UI case through test-isolated.py. Run other Sessões UI tests that need seeded requests before this one.

  python3 packages/ios-custom/script/test-session-chips.py --url http://127.0.0.1:4188 --home <sandbox-home> \\
    --device <simulator-udid> --derived <derived-data> --evidence <dir> [--theme openchamber-light]
"""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--url", required=True)
parser.add_argument("--home", type=Path, required=True)
parser.add_argument("--device", required=True)
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--theme", default="openchamber-dark")
args = parser.parse_args()
url = urllib.parse.urlparse(args.url)
if url.hostname not in ("127.0.0.1", "localhost") or url.port in (None, 4096, 4178):
    parser.error("Use an isolated loopback sandbox, never 4096/4178")
owner = json.loads((args.home / "sandbox.json").read_text())
if Path(owner["home"]).resolve() != args.home.resolve() or owner["port"] != url.port:
    parser.error("Sandbox home/port do not match its ownership record")
password = (args.home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
    "Content-Type": "application/json"}

def api(path, body=None):
    request = urllib.request.Request(args.url + path, data=None if body is None else json.dumps(body).encode(),
        headers=headers, method="GET" if body is None else "POST")
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
        return json.loads(data) if data else None

def rpc(name, method, payload):
    return api("/api/rpc/" + name + "/" + method, {"input": payload})["output"]

def roots():
    return [row["session"] for row in rpc("custom.navigation", "list", {"limit": 500})["data"]
        if not row["session"].get("parentID") and not row["session"]["time"].get("archived")]

def read_all():
    for session in roots():
        idle = session["time"].get("idle")
        if idle and idle > (session["time"].get("viewed") or 0):
            api("/api/session/" + session["id"] + "/view", {"idle": idle})

def settle_active():
    deadline = time.monotonic() + 120
    while api("/api/session/active")["data"]:
        if time.monotonic() > deadline:
            raise SystemExit("Live executions did not stop")
        for session in api("/api/session/active")["data"]:
            try:
                api("/api/session/" + session + "/interrupt", {})
            except urllib.error.HTTPError:
                pass
        time.sleep(1)

manual = [Path(item["worktree"]).name
    for item in rpc("custom.preferences", "get", {})["data"]["projects"]["local"]["projects"]]
unread = manual[1:3]
assert len(manual) >= 4, "Needs at least four saved repositories (seed-sessions.ts, seed-conversation.ts)"
settle_active()
read_all()
active = set()
targets = {}
for name in unread:
    root = str(args.home / "repos" / name)
    targets[name] = next(s for s in sorted(roots(), key=lambda s: s["title"])
        if s["location"]["directory"].startswith(root) and s["id"] not in active and s.get("outcome") == "succeeded")
run_root = str(args.home / "repos" / manual[3])
run = next(s for s in sorted(roots(), key=lambda s: s["title"])
    if s["location"]["directory"].startswith(run_root) and s.get("outcome") == "succeeded")
for target in [*targets.values(), run]:
    api("/api/session/" + target["id"] + "/agent", {"agent": "build"})
    api("/api/session/" + target["id"] + "/model", {"model": {"id": "gpt-6-luna", "providerID": "llm-proxy", "variant": "low"}})
    if target is not run:
        api("/api/session/" + target["id"] + "/prompt", {"text": "Responda apenas: ok"})
deadline = time.monotonic() + 300
while time.monotonic() < deadline:
    state = {s["id"]: s for s in roots()}
    if all((state[t["id"]]["time"].get("idle") or 0) > (state[t["id"]]["time"].get("viewed") or 0)
        and state[t["id"]].get("outcome") == "succeeded" and t["id"] not in api("/api/session/active")["data"]
        for t in targets.values()):
        break
    time.sleep(1)
else:
    raise SystemExit("The two prompts did not complete")
environment = args.evidence / "chips-environment.json"
args.evidence.mkdir(parents=True, exist_ok=True)
environment.write_text(json.dumps({"OPENCODE_TEST_CHIP_MANUAL": ",".join(manual),
    "OPENCODE_TEST_CHIP_UNREAD": ",".join(unread), "OPENCODE_TEST_CHIP_SESSION": targets[unread[1]]["title"],
    "OPENCODE_TEST_CHIP_RUN_PROJECT": manual[3], "OPENCODE_TEST_CHIP_RUN_SESSION": run["id"]}))
environment.chmod(0o600)
status = subprocess.call(["python3", str(Path(__file__).with_name("test-isolated.py")), "--device", args.device,
    "--derived", str(args.derived), "--evidence", str(args.evidence), "--label", "chips-" + args.theme,
    "--theme", args.theme, "--server-url", args.url, "--home", str(args.home), "--environment", str(environment),
    "OpenCodeUITests/SessionChipsTests"])
environment.unlink()
raise SystemExit(status)

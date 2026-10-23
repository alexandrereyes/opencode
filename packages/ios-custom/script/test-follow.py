#!/usr/bin/env python3
"""Dedicated Follow simulator; explicit sandbox launch credentials, no seed writes."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--label", required=True)
parser.add_argument("--live", action="store_true")
parser.add_argument("--parent", default="ses_e9aace23cffe0TUb3AnRAXkjOe")
parser.add_argument("--child-a", default="ses_e9aacd950ffeBx53GFRsZehrRS")
parser.add_argument("--child-b", default="ses_e9aaccfc1ffeZOyb8ec0mqlcT2")
parser.add_argument("--regressions", action="store_true", help="Import and remove owned action/missing-directory histories")
parser.add_argument("tests", nargs="*")
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
home = temporary / "custom-sandbox-4177"
products = temporary / "ios-follow-derived/Build/Products"
evidence = temporary / "ios-follow-prints"
evidence.mkdir(exist_ok=True)
device = "8291AAB6-DF26-4128-BE44-A459BAD14186"
password = (home / "password").read_text().strip()
run = plistlib.loads(next(products.glob("OpenCode_*.xctestrun")).read_bytes())
manifest = json.loads((home / "seed-conversation.json").read_text())
owned = []
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}

def api(path, body=None, method="POST"):
    request = urllib.request.Request("http://127.0.0.1:4177" + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

def create(role, directory):
    session = "ses_" + uuid.uuid4().hex
    now = int(time.time() * 1000)
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    api("/api/experimental/session/import", {"info": {"id": session, "title": "Follow — " + role,
        "projectID": "global", "location": {"directory": directory}, "agent": "build", "model": model,
        "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": directory}, "messages": [
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "time": {"created": now - 1000}, "text": "Verificação isolada."},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "time": {"created": now - 500, "completed": now},
                "agent": "build", "model": model, "finish": "stop", "content": [{"type": "text", "text": "Histórico preservado para conferir os controles nativos."}]},
        ]})
    owned.append(session)
    return session

extra = {}
if args.live:
    extra["OPENCODE_FOLLOW_PARENT"] = args.parent
    for role, session_id in [("PARENT", args.parent), ("A", args.child_a), ("B", args.child_b)]:
        session = api("/api/session/" + session_id, method="GET")["data"]
        assert Path(session["location"]["directory"]).is_relative_to(home / "repos")
        assert session["model"] == {"id": "gpt-6-luna", "providerID": "llm-proxy", "variant": "low"}
        if role != "PARENT":
            assert session["parentID"] == args.parent
            extra["OPENCODE_FOLLOW_CHILD_" + role] = session_id
            extra["OPENCODE_FOLLOW_TITLE_" + role] = session["title"]
if args.regressions:
    directory = Path(manifest["directory"])
    assert directory.is_relative_to(home / "repos")
    extra["OPENCODE_TEST_SESSION_ACTIONS"] = create("ações", str(directory))
    missing = home / "repos" / ("ios-follow-missing-" + uuid.uuid4().hex)
    missing.mkdir()
    extra["OPENCODE_TEST_SESSION_MISSING"] = create("diretório ausente", str(missing))
    missing.rmdir()
targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
           if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
for target in targets:
    environment = target.setdefault("EnvironmentVariables", {})
    environment.update({"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
        "OPENCODE_TEST_THEME": os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark"),
        "OPENCODE_FOLLOW_LIVE": "1" if args.live else "0"})
    environment.update(extra)
    for key, role in [("A", "working"), ("B", "permission"), ("C", "history"), ("CHILD", "child-1")]:
        environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
    arguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
    target["CommandLineArguments"] = arguments
    target["UITargetAppCommandLineArguments"] = arguments
    target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
configured = products / ("Follow-" + args.label + ".xctestrun")
configured.write_bytes(plistlib.dumps(run))
configured.chmod(0o600)
root = Path(__file__).resolve().parents[1]
(evidence / (args.label + "-state.json")).write_text(json.dumps({
    "head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "binarySHA256": hashlib.sha256((products / "Debug-iphonesimulator/OpenCode.app/OpenCode.debug.dylib").read_bytes()).hexdigest(),
    "files": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob("*.swift")) if not any(part.startswith(".") for part in p.relative_to(root).parts)},
    "ownedSessions": owned,
}, indent=2) + "\n")
video = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo", str(evidence / (args.label + ".mp4"))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
logfile = (evidence / (args.label + "-follow.log")).open("w")
logs = subprocess.Popen(["xcrun", "simctl", "spawn", device, "log", "stream", "--level", "debug", "--style", "compact", "--predicate", 'eventMessage BEGINSWITH "FOLLOW"'], stdout=logfile, stderr=subprocess.STDOUT)
try:
    result = evidence / (args.label + ".xcresult")
    tests = args.tests or ["OpenCodeUITests/ConversationFollowTests"]
    with (evidence / (args.label + "-test.log")).open("w") as output:
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)] +
            ["-only-testing:" + test for test in tests], stdout=output, stderr=subprocess.STDOUT)
    subprocess.run(["xcrun", "xcresulttool", "export", "metrics", "--path", str(result),
        "--output-path", str(evidence / (args.label + "-metrics"))], check=True)
    summary = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)])
    (evidence / (args.label + "-summary.json")).write_bytes(summary)
    print(args.label, "status", status, flush=True)
    raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    video.send_signal(signal.SIGINT)
    video.wait(timeout=30)
    logs.terminate()
    logs.wait(timeout=30)
    logfile.close()
    subprocess.run(["xcrun", "simctl", "terminate", device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for session in owned:
        api("/api/session/" + session, method="DELETE")

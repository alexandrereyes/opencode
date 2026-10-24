#!/usr/bin/env python3
"""Pending-steer bubble checks: owned imports in an isolated sandbox, explicit credentials.

`prepare --label L` imports three owned sessions into a fake repository; `test --label L` runs
OpenCodeUITests/PendingBubbleTests against them (one tiny real Luna-6/low delivery); `cleanup`
deletes every owned session of every label.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import urllib.request
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("command", choices=["prepare", "test", "cleanup"])
parser.add_argument("--label", default="dark")
parser.add_argument("--theme", default="openchamber-dark")
parser.add_argument("--port", type=int, default=4193)
parser.add_argument("--home", type=Path, default=temporary / "custom-sandbox-pending-4193")
parser.add_argument("--device", default=os.environ.get("OPENCODE_TEST_DEVICE", "FDB1B4E0-2C49-4642-AB8D-88AA57C38F9A"))
parser.add_argument("--derived", type=Path, default=temporary / "ios-pendente-derived")
parser.add_argument("--evidence", type=Path, default=temporary / "ios-pendente-prints")
parser.add_argument("--tag", default="", help="Suffix for this run's evidence names")
parser.add_argument("--env", action="append", default=[], help="Extra KEY=VALUE for the test target")
parser.add_argument("tests", nargs="*")
args = parser.parse_args()
assert args.port not in (4096, 4177, 4178), "Use an isolated sandbox port"
owner = json.loads((args.home / "sandbox.json").read_text())
assert owner["port"] == args.port and Path(owner["home"]) == args.home.resolve(), "Sandbox ownership mismatch"
url = f"http://127.0.0.1:{args.port}"
password = (args.home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
    "Content-Type": "application/json"}
args.evidence.mkdir(parents=True, exist_ok=True)
ledger = args.evidence / "owned-sessions.json"
owned = json.loads(ledger.read_text()) if ledger.exists() else {}

def api(path, body=None, method="POST"):
    request = urllib.request.Request(url + path, data=json.dumps(body).encode() if body is not None else None,
        headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

if args.command == "prepare":
    assert args.label not in owned, "Label already prepared"
    directory = args.home / "repos" / "pendente"
    directory.mkdir(parents=True, exist_ok=True)
    if not (directory / ".git").exists():
        subprocess.run(["git", "init", "-q", str(directory)], check=True)
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    now = int(time.time() * 1000)
    sessions = {}
    for role in ["WAIT", "START", "DELIVER", "OPTIMISTIC"]:
        session = "ses_" + uuid.uuid4().hex
        messages = [
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Pedido anterior já entregue.",
                "time": {"created": now - 2000}, "metadata": {}, "files": []},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
                "time": {"created": now - 1900, "completed": now - 1800}, "finish": "stop",
                "content": [{"type": "text", "text": "Resposta sintética anterior."}]},
        ]
        # A later idle marker strands every steer admitted afterwards, like an execution that ended without them.
        if role in ["WAIT", "DELIVER"]:
            messages.append({"id": "msg_" + uuid.uuid4().hex, "type": "idle", "outcome": "succeeded",
                "time": {"created": now + 3_600_000}})
        api("/api/experimental/session/import", {"info": {"id": session, "title": f"Pendente — {role} — {args.label}",
            "projectID": "global", "location": {"directory": str(directory)}, "agent": "build", "model": model,
            "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
            "location": {"directory": str(directory)}, "messages": messages})
        sessions[role] = session
        owned[args.label] = sessions
        ledger.write_text(json.dumps(owned, indent=2) + "\n")
    # A selected fake project with a root checkout and one worktree, for the new-session checks.
    project = args.home / "repos" / "projeto-pendente"
    worktree = args.home / "repos" / "projeto-pendente-worktrees" / "ramo-pendente"
    if not (project / ".git").exists():
        project.mkdir(parents=True)
        git = ["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "-C", str(project)]
        subprocess.run(["git", "init", "-q", "-b", "main", str(project)], check=True)
        (project / "README.md").write_text("Repositório fictício. Não faça trabalho real.\n")
        subprocess.run(git + ["add", "."], check=True)
        subprocess.run(git + ["commit", "-q", "-m", "Fixture"], check=True)
        subprocess.run(git + ["worktree", "add", "-q", "-b", "ramo-pendente", str(worktree)], check=True)
        api("/api/rpc/custom.preferences/mutate", {"input": {"type": "project.open", "server": "local", "directory": str(project)}})
    for role, directory in [("ORIGIN_ROOT", project), ("ORIGIN_WORKTREE", worktree)]:
        session = "ses_" + uuid.uuid4().hex
        api("/api/experimental/session/import", {"info": {"id": session, "title": f"Origem — {role} — {args.label}",
            "projectID": "global", "location": {"directory": str(directory)}, "agent": "build", "model": model,
            "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
            "location": {"directory": str(directory)}, "messages": [
                {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Origem do menu.", "time": {"created": now - 2000}},
                {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
                    "time": {"created": now - 1900, "completed": now - 1800}, "finish": "stop",
                    "content": [{"type": "text", "text": "Origem sintética."}]}]})
        sessions[role] = session
        owned[args.label] = sessions
        ledger.write_text(json.dumps(owned, indent=2) + "\n")
    print(json.dumps(sessions))
    raise SystemExit()

if args.command == "cleanup":
    for label, sessions in owned.items():
        for session in sessions.values():
            api("/api/session/" + session, method="DELETE")
    ledger.rename(args.evidence / "removed-sessions.json")
    print("Removed", sum(len(s) for s in owned.values()), "owned sessions")
    raise SystemExit()

products = args.derived / "Build/Products"
run = plistlib.loads(next(products.glob("OpenCode_*.xctestrun")).read_bytes())
targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
    if "TestConfigurations" in run else [value for key, value in run.items() if key != "__xctestrun_metadata__"])
for target in targets:
    environment = target.setdefault("EnvironmentVariables", {})
    environment.update({"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
        "OPENCODE_TEST_SERVER_URL": url, "OPENCODE_TEST_THEME": args.theme,
        "OPENCODE_TEST_PROMPT_DELAY": os.environ.get("OPENCODE_TEST_PROMPT_DELAY", "5000")})
    for role, session in owned[args.label].items():
        environment["OPENCODE_TEST_PENDING_" + role] = session
    environment["OPENCODE_TEST_PENDING_PROJECT"] = "projeto-pendente"
    # `@ROLE` names one of this label's owned sessions.
    environment.update({key: owned[args.label][value[1:]] if value.startswith("@") else value
        for key, value in (item.split("=", 1) for item in args.env)})
    arguments = ["-OpenCodeServerURL", url]
    target["CommandLineArguments"] = arguments
    target["UITargetAppCommandLineArguments"] = arguments
    target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
name = args.label + (("-" + args.tag) if args.tag else "")
configured = products / ("Pendente-" + name + ".xctestrun")
configured.write_bytes(plistlib.dumps(run))
configured.chmod(0o600)
try:
    result = args.evidence / (name + ".xcresult")
    with (args.evidence / (name + "-test.log")).open("w") as output:
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=" + args.device, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)] +
            ["-only-testing:" + test for test in (args.tests or ["OpenCodeUITests/PendingBubbleTests"])],
            stdout=output, stderr=subprocess.STDOUT)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
        "--output-path", str(args.evidence / (name + "-attachments"))], check=True)
    print(name, "status", status)
    raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "terminate", args.device, "br.com.alexandrem.opencode"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

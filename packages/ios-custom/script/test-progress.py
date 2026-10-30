#!/usr/bin/env python3
"""Progresso checks (rev. 2026-10-30): an owned import in an isolated sandbox, explicit credentials.

`prepare --label L` turns `experimental.todo` on in a fake repository's `.opencode/opencode.jsonc` (never in the
sandbox's global config) and imports one idle session whose transcript ends with a completed `todowrite`;
`test --label L --device <fresh simulator>` runs OpenCodeUITests/SessionProgressUITests against it (one tiny real
Luna-6/low run); `cleanup` deletes every owned session of every label.
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
parser.add_argument("--port", type=int, default=4214)
parser.add_argument("--home", type=Path, default=temporary / "session-progress/sandbox-4214")
parser.add_argument("--device", default=os.environ.get("OPENCODE_TEST_DEVICE"))
parser.add_argument("--derived", type=Path, default=temporary / "session-progress/derived-tests")
parser.add_argument("--evidence", type=Path, default=temporary / "session-progress/evidence")
args = parser.parse_args()
assert args.port not in (4096, 4177, 4178, 4179, 4192), "Use an isolated sandbox port"
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

# The plan of every Progresso fixture: three completed, one in progress, two pending and one cancelled.
plan = [
    {"content": "Ler o rastreador da Live Activity", "status": "completed"},
    {"content": "Somar o progresso do plano no plugin", "status": "completed"},
    {"content": "Adicionar a unidade todos ao contrato", "status": "completed"},
    {"content": "Atualizar a Live Activity e o relógio", "status": "in_progress"},
    {"content": "Rodar os testes do OpenCodeKit", "status": "pending"},
    {"content": "Capturar as telas no iPhone 14", "status": "pending"},
    {"content": "Migrar as fixtures antigas", "status": "cancelled"},
]

if args.command == "prepare":
    assert args.label not in owned, "Label already prepared"
    directory = args.home / "repos" / "progresso"
    (directory / ".opencode").mkdir(parents=True, exist_ok=True)
    if not (directory / ".git").exists():
        subprocess.run(["git", "init", "-q", str(directory)], check=True)
    # Sandbox only: the project document turns the Core todo tool on for this Location.
    (directory / ".opencode/opencode.jsonc").write_text('{ "experimental": { "todo": true } }\n')
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    now = int(time.time() * 1000)
    session = "ses_" + uuid.uuid4().hex
    api("/api/experimental/session/import", {"info": {"id": session, "title": f"Progresso — {args.label}",
        "projectID": "global", "location": {"directory": str(directory)}, "agent": "build", "model": model,
        "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": str(directory)}, "messages": [
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Planeje a Live Activity do Progresso.",
                "time": {"created": now - 3000}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
                "time": {"created": now - 2900, "completed": now - 1800}, "finish": "stop",
                "content": [
                    {"type": "tool", "id": "call_" + uuid.uuid4().hex, "name": "todowrite",
                        "state": {"status": "completed", "input": {"todos": plan},
                            "content": [{"type": "text", "text": "Todos updated"}], "metadata": {"todos": plan}},
                        "time": {"created": now - 2800, "ran": now - 2800, "completed": now - 2700}},
                    {"type": "text", "text": "Plano registrado; sigo na etapa da Live Activity."}]}]})
    owned[args.label] = session
    ledger.write_text(json.dumps(owned, indent=2) + "\n")
    print(session)
    raise SystemExit()

if args.command == "cleanup":
    for label, session in owned.items():
        api("/api/session/" + session, method="DELETE")
    ledger.rename(args.evidence / "removed-sessions.json")
    print("Removed", len(owned), "owned sessions")
    raise SystemExit()

assert args.device, "Pass --device with a freshly created simulator"
products = args.derived / "Build/Products"
run = plistlib.loads(next(products.glob("OpenCode_*.xctestrun")).read_bytes())
targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
    if "TestConfigurations" in run else [value for key, value in run.items() if key != "__xctestrun_metadata__"])
for target in targets:
    environment = target.setdefault("EnvironmentVariables", {})
    environment.update({"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
        "OPENCODE_TEST_SERVER_URL": url, "OPENCODE_TEST_THEME": args.theme,
        "OPENCODE_TEST_PROGRESS_SESSION": owned[args.label]})
    arguments = ["-OpenCodeServerURL", url]
    target["CommandLineArguments"] = arguments
    target["UITargetAppCommandLineArguments"] = arguments
    target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
configured = products / ("Progresso-" + args.label + ".xctestrun")
configured.write_bytes(plistlib.dumps(run))
configured.chmod(0o600)
try:
    result = args.evidence / (args.label + ".xcresult")
    with (args.evidence / (args.label + "-test.log")).open("w") as output:
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=" + args.device, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never", "-resultBundlePath", str(result),
            "-only-testing:OpenCodeUITests/SessionProgressUITests"], stdout=output, stderr=subprocess.STDOUT)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
        "--output-path", str(args.evidence / (args.label + "-attachments"))], check=True)
    print(args.label, "status", status)
    raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "terminate", args.device, "br.com.alexandrem.opencode"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

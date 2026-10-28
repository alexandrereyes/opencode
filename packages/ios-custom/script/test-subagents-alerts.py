#!/usr/bin/env python3
"""Sandbox-only wave 7 checks, real delegated child and live SSE alerts. Never touches seed requests."""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import urllib.request
import urllib.error
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--server-url", default="http://127.0.0.1:4177")
parser.add_argument("--home", type=Path, default=temporary / "custom-sandbox-4177")
parser.add_argument("--derived", type=Path, default=temporary / "ios-sessoes-derived")
parser.add_argument("--device", default="OpenCode Sessoes", help="Simulator name or UUID")
parser.add_argument("--evidence", type=Path, default=temporary / "ios-conversa-prints/onda7")
parser.add_argument("tests", nargs="*")
args = parser.parse_args()
port = int(args.server_url.rsplit(":", 1)[1].split("/")[0])
assert args.server_url.startswith(("http://127.0.0.1:", "http://localhost:")) and port not in (4096, 4178), "Use an isolated loopback sandbox"
home = args.home
derived = args.derived
lease = (temporary / ("ios-alerts-test-" + str(port) + ".lock")).open("a")
fcntl.flock(lease, fcntl.LOCK_EX)
password = (home / "password").read_text().strip()
directory = str(home / "repos/ios-conversation")
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
token = uuid.uuid4().hex
own = {}
created = []
children = []
configuration = derived / ("Build/Products/SubagentAlerts-" + token + ".xctestrun")
result = temporary / ("onda7-" + theme + "-" + token + ".xcresult")
evidence = args.evidence

def api(path, body=None, method="POST"):
    request = urllib.request.Request(args.server_url + path, data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            data = response.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        raise RuntimeError(str(error) + ": " + error.read().decode()) from error

def transcript(session):
    return api("/api/rpc/custom.transcript/list", {"input": {"sessionID": session, "limit": 200, "order": "asc"}})["output"]["data"]

def tools(session):
    return [part for message in transcript(session) for part in message.get("content", []) if part.get("name") == "subagent"]

try:
    now = int(time.time() * 1000)
    for role, title in [("PARENT", "sessão principal"), ("SUCCESS", "conclusão"), ("FAILURE", "falha"), ("PERMISSION", "permissão"), ("PERMISSION2", "outra permissão"), ("QUESTION", "pergunta"), ("MISSING", "diretório ausente"), ("ORCHESTRATOR", "orquestradora"), ("TASKS", "tarefa em segundo plano")]:
        session = "ses_" + uuid.uuid4().hex
        own[role] = session
        location = {"directory": directory + "/onda7-ausente-" + token if role == "MISSING" else directory}
        messages = [] if role != "MISSING" else [
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "O histórico continua disponível?", "time": {"created": now - 1000}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model, "time": {"created": now - 900, "completed": now - 800}, "finish": "stop", "content": [{"type": "text", "text": "Histórico preservado, mesmo sem o diretório original."}]}]
        api("/api/experimental/session/import", {"info": {"id": session, "title": "Onda 7 — " + title, "projectID": "global", "location": location,
            "agent": "onda7-agente-inexistente" if role == "FAILURE" else "build", "model": model,
            "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "permissions": [{"action": "*", "resource": "*", "effect": "allow"}] + ([{"action": "shell", "resource": "git push*", "effect": "ask"}] if role.startswith("PERMISSION") else []),
            "time": {"created": now, "updated": now}}, "location": location, "messages": messages})
        created.append(session)
    api("/api/session/" + own["PARENT"] + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "text": 'Chame a ferramenta subagent uma unica vez com agent="general", description="Conferir exemplo", model="llm-proxy/gpt-6-luna#low", prompt="Responda apenas: Exemplo conferido. Nao use ferramentas.", background=false. Depois responda apenas: Delegacao concluida.', "delivery": "steer"})
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        family = api("/api/rpc/custom.session-family/page", {"input": {"sessionID": own["PARENT"], "limit": 100}})["output"]["data"]
        children = [session["id"] for session in family]
        active = api("/api/session/active", method="GET")["data"]
        if children and not any(session in active for session in [own["PARENT"]] + children) and tools(own["PARENT"]):
            break
        time.sleep(0.5)
    assert children and not any(session in active for session in [own["PARENT"]] + children), "Delegation did not settle"
    own["CHILD"] = children[0]
    before = tools(own["PARENT"])
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_TEST_THEME": theme, "OPENCODE_TEST_SERVER_URL": args.server_url, **{"OPENCODE_TEST_" + role: session for role, session in own.items()}}
    targets = [target for c in run["TestConfigurations"] for target in c["TestTargets"]] if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"]
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["EnvironmentVariables"]["OPENCODE_SERVER_PASSWORD"] = password
        target["CommandLineArguments"] = ["-OpenCodeServerURL", args.server_url]
    configuration.write_bytes(plistlib.dumps(run))
    configuration.chmod(0o600)
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    device = next(d["udid"] for group in devices["devices"].values() for d in group if args.device in (d["name"], d["udid"]))
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configuration), "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "300", "-resultBundlePath", str(result)]
    for method in args.tests or ["OpenCodeUITests/SubagentAlertTests"]:
        command.append("-only-testing:" + method)
    status = subprocess.call(command)
    evidence.mkdir(parents=True, exist_ok=True)
    export = evidence / ("attachments-" + token)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(export)], check=True)
    for test in json.loads((export / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = export / attachment["exportedFileName"]
            if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                shutil.copyfile(source, evidence / (attachment["suggestedHumanReadableName"].split("_0_")[0].replace("openchamber-", "") + ".png"))
    after = tools(own["PARENT"])
    assert before == after, "Direct child send changed the parent's historical tool result"
    child = api("/api/session/" + own["CHILD"], method="GET")["data"]
    assert child["agent"] == "general"
    report = {"sessions": own, "parentToolUnchanged": before == after, "childAgent": child["agent"], "result": str(result), "status": status}
    (evidence / ("verification-" + theme + ".json")).write_text(json.dumps(report, indent=2))
    print(json.dumps(report))
    sys.exit(status)
finally:
    configuration.unlink(missing_ok=True)
    for role in ["ORCHESTRATOR", "TASKS"]:
        if role in own:
            children += [session["id"] for session in api("/api/rpc/custom.session-family/page", {"input": {"sessionID": own[role], "limit": 100}})["output"]["data"]]
    for session in dict.fromkeys([s for s in created if s != own.get("MISSING")] + children):
        api("/api/session/" + session + "/interrupt", {})
    deadline = time.monotonic() + 30
    while True:
        active = api("/api/session/active", method="GET")["data"]
        remaining = set(active).intersection(list(own.values()) + children)
        if not remaining or time.monotonic() >= deadline:
            break
        time.sleep(0.1)
    assert not remaining, "Owned executions left running: " + str(remaining)
    if "report" in locals():
        report["finalActive"] = []
        report["finalOutcomes"] = {role: api("/api/session/" + session, method="GET")["data"].get("outcome", "never executed") for role, session in own.items()}
        (evidence / ("verification-" + theme + ".json")).write_text(json.dumps(report, indent=2))
        (evidence / ("verification-" + theme + "-" + token + ".json")).write_text(json.dumps(report, indent=2))
    print("Wave 7 owned sessions interrupted/idle; no seed request consumed.")

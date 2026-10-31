#!/usr/bin/env python3
"""Subagent header and "Agentes e tarefas" with each subagent's Progresso (rev. 2026-10-30): UI test on an isolated
sandbox and a fresh simulator.

It owns a temporary git checkout with `experimental.todo` on (its own `.opencode/opencode.jsonc`, never the sandbox's
global config) and imports a finished parent with two children: "Etapa 1: confronto F12", which then really runs
(Luna 6 / low): it writes a Progresso of 2/4 with `todowrite` and sleeps through the shell tool; and "Etapa 2:
inventário F12", finished without subagents. The first child has its own subagents: "Revisar regras F12a",
finished, and "Conferir regras F12b", made running the same way. It waits until the plugin's family snapshot of the
parent carries the child's Progresso, then runs OpenCodeUITests/SubagentHeaderTests in one runner: the light
captures first, then the whole flow in the dark theme (which stops a grandchild). Running work is interrupted and the family deleted
afterwards. Run after `build-for-testing`:
  python3 packages/ios-custom/script/test-subagent-header.py --device <sim-udid> --derived <DerivedData> \\
    --home <sandbox-home> --server-url http://127.0.0.1:<port> --evidence <prints-dir>
"""
import argparse
import base64
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--device", required=True)
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--home", type=Path, required=True, help="custom-sandbox.ts home (reads its password file)")
parser.add_argument("--server-url", required=True)
parser.add_argument("--evidence", type=Path, required=True)
args = parser.parse_args()
port = int(args.server_url.rsplit(":", 1)[1].rstrip("/"))
if port in (4096, 4177, 4178, 4179) or not args.server_url.startswith(("http://127.0.0.1:", "http://localhost:")):
    parser.error("Use an isolated loopback sandbox, never 4096, 4177, 4178 or 4179")
owner = json.loads((args.home / "sandbox.json").read_text())
assert owner["port"] == port and Path(owner["home"]) == args.home.resolve(), "Sandbox ownership mismatch"

password = (args.home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
    "Content-Type": "application/json"}
def api(path, body=None, method="POST"):
    request = urllib.request.Request(args.server_url + path, data=json.dumps(body).encode() if body is not None else None,
        headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        raise SystemExit("%s %s: %s" % (method, path, error.read().decode()[:400]))
def rpc(name, payload):
    # Right after a new Location boots, the plugin's RPCs can briefly report themselves unavailable.
    deadline = time.time() + 60
    while True:
        try:
            return api("/api/rpc/" + name, {"input": payload})["output"]
        except SystemExit as error:
            if "rpc.unavailable" not in str(error) or time.time() > deadline:
                raise
            time.sleep(1)
def active():
    return api("/api/session/active", method="GET")["data"]

token = uuid.uuid4().hex[:10]
fixture = Path(tempfile.mkdtemp(prefix="ios-subagent-header-" + token + "-")).resolve()
root = fixture / "repo"
args.evidence.mkdir(parents=True, exist_ok=True)
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
query = "location%5Bdirectory%5D=" + urllib.parse.quote(str(root), safe="")
owned = []
def imported(title, minutes_ago, parent_id=None, agent="general", lasted=2):
    now = int(time.time() * 1000)
    created = now - minutes_ago * 60_000
    idle = created + lasted * 60_000
    session = "ses_" + uuid.uuid4().hex
    info = {"id": session, "title": title, "projectID": "global", "location": {"directory": str(root)}, "agent": agent,
        "model": model, "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": "succeeded", "time": {"created": created, "updated": idle, "idle": idle, "viewed": idle}}
    if parent_id:
        info["parentID"] = parent_id
    api("/api/experimental/session/import", {"info": info, "location": {"directory": str(root)},
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": title + ".", "time": {"created": created}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": agent, "model": model,
             "time": {"created": created + 1000, "completed": idle}, "finish": "stop", "content": [{"type": "text", "text": "Pronto."}]}]})
    owned.append(session)
    return session
def sleeping(session):
    return any(shell["status"] == "running" and (shell.get("metadata") or {}).get("sessionID") == session
        for shell in api("/api/shell?" + query, method="GET")["data"])
def run_tests(environment):
    run = plistlib.loads(next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run
        else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    arguments = ["-OpenCodeServerURL", args.server_url]
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["CommandLineArguments"] = arguments
        target["UITargetAppCommandLineArguments"] = arguments
        target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
    configured = next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).with_name("Subagent-" + token + ".xctestrun")
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    result = args.evidence / ("subagent-" + token + ".xcresult")
    try:
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=" + args.device, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
            "-maximum-test-execution-time-allowance", "420", "-resultBundlePath", str(result),
            # One runner: the light captures, then the whole flow in the dark theme (alphabetical order).
            "-only-testing:OpenCodeUITests/SubagentHeaderTests/testSubagentCaptures",
            "-only-testing:OpenCodeUITests/SubagentHeaderTests/testSubagentHeaderPathCapsuleAndProgresso"])
    finally:
        configured.unlink(missing_ok=True)
    exported = args.evidence / ("attachments-" + token)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(exported)],
        check=True, stdout=subprocess.DEVNULL)
    for test in json.loads((exported / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = exported / attachment["exportedFileName"]
            if source.suffix == ".png":
                name = attachment["suggestedHumanReadableName"].split("_0_")[0]
                shutil.copyfile(source, args.evidence / ((("falha-" if attachment["isAssociatedWithFailure"] else "") + name) + ".png"))
    shutil.rmtree(exported)
    if status == 0:
        shutil.rmtree(result)
    return status

parent = child = grandchild = None
try:
    (root / ".opencode").mkdir(parents=True)
    (root / ".opencode/opencode.jsonc").write_text('{ "experimental": { "todo": true } }\n', encoding="utf8")
    (root / "README.md").write_text("# Subagentes\n", encoding="utf8")
    git = ["git", "-C", str(root), "-c", "user.email=fixture@example.invalid", "-c", "user.name=Fixture"]
    subprocess.run(git[:3] + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-qm", "fixture"], check=True)

    title = "Subagentes no iPhone " + token
    parent = imported(title, 60, agent="build", lasted=1)
    child = imported("Etapa 1: confronto F12", 50, parent)
    sibling = imported("Etapa 2: inventário F12", 40, parent)
    finished = imported("Revisar regras F12a", 45, child)
    grandchild = imported("Conferir regras F12b", 44, child)

    # The child writes its Progresso (2 of 4) and keeps working; its own subagent works too.
    plan = [{"content": "Ler o inventário F12", "status": "completed"},
        {"content": "Listar as regras no código", "status": "completed"},
        {"content": "Comparar o inventário F12 com o código", "status": "in_progress"},
        {"content": "Escrever notas.md com as diferenças", "status": "pending"}]
    api("/api/session/" + child + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "delivery": "steer",
        "text": "Faça exatamente estas duas chamadas de ferramenta, nesta ordem e sem nenhuma outra. 1) todowrite com "
            "todos=" + json.dumps(plan, ensure_ascii=False) + ". 2) shell com command=\"sleep 900\" e timeout=0. "
            "Depois responda apenas: OK."})
    api("/api/session/" + grandchild + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "delivery": "steer",
        "text": "Use a ferramenta shell uma única vez com command=\"sleep 901\" e timeout=0. Depois responda apenas: OK."})
    deadline = time.time() + 240
    while True:
        live = active()
        snapshot = rpc("custom.session-family/snapshot", {"sessionID": parent})
        progress = (snapshot.get("progress") or {}).get(child)
        if (child in live and grandchild in live and sleeping(child) and sleeping(grandchild)
                and progress and progress["done"] == 2 and progress["total"] == 4):
            break
        if time.time() > deadline:
            raise SystemExit("The child and the grandchild did not start: " + json.dumps(
                {"live": [s in live for s in (child, grandchild)], "progress": progress}))
        time.sleep(1)
    print(json.dumps({"snapshotProgress": progress}, ensure_ascii=False))

    environment = {"OPENCODE_SUB_PARENT": parent, "OPENCODE_SUB_TITLE": title, "OPENCODE_SUB_CHILD": child,
        "OPENCODE_SUB_SIBLING": sibling, "OPENCODE_SUB_GRANDCHILD": grandchild, "OPENCODE_SUB_GRANDCHILD_DONE": finished,
        "OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_SERVER_URL": args.server_url}
    subprocess.run(["xcrun", "simctl", "status_bar", args.device, "override", "--time", "10:58", "--dataNetwork", "wifi",
        "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
        "--batteryState", "charged", "--batteryLevel", "100"], check=True)
    status = run_tests(environment)
    print(json.dumps({"status": status, "parent": parent, "child": child, "grandchild": grandchild}))
    sys.exit(status)
finally:
    for session in owned:
        api("/api/session/" + session + "/interrupt", {})
    deadline = time.time() + 30
    while set(owned).intersection(active()) and time.time() < deadline:
        time.sleep(1)
    for shell in api("/api/shell?" + query, method="GET")["data"]:
        if shell["status"] == "running" and (shell.get("metadata") or {}).get("sessionID") in owned:
            api("/api/shell/" + shell["id"] + "?" + query, method="DELETE")
    if parent:
        api("/api/session/" + parent, method="DELETE")
    shutil.rmtree(fixture)

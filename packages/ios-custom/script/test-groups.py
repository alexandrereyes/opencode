#!/usr/bin/env python3
"""Owned sandbox imports only; never seeds, model calls, or production destinations."""
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
import uuid

signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
home = temporary / "custom-sandbox-4177"
derived = temporary / "ios-grupos-derived"
evidence = temporary / "ios-grupos-prints"
evidence.mkdir(exist_ok=True)
manifest = json.loads((home / "seed-conversation.json").read_text())
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
token = uuid.uuid4().hex
now = int(time.time() * 1000)
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
own = []
configuration = derived / ("Build/Products/Groups-" + token + ".xctestrun")

def api(path, body=None, method="GET"):
    request = urllib.request.Request("http://127.0.0.1:4177" + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

def message(kind, **fields):
    return {"id": "msg_" + uuid.uuid4().hex, "type": kind, "time": {"created": now - 20000}, **fields}

def assistant(parts, **fields):
    return message("assistant", agent="build", model=model,
        time={"created": now - 15000, "completed": now - 1000}, finish="tool-calls", content=parts, **fields)

def tool(name, index, running=False):
    inputs = {"glob": {"pattern": "docs/**/*.md"}, "grep": {"pattern": "exemplo", "path": "docs"},
        "read": {"path": "docs/exemplo-" + str(index) + ".md"}, "shell": {"command": "printf 'verificação'"}}
    return {"type": "tool", "id": "tool_" + uuid.uuid4().hex, "name": name,
        "time": {"created": now - 4000, "ran": now - 3000, **({} if running else {"completed": now - 1000})},
        "state": {"status": "running" if running else "completed", "input": inputs[name], "metadata": {},
            **({} if running else {"content": [{"type": "text", "text": "Resultado sintético de verificação."}]})}}

def create(title, messages, directory=None):
    session = "ses_" + uuid.uuid4().hex
    path = directory or manifest["directory"]
    api("/api/experimental/session/import", {"info": {"id": session, "title": title, "projectID": "global",
        "location": {"directory": path}, "agent": "build", "model": model, "cost": 0,
        "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": path}, "messages": messages}, "POST")
    own.append(session)
    return session

try:
    environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_TEST_THEME": theme}
    for role, running in [("FINISHED", False), ("RUNNING", True)]:
        steps = [["glob", "read"], ["read"], ["grep"], ["read"] * 5, ["shell"], ["shell"]]
        messages = [message("user", text="Confira os documentos de exemplo."), assistant([{"type": "text", "text": "Vou conferir os documentos e validar o resultado."}])]
        for index, names in enumerate(steps):
            parts = ([{"type": "reasoning", "text": "Conferir os arquivos antes da validação.",
                "time": {"created": now - 12000, "completed": now - 11000}}] if index == 0 else [])
            parts += [tool(name, index * 5 + offset, running and index == len(steps) - 1) for offset, name in enumerate(names)]
            messages.append(assistant(parts))
        if not running:
            messages.append(assistant([{"type": "text", "text": "Conferência concluída. Os documentos estão consistentes."}]))
        session = create("Grupos — " + ("em execução" if running else "concluído"), messages)
        environment["OPENCODE_TEST_GROUP_" + role] = session
    for key, role in [("A", "working"), ("C", "history"), ("CHILD", "child-1"),
        ("WORKING", "working"), ("HISTORY", "history"), ("PERMISSION", "permission"), ("QUESTION", "question")]:
        environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
    environment["OPENCODE_TEST_SESSION_ACTIONS"] = create("Onda 5 — ações", [message("user", text="Verificação isolada."), assistant([{"type": "text", "text": "Histórico preservado para conferir os controles nativos."}])])
    missing = home / ("grupos-missing-" + token)
    missing.mkdir()
    environment["OPENCODE_TEST_SESSION_MISSING"] = create("Grupos — diretório ausente", [message("user", text="Verificação isolada."), assistant([{"type": "text", "text": "Histórico preservado para conferir os controles nativos."}])], str(missing))
    missing.rmdir()
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([target for c in run["TestConfigurations"] for target in c["TestTargets"]]
        if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["EnvironmentVariables"]["OPENCODE_SERVER_PASSWORD"] = password
        target["CommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
    configuration.write_bytes(plistlib.dumps(run))
    configuration.chmod(0o600)
    result = evidence / ("groups-" + theme + "-" + token + ".xcresult")
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configuration), "-destination",
        "platform=iOS Simulator,name=OpenCode Grupos", "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
        "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "180", "-resultBundlePath", str(result)]
    command += ["-only-testing:" + method for method in (sys.argv[1:] or ["OpenCodeUITests/ToolGroupingTests", "OpenCodeUITests/SessionReadingTests"])]
    status = subprocess.call(command)
    attachments = evidence / ("attachments-" + theme + "-" + token)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(attachments)], check=True)
    for test in json.loads((attachments / "manifest.json").read_text()):
        for item in test["attachments"]:
            source = attachments / item["exportedFileName"]
            if source.suffix == ".png" and not item["isAssociatedWithFailure"]:
                name = item["suggestedHumanReadableName"].split("_0_")[0].replace("openchamber-", "")
                shutil.copyfile(source, evidence / (name + ".png"))
    (evidence / ("verification-" + theme + ".json")).write_text(json.dumps({"status": status, "result": str(result), "ownedImports": len(own)}, indent=2))
    sys.exit(status)
finally:
    configuration.unlink(missing_ok=True)
    for session in own:
        api("/api/session/" + session, method="DELETE")

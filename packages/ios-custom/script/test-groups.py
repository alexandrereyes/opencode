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
server = os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4177")
home = Path(os.environ.get("OPENCODE_TEST_HOME", temporary / "custom-sandbox-4177"))
derived = Path(os.environ.get("OPENCODE_TEST_DERIVED", temporary / "ios-grupos2-derived"))
evidence = Path(os.environ.get("OPENCODE_GROUP_EVIDENCE", temporary / "ios-grupos2-prints"))
evidence.mkdir(parents=True, exist_ok=True)
# Without the conversation seed only the imported groups exist: run ToolGroupingTests alone.
seed = home / "seed-conversation.json"
manifest = json.loads(seed.read_text()) if seed.exists() else {"directory": str(home), "sessions": []}
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
token = uuid.uuid4().hex
now = int(time.time() * 1000)
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
own = []
configuration = derived / ("Build/Products/Groups-" + token + ".xctestrun")

def api(path, body=None, method="GET"):
    request = urllib.request.Request(server + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

def message(kind, **fields):
    return {"id": "msg_" + uuid.uuid4().hex, "type": kind, "time": {"created": now - 20000}, **fields}

def assistant(parts, **fields):
    return message("assistant", agent="build", model=model,
        time={"created": now - 15000, "completed": now - 1000}, finish="tool-calls", content=parts, **fields)

def tool(name, index, status="completed"):
    running = status in ["running", "streaming"]
    inputs = {"glob": {"pattern": "docs/**/*.md"}, "grep": {"pattern": "exemplo", "path": "docs"},
        "read": {"path": "docs/exemplo-" + str(index) + ".md"}, "shell": {"command": "printf 'verificação'"},
        "patch": {"patchText": "*** Begin Patch\n*** Update File: docs/exemplo.md\n@@\n-antigo\n+novo\n*** End Patch"}}
    metadata = {"files": [{"file": "docs/exemplo.md", "status": "modified", "additions": 1, "deletions": 1,
        "before": "antigo\n", "after": "novo\n", "patch": "--- a/docs/exemplo.md\n+++ b/docs/exemplo.md\n@@ -1 +1 @@\n-antigo\n+novo"}]} if name == "patch" and status == "completed" else {}
    return {"type": "tool", "id": "tool_" + uuid.uuid4().hex, "name": name,
        "time": {"created": now - 4000, "ran": now - 3000, **({} if running else {"completed": now - 1000})},
        "state": {"status": status, "input": inputs[name], "metadata": metadata,
            **({"error": {"type": "tool.execution", "message": "Falha de exemplo"}} if status == "error" else {}),
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
    environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_TEST_THEME": theme, "OPENCODE_TEST_SERVER_URL": server}
    for role, running in [("FINISHED", False), ("RUNNING", True)]:
        steps = json.loads((Path(__file__).parent / "fixtures/tool-groups.json").read_text())
        messages = [message("user", text="Confira os documentos de exemplo."), assistant([{"type": "text", "text": "Vou conferir os documentos e validar o resultado."}])]
        for index, names in enumerate(steps):
            parts = [{"type": "reasoning", "text": "Conferir os arquivos antes da validação.",
                "time": {"created": now - 12000, "completed": now - 11000}} if name == "reasoning"
                else tool(name.split(":")[0], index * 10 + offset,
                    "running" if running and index == len(steps) - 1 else name.split(":")[1])
                for offset, name in enumerate(names)]
            messages.append(assistant(parts))
        if not running:
            messages.append(assistant([{"type": "text", "text": "Conferência concluída. Os documentos estão consistentes."}]))
        session = create("Grupos — " + ("em execução" if running else "concluído"), messages)
        environment["OPENCODE_TEST_GROUP_" + role] = session
    (evidence / "sessions.json").write_text(json.dumps({key: value for key, value in environment.items() if key.startswith("OPENCODE_TEST_GROUP_")}))
    for key, role in [("A", "working"), ("C", "history"), ("CHILD", "child-1"),
        ("WORKING", "working"), ("HISTORY", "history"), ("PERMISSION", "permission"), ("QUESTION", "question")]:
        for seeded in (s["id"] for s in manifest["sessions"] if s["role"] == role):
            environment["OPENCODE_TEST_" + key] = seeded
            break
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
        target["CommandLineArguments"] = ["-OpenCodeServerURL", server]
    configuration.write_bytes(plistlib.dumps(run))
    configuration.chmod(0o600)
    result = evidence / ("groups-" + theme + "-" + token + ".xcresult")
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configuration), "-destination",
        os.environ.get("OPENCODE_TEST_DESTINATION", "platform=iOS Simulator,name=OpenCode Grupos2"), "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
        "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "180", "-resultBundlePath", str(result)]
    attempts = int(os.environ.get("OPENCODE_TEST_ATTEMPTS", "1"))
    if attempts > 1:
        command += ["-retry-tests-on-failure", "-test-iterations", str(attempts)]
    command += ["-only-testing:" + method for method in (sys.argv[1:] or [
        "OpenCodeUITests/ToolGroupingTests",
        "OpenCodeUITests/TranscriptCompatibilityTests/testToolsReasoningAndChildThroughBothTransports",
        "OpenCodeUITests/ReadingContinuityTests/testParentChildEdgeSwipeAndExpansion",
        "OpenCodeUITests/SessionReadingTests",
    ])]
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

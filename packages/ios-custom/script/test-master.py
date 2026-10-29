#!/usr/bin/env python3
"""Only an owned loopback sandbox (never 4096/4178); credentials never appear in argv/logs.

Self-contained: the target conversation of `testTargetUserMessageShowsMasterOrigin` is a synthetic import whose user
message carries the `custom.master` metadata the master's tools write, so no recorded voice/master transcript is needed.
"""
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import urllib.request
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
# Overrides let an isolated worker use its own sandbox, build and simulator (never 4096/4178).
server = os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4177")
home = Path(os.environ.get("OPENCODE_TEST_HOME", str(temporary / "custom-sandbox-4177")))
derived = Path(os.environ.get("OPENCODE_TEST_DERIVED", str(temporary / "ios-mestra-derived")))
base_evidence = Path(os.environ.get("OPENCODE_TEST_EVIDENCE", str(temporary / "ios-mestra-prints")))
evidence = base_evidence / "review-1" if "--review-1" in sys.argv else base_evidence
evidence.mkdir(parents=True, exist_ok=True, mode=0o700)
device = os.environ.get("OPENCODE_TEST_DEVICE", "EC672074-0EF6-47AB-9299-8AF7FE2658C1")
password = (home / "password").read_text().strip()
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
regressions = "--regressions" in sys.argv
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}

def rpc(id, method, input):
    request = urllib.request.Request(server + "/api/rpc/" + id + "/" + method,
        data=json.dumps({"input": input}).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)["output"]

def api(path, input=None, method="POST"):
    request = urllib.request.Request(server + path,
        data=json.dumps(input).encode() if input is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
        return json.loads(data) if data else None

owned = []
extra = {}
if not regressions:
    allocation = rpc("custom.chats", "allocate", {})
    chat = "ses_" + uuid.uuid4().hex
    rpc("custom.chats", "claim", {**allocation, "sessionID": chat})
    now = int(time.time() * 1000)
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    api("/api/experimental/session/import", {
        "info": {"id": chat, "title": "Conversa tranquila", "projectID": "global",
            "location": {"directory": allocation["directory"]}, "agent": "build", "model": model, "cost": 0,
            "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": allocation["directory"]},
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "time": {"created": now - 1000},
            "text": "Vamos organizar as ideias."},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
             "time": {"created": now - 500, "completed": now}, "finish": "stop",
             "content": [{"type": "text", "text": "Esta conversa não está vinculada a um repositório."}]}],
    })
    owned.append(chat)
    rpc("custom.chats", "confirm", {**allocation, "sessionID": chat})
    extra.update({"OPENCODE_TEST_CHAT": chat, "OPENCODE_TEST_CHAT_DIRECTORY": allocation["directory"]})
    master_target = "ses_" + uuid.uuid4().hex
    directory = home / "repos" / "mestra-target"
    directory.mkdir(parents=True, exist_ok=True)
    api("/api/experimental/session/import", {
        "info": {"id": master_target, "title": "Mestra · alvo", "projectID": "global",
            "location": {"directory": str(directory)}, "agent": "build", "model": model, "cost": 0,
            "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": str(directory)},
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "time": {"created": now - 1000},
            "text": "Confira o status do PR.", "metadata": {"custom.master": {"sessionID": "ses_" + uuid.uuid4().hex}}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
             "time": {"created": now - 500, "completed": now}, "finish": "stop",
             "content": [{"type": "text", "text": "O PR está aprovado."}]}],
    })
    owned.append(master_target)
    extra["OPENCODE_TEST_MASTER_TARGET"] = master_target
if regressions:
    directory = str(home / "repos/mestra-alpha")
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    now = int(time.time() * 1000)
    def imported(role, directory=directory, parent=None, history=False):
        id = "ses_" + uuid.uuid4().hex
        messages = []
        for index in range(1, 81 if history else 2):
            created = now - (81 - index) * 2000
            messages += [
                {"id": "msg_" + uuid.uuid4().hex, "type": "user", "time": {"created": created}, "text": "Verificação isolada."},
                {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
                    "time": {"created": created + 500, "completed": created + 1000}, "finish": "stop",
                    "content": [{"type": "text", "text": f"Revisão {index} concluída para o PR fictício." if history else "Histórico preservado para conferir os controles nativos."}]},
            ]
        # The existing rename test taps the middle of its field before Backspace, so keep its seed short.
        info = {"id": id, "title": "Ações" if role == "ações" else "Mestra regressão · " + role, "projectID": "global",
            "location": {"directory": directory}, "agent": "build", "model": model, "cost": 0,
            "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}}
        if parent:
            info["parentID"] = parent
        api("/api/experimental/session/import", {"info": info, "location": {"directory": directory}, "messages": messages})
        owned.append(id)
        return id
    extra["OPENCODE_TEST_A"] = imported("detalhes")
    extra["OPENCODE_TEST_CHILD"] = imported("filho", parent=extra["OPENCODE_TEST_A"])
    extra["OPENCODE_TEST_C"] = imported("histórico", history=True)
    extra["OPENCODE_TEST_SESSION_ACTIONS"] = imported("ações")
    missing = home / "repos" / ("mestra-missing-" + uuid.uuid4().hex)
    missing.mkdir()
    extra["OPENCODE_TEST_SESSION_MISSING"] = imported("diretório ausente", directory=str(missing))
    missing.rmdir()

profile = rpc("custom.preferences", "get", {})
old = profile["data"].get("masterSessions", {}).get("local")
if old:
    rpc("custom.archive", "archive", {"sessionID": old})
rpc("custom.preferences", "mutate", {"type": "master.clear", "server": "local"})
run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
    if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
for target in targets:
    target.setdefault("EnvironmentVariables", {}).update({
        "OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
        "OPENCODE_TEST_THEME": theme,
        "OPENCODE_TEST_SERVER_URL": server, **extra,
    })
    target["CommandLineArguments"] = ["-OpenCodeServerURL", server]
    target["UITargetAppCommandLineArguments"] = ["-OpenCodeServerURL", server]
    target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
configured = derived / ("Build/Products/Master-" + uuid.uuid4().hex + ".xctestrun")
configured.write_bytes(plistlib.dumps(run))
configured.chmod(0o600)
result = evidence / ("master-" + theme + "-" + uuid.uuid4().hex + ".xcresult")
try:
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    selected = "OpenCodeUITests/SessionReadingTests" if regressions else "OpenCodeUITests/MasterSessionTests"
    status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
        "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
        "-collect-test-diagnostics", "never", "-resultBundlePath", str(result),
        "-only-testing:" + selected, "-only-testing:OpenCodeTests"])
    export = evidence / ("attachments-" + theme + "-" + uuid.uuid4().hex)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(export)], check=True)
    for test in json.loads((export / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = export / attachment["exportedFileName"]
            if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                shutil.copyfile(source, evidence / (attachment["suggestedHumanReadableName"].split("_0_")[0] + ".png"))
    (evidence / (("regressions-" if regressions else "ui-") + theme + ".json")).write_text(json.dumps({"status": status, "result": str(result), "server": server, "device": device}, indent=2))
    if status:
        raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "terminate", device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for id in reversed(owned):
        api("/api/session/" + id, method="DELETE")

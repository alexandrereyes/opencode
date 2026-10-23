#!/usr/bin/env python3
"""Owned histories and one Luna-6/low child, sandbox only; no seed or service changes."""
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
import urllib.parse
import uuid

signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
home = temporary / "custom-sandbox-4177"
derived = temporary / "ios-abertura-derived"
evidence = temporary / "ios-cache-prints/review-1"
evidence.mkdir(parents=True, exist_ok=True)
manifest = json.loads((home / "seed-conversation.json").read_text())
directory = manifest["directory"]
assert Path(directory).is_relative_to(home / "repos")
password = (home / "password").read_text().strip()
headers = {"Content-Type": "application/json", "Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode()}
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
own = []
children = []
configuration = None
now = int(time.time() * 1000)
totals = {"input": 100000, "output": 100000, "reasoning": 0, "cache": {"read": 5600000, "write": 170000}}

def api(path, body=None, method="GET"):
    request = urllib.request.Request("http://127.0.0.1:4177" + path,
        headers=headers, data=json.dumps(body).encode() if body is not None else None, method=method)
    with urllib.request.urlopen(request, timeout=90) as response:
        data = response.read()
        return json.loads(data) if data else None

def create(title, measurement=True, empty=False):
    sid = "ses_" + uuid.uuid4().hex
    uid, mid = "msg_" + uuid.uuid4().hex, "msg_" + uuid.uuid4().hex
    assistant = {"id": mid, "type": "assistant", "agent": "build", "model": model,
        "time": {"created": now - 2000, "completed": now - 1000},
        "content": [{"type": "text", "text": "Conferência concluída. O contexto medido pertence a esta resposta, e o cache da sessão reúne todos os passos."}]}
    assistant["finish"] = "stop"
    if measurement:
        assistant["tokens"] = measured
    messages = [{"id": uid, "type": "user", "text": "Confira o contexto e o cache da resposta de exemplo.", "time": {"created": now - 3000}}, assistant]
    api("/api/experimental/session/import", {"info": {"id": sid, "title": title, "projectID": "global",
        "location": {"directory": directory}, "agent": "build", "model": model, "cost": 9.18, "tokens": totals,
        "permissions": [{"action": "*", "resource": "*", "effect": "allow"}], "outcome": "succeeded",
        "time": {"created": now - 10000, "updated": now, "idle": now - 500, "viewed": now}},
        "location": {"directory": directory}, "messages": [] if empty else messages}, "POST")
    own.append(sid)
    return sid

def prompt(sid, text):
    api("/api/session/" + sid + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "text": text, "delivery": "steer"}, "POST")

def wait_idle(sid, after=0):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        info = api("/api/session/" + sid)["data"]
        if info.get("outcome") == "succeeded" and info["time"].get("idle", 0) > after:
            return
        time.sleep(0.25)
    raise RuntimeError("Owned Luna session did not finish")

try:
    models = api("/api/model?location%5Bdirectory%5D=" + urllib.parse.quote(directory, safe=""))["data"]
    limit = next(m["limit"]["context"] for m in models if m["providerID"] == model["providerID"] and m["id"] == model["id"])
    measured = {"input": limit * 25 / 1050, "output": limit * 14 / 1050, "reasoning": 0,
                "cache": {"read": limit / 3, "write": limit / 105}}
    roles = {"COMPLETE": create("Cache — resposta concluída"), "MISSING": create("Cache — sem medição", False),
             "EMPTY": create("Cache — sessão vazia", False, empty=True),
             "PARENT": create("Cache — família")}
    watermark = api("/api/session/" + roles["PARENT"])["data"]["time"].get("idle", 0)
    prompt(roles["PARENT"], 'Chame subagent uma única vez com agent="general", description="Conferir contexto do exemplo", model="llm-proxy/gpt-6-luna#low", prompt="Responda apenas: Contexto conferido. Não use ferramentas.", background=false. Depois responda apenas: Conferência delegada.')
    wait_idle(roles["PARENT"], watermark)
    members = api("/api/rpc/custom.session-family/page", {"input": {"sessionID": roles["PARENT"], "limit": 100}}, "POST")["output"]["data"]
    children = [c["id"] for c in members]
    assert len(children) == 1 and members[0].get("context"), "Family context missing"
    roles["CHILD"] = children[0]
    child = api("/api/session/" + roles["CHILD"])["data"]
    assert child["parentID"] == roles["PARENT"] and child["location"]["directory"] == directory
    assert child["model"] == model
    prompt(roles["CHILD"] , "Use apenas shell para executar sleep 600, sem background. Depois responda: fim.")
    deadline = time.monotonic() + 60
    while roles["CHILD"] not in api("/api/session/active")["data"]:
        assert time.monotonic() < deadline
        time.sleep(0.25)
    while True:
        page = api("/api/session/" + roles["CHILD"] + "/message?limit=10&order=desc")["data"]
        if any(m["type"] == "assistant" and m["time"].get("completed") is None for m in page):
            assert any(m.get("tokens") is not None for m in page)
            break
        assert time.monotonic() < deadline, "Owned child did not start its live step"
        time.sleep(0.25)
    ledger = {"owned": own, "children": children, "limit": limit, "measured": measured}
    (evidence / "execution-ledger.json").write_text(json.dumps(ledger, indent=2))
    device = "3CD95181-75A3-4225-B919-6B1C4DCFA77E"
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi",
        "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
        "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    statuses = []
    for theme in ([os.environ["OPENCODE_TEST_THEME"]] if "OPENCODE_TEST_THEME" in os.environ else ["openchamber-dark", "openchamber-light"]):
        run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
        environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
            "OPENCODE_TEST_THEME": theme, **{"OPENCODE_TEST_USAGE_" + key: value for key, value in roles.items()}}
        targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
                   if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
        for target in targets:
            target.setdefault("EnvironmentVariables", {}).update(environment)
            target["CommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
        token = uuid.uuid4().hex[:8]
        configuration = derived / ("Build/Products/Cache-" + token + ".xctestrun")
        configuration.write_bytes(plistlib.dumps(run))
        configuration.chmod(0o600)
        result = evidence / ("cache-" + theme + "-" + token + ".xcresult")
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(configuration), "-destination",
            "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-resultBundlePath", str(result)]
        command += ["-only-testing:" + test for test in (sys.argv[1:] or ["OpenCodeUITests/ContextUsageTests"])]
        statuses.append(subprocess.call(command))
        configuration.unlink(missing_ok=True)
        export = evidence / ("attachments-" + token)
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(export)], check=True)
        for test in json.loads((export / "manifest.json").read_text()):
            for attachment in test["attachments"]:
                source = export / attachment["exportedFileName"]
                if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                    shutil.copyfile(source, evidence / (attachment["suggestedHumanReadableName"].split("_0_")[0] + ".png"))
    ledger["statuses"] = statuses
    raise SystemExit(max(statuses))
finally:
    if configuration is not None:
        configuration.unlink(missing_ok=True)
    for sid in own:
        api("/api/session/" + sid + "/interrupt", {}, "POST")
    for sid in own:
        page = api("/api/rpc/custom.session-family/page", {"input": {"sessionID": sid, "limit": 100}}, "POST")["output"]
        children.extend(c["id"] for c in page["data"] if c["id"] not in children)
    for sid in children:
        api("/api/session/" + sid + "/interrupt", {}, "POST")
    shells = api("/api/shell?location%5Bdirectory%5D=" + urllib.parse.quote(directory, safe=""))["data"]
    for shell in shells:
        if shell.get("metadata", {}).get("sessionID") in own + children:
            api("/api/shell/" + shell["id"] + "?location%5Bdirectory%5D=" + urllib.parse.quote(directory, safe=""), method="DELETE")
    deadline = time.monotonic() + 30
    while set(own + children).intersection(api("/api/session/active")["data"]):
        assert time.monotonic() < deadline, "Owned execution did not stop"
        time.sleep(0.25)
    for sid in children + own:
        api("/api/session/" + sid, method="DELETE")
    if "ledger" in globals():
        ledger["cleaned"] = True
        (evidence / "execution-ledger.json").write_text(json.dumps(ledger, indent=2))

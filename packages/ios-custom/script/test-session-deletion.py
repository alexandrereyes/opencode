#!/usr/bin/env python3
"""Delete only this run's owned sessions; never modify sandbox seeds or lifecycle."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import urllib.error
import urllib.request
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("tests", nargs="*")
parser.add_argument("--live-family", action="store_true")
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
# Overrides let an isolated worker use its own sandbox, build and simulator (never 4096/4178).
server = os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4177")
home = Path(os.environ.get("OPENCODE_TEST_HOME", str(temporary / "custom-sandbox-4177")))
derived = Path(os.environ.get("OPENCODE_TEST_DERIVED", str(temporary / "ios-excluir-derived")))
evidence = Path(os.environ.get("OPENCODE_TEST_EVIDENCE", str(temporary / "ios-excluir-prints")))
evidence.mkdir(parents=True, exist_ok=True)
device = os.environ.get("OPENCODE_TEST_DEVICE", "BAF8F32A-941F-4407-84A7-BF205CDC9EA6")
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
token = uuid.uuid4().hex[:10]
ledger_path = evidence / ("ledger-" + theme + "-" + token + ".json")
ledger = {"theme": theme, "created": [], "deleted": [], "children": [], "checks": {}}
configured = derived / ("Build/Products/Delete-" + token + ".xctestrun")
environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme,
    "OPENCODE_TEST_SERVER_URL": server}
tests = args.tests or ["OpenCodeUITests/SessionDeletionTests", "OpenCodeTests/SessionDeletionTests"]

def save():
    ledger_path.write_text(json.dumps(ledger, indent=2))

def api(path, body=None, method="GET"):
    request = urllib.request.Request(server + path, headers=headers,
        data=json.dumps(body).encode() if body is not None else None, method=method)
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
        return json.loads(data) if data else None

def rpc(name, method, body):
    return api("/api/rpc/" + name + "/" + method, {"input": body}, "POST")["output"]

def exists(session):
    try:
        api("/api/session/" + session)
        return True
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise

def children(session):
    result = []
    after = None
    while True:
        page = rpc("custom.session-family", "page", {"sessionID": session, "limit": 100, **({"after": after} if after else {})})
        result += [item["id"] for item in page["data"]]
        after = page.get("next")
        if not after:
            return result

def idle(session):
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        value = api("/api/session/" + session)["data"]
        if value["time"].get("idle"):
            return
        time.sleep(1)
    raise RuntimeError("Owned prompt did not become idle: " + session)

def preference_cleanup(ids):
    prefs = rpc("custom.preferences", "get", {})["data"]
    for field, intent, flag in [("pinnedSessions", "sidebar.pin", "pinned"), ("mutedSessions", "sidebar.mute", "muted")]:
        for key in prefs.get(field, []):
            try:
                identity = json.loads(key)[1] if key.startswith("[") else key
            except (ValueError, IndexError):
                continue
            if identity in ids:
                rpc("custom.preferences", "mutate", {"type": intent, "session": key, flag: False})

try:
    repo = home / "repos" / ("ios-excluir-" + token)
    repo.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=OpenCode Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "Owned deletion fixture"], check=True)
    ledger["directory"] = str(repo)
    for role in ["SWIPE", "MENU", "FAILURE", "ARCHIVED"]:
        session = "ses_" + uuid.uuid4().hex
        api("/api/session", {"id": session, "title": "Excluir — " + role.lower(),
            "location": {"directory": str(repo)}, "agent": "build",
            "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}}, "POST")
        ledger["created"].append({"id": session, "role": role})
        environment["OPENCODE_DELETE_" + role] = session
        save()
        prompt = "Responda apenas OK. Não use ferramentas."
        if role == "SWIPE" and args.live_family:
            prompt = "Use a ferramenta subagent exatamente uma vez, com agente explore e modelo llm-proxy/gpt-6-luna variante low, para pedir que responda apenas OK, sem ferramentas ou leitura de arquivos. Aguarde o resultado e responda apenas OK. Não faça mais nada."
        api("/api/session/" + session + "/prompt", {"text": prompt}, "POST")
        idle(session)
        owned_children = children(session)
        ledger["children"] += owned_children
        save()
        if role == "SWIPE" and args.live_family:
            assert owned_children, "Parent did not create a subagent"
        if role == "ARCHIVED":
            rpc("custom.archive", "archive", {"sessionID": session})
    swipe = environment["OPENCODE_DELETE_SWIPE"]
    for session in [swipe] + ledger["children"]:
        key = json.dumps(["http://localhost:4096", session], separators=(",", ":"))
        rpc("custom.preferences", "mutate", {"type": "sidebar.pin", "session": key, "pinned": True})
        rpc("custom.preferences", "mutate", {"type": "sidebar.mute", "session": key, "muted": True})
    manifest = json.loads((home / "seed-conversation.json").read_text())
    for key, role in [("A", "working"), ("C", "history"), ("CHILD", "child-1")]:
        environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
    if any("SessionReadingTests" in test for test in tests):
        now = int(time.time() * 1000)
        for role, directory in [("SESSION_ACTIONS", str(repo)), ("SESSION_MISSING", str(home / ("missing-excluir-" + token)))]:
            session = "ses_" + uuid.uuid4().hex
            api("/api/experimental/session/import", {
                "info": {"id": session, "title": "Excluir — regressão", "projectID": "global", "location": {"directory": directory},
                    "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                    "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                    "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
                "location": {"directory": directory}, "messages": [
                    {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Teste isolado.", "time": {"created": now - 1000}},
                    {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build",
                     "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                     "time": {"created": now - 900, "completed": now - 800}, "finish": "stop",
                     "content": [{"type": "text", "text": "Histórico preservado para conferir os controles nativos."}]}]}, "POST")
            ledger["created"].append({"id": session, "role": role})
            environment["OPENCODE_TEST_" + role] = session
            save()
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
               if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["CommandLineArguments"] = ["-OpenCodeServerURL", server]
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    subprocess.run(["xcrun", "simctl", "boot", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True)
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi",
        "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
        "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    result = evidence / (theme + "-" + token + ".xcresult")
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination",
        "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
        "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "240", "-resultBundlePath", str(result)]
    status = subprocess.call(command + ["-only-testing:" + test for test in tests])
    ledger["status"] = status
    ledger["result"] = str(result)
    for item in ledger["created"]:
        ledger["checks"][item["role"]] = {"existsAfterTests": exists(item["id"])}
    for session in ledger["children"]:
        ledger["checks"][session] = {"existsAfterTests": exists(session)}
    prefs = rpc("custom.preferences", "get", {})["data"]
    ledger["checks"]["preferenceKeysRemoved"] = all(session not in key for session in [swipe] + ledger["children"]
        for key in prefs.get("pinnedSessions", []) + prefs.get("mutedSessions", []))
    save()
    exported = evidence / ("attachments-" + token)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(exported)], check=True)
    for test in json.loads((exported / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = exported / attachment["exportedFileName"]
            if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                shutil.copyfile(source, evidence / (attachment["suggestedHumanReadableName"].split("_0_")[0] + ".png"))
    print(json.dumps({"status": status, "ledger": str(ledger_path), "result": str(result)}))
    raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    owned = [item["id"] for item in ledger["created"]]
    for session in owned:
        if exists(session):
            descendants = children(session)
            ledger["children"] = list(dict.fromkeys(ledger["children"] + descendants))
            api("/api/session/" + session, method="DELETE")
        ledger["deleted"].append(session)
        save()
    for session in ledger["children"]:
        assert not exists(session), "Descendant survived server cascade"
        ledger["deleted"].append(session)
    preference_cleanup(set(owned + ledger["children"]))
    save()
    subprocess.run(["xcrun", "simctl", "terminate", device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

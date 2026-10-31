#!/usr/bin/env python3
"""A subagent's header capsule and its long-press actions: UI test on an isolated sandbox and a fresh simulator.

The sandbox and the fixture live where the server runs; Xcode, the simulator and the test bundle live on the Mac.
So the run has three steps, each on its own side (on a Mac-only setup, run all three there):

  prepare  (server side) owns a temporary git checkout and imports a finished parent with four subagents:
           "Etapa 1: confronto F12" with a subagent of its own made really running (Luna 6 / low sleeping through
           the shell tool) and a resource in use, "Etapa 2: inventário F12" with only a resource, "Etapa 3: regras
           F12" with only a finished subagent, and "Etapa 4: notas F12" with nothing. The resources are two booted
           simulators registered in the sandbox's own resources hub with each subagent as owner. It writes the test
           environment to --exchange/env.json (0600) and the owned sessions to --exchange/owned.json.
  test     (Mac) uninstalls the app, then runs OpenCodeUITests/SubagentCapsuleTests (the light captures, then the
           whole flow in the dark theme) with that environment, and copies the captures to --evidence.
  cleanup  (server side) interrupts and deletes every owned session and removes the checkout.

  python3 packages/ios-custom/script/test-subagent-capsule.py prepare --server-url http://127.0.0.1:<port> \\
    --home <sandbox-home> --exchange <dir the Mac can read> --device-file <file> --resource-device-file <file>
  python3 packages/ios-custom/script/test-subagent-capsule.py test --derived <DerivedData> --exchange <dir> \\
    --device-file <file> --evidence <dir>
  python3 packages/ios-custom/script/test-subagent-capsule.py cleanup --server-url ... --home ... --exchange ...

The simulator UDIDs are read from files so they never appear on a command line or in the output.
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
parser.add_argument("command", choices=["prepare", "test", "cleanup"])
parser.add_argument("--server-url")
parser.add_argument("--home", type=Path, help="custom-sandbox.ts home (its password, ownership and hub state)")
parser.add_argument("--exchange", type=Path, required=True)
parser.add_argument("--device-file", type=Path)
parser.add_argument("--resource-device-file", type=Path)
parser.add_argument("--derived", type=Path)
parser.add_argument("--evidence", type=Path)
args = parser.parse_args()
environment_file = args.exchange / "env.json"
ledger = args.exchange / "owned.json"


def sandbox():
    port = int(args.server_url.rsplit(":", 1)[1].rstrip("/"))
    if port in (4096, 4177, 4178, 4179) or not args.server_url.startswith(("http://127.0.0.1:", "http://localhost:")):
        parser.error("Use an isolated loopback sandbox, never 4096, 4177, 4178 or 4179")
    owner = json.loads((args.home / "sandbox.json").read_text())
    assert owner["port"] == port and Path(owner["home"]) == args.home.resolve(), "Sandbox ownership mismatch"
    password = (args.home / "password").read_text().strip()
    headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
        "Content-Type": "application/json"}

    def api(path, body=None, method="POST", base=args.server_url, extra=None):
        request = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
            headers=extra or headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read()
                return json.loads(data) if data else None
        except urllib.error.HTTPError as error:
            raise SystemExit("%s %s: %s" % (method, path, error.read().decode()[:400]))
    return password, api


def prepare():
    password, api = sandbox()

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

    token = uuid.uuid4().hex[:10]
    fixture = Path(tempfile.mkdtemp(prefix="ios-subagent-capsule-" + token + "-")).resolve()
    root = fixture / "repo"
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    owned = {"fixture": str(fixture), "root": str(root), "sessions": []}
    args.exchange.mkdir(parents=True, exist_ok=True)

    def save():
        ledger.write_text(json.dumps(owned))
        ledger.chmod(0o600)

    def imported(title, minutes_ago, parent_id=None, agent="general", lasted=2):
        now = int(time.time() * 1000)
        created = now - minutes_ago * 60_000
        idle = created + lasted * 60_000
        session = "ses_" + uuid.uuid4().hex
        info = {"id": session, "title": title, "projectID": "global", "location": {"directory": str(root)},
            "agent": agent, "model": model, "cost": 0,
            "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": created, "updated": idle, "idle": idle, "viewed": idle}}
        if parent_id:
            info["parentID"] = parent_id
        api("/api/experimental/session/import", {"info": info, "location": {"directory": str(root)},
            "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": title + ".",
                "time": {"created": created}},
                {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": agent, "model": model,
                 "time": {"created": created + 1000, "completed": idle}, "finish": "stop",
                 "content": [{"type": "text", "text": "Pronto."}]}]})
        owned["sessions"].append(session)
        save()
        return session

    root.mkdir()
    (root / "README.md").write_text("# Subagentes\n", encoding="utf8")
    git = ["git", "-C", str(root), "-c", "user.email=fixture@example.invalid", "-c", "user.name=Fixture"]
    subprocess.run(git[:3] + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-qm", "fixture"], check=True)

    title = "Cápsula do subagente " + token
    parent = imported(title, 60, agent="build", lasted=1)
    both = imported("Etapa 1: confronto F12", 50, parent)
    resource = imported("Etapa 2: inventário F12", 45, parent)
    agents = imported("Etapa 3: regras F12", 40, parent)
    none = imported("Etapa 4: notas F12", 35, parent)
    grandchild = imported("Conferir regras F12b", 44, both)
    finished = imported("Revisar regras F12a", 39, agents)

    # The first subagent's own subagent really runs.
    api("/api/session/" + grandchild + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "delivery": "steer",
        "text": "Use a ferramenta shell uma única vez com command=\"sleep 900\" e timeout=0. Depois responda apenas: OK."})

    # Two booted simulators in the sandbox's own hub, each in use by one subagent (the plugin starts the hub).
    rpc("custom.resources/list", {})
    hub_file = args.home / "xdg/state/opencode/resources-hub/hub.json"
    deadline = time.time() + 30
    while not hub_file.exists() and time.time() < deadline:
        time.sleep(0.5)
    hub = json.loads(hub_file.read_text())
    hub_url = "http://127.0.0.1:%d" % hub["port"]
    bearer = {"Authorization": "Bearer " + hub["secret"], "Content-Type": "application/json"}
    devices = {both: args.resource_device_file.read_text().strip(), resource: args.device_file.read_text().strip()}
    ids = {}
    for session, udid in devices.items():
        created = api("/admin/resources", {"kind": "ios-simulator", "meta": {"kind": "ios-simulator", "udid": udid},
            "owner": {"sessionID": session, "rootSessionID": parent, "agent": "general"}, "used": True},
            method="PUT", base=hub_url, extra=bearer)
        ids[session] = created["id"]

    shells = "/api/shell?location%5Bdirectory%5D=" + urllib.parse.quote(str(root), safe="")
    deadline = time.time() + 240
    while True:
        live = api("/api/session/active", method="GET")["data"]
        sleeping = any(shell["status"] == "running" and (shell.get("metadata") or {}).get("sessionID") == grandchild
            for shell in api(shells, method="GET")["data"])
        listed = {item["id"]: item["state"] for item in rpc("custom.resources/list", {}).get("resources", [])}
        running = all(listed.get(id) in ("agent", "live", "idle", "user") for id in ids.values())
        if grandchild in live and sleeping and running:
            break
        if time.time() > deadline:
            raise SystemExit("The scenario did not settle: " + json.dumps(
                {"grandchild": grandchild in live, "sleeping": sleeping, "resources": list(listed.values())}))
        time.sleep(1)

    environment = {"OPENCODE_CAP_PARENT": parent, "OPENCODE_CAP_TITLE": title, "OPENCODE_CAP_BOTH": both,
        "OPENCODE_CAP_GRANDCHILD": grandchild, "OPENCODE_CAP_BOTH_RESOURCE": ids[both],
        "OPENCODE_CAP_RESOURCE": resource, "OPENCODE_CAP_RESOURCE_RESOURCE": ids[resource],
        "OPENCODE_CAP_AGENTS": agents, "OPENCODE_CAP_AGENTS_CHILD": finished, "OPENCODE_CAP_NONE": none,
        "OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
        "OPENCODE_TEST_SERVER_URL": args.server_url}
    environment_file.write_text(json.dumps(environment))
    environment_file.chmod(0o600)
    print(json.dumps({"parent": parent, "sessions": len(owned["sessions"]), "resources": len(ids)}))


def test():
    environment = json.loads(environment_file.read_text())
    device = args.device_file.read_text().strip()
    args.evidence.mkdir(parents=True, exist_ok=True)
    token = uuid.uuid4().hex[:10]
    original = next(args.derived.glob("Build/Products/OpenCode_*.xctestrun"))
    run = plistlib.loads(original.read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run
        else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    arguments = ["-OpenCodeServerURL", environment["OPENCODE_TEST_SERVER_URL"]]
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["CommandLineArguments"] = arguments
        target["UITargetAppCommandLineArguments"] = arguments
        target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = environment[
            "OPENCODE_SERVER_PASSWORD"]
    configured = original.with_name("Capsule-" + token + ".xctestrun")
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    result = args.derived / ("capsule-" + token + ".xcresult")
    try:
        # Every round starts from a fresh app container: no server registry, Keychain item or draft of the last one.
        subprocess.run(["xcrun", "simctl", "uninstall", device, "br.com.alexandrem.opencode"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork",
            "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
            "--batteryState", "charged", "--batteryLevel", "100"], check=True)
        with (args.evidence / ("xcodebuild-" + token + ".log")).open("w") as log:
            status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
                "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
                "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
                "-maximum-test-execution-time-allowance", "480", "-resultBundlePath", str(result),
                "-only-testing:OpenCodeUITests/SubagentCapsuleTests/testCapsuleCapturesInLightTheme",
                "-only-testing:OpenCodeUITests/SubagentCapsuleTests/testHeaderCapsuleAndLongPressActions"],
                stdout=log, stderr=subprocess.STDOUT)
    finally:
        configured.unlink(missing_ok=True)
    exported = Path(tempfile.mkdtemp(prefix="capsule-attachments-"))
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path",
        str(exported)], check=True, stdout=subprocess.DEVNULL)
    for test in json.loads((exported / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = exported / attachment["exportedFileName"]
            if source.suffix == ".png":
                name = attachment["suggestedHumanReadableName"].split("_0_")[0]
                prefix = "falha-" if attachment["isAssociatedWithFailure"] else ""
                shutil.copyfile(source, args.evidence / (prefix + name + ".png"))
    shutil.rmtree(exported)
    if status == 0:
        shutil.rmtree(result)
    print(json.dumps({"status": status}))
    sys.exit(status)


def cleanup():
    _, api = sandbox()
    if not ledger.exists():
        return
    owned = json.loads(ledger.read_text())
    for session in owned["sessions"]:
        api("/api/session/" + session + "/interrupt", {})
    deadline = time.time() + 30
    while set(owned["sessions"]).intersection(api("/api/session/active", method="GET")["data"]) and time.time() < deadline:
        time.sleep(1)
    shells = "/api/shell?location%5Bdirectory%5D=" + urllib.parse.quote(owned["root"], safe="")
    for shell in api(shells, method="GET")["data"]:
        if shell["status"] == "running" and (shell.get("metadata") or {}).get("sessionID") in owned["sessions"]:
            api("/api/shell/" + shell["id"] + "?" + shells.split("?", 1)[1], method="DELETE")
    # Deleting the top-level session deletes its whole family.
    api("/api/session/" + owned["sessions"][0], method="DELETE")
    shutil.rmtree(owned["fixture"], ignore_errors=True)
    ledger.unlink()
    environment_file.unlink(missing_ok=True)


{"prepare": prepare, "test": test, "cleanup": cleanup}[args.command]()

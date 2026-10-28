#!/usr/bin/env python3
"""Agentes e tarefas screen UI test: running and finished subagents in one list, open a child and go back.

It owns a temporary git checkout and imports a parent with four direct children: three finished ones (succeeded,
failed, interrupted) and one made genuinely running by a Luna 6 / low prompt that runs `sleep` through the shell
tool. The parent then starts a background subagent, a background `sleep` script and a foreground `subagent` call that also
sleeps, so the app opens on a reloaded running call whose part has no child `sessionID` (it only travels in
ephemeral progress) beside its active child, plus one agent and one script running in the background. Running
work is interrupted and the whole family deleted afterwards. Run after `build-for-testing`:
  python3 packages/ios-custom/script/test-agents-screen.py --device <sim-udid> --derived <DerivedData> \\
    --home <sandbox-home> --server-url http://127.0.0.1:<port> --evidence <prints-dir> [--theme openchamber-light]
With `--scenario model`, the parent instead runs one General subagent with Luna 6 / low and the UI test continues it
(same `sessionID`) with Luna 6 - fast / low while "Agentes e tarefas" is open, expecting the row's model to follow.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--device", required=True)
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--home", type=Path, required=True, help="custom-sandbox.ts home (reads its password file)")
parser.add_argument("--server-url", default="http://127.0.0.1:4177")
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--theme", default=os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark"))
parser.add_argument("--only", help="xctest selector (default: the scenario's test)")
parser.add_argument("--scenario", choices=["list", "model"], default="list",
    help="list: the agents/scripts list; model: one subagent continued with another model, row updated live")
args = parser.parse_args()
port = int(args.server_url.rsplit(":", 1)[1].rstrip("/"))
if port in (4096, 4177, 4178) or not args.server_url.startswith(("http://127.0.0.1:", "http://localhost:")):
    parser.error("Use an isolated loopback sandbox, never 4096, 4177 or 4178")

password = (args.home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
def api(path, body=None, method="POST"):
    request = urllib.request.Request(args.server_url + path, data=json.dumps(body).encode() if body is not None else None,
        headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        raise SystemExit("%s %s: %s" % (method, path, error.read().decode()[:400]))
def family(session):
    # Right after a new Location boots, the plugin's RPCs can briefly report themselves unavailable.
    deadline = time.time() + 60
    while True:
        try:
            return api("/api/rpc/custom.session-family/page", {"input": {"sessionID": session, "limit": 100}})["output"]["data"]
        except SystemExit as error:
            if "rpc.unavailable" not in str(error) or time.time() > deadline:
                raise
            time.sleep(1)
def active():
    return api("/api/session/active", method="GET")["data"]

token = uuid.uuid4().hex[:10]
fixture = Path(tempfile.mkdtemp(prefix="ios-agents-screen-" + token + "-")).resolve()
root = fixture / "repo"
configured = next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).with_name("Agents-" + token + ".xctestrun")
args.evidence.mkdir(parents=True, exist_ok=True)
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
parent = None
running = None
delegated = None
background = None
script = None
def imported(title, minutes_ago, parent_id=None, agent="build", outcome="succeeded", lasted=2):
    now = int(time.time() * 1000)
    created = now - minutes_ago * 60_000
    idle = created + lasted * 60_000
    session = "ses_" + uuid.uuid4().hex
    info = {"id": session, "title": title, "projectID": "global", "location": {"directory": str(root)}, "agent": agent,
        "model": model, "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": outcome, "time": {"created": created, "updated": idle, "idle": idle, "viewed": idle}}
    if parent_id:
        info["parentID"] = parent_id
    api("/api/experimental/session/import", {"info": info, "location": {"directory": str(root)},
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": title + ".", "time": {"created": created}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": agent, "model": model,
             "time": {"created": created + 1000, "completed": idle}, "finish": "stop", "content": [{"type": "text", "text": "Pronto."}]}]})
    return session
def scenario_list():
    global parent, running, delegated, background, script, order
    parent = imported("Agentes e tarefas", 60, lasted=1)
    # Finished children ran last at -28 (interrupted), -38 (failed) and -48 min (succeeded). The "running" child
    # was created at -45 min and is resumed now, like a reused subagent: it must list above all finished ones.
    finished = {
        "succeeded": imported("Mapear dependências", 50, parent, "explore", "succeeded"),
        "failed": imported("Revisar migrações", 40, parent, "general", "failed"),
        "interrupted": imported("Comparar alternativas", 30, parent, "explore", "interrupted"),
    }
    running = imported("Executar verificação longa", 45, parent, "general", "succeeded")
    api("/api/session/" + running + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "delivery": "steer",
        "text": "Use a ferramenta shell uma única vez para executar exatamente `sleep 300`. Depois responda apenas: OK."})
    deadline = time.time() + 120
    while running not in active() or not any(s.get("status") == "running" and (s.get("metadata") or {}).get("sessionID") == running
            for s in api("/api/shell?location%5Bdirectory%5D=" + urllib.request.quote(str(root), safe=""), method="GET")["data"]):
        if time.time() > deadline:
            raise SystemExit("The running child did not start its shell")
        time.sleep(1)
    api("/api/session/" + parent + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "delivery": "steer",
        "text": 'Faça exatamente estas três chamadas de ferramenta, uma de cada vez e nesta ordem, sem nenhuma outra. '
            '1) subagent com agent="general", description="Vigiar em segundo plano", model="llm-proxy/gpt-6-luna#low", '
            'background=true, prompt="Use a ferramenta shell uma única vez para executar exatamente `sleep 300`. Depois '
            'responda apenas: OK." 2) shell com command="sleep 301", background=true. 3) subagent com agent="general", '
            'description="Delegar verificação real", model="llm-proxy/gpt-6-luna#low", background=false, prompt="Use a '
            'ferramenta shell uma única vez para executar exatamente `sleep 300`. Depois responda apenas: OK." '
            'Depois responda apenas: OK.'})
    deadline = time.time() + 240
    q = "location%5Bdirectory%5D=" + urllib.request.quote(str(root), safe="")
    while True:
        members = family(parent)
        titles = {m.get("title"): m["id"] for m in members if m.get("parentID") == parent}
        background = titles.get("Vigiar em segundo plano")
        delegated = titles.get("Delegar verificação real")
        shells = [sh for sh in api("/api/shell?" + q, method="GET")["data"] if sh["status"] == "running"]
        script = next((sh["id"] for sh in shells
            if (sh.get("metadata") or {}).get("sessionID") == parent and sh["command"] == "sleep 301"), None)
        # Each delegated child must really be sleeping, or it may finish before the app counts it.
        sleeping = {(sh.get("metadata") or {}).get("sessionID") for sh in shells}
        page = api("/api/session/" + parent + "/message?limit=20&order=desc", method="GET")["data"]
        calls = [part for message in page if message["type"] == "assistant" for part in message["content"]
            if part["type"] == "tool" and part["name"] == "subagent"]
        live = active()
        if (background in live and delegated in live and parent in live and script
                and {background, delegated} <= sleeping and any(c["state"]["status"] == "running" for c in calls)):
            # The stored running part carries no child ID; that is the case the app must merge.
            assert all(not (c["state"].get("metadata") or {}).get("sessionID") for c in calls if c["state"]["status"] == "running")
            break
        if time.time() > deadline:
            raise SystemExit("The delegations and the background script did not start: " + json.dumps(
                {"background": background, "delegated": delegated, "script": script}))
        time.sleep(1)
    # Running first by latest start (the resumed child keeps its old creation), then finished by last run.
    order = [delegated, background, running, finished["interrupted"], finished["failed"], finished["succeeded"]]
    return ({"OPENCODE_AGENTS_PARENT": parent, "OPENCODE_AGENTS_RUNNING": running, "OPENCODE_AGENTS_ORDER": ",".join(order),
        "OPENCODE_AGENTS_DELEGATED": delegated, "OPENCODE_AGENTS_BACKGROUND": background, "OPENCODE_AGENTS_SCRIPT": script},
        args.only or "OpenCodeUITests/ConversationAgentsTests/testRunningAndFinishedShareOneScreenAndNavigationReturnsThroughIt")

try:
    root.mkdir()
    (root / "README.md").write_text("# Agentes e tarefas\n", encoding="utf8")
    git = ["git", "-C", str(root), "-c", "user.email=fixture@example.invalid", "-c", "user.name=Fixture"]
    subprocess.run(git[:3] + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-qm", "fixture"], check=True)

    order = []
    if args.scenario == "model":
        title = "Modelo do subagente " + token
        parent = imported(title, 10, lasted=1)
        api("/api/session/" + parent + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "delivery": "steer",
            "text": 'Chame a ferramenta subagent uma única vez com agent="general", description="Worker de teste", '
                'model="llm-proxy/gpt-6-luna#low", background=false, prompt="Responda apenas: OK." '
                'Depois responda apenas: OK.'})
        deadline = time.time() + 180
        while True:
            members = family(parent)
            worker = next((m for m in members if m.get("parentID") == parent), None)
            live = active()
            if worker and worker.get("context") and worker["id"] not in live and parent not in live:
                break
            if time.time() > deadline:
                raise SystemExit("The worker subagent did not finish: " + json.dumps({"worker": worker and worker["id"]}))
            time.sleep(1)
        assert worker["model"] == {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}, worker["model"]
        delegated = worker["id"]
        environment = {"OPENCODE_MODEL_PARENT": parent, "OPENCODE_MODEL_CHILD": delegated, "OPENCODE_MODEL_TITLE": title}
        only = args.only or "OpenCodeUITests/ConversationAgentsTests/testContinuedSubagentShowsItsLatestModelLive"
    else:
        environment, only = scenario_list()
    environment.update({"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
        "OPENCODE_TEST_THEME": args.theme, "OPENCODE_TEST_SERVER_URL": args.server_url})
    run = plistlib.loads(next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run
        else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    arguments = ["-OpenCodeServerURL", args.server_url, "-OpenCodeTheme", args.theme]
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["CommandLineArguments"] = arguments
        target["UITargetAppCommandLineArguments"] = arguments
        target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    subprocess.run(["xcrun", "simctl", "status_bar", args.device, "override", "--time", "10:58", "--dataNetwork", "wifi",
        "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
        "--batteryState", "charged", "--batteryLevel", "100"], check=True)
    result = args.evidence / (args.scenario + "-" + args.theme + "-" + token + ".xcresult")
    status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
        "-destination", "platform=iOS Simulator,id=" + args.device, "-parallel-testing-enabled", "NO",
        "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "300",
        "-resultBundlePath", str(result), "-only-testing:" + only])
    exported = args.evidence / ("attachments-" + token)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(exported)],
        check=True, stdout=subprocess.DEVNULL)
    for test in json.loads((exported / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = exported / attachment["exportedFileName"]
            if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                shutil.copyfile(source, args.evidence / (attachment["suggestedHumanReadableName"].split("_0_")[0] + ".png"))
    shutil.rmtree(exported)
    if status == 0:
        shutil.rmtree(result)
    print(json.dumps({"status": status, "parent": parent, "order": order, "running": running, "delegated": delegated,
        "background": background, "script": script}))
    sys.exit(status)
finally:
    configured.unlink(missing_ok=True)
    owned = [session for session in (parent, delegated, background, running) if session]
    for session in owned:
        api("/api/session/" + session + "/interrupt", {})
    if script:
        api("/api/shell/" + script + "?location%5Bdirectory%5D=" + urllib.request.quote(str(root), safe=""), method="DELETE")
    deadline = time.time() + 30
    while set(owned).intersection(active()) and time.time() < deadline:
        time.sleep(1)
    if parent:
        api("/api/session/" + parent, method="DELETE")
    shutil.rmtree(fixture)

#!/usr/bin/env python3
"""Snippets on the iPhone against an owned, isolated sandbox: Você ▸ Snippets (create, a name error, edit, duplicate,
scope, delete with confirmation) and the conversation shortcuts (Salvar como snippet from a message and from the
composer's selection, Novo snippet from `#`, `#` following saves without reopening).

Each phase runs on a simulator created for it and deleted afterwards. The catalog must start empty; every snippet,
Session and the fake repository's project data the run creates are removed at the end. No model call is made.

  OPENCODE_TEST_SERVER_URL=http://127.0.0.1:4195 OPENCODE_TEST_HOME=… OPENCODE_TEST_DERIVED=… \
    OPENCODE_TEST_EVIDENCE=… OPENCODE_TEST_THEME=openchamber-dark python3 packages/ios-custom/script/test-snippets.py
"""
import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
url = os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4177")
address = urllib.parse.urlparse(url)
assert address.hostname in ("127.0.0.1", "localhost") and address.port not in (None, 4096, 4178, 4179), \
    "use an isolated loopback sandbox"
home = Path(os.environ.get("OPENCODE_TEST_HOME", temporary / ("custom-sandbox-" + str(address.port))))
derived = Path(os.environ["OPENCODE_TEST_DERIVED"])
evidence = Path(os.environ.get("OPENCODE_TEST_EVIDENCE", temporary / "ios-snippets-prints"))
evidence.mkdir(parents=True, exist_ok=True)
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
           "Content-Type": "application/json"}
phases = sys.argv[1:] or ["testLibraryCreateEditDuplicateDelete", "testConversationShortcutsAndLiveHash"]


def api(path, body=None, method="GET"):
    request = urllib.request.Request(url + path, data=json.dumps(body).encode() if body is not None else None,
                                     headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
        return json.loads(data) if data else None


def catalog():
    return api("/api/rpc/custom.snippets/list", {"input": {}}, "POST")["output"]["items"]


def clear(report):
    items = catalog()
    for item in items:
        api("/api/rpc/custom.snippets/remove", {"input": {"id": item["id"]}}, "POST")
    report.setdefault("removed", []).append([item["name"] for item in items])


def run_phase(test, environment, report):
    """One xcodebuild run on a new simulator, deleted afterwards whatever happens."""
    device = subprocess.check_output(["xcrun", "simctl", "create", "OpenCode Snippets " + uuid.uuid4().hex[:8],
        "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"],
        text=True).strip()
    configured = derived / ("Build/Products/Snippets-" + uuid.uuid4().hex + ".xctestrun")
    label = test + "-" + theme
    try:
        subprocess.run(["xcrun", "simctl", "boot", device], check=True)
        subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["xcrun", "simctl", "ui", device, "content_size", "large"], check=True)
        subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--dataNetwork", "wifi",
            "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
            "--batteryState", "charged", "--batteryLevel", "100"], check=True)
        run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
        targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
                   if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
        for target in targets:
            target.setdefault("EnvironmentVariables", {}).update(environment)
            target["CommandLineArguments"] = ["-OpenCodeServerURL", url]
        configured.write_bytes(plistlib.dumps(run))
        configured.chmod(0o600)
        result = evidence / (label + "-" + uuid.uuid4().hex[:8] + ".xcresult")
        started = time.time()
        with (evidence / (label + ".log")).open("w") as log:
            status = subprocess.run(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
                "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
                "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
                "-maximum-test-execution-time-allowance", "600", "-resultBundlePath", str(result),
                "-only-testing:OpenCodeUITests/SnippetsUITests/" + test], stdout=log, stderr=subprocess.STDOUT).returncode
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path",
            str(evidence / (label + "-attachments"))], check=False, stdout=subprocess.DEVNULL)
        report[test] = {"status": status, "seconds": round(time.time() - started), "device": device,
                        "result": str(result)}
        return status
    finally:
        configured.unlink(missing_ok=True)
        subprocess.run(["xcrun", "simctl", "shutdown", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["xcrun", "simctl", "delete", device], check=False)


report = {"theme": theme, "server": url}
created = []
status = 1
try:
    if catalog():
        raise SystemExit("The sandbox catalog is not empty; this runner only clears what it creates.")
    # A Git repository with one commit is a Core project of its own (not "global"), so `#` and the editor see it.
    directory = home / "repos" / "snippets-ios"
    (directory / "src").mkdir(parents=True, exist_ok=True)
    (directory / "README.md").write_text("Repositório falso dos testes de snippets.\n")
    if not (directory / ".git").exists():
        git = ["git", "-C", str(directory), "-c", "user.name=OpenCode", "-c", "user.email=opencode@example.invalid"]
        subprocess.run(git[:3] + ["init", "-q"], check=True)
        subprocess.run(git + ["add", "."], check=True)
        subprocess.run(git + ["commit", "-qm", "fixture"], check=True)
    probe = api("/api/session", {"title": "Sonda de projeto", "location": {"directory": str(directory)}}, "POST")["data"]
    api("/api/session/" + probe["id"], method="DELETE")
    project_id = probe["projectID"]
    project = next(p for p in api("/api/project") if p["id"] == project_id)
    project_name = project.get("name") or Path(project["canonical"]).name
    now = int(time.time() * 1000)
    session = "ses_" + uuid.uuid4().hex
    message = "msg_" + uuid.uuid4().hex
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    api("/api/experimental/session/import", {
        "info": {"id": session, "title": "Snippets no iPhone", "projectID": project_id,
                 "location": {"directory": str(directory)}, "agent": "build", "model": model, "outcome": "succeeded",
                 "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                 "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": str(directory)},
        "messages": [
            {"id": message, "type": "user", "text": "Revise o diff atual e aponte riscos de regressão.",
             "time": {"created": now - 2000}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
             "time": {"created": now - 1500, "completed": now - 1000}, "finish": "stop",
             "content": [{"type": "text", "text": "Revisei o diff: nenhum risco encontrado."}]}]}, "POST")
    created.append(session)
    report.update({"session": session, "message": message, "project": project_id, "projectName": project_name})
    environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
                   "OPENCODE_TEST_THEME": theme, "OPENCODE_TEST_SERVER_URL": url,
                   "OPENCODE_SNIPPETS_SESSION": session, "OPENCODE_SNIPPETS_MESSAGE": message,
                   "OPENCODE_SNIPPETS_PROJECT": project_name}
    failures = 0
    for test in phases:
        failures += 1 if run_phase(test, environment, report) else 0
        items = catalog()
        report[test]["catalog"] = items
        # What the server kept is the proof, not only what the screen showed.
        names = sorted((item["name"], item.get("project") or "") for item in items)
        if test == "testLibraryCreateEditDuplicateDelete":
            expected = sorted([("revisar", ""), ("revisar", project_id)])
            glob = next((i for i in items if i["name"] == "revisar" and i.get("project") is None), {})
            ok = names == expected and glob.get("aliases") == ["review"] \
                and glob.get("description") == "Revisa o diff e aponta riscos"
        else:
            expected = sorted([("revise-o-diff", project_id), ("deploy-ios", project_id), ("externo-api", ""),
                               ("rode-os-testes", project_id)])
            ok = names == expected
        report[test]["catalogMatches"] = ok
        if not ok:
            failures += 1
            print("Unexpected catalog after", test, names)
        clear(report)
    status = 1 if failures else 0
    print("Result:", status, "Evidence:", evidence)
finally:
    try:
        clear(report)
    finally:
        for id in created:
            api("/api/session/" + id, method="DELETE")
        (evidence / ("ledger-" + theme + ".json")).write_text(json.dumps(report, indent=2))
sys.exit(status)

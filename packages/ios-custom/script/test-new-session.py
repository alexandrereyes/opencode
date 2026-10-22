#!/usr/bin/env python3
"""Wave 9, dedicated simulator and explicit sandbox launches only; never seeds or production.

The failure test changes only the simulator's own saved new-session base branch to
an invalid ref, while the app is stopped. No Git refs or server configuration change.
"""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
home = temporary / "custom-sandbox-4177"
derived = temporary / "ios-sessoes-derived"
evidence = temporary / "ios-onda9-prints"
evidence.mkdir(parents=True, exist_ok=True)
lease = (temporary / "ios-sessoes-test.lock").open("a")
fcntl.flock(lease, fcntl.LOCK_EX)
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
token = uuid.uuid4().hex
configured = derived / ("Build/Products/NewSession-" + token + ".xctestrun")
report = {"theme": theme, "runs": [], "sessions": [], "worktrees": [], "production": "never used"}

def api(path, body=None, method="GET"):
    request = urllib.request.Request("http://127.0.0.1:4177" + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
        return json.loads(data) if data else None

projects = api("/api/project")
project = next(p for p in projects if p["canonical"] == str(home / "repos/abacato-v2"))
ledger_path = evidence / "worktrees-created.json"
ledger = json.loads(ledger_path.read_text()) if ledger_path.exists() else []
before = {s["id"] for s in api("/api/session?limit=500")["data"]}
worktrees_before = {w["directory"] for w in api("/api/worktree?projectID=" + project["id"])}
real_worktrees = Path.home() / "Worktrees"
folders_before = {str(p) for p in real_worktrees.iterdir() if p.is_dir()}
fake_roots = [p for p in (home / "repos").iterdir() if (p / ".git").exists()]

def fake_checkouts():
    return {line.removeprefix("worktree ") for root in fake_roots
        for line in subprocess.check_output(["git", "-C", str(root), "worktree", "list", "--porcelain"], text=True).splitlines()
        if line.startswith("worktree ")}

def cleanup_worktrees():
    inventory = api("/api/worktree?projectID=" + project["id"])
    for item in inventory:
        if item["directory"] in worktrees_before:
            continue
        directory = item["directory"]
        assert directory in fake_checkouts(), "Refuse an unregistered checkout"
        common = subprocess.check_output(["git", "-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"], text=True).strip()
        assert Path(common).resolve() == (Path(project["canonical"]) / ".git").resolve(), "Refuse a real repository's checkout"
        verification = {"directory": directory, "kept": False}
        try:
            owned = {s["id"] for s in api("/api/session?limit=500")["data"]
                if s["id"] not in before and s["location"]["directory"] == directory}
            deadline = time.monotonic() + 60
            while owned.intersection(api("/api/session/active")["data"]):
                if time.monotonic() >= deadline:
                    for session in owned:
                        api("/api/session/" + session + "/interrupt", method="POST")
                    raise RuntimeError("Verification execution did not settle")
                time.sleep(0.25)
            verification["revision"] = subprocess.check_output(["git", "-C", directory, "rev-parse", "HEAD"], text=True).strip()
            verification["baseRevision"] = subprocess.check_output(["git", "-C", project["canonical"], "rev-parse", "feat/redesign-identidade"], text=True).strip()
            verification["matchesBase"] = verification["revision"] == verification["baseRevision"]
            q = urllib.parse.urlencode({"location[directory]": directory})
            verification["mcp"] = [{"name": s["name"], "status": s["status"]["status"]} for s in api("/api/mcp?" + q)["data"]]
        finally:
            api("/api/worktree", {"projectID": project["id"], "directory": directory, "force": True}, method="DELETE")
            assert not Path(directory).exists() and directory not in fake_checkouts()
            ledger.append({"directory": directory, "projectID": project["id"], "removed": True})
            report["worktrees"].append(verification)
            ledger_path.write_text(json.dumps(ledger, indent=2))
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
device = next(d["udid"] for group in devices["devices"].values() for d in group if d["name"] == "OpenCode Sessoes")
def draft_path():
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, "br.com.alexandrem.opencode", "data"], text=True).strip())
    return container / "Library/Application Support/OpenCode/Drafts" / hashlib.sha256(b"http://127.0.0.1:4177").hexdigest() / "new-session/draft.json"

def run_case(case):
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme}
    targets = [t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"]
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["CommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    result = temporary / ("onda9-" + case + "-" + token + ".xcresult")
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", "platform=iOS Simulator,name=OpenCode Sessoes",
        "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
        "-maximum-test-execution-time-allowance", "300", "-resultBundlePath", str(result), "-only-testing:OpenCodeUITests/NewSessionTests/" + case]
    status = subprocess.call(command)
    report["runs"].append({"case": case, "status": status, "result": str(result)})
    cleanup_worktrees()
    export = evidence / ("attachments-" + case + "-" + token)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(export)], check=True)
    for test in json.loads((export / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = export / attachment["exportedFileName"]
            if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                shutil.copyfile(source, evidence / (attachment["suggestedHumanReadableName"].split("_0_")[0] + ".png"))
    if status:
        raise RuntimeError("UI test failed: " + case)

try:
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    cases = sys.argv[1:] or ["test01SelectorsPreviewAndPersistentDraft", "test02InvalidBaseKeepsDraftAndShowsToast", "test03SendRootExistingAndNewWorktree", "test04SelectorKeyboardDismissalAndComposerRestoration"]
    for case in cases:
        if case in ["test01SelectorsPreviewAndPersistentDraft", "test04SelectorKeyboardDismissalAndComposerRestoration"]:
            subprocess.run(["xcrun", "simctl", "terminate", device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            draft_path().unlink(missing_ok=True)
        if case == "test02InvalidBaseKeepsDraftAndShowsToast":
            # No app runs between XCTest cases; persisted tokens, attachments and intent remain intact.
            draft = draft_path()
            value = json.loads(draft.read_text())
            assert value["newSession"]["projectID"] == project["id"]
            assert value["newSession"]["destination"] == {"create": {}}
            original_base = value["newSession"].get("baseBranch")
            value["newSession"]["baseBranch"] = "onda9-invalid-base"
            draft.write_text(json.dumps(value))
        try:
            run_case(case)
        finally:
            if case == "test02InvalidBaseKeepsDraftAndShowsToast":
                draft = draft_path()
                value = json.loads(draft.read_text())
                if value.get("newSession"):
                    value["newSession"]["baseBranch"] = original_base
                    draft.write_text(json.dumps(value))
finally:
    configured.unlink(missing_ok=True)
    cleanup_worktrees()
    for session in api("/api/session?limit=500")["data"]:
        if session["id"] in before:
            continue
        if session.get("projectID") not in {p["id"] for p in projects if p["canonical"].startswith(str(home / "repos") + "/")}:
            continue
        report["sessions"].append({k: session.get(k) for k in ["id", "location", "model", "agent", "outcome"]})
    for item in ledger:
        if not Path(item["directory"]).exists() and item["directory"] not in fake_checkouts():
            item["removed"] = True
    additions = {str(p) for p in real_worktrees.iterdir() if p.is_dir()} - folders_before
    report["leftoverFakeCheckouts"] = sorted(p for p in fake_checkouts() if Path(p).parent == real_worktrees)
    report["newFoldersStillPresent"] = sorted(additions)
    assert not report["leftoverFakeCheckouts"]
    ledger_path.write_text(json.dumps(ledger, indent=2))
    (evidence / ("verification-" + theme + "-" + token + ".json")).write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))

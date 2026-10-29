#!/usr/bin/env python3
"""Wave 5 simulator checks. Only disposable owned sessions are mutated; no model calls."""
import base64
import fcntl
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import time
import urllib.request
import uuid

signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
# Overrides let an isolated worker use its own sandbox, build and simulator (never 4096/4178).
server = os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4177")
home = Path(os.environ.get("OPENCODE_TEST_HOME", str(temporary / "custom-sandbox-4177")))
derived = Path(os.environ.get("OPENCODE_TEST_DERIVED", str(temporary / "ios-sessoes-derived")))
lease = (temporary / "ios-sessoes-test.lock").open("a")
fcntl.flock(lease, fcntl.LOCK_EX)
manifest = json.loads((home / "seed-conversation.json").read_text())
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}

def api(path, body=None, method="POST"):
    request = urllib.request.Request(server + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
token = uuid.uuid4().hex
own, missing = "ses_" + uuid.uuid4().hex, "ses_" + uuid.uuid4().hex
# Outside any Git repository: a vanished non-Git directory offers no move to a root checkout.
directory = home / "repos" / ("onda5-location-" + token)
directory.mkdir()
moved = directory.with_name(directory.name + "-moved")
# A fake Git project whose worktree `sumiu` (holding a parent and a child Session) is removed, with `outro` left to
# choose: the relocation offer of testMoveToProjectRootRestoresComposerWithStrandedChild.
relocate_root = home / "repos" / ("onda5-relocate-" + token)
relocate_worktrees = relocate_root.with_name(relocate_root.name + "-worktrees")
relocate, relocate_child = "ses_" + uuid.uuid4().hex, "ses_" + uuid.uuid4().hex
relocate_created = False

def git(*command):
    subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Fixture",
        "-c", "user.email=fixture@example.invalid", *command], cwd=relocate_root, check=True, capture_output=True)

def history(session, title, path, parent=None):
    info = {"id": session, "title": title, "projectID": "global", "location": {"directory": path}, "agent": "build",
        "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
        "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}}
    if parent:
        info["parentID"] = parent
    api("/api/experimental/session/import", {"info": info, "location": {"directory": path}, "messages": [
        {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Uma sessão de verificação isolada.", "time": {"created": now - 1000}},
        {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build",
         "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
         "time": {"created": now - 900, "completed": now - 800},
         "finish": "stop", "content": [{"type": "text", "text": "Histórico preservado para conferir os controles nativos."}]}]})
now = int(time.time() * 1000)
configuration = derived / ("Build/Products/SessionReading-" + token + ".xctestrun")
evidence = Path(os.environ.get("OPENCODE_TEST_EVIDENCE", str(temporary / "ios-conversa-prints/onda5")))
result = temporary / ("onda5-" + theme + "-" + token + ".xcresult")
try:
    history(own, "Onda 5 — ações", manifest["directory"])
    history(missing, "Onda 5 — diretório ausente", str(directory))
    directory.rename(moved)
    relocate_root.mkdir()
    (relocate_root / "README.md").write_text("Repositório fictício de verificação.\n")
    git("init", "-b", "main")
    git("add", ".")
    git("commit", "-m", "Fixture")
    git("worktree", "add", "-b", "outro", str(relocate_worktrees / "outro"))
    git("worktree", "add", "-b", "sumiu", str(relocate_worktrees / "sumiu"))
    relocate_created = True
    history(relocate, "Onda 5 — mover para a raiz", str(relocate_worktrees / "sumiu"))
    history(relocate_child, "Onda 5 — subsessão ilhada", str(relocate_worktrees / "sumiu"), parent=relocate)
    git("worktree", "remove", str(relocate_worktrees / "sumiu"))
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_TEST_THEME": theme, "OPENCODE_TEST_SERVER_URL": server,
                   "OPENCODE_TEST_SESSION_ACTIONS": own, "OPENCODE_TEST_SESSION_MISSING": missing,
                   "OPENCODE_TEST_SESSION_RELOCATE": relocate}
    for key, role in [("A", "working"), ("C", "history"), ("CHILD", "child-1")]:
        environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
    targets = ([target for c in run["TestConfigurations"] for target in c["TestTargets"]]
               if "TestConfigurations" in run else [value for key, value in run.items() if key != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["EnvironmentVariables"]["OPENCODE_SERVER_PASSWORD"] = password
        target["CommandLineArguments"] = ["-OpenCodeServerURL", server]
    configuration.write_bytes(plistlib.dumps(run))
    configuration.chmod(0o600)
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configuration), "-destination",
        "platform=iOS Simulator," + ("id=" + os.environ["OPENCODE_TEST_DEVICE"] if "OPENCODE_TEST_DEVICE" in os.environ else "name=OpenCode Sessoes"), "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
        "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "180",
        "-resultBundlePath", str(result)]
    for method in sys.argv[1:] or ["OpenCodeUITests/SessionReadingTests"]:
        command.append("-only-testing:" + method)
    status = subprocess.call(command)
    evidence.mkdir(parents=True, exist_ok=True)
    export = evidence / ("attachments-" + theme + "-" + token)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(export)], check=True)
    for test in json.loads((export / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = export / attachment["exportedFileName"]
            name = attachment["suggestedHumanReadableName"].split("_0_")[0]
            if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                shutil.copyfile(source, evidence / (name.replace("openchamber-", "") + ".png"))
    info = api("/api/session/" + own, method="GET")["data"]
    report = {"session": own, "title": info.get("title"), "archived": info["time"].get("archived"),
              "missingSession": missing, "result": str(result), "status": status}
    (evidence / ("verification-" + theme + ".json")).write_text(json.dumps(report, indent=2))
    print(json.dumps(report))
    if status == 0 and (not sys.argv[1:] or any(method in {
        "OpenCodeUITests/SessionReadingTests", "OpenCodeUITests/SessionReadingTests/testMenuRenameAndArchiveOwnSession"
    } for method in sys.argv[1:])):
        assert info.get("title") == "Onda 5 — renomeada" and info["time"].get("archived") is not None
    sys.exit(status)
finally:
    configuration.unlink(missing_ok=True)
    if moved.exists():
        moved.rename(directory)
    directory.rmdir()
    if relocate_created:
        # The server deletes the child with its parent.
        api("/api/session/" + relocate, method="DELETE")
    shutil.rmtree(relocate_worktrees, ignore_errors=True)
    shutil.rmtree(relocate_root, ignore_errors=True)

#!/usr/bin/env python3
"""Case-insensitive composer suggestions against an isolated sandbox. Creates a fake repository, two disposable
Sessions and one snippet, runs ComposerCaseUITests (or the given test IDs) and removes what it created."""
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
assert urllib.parse.urlparse(url).port not in (None, 4096, 4178), "use an isolated sandbox"
home = Path(os.environ.get("OPENCODE_TEST_HOME", temporary / "custom-sandbox-4177"))
derived = Path(os.environ.get("OPENCODE_TEST_DERIVED", temporary / "ios-case-derived"))
device = os.environ["OPENCODE_TEST_SIMULATOR"]
evidence = Path(os.environ.get("OPENCODE_TEST_EVIDENCE", temporary / "ios-case-prints"))
evidence.mkdir(parents=True, exist_ok=True)
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
label = os.environ.get("OPENCODE_TEST_LABEL", theme)
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
           "Content-Type": "application/json"}


def api(path, body=None, method="GET"):
    request = urllib.request.Request(url + path, data=json.dumps(body).encode() if body is not None else None,
                                     headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
        return json.loads(data) if data else None


directory = home / "repos" / "composer-case"
(directory / "src").mkdir(parents=True, exist_ok=True)
(directory / "README.md").write_text("readme\n")
(directory / "src" / "SafariBridge.ts").write_text("export {}\n")
if not (directory / ".git").exists():
    subprocess.run(["git", "init", "-q", str(directory)], check=True)
query = urllib.parse.urlencode({"location[directory]": str(directory)})
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
created = []


def session(title, messages):
    now = int(time.time() * 1000)
    id = "ses_" + uuid.uuid4().hex
    api("/api/experimental/session/import", {
        "info": {"id": id, "title": title, "projectID": "global", "location": {"directory": str(directory)},
                 "agent": "build", "model": model, "outcome": "succeeded", "cost": 0,
                 "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                 "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": str(directory)}, "messages": messages}, "POST")
    created.append(id)
    return id


report = {"theme": theme}
configured = derived / ("Build/Products/Case-" + uuid.uuid4().hex + ".xctestrun")
try:
    now = int(time.time() * 1000)
    conversation = session("Caixa das sugestões", [
        {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Teste de caixa.", "time": {"created": now - 1000}}])
    target = session("Sessão Revisão Especial", [])
    api("/api/rpc/custom.snippets/save?" + query, {"input": {
        "id": "snip-commit", "name": "commit-push-pr", "description": "Commit, push e PR", "aliases": ["cpp"],
        "content": "Faça commit, push e abra o PR."}}, "POST")
    skill = next(s["id"] for s in api("/api/skill?" + query)["data"] if s["id"].isascii() and s["id"].isalpha())
    command = next(c["name"] for c in api("/api/command?" + query)["data"] if c["name"].isascii() and c["name"].isalpha())
    agent = next(a["id"] for a in api("/api/agent?" + query)["data"]
                 if a.get("mode") != "primary" and not a.get("hidden") and a["id"].isascii() and a["id"].isalpha())
    report.update({"conversation": conversation, "target": target, "skill": skill, "command": command, "agent": agent})
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
               if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for test_target in targets:
        test_target.setdefault("EnvironmentVariables", {}).update({
            "OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme,
            "OPENCODE_TEST_SERVER_URL": url, "OPENCODE_CASE_SESSION": conversation, "OPENCODE_CASE_TARGET": target,
            "OPENCODE_CASE_SKILL": skill, "OPENCODE_CASE_COMMAND": command, "OPENCODE_CASE_AGENT": agent})
        test_target["CommandLineArguments"] = ["-OpenCodeServerURL", url]
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    command_line = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", "id=" + device,
                    "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                    "-resultBundlePath", str(evidence / (label + "-" + uuid.uuid4().hex[:8] + ".xcresult"))]
    command_line += ["-only-testing:" + t for t in (sys.argv[1:] or ["OpenCodeUITests/ComposerCaseUITests"])]
    with (evidence / (label + ".log")).open("w") as log:
        result = subprocess.run(command_line, stdout=log, stderr=subprocess.STDOUT)
    report["result"] = result.returncode
    # The `!` case sends one prompt; its file reference must be the one `@` used to send.
    sent = [m for m in api("/api/session/" + conversation + "/message?limit=20&order=desc")["data"]
            if m["type"] == "user" and "@README.md" in json.dumps(m)]
    if sent:
        report["bangMessage"] = sent[0]
        uris = [f.get("source", {}).get("uri") or f.get("uri") for f in sent[0].get("files", [])]
        report["bangFileURIs"] = uris
        if ("file://" + str(directory / "README.md")) not in uris and ("file://" + str(directory.resolve() / "README.md")) not in uris:
            report["result"] = 1
            print("The sent `!` message lacks the README.md file reference")
    print("Result:", report["result"], "Log:", evidence / (label + ".log"))
finally:
    configured.unlink(missing_ok=True)
    api("/api/rpc/custom.snippets/remove?" + query, {"input": {"id": "snip-commit"}}, "POST")
    for id in created:
        api("/api/session/" + id, method="DELETE")
    (evidence / (label + "-ledger.json")).write_text(json.dumps(report, indent=2))
sys.exit(report.get("result", 1))

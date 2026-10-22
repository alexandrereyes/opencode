#!/usr/bin/env python3
"""Run sandbox-only XCUITests. Credentials stay in the generated, private xctestrun file."""
import base64
import fcntl
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import urllib.request
import uuid

temporary = Path(os.environ.get("TMPDIR", "/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T")).resolve() / "opencode"
home = temporary / "custom-sandbox-4177"
derived = temporary / "ios-sessoes-derived"
# Every invocation drives the same dedicated simulator and installed app.
lease = (temporary / "ios-sessoes-test.lock").open("a")
fcntl.flock(lease, fcntl.LOCK_EX)
password = (home / "password").read_text().strip()
manifest = json.loads((home / "seed-conversation.json").read_text())
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
           "Content-Type": "application/json"}

def api(path, body=None, method="POST"):
    request = urllib.request.Request("http://127.0.0.1:4177" + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

own = "ses_" + uuid.uuid4().hex
comment = "ses_" + uuid.uuid4().hex
created = []
now = int(time.time() * 1000)
try:
    for session in [own, comment]:
        messages = [] if session != comment else [
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Confira este trecho.", "time": {"created": now - 1000}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build",
             "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
             "time": {"created": now - 900, "completed": now - 800}, "finish": "stop",
             "content": [{"type": "text", "text": "Trecho para conferir os comentários."}]}]
        api("/api/experimental/session/import", {
            "info": {"id": session, "title": "Onda 6 — comentários" if session == comment else "Onda 6 — teclado", "projectID": "global",
                "location": {"directory": manifest["directory"]}, "agent": "build",
                "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
            "location": {"directory": manifest["directory"]}, "messages": messages})
        created.append(session)
    source = next(derived.glob("Build/Products/OpenCode_*.xctestrun"))
    run = plistlib.loads(source.read_bytes())
    environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_TEST_OWN": own,
                   "OPENCODE_TEST_COMMENT": comment,
                   "OPENCODE_TEST_THEME": os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")}
    for key, role in [("A", "working"), ("B", "permission"), ("C", "history")]:
        environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
    targets = [target for configuration in run.get("TestConfigurations", [])
               for target in configuration["TestTargets"]] if "TestConfigurations" in run else [value for key, value in run.items() if key != "__xctestrun_metadata__"]
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["EnvironmentVariables"]["OPENCODE_SERVER_PASSWORD"] = password
        target["CommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
    configured = derived / ("Build/Products/ReadingContinuity-" + str(now) + ".xctestrun")
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured),
        "-destination", "platform=iOS Simulator,name=OpenCode Sessoes", "-parallel-testing-enabled", "NO",
        "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
        "-maximum-test-execution-time-allowance", "300",
        "-resultBundlePath", str(temporary / ("onda6-" + str(now) + ".xcresult"))]
    for method in sys.argv[1:]:
        command += ["-only-testing:" + (method if "/" in method or method in {"OpenCodeTests", "OpenCodeUITests"} else "OpenCodeUITests/ReadingContinuityTests/" + method)]
    status = subprocess.call(command)
    if status == 0 and (not sys.argv[1:] or any(method.endswith("testTokensInComments") for method in sys.argv[1:])):
        messages = api("/api/rpc/custom.transcript/list", {"input": {"sessionID": comment, "limit": 200, "order": "asc"}})["output"]["data"]
        sent = next(message for message in messages if message["type"] == "user" and message.get("metadata", {}).get("quotes"))
        display = sent["metadata"]["displayText"]
        quote = sent["metadata"]["quotes"][0]
        evidence = temporary / "ios-conversa-prints/onda6/final/comment-server-verification.json"
        evidence.parent.mkdir(parents=True, exist_ok=True)
        evidence.write_text(json.dumps({"sessionID": comment, "id": sent["id"], "text": sent["text"], "metadata": sent["metadata"],
            "files": [{key: value for key, value in file.items() if key != "data"} for file in sent["files"]],
            "agents": [{key: value for key, value in agent.items() if key in {"name", "mention"}} for agent in sent["agents"]],
            "skills": [{key: value for key, value in skill.items() if key in {"id", "name", "mention"}} for skill in sent["skills"]]}, indent=2, ensure_ascii=False))
        assert "@docs/alternativas.md" in quote["comment"] and "$conversation-check" in quote["comment"] and "#resumo" in quote["comment"]
        expansion = next(part["expansion"] for part in quote["commentPrompt"] if part["type"] == "snippet")
        assert "User comment: " + quote["comment"].replace("#resumo", expansion).strip() in sent["text"]
        files = sent["files"]
        main = next(file for file in files if file.get("mention") is not None)
        mention = main["mention"]
        token = "@docs/infra.md"
        start = display.index(token)
        assert mention["text"] == token
        assert mention["start"] == sum(2 if ord(char) > 0xFFFF else 1 for char in display[:start])
        assert mention["end"] == mention["start"] + len(token)
        assert any(file.get("name") == "alternativas.md" and file.get("mention") is None for file in files)
        assert any(agent.get("name") == "explore" and agent.get("mention") is None for agent in sent["agents"])
        assert any(skill.get("mention") is None for skill in sent["skills"])
        print("COMMENT VERIFIED: structured file/agent/skill, unchanged main UTF-16 offsets, expanded snippet; session=" + comment)
    sys.exit(status)
finally:
    if "configured" in locals():
        configured.unlink(missing_ok=True)
    for session in created:
        api("/api/session/" + session + "/interrupt", {})
        api("/api/session/" + session, method="DELETE")

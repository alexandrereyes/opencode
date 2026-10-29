#!/usr/bin/env python3
"""Screen-to-master UI tests in an owned sandbox: no audio, no GPT Live call.

The fixture admits one real prompt with the screen to the sandbox's Sessão mestra. The runner interrupts the
master as soon as that prompt is stored, checks the image part and saves the JPEG the master received.
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
import urllib.error
import urllib.parse
import urllib.request
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
server = os.environ["OPENCODE_VOICE_SERVER_URL"]
address = urllib.parse.urlparse(server)
assert address.hostname == "127.0.0.1" and address.port not in (None, 4096, 4177, 4178)
home = Path(os.environ["OPENCODE_VOICE_HOME"])
derived = Path(os.environ["OPENCODE_VOICE_DERIVED"])
evidence = Path(os.environ["OPENCODE_VOICE_EVIDENCE"])
device = os.environ["OPENCODE_VOICE_DEVICE"]
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
    "Content-Type": "application/json"}
evidence.mkdir(parents=True, exist_ok=True)


def api(path, body=None, method="POST"):
    request = urllib.request.Request(server + path, data=json.dumps(body).encode() if body is not None else None,
        headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        print(error.read().decode()[:2000], file=sys.stderr)
        raise


def master_id():
    return (api("/api/rpc/custom.preferences/get", {"input": {}})["output"]["data"].get("masterSessions") or {}).get("local")


def screen_prompts(master):
    if not master:
        return []
    rows = api("/api/rpc/custom.transcript/list", {"input": {"sessionID": master, "limit": 40}})["output"]["data"]
    return [row for row in rows if row.get("type") == "user" and "[Captura da tela do app OpenCode anexada" in json.dumps(row)]


root = home / "repos" / "voz-tela"
root.mkdir(parents=True, exist_ok=True)
session = "ses_" + uuid.uuid4().hex
now = int(time.time() * 1000)
configured = derived / ("Build/Products/VoiceScreen-" + uuid.uuid4().hex + ".xctestrun")
before_master = master_id()
before = len(screen_prompts(before_master))
created = False
report = {"theme": theme, "session": session, "interrupted": [], "masterPrompts": 0}
try:
    api("/api/experimental/session/import", {"info": {"id": session, "title": "Voz · tela da conversa",
        "projectID": "global", "location": {"directory": str(root)}, "agent": "build",
        "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
        "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": str(root)}, "messages": [
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Por que o teste de voz falhou?",
             "time": {"created": now - 1000}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build",
             "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
             "time": {"created": now - 900, "completed": now - 500}, "finish": "stop",
             "content": [{"type": "text", "text": "A tela mostra esta conversa sintética para a mestra conferir."}]}]})
    created = True
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([target for config in run["TestConfigurations"] for target in config["TestTargets"]]
        if "TestConfigurations" in run else [value for key, value in run.items() if key != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update({"OPENCODE_TEST_PASSWORD": password,
            "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme, "OPENCODE_VOICE_SESSION": session,
            "OPENCODE_TEST_SERVER_URL": server})
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    result = evidence / ("screen-" + theme + "-" + uuid.uuid4().hex[:8] + ".xcresult")
    command = ["xcodebuild", "-quiet", "test-without-building", "-xctestrun", str(configured),
        "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
        "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)]
    for test in sys.argv[1:] or ["OpenCodeUITests/VoiceScreenUITests"]:
        command.append("-only-testing:" + test)
    process = subprocess.Popen(command)
    # Stop the master's model run as soon as the screen prompt is stored: only admission is under test.
    while process.poll() is None:
        master = master_id()
        prompts = screen_prompts(master)
        if len(prompts) > before and master not in report["interrupted"]:
            api("/api/session/" + master + "/interrupt", {})
            report["interrupted"].append(master)
        time.sleep(0.5)
    status = process.returncode
    master = master_id()
    prompts = screen_prompts(master)
    report["masterPrompts"] = len(prompts) - before
    if prompts:
        latest = prompts[0] if prompts[0]["id"] > prompts[-1]["id"] else prompts[-1]
        images = [part for part in latest.get("files") or [] if str(part.get("mime", "")).startswith("image/")]
        report["imageParts"] = [{key: (value if key != "data" else len(value)) for key, value in part.items()} for part in images]
        if images:
            (evidence / (theme + "-sent-to-master.jpg")).write_bytes(base64.b64decode(images[0]["data"]))
        stored = dict(latest, files=report["imageParts"])
        (evidence / (theme + "-master-prompt.json")).write_text(json.dumps(stored, ensure_ascii=False, indent=2))
        report["text"] = latest.get("text")
    attachments = evidence / (result.stem + "-attachments")
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path",
        str(attachments)], check=True)
    for test in json.loads((attachments / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = attachments / attachment["exportedFileName"]
            if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                shutil.copyfile(source, evidence / (theme + "-" + attachment["suggestedHumanReadableName"].split("_0_")[0] + ".png"))
    report.update({"status": status, "result": str(result), "voiceCalls": 0})
    print(json.dumps(report, ensure_ascii=False))
    sys.exit(status)
finally:
    configured.unlink(missing_ok=True)
    if created:
        api("/api/session/" + session, method="DELETE")
    (evidence / ("report-" + theme + ".json")).write_text(json.dumps(report, ensure_ascii=False, indent=2))

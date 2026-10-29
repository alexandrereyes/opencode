#!/usr/bin/env python3
"""Mac voice screen checks against an owned sandbox: simulated GPT Live, real Sessão mestra, no permission prompt.

Runs a Debug OpenCodeMac copy (own bundle identifier, ad-hoc signed, opened in the background with `open -g`) once
per scenario of `MacVoiceScreenCheck`. A fake system stands in for the front app, the window list and Screen
Recording; OpenCode's own window is captured for real. The master is interrupted as soon as each prompt is stored;
the JPEG it received is saved.

  OPENCODE_VOICE_SERVER_URL=http://127.0.0.1:<port> OPENCODE_VOICE_HOME=<sandbox home> \
  OPENCODE_MAC_APP=<Debug OpenCodeMac.app> OPENCODE_VOICE_EVIDENCE=<folder> python3 script/test-mac-voice-screen.py
"""
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
import urllib.parse
import urllib.request
import uuid

server = os.environ["OPENCODE_VOICE_SERVER_URL"]
address = urllib.parse.urlparse(server)
assert address.hostname == "127.0.0.1" and address.port not in (None, 4096, 4177, 4178)
home = Path(os.environ["OPENCODE_VOICE_HOME"])
app = Path(os.environ["OPENCODE_MAC_APP"])
evidence = Path(os.environ["OPENCODE_VOICE_EVIDENCE"])
evidence.mkdir(parents=True, exist_ok=True)
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
    "Content-Type": "application/json"}
domain = "br.com.alexandrem.opencode.mac.debug.voice-screen"
scenarios = {
    "own": {"text": "Dá uma olhada nessa tela", "screen": "front"},
    "first": {"text": "Olha o Chrome", "screen": "app", "screen_app": "Chrome"},
    "denied": {"text": "Olha essa página", "screen": "front"},
    "granted": {"text": "Olha essa página", "screen": "front"},
    "display": {"text": "Olha minha tela toda", "screen": "display"},
    "missing": {"text": "Olha o simulador", "screen": "app", "screen_app": "Simulator"},
}
expected = {"own": "sent:", "first": "sent:", "denied": "sent:", "granted": "sent:", "display": "sent:",
    "missing": "refused:appNotRunning"}


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


def clear_state():
    # A window frame saved off-screen by the previous run keeps the next one from opening its window.
    subprocess.run(["defaults", "delete", domain], capture_output=True)
    saved = Path.home() / "Library/Saved Application State" / f"{domain}.savedState"
    if saved.exists():
        shutil.rmtree(saved)


def master_id():
    return (api("/api/rpc/custom.preferences/get", {"input": {}})["output"]["data"].get("masterSessions") or {}).get("local")


def screen_prompts(master):
    if not master:
        return []
    rows = api("/api/rpc/custom.transcript/list", {"input": {"sessionID": master, "limit": 40}})["output"]["data"]
    return sorted((row for row in rows if row.get("type") == "user" and "[Captura " in (row.get("text") or "")),
        key=lambda row: row["id"])


root = home / "repos" / "voz-tela-mac"
root.mkdir(parents=True, exist_ok=True)
session = "ses_" + uuid.uuid4().hex
now = int(time.time() * 1000)
report = {"session": session, "scenarios": {}, "voiceCalls": 0}
created = False
with tempfile.TemporaryDirectory(prefix="mac-voice-screen-", dir=evidence) as temporary:
    copy = Path(temporary) / "OpenCodeMacVoiceScreen.app"
    shutil.copytree(app, copy, symlinks=True)
    info = copy / "Contents/Info.plist"
    metadata = plistlib.loads(info.read_bytes())
    metadata["CFBundleIdentifier"] = domain
    info.write_bytes(plistlib.dumps(metadata))
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(copy)], check=True, capture_output=True)
    try:
        api("/api/experimental/session/import", {"info": {"id": session, "title": "Voz · tela no Mac",
            "projectID": "global", "location": {"directory": str(root)}, "agent": "build",
            "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
            "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
            "location": {"directory": str(root)}, "messages": [
                {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Por que o build do Mac falhou?",
                 "time": {"created": now - 1000}},
                {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build",
                 "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                 "time": {"created": now - 900, "completed": now - 500}, "finish": "stop",
                 "content": [{"type": "text", "text": "Conversa sintética aberta na janela do OpenCode no Mac."}]}]})
        created = True
        for name in sys.argv[1:] or scenarios:
            clear_state()
            before = {row["id"] for row in screen_prompts(master_id())}
            log = evidence / f"{name}.log"
            log.unlink(missing_ok=True)
            command = ["open", "-g", "-n", "--env", "OPENCODE_SERVER_PASSWORD=" + password,
                "--stdout", str(log), "--stderr", str(log), str(copy), "--args",
                "-OpenCodeServerURL", server, "-OpenCodeVoiceScreenFixture",
                "-OpenCodeVoiceScreenDelay", "2", "-OpenCodeVoiceScreenJSON", json.dumps(scenarios[name], ensure_ascii=False),
                "-OpenCodeMacVoiceScreenCheck", name, "-OpenCodeMacVoiceScreenSession", session,
                "-OpenCodeMacVoiceScreenEvidence", str(evidence)]
            subprocess.run(command, check=True)
            executable = str(copy / "Contents/MacOS/OpenCodeMac")
            running = lambda: subprocess.run(["pgrep", "-f", executable], capture_output=True).returncode == 0
            interrupted = []
            deadline = time.time() + 120
            time.sleep(1)
            while running() and time.time() < deadline:
                master = master_id()
                if master and master not in interrupted and any(row["id"] not in before for row in screen_prompts(master)):
                    api("/api/session/" + master + "/interrupt", {})
                    interrupted.append(master)
                time.sleep(0.5)
            if running():
                subprocess.run(["pkill", "-f", executable])
            lines = [line for line in log.read_text().splitlines() if line.startswith("MacVoiceScreen ")] if log.exists() else []
            outcome = next((line.split(": ", 1)[1] for line in lines if "outcome:" in line), "missing")
            result = {"outcome": outcome, "log": lines, "interrupted": interrupted, "ok": outcome.startswith(expected[name])}
            new = [row for row in screen_prompts(master_id()) if row["id"] not in before]
            result["masterPrompts"] = len(new)
            if new:
                prompt = new[-1]
                images = [part for part in prompt.get("files") or [] if str(part.get("mime", "")).startswith("image/")]
                result["text"] = prompt.get("text")
                result["imageParts"] = [{key: (value if key != "data" else len(value)) for key, value in part.items()} for part in images]
                if images:
                    extension = "png" if images[0].get("mime") == "image/png" else "jpg"
                    (evidence / f"{name}-sent-to-master.{extension}").write_bytes(base64.b64decode(images[0]["data"]))
            if name == "missing":
                result["ok"] = result["ok"] and not new
            report["scenarios"][name] = result
            print(name, json.dumps(result, ensure_ascii=False), flush=True)
    finally:
        if created:
            api("/api/session/" + session, method="DELETE")
        clear_state()
        (evidence / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
ok = all(result["ok"] for result in report["scenarios"].values())
print(json.dumps({"ok": ok, "report": str(evidence / "report.json")}))
sys.exit(0 if ok else 1)

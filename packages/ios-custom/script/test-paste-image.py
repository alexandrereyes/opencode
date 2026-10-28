#!/usr/bin/env python3
"""Pasted images become composer attachments, against an isolated sandbox. Imports one owned conversation with a
response in a fake repository, runs ComposerPasteImageUITests (or the given test IDs), checks the image files of the
messages it sent and deletes the conversation."""
import base64
import json
import os
from pathlib import Path
import plistlib
import re
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
derived = Path(os.environ.get("OPENCODE_TEST_DERIVED", temporary / "ios-paste-derived"))
device = os.environ["OPENCODE_TEST_SIMULATOR"]
evidence = Path(os.environ.get("OPENCODE_TEST_EVIDENCE", temporary / "ios-paste-prints"))
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


def images(message):
    """Pasted images by name, whether sent inline, staged as paths or inside a quote; plus the inline image parts."""
    names = sorted(set(re.findall(r"Imagem-[0-9A-F]{6}\.[a-z]+", json.dumps(message))))
    inline = [f.get("name") for f in message.get("files", []) if str(f.get("mime", "")).startswith("image/")]
    return names, inline


directory = home / "repos" / "paste-image"
directory.mkdir(parents=True, exist_ok=True)
if not (directory / ".git").exists():
    subprocess.run(["git", "init", "-q", str(directory)], check=True)
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
token = uuid.uuid4().hex
conversation = "ses_" + token
source = "msg_" + token + "0001"
now = int(time.time() * 1000)
report = {"theme": theme, "conversation": conversation}
configured = derived / ("Build/Products/Paste-" + uuid.uuid4().hex + ".xctestrun")
created = False
try:
    api("/api/experimental/session/import", {
        "info": {"id": conversation, "title": "Colar imagens", "projectID": "global",
                 "location": {"directory": str(directory)}, "agent": "build", "model": model, "outcome": "succeeded",
                 "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                 "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": str(directory)},
        "messages": [
            {"id": "msg_" + token + "0000", "type": "user", "text": "Mostre um trecho.", "time": {"created": now - 2000}},
            {"id": source, "type": "assistant", "agent": "build", "model": model,
             "time": {"created": now - 1000, "completed": now - 999}, "finish": "stop",
             "content": [{"type": "text", "text": "Este trecho de resposta recebe um comentário com uma imagem colada."}]},
        ]}, "POST")
    created = True
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
               if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for test_target in targets:
        test_target.setdefault("EnvironmentVariables", {}).update({
            "OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme,
            "OPENCODE_TEST_SERVER_URL": url, "OPENCODE_PASTE_SESSION": conversation, "OPENCODE_PASTE_SOURCE": source})
        test_target["CommandLineArguments"] = ["-OpenCodeServerURL", url]
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    command_line = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", "id=" + device,
                    "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                    "-resultBundlePath", str(evidence / (label + "-" + uuid.uuid4().hex[:8] + ".xcresult"))]
    tests = sys.argv[1:] or ["OpenCodeUITests/ComposerPasteImageUITests"]
    command_line += ["-only-testing:" + t for t in tests]
    with (evidence / (label + ".log")).open("w") as log:
        result = subprocess.run(command_line, stdout=log, stderr=subprocess.STDOUT)
    report["result"] = result.returncode
    sent = [m for m in api("/api/session/" + conversation + "/message?limit=20&order=desc")["data"] if m["type"] == "user"]
    expected = {"Imagens coladas:": 3, "Comentário com imagem colada.": 1}
    for message in sent:
        text = message.get("metadata", {}).get("displayText") or message.get("text", "")
        for prefix, count in expected.items():
            if text.startswith(prefix):
                names, inline = images(message)
                report[prefix] = {"images": names, "inlineImageParts": inline, "text": message.get("text", "")[:600]}
                if len(names) != count or "\ufffc" in message.get("text", ""):
                    report["result"] = 1
                    print("Unexpected images in", repr(prefix), names, "expected", count)
    for prefix in expected:
        wanted = any(t.endswith(name) for t in tests for name in (
            ["ComposerPasteImageUITests", "testPasteMenuAndCommandVAddImagesAsAttachmentsAndSend"] if prefix.startswith("Imagens")
            else ["ComposerPasteImageUITests", "testCommentSheetPastesAnImageAsItsAttachment"]))
        if wanted and prefix not in report:
            report["result"] = 1
            print("No sent message for", repr(prefix))
    print("Result:", report["result"], "Log:", evidence / (label + ".log"))
finally:
    configured.unlink(missing_ok=True)
    if created:
        api("/api/session/" + conversation, method="DELETE")
    (evidence / (label + "-ledger.json")).write_text(json.dumps(report, indent=2, ensure_ascii=False))
sys.exit(report.get("result", 1))

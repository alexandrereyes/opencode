#!/usr/bin/env python3
"""Owned image fixtures only; explicit sandbox launches, no model or production mutations."""
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import time
import urllib.request
import urllib.error
import uuid
import zlib

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
home = temporary / "custom-sandbox-4177"
derived = temporary / "ios-imagens-derived"
device = "C70D22D2-4EFC-4C70-A7D4-F085C26D40D6"
evidence = temporary / "ios-imagens-prints"
evidence.mkdir(exist_ok=True)
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}

def api(path, body=None, method="POST"):
    request = urllib.request.Request("http://127.0.0.1:4177" + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        print("Sandbox request failed:", path, error.code, error.read().decode()[:1000])
        raise

manifest = json.loads((home / "seed-conversation.json").read_text())
root = Path(manifest["directory"]).resolve()
assert root.is_relative_to((home / "repos").resolve())
token = uuid.uuid4().hex[:10]
folder = root / ("ios-images-" + token)
outside = root / ("ios-images-assets-" + token)
folder.mkdir()
outside.mkdir()

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

rows = b"".join(b"\x00" + b"".join(bytes((int(40 + x * 140 / 640), int(90 + y * 110 / 360), 180 if (x // 80 + y // 60) % 2 else 230))
    for x in range(640)) for y in range(360))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 640, 360, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
(folder / "image.png").write_bytes(png)
(outside / "outside.png").write_bytes(png)
encoded = base64.b64encode(png).decode()
data_uri = "data:image/png;base64," + encoded
server_home = Path(api("/api/rpc/custom.directories/home", {"input": {}})["output"]["path"])
now = int(time.time() * 1000)
created = []
configured = derived / ("Build/Products/Images-" + token + ".xctestrun")
environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
    "OPENCODE_TEST_THEME": os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")}
sources = {
    "RELATIVE": "image.png", "ABSOLUTE": str(outside / "outside.png"),
    "TILDE": "~/" + os.path.relpath(folder / "image.png", server_home),
    "FILE": (folder / "image.png").as_uri(), "DATA": data_uri,
    "HTML": "image.png", "LOOPBACK": "http://localhost:4096/api/fs/read/image.png?location%5Bdirectory%5D=" + urllib.parse.quote(str(folder), safe=""),
    "MISSING": "missing-image.png", "MACONLY": "http://localhost:3000/image.png",
    "INTERNAL": "https://unreachable-image-svc.invalid/image.png",
    "HTTPS": "https://httpbin.org/image/png",
    "ATTACHMENT": data_uri, "READ": data_uri, "MCP": data_uri,
}
try:
    for role, source in sources.items():
        session = "ses_" + uuid.uuid4().hex
        user = {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Verificação isolada · " + role, "time": {"created": now - 1000}}
        content = [{"type": "text", "text": "![" + role + "](" + source + ")"}]
        if role == "HTML":
            content = [{"type": "text", "text": '<img src="image.png" alt="HTML">'}]
        if role == "ATTACHMENT":
            user["files"] = [{"mime": "image/png", "name": role, "data": encoded, "source": {"type": "inline"}}]
            content = [{"type": "text", "text": "Imagem anexada pelo usuário."}]
        if role in {"READ", "MCP"}:
            content = [{"type": "tool", "id": "call_" + uuid.uuid4().hex,
                "name": "read" if role == "READ" else "browser_screenshot", "time": {"created": now - 800, "ran": now - 800, "completed": now - 700},
                "state": {"status": "completed", "input": {"path": str(folder / "image.png")} if role == "READ" else {},
                    "content": [{"type": "text", "text": "Imagem de teste isolada."}, {"type": "file", "uri": data_uri, "mime": "image/png", "name": role}]}}]
        api("/api/experimental/session/import", {"info": {"id": session, "title": "Imagens · " + role, "projectID": "global",
            "location": {"directory": str(folder)}, "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
            "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
            "location": {"directory": str(folder)}, "messages": [user,
                {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                 "time": {"created": now - 900, "completed": now - 600}, "finish": "stop", "content": content}]})
        created.append(session)
        environment["OPENCODE_IMAGE_" + role] = session
    missing = folder / "missing-directory"
    missing.mkdir()
    moved = folder / "missing-directory-moved"
    for role, directory in [("SESSION_ACTIONS", root), ("SESSION_MISSING", missing)]:
        session = "ses_" + uuid.uuid4().hex
        api("/api/experimental/session/import", {"info": {"id": session, "title": "Onda 5 — ações", "projectID": "global",
            "location": {"directory": str(directory)}, "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
            "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
            "location": {"directory": str(directory)}, "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build",
                "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}, "finish": "stop",
                "time": {"created": now - 1000, "completed": now - 900},
                "content": [{"type": "text", "text": "Histórico preservado para conferir os controles nativos."}]}]})
        created.append(session)
        environment["OPENCODE_TEST_" + role] = session
    missing.rename(moved)
    for key, role in [("A", "working"), ("C", "history"), ("CHILD", "child-1")]:
        environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["CommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    result = evidence / ("images-" + environment["OPENCODE_TEST_THEME"] + "-" + token + ".xcresult")
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", "platform=iOS Simulator,id=" + device,
        "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "180", "-resultBundlePath", str(result)]
    for test in sys.argv[1:] or ["OpenCodeUITests/FeedImageTests", "OpenCodeTests"]:
        command.append("-only-testing:" + test)
    status = subprocess.call(command)
    exported = evidence / ("attachments-" + token)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(exported)], check=True)
    for test in json.loads((exported / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = exported / attachment["exportedFileName"]
            if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                name = attachment["suggestedHumanReadableName"].split("_0_")[0]
                shutil.copyfile(source, evidence / (name + ".png"))
    print(json.dumps({"status": status, "result": str(result), "ownedSessions": len(created)}))
    sys.exit(status)
finally:
    configured.unlink(missing_ok=True)
    for session in created:
        api("/api/session/" + session, method="DELETE")
    for image in [folder / "image.png", outside / "outside.png"]:
        image.unlink(missing_ok=True)
    if "moved" in locals() and moved.exists():
        moved.rmdir()
    if "missing" in locals() and missing.exists():
        missing.rmdir()
    folder.rmdir()
    outside.rmdir()

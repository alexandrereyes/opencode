#!/usr/bin/env python3
"""Session file explorer UI test against an owned git checkout and imported session; no model or seed changes.

Run after `build-for-testing`:
  python3 packages/ios-custom/script/test-file-explorer.py --device <sim-udid> --derived <DerivedData> \
    --home <sandbox-home> --server-url http://127.0.0.1:<port> --evidence <prints-dir>
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
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--device", required=True)
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--home", type=Path, required=True, help="custom-sandbox.ts home (reads its password file)")
parser.add_argument("--server-url", default="http://127.0.0.1:4177")
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--theme", default=os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark"))
args = parser.parse_args()
port = int(args.server_url.rsplit(":", 1)[1].rstrip("/"))
if port in (4096, 4178) or not args.server_url.startswith(("http://127.0.0.1:", "http://localhost:")):
    parser.error("Use an isolated loopback sandbox, never 4096 or 4178")

password = (args.home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
def api(path, body=None, method="POST"):
    request = urllib.request.Request(args.server_url + path, data=json.dumps(body).encode() if body is not None else None,
        headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

token = uuid.uuid4().hex[:10]
fixture = Path(tempfile.mkdtemp(prefix="ios-file-explorer-" + token + "-")).resolve()
root = fixture / "repo"
configured = next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).with_name("Explorer-" + token + ".xctestrun")
args.evidence.mkdir(parents=True, exist_ok=True)
session = None
try:
    (root / "src/deep").mkdir(parents=True)
    (root / "docs").mkdir()
    (root / "README.md").write_text("# Repositório fictício\n", encoding="utf8")
    (root / "src/main.swift").write_text("let a = 1\n", encoding="utf8")
    (root / "src/deep/inner.txt").write_text("Arquivo interno\n", encoding="utf8")
    (root / ".env").write_text("FIXTURE=1\n", encoding="utf8")
    (root / "docs/config.json").write_text('{"a": 1}\n', encoding="utf8")
    git = ["git", "-C", str(root), "-c", "user.email=fixture@example.invalid", "-c", "user.name=Fixture"]
    subprocess.run(git[:3] + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-qm", "fixture"], check=True)
    (root / "src/main.swift").write_text("let a = 1\nlet b = 2\n", encoding="utf8")
    (root / "docs/new.md").write_text("Novo\n", encoding="utf8")
    (fixture / "outside.txt").write_text("Fora da sessão, acima do diretório de trabalho.\n", encoding="utf8")
    (root / "locked").mkdir()
    (root / "locked").chmod(0)

    now = int(time.time() * 1000)
    session = "ses_" + uuid.uuid4().hex
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    api("/api/experimental/session/import", {"info": {"id": session, "title": "Explorador de arquivos", "projectID": "global",
        "location": {"directory": str(root)}, "agent": "build", "model": model, "cost": 0,
        "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}, "outcome": "succeeded",
        "time": {"created": now, "updated": now, "idle": now, "viewed": now}}, "location": {"directory": str(root)},
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Verificação do explorador.", "time": {"created": now - 1000}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
             "time": {"created": now - 900, "completed": now - 600}, "finish": "stop", "content": [{"type": "text", "text": "Pronto."}]}]})

    environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": args.theme,
        "OPENCODE_TEST_SERVER_URL": args.server_url, "OPENCODE_EXPLORER_SESSION": session, "OPENCODE_EXPLORER_ROOT": str(root)}
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
    result = args.evidence / ("explorer-" + args.theme + "-" + token + ".xcresult")
    status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
        "-destination", "platform=iOS Simulator,id=" + args.device, "-parallel-testing-enabled", "NO",
        "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "300",
        "-resultBundlePath", str(result), "-only-testing:OpenCodeUITests/FileExplorerTests"])
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
    print(json.dumps({"status": status, "session": session}))
    sys.exit(status)
finally:
    configured.unlink(missing_ok=True)
    if session:
        api("/api/session/" + session, method="DELETE")
    if (root / "locked").exists():
        (root / "locked").chmod(0o700)
    shutil.rmtree(fixture)

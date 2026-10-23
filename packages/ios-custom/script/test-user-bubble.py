#!/usr/bin/env python3
"""Owned Bolha simulator and synthetic imports; explicit sandbox credentials, no model calls."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--prepare", action="store_true")
parser.add_argument("--cleanup", action="store_true")
parser.add_argument("--label", default="user-bubble")
parser.add_argument("tests", nargs="*")
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
home = temporary / "custom-sandbox-4177"
products = temporary / "ios-bolha-derived/Build/Products"
evidence = temporary / "ios-bolha-prints"
evidence.mkdir(exist_ok=True)
manifest_path = evidence / "owned-sessions.json"
device = "49BFE0E0-8D48-406C-A5D1-491DE91CA392"
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}

def api(path, body=None, method="POST"):
    request = urllib.request.Request("http://127.0.0.1:4177" + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

if args.prepare:
    assert not manifest_path.exists(), "Clean the previous owned imports first"
    seed = json.loads((home / "seed-conversation.json").read_text())
    directory = Path(seed["directory"])
    assert directory.is_relative_to(home / "repos")
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    now = int(time.time() * 1000)
    sessions = []
    for role in ["BUBBLE", "SHORT"]:
        session = "ses_" + uuid.uuid4().hex
        user = "msg_" + uuid.uuid4().hex
        text = "Primeira linha.\nSegunda linha." if role == "SHORT" else "Pedido longo de comparação.\n" + "\n".join(
            f"Detalhe {n}: preserve a leitura da resposta e o contexto do pedido sintético." for n in range(1, 25)) + "\nDetalhe final exclusivo."
        answer = "\n\n".join(f"## Etapa {n}\n\nResposta sintética para conferir a rolagem. O pedido fica fixado sem mudar de tamanho por conta própria.\n\n- Leitura preservada.\n- Expansão apenas manual."
            for n in range(1, 35))
        api("/api/experimental/session/import", {"info": {"id": session, "title": "Bolha — " + role,
            "projectID": "global", "location": {"directory": str(directory)}, "agent": "build", "model": model,
            "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
            "location": {"directory": str(directory)}, "messages": [
                {"id": user, "type": "user", "text": text, "time": {"created": now - 1000},
                    "metadata": {"quotes": [{"id": "quote-bolha", "messageID": "msg_quote_bolha", "partID": "part_quote_bolha", "text": "Citação sintética preservada.", "comment": "Comentário preservado."}],
                        "attachments": [{"name": "nota-sintetica.txt"}]} if role == "BUBBLE" else {}},
                {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
                    "time": {"created": now - 900, "completed": now - 800}, "finish": "stop",
                    "content": [{"type": "text", "text": answer}]},
            ]})
        sessions.append({"role": role, "id": session, "userMessageID": user, "directory": str(directory)})
        manifest_path.write_text(json.dumps(sessions, indent=2) + "\n")
    print(json.dumps(sessions))
    raise SystemExit()

owned = json.loads(manifest_path.read_text()) if manifest_path.exists() else []
if args.cleanup:
    for session in owned:
        assert Path(session["directory"]).is_relative_to(home / "repos")
        api("/api/session/" + session["id"], method="DELETE")
    manifest_path.rename(evidence / "removed-sessions.json")
    print("Removed", len(owned), "owned synthetic imports; no model calls")
    raise SystemExit()

run = plistlib.loads(next(products.glob("OpenCode_*.xctestrun")).read_bytes())
targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
    if "TestConfigurations" in run else [value for key, value in run.items() if key != "__xctestrun_metadata__"])
seed = json.loads((home / "seed-conversation.json").read_text())
for target in targets:
    environment = target.setdefault("EnvironmentVariables", {})
    environment.update({"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
        "OPENCODE_TEST_THEME": os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark"), "OPENCODE_FOLLOW_LIVE": "0"})
    for session in owned:
        environment["OPENCODE_TEST_" + session["role"]] = session["id"]
        environment["OPENCODE_TEST_" + session["role"] + "_MESSAGE"] = session["userMessageID"]
    for key, role in [("A", "working"), ("B", "permission"), ("C", "history"), ("CHILD", "child-1")]:
        environment["OPENCODE_TEST_" + key] = next(s["id"] for s in seed["sessions"] if s["role"] == role)
    arguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
    target["CommandLineArguments"] = arguments
    target["UITargetAppCommandLineArguments"] = arguments
    target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
configured = products / ("Bolha-" + args.label + ".xctestrun")
configured.write_bytes(plistlib.dumps(run))
configured.chmod(0o600)
video = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo", str(evidence / (args.label + ".mp4"))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    result = evidence / (args.label + ".xcresult")
    with (evidence / (args.label + "-test.log")).open("w") as output:
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)] +
            ["-only-testing:" + test for test in (args.tests or ["OpenCodeUITests/UserBubbleTests"])], stdout=output, stderr=subprocess.STDOUT)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
        "--output-path", str(evidence / (args.label + "-attachments"))], check=True)
    summary = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)])
    (evidence / (args.label + "-summary.json")).write_bytes(summary)
    print(args.label, "status", status)
    raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    video.send_signal(signal.SIGINT)
    video.wait(timeout=30)
    subprocess.run(["xcrun", "simctl", "terminate", device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

#!/usr/bin/env python3
"""Owned quote histories on sandbox 4184; no seed mutations or model calls."""
import argparse
import base64
import json
import hashlib
from pathlib import Path
import plistlib
import subprocess
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("action", choices=["prepare", "test", "cleanup"])
parser.add_argument("--theme", default="openchamber-dark")
parser.add_argument("--device", default="C8FF24A6-89EE-42D4-B7E2-4BEDBE5E5060")
parser.add_argument("--label", default="quotes-dark")
parser.add_argument("tests", nargs="*")
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
home = temporary / "custom-sandbox-4184"
evidence = temporary / "ios-citacoes-prints"
evidence.mkdir(parents=True, exist_ok=True)
ledger = evidence / "owned-sessions.json"
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}

def api(path, body=None, method="POST"):
    request = urllib.request.Request("http://127.0.0.1:4184" + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

if args.action == "prepare":
    assert not ledger.exists(), "Clean previous owned sessions first"
    directory = home / "repos/citacoes-fixture"
    directory.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", str(directory)], check=True, stdout=subprocess.DEVNULL)
    sessions = []
    now = int(time.time() * 1000)
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    source = "Uma escolha que deixei como está: a consultora também recebe o botão Meu negócio. Faz sentido se ela também vender outra marca; se preferir esconder o botão, é uma condição a mais no Core."
    for theme in ["dark", "light", "web"]:
        for kind in ["pending", "sent", "paged", "missing"]:
            token = uuid.uuid4().hex
            session = "ses_" + token
            def mid(n): return "msg_" + token + f"{n:04d}"
            def user(n, text, metadata=None):
                return {"id": mid(n), "type": "user", "text": text, "time": {"created": now + n}, "metadata": metadata or {}}
            def assistant(n, text):
                return {"id": mid(n), "type": "assistant", "agent": "build", "model": model,
                    "time": {"created": now + n, "completed": now + n + 1}, "finish": "stop", "content": [{"type": "text", "text": text}]}
            messages = [user(0, "Confira a decisão de apresentação."), assistant(1, "**Uma escolha que deixei como está:**" + source[len("Uma escolha que deixei como está:"):])]
            quote = {"id": "quote-owned-" + token, "messageID": mid(1), "partID": mid(1) + ":text:0",
                "text": source, "comment": "Confira esta decisão antes de continuar."}
            if kind == "paged":
                messages += [item for n in range(2, 64, 2) for item in [user(n, "Pedido sintético " + str(n)), assistant(n + 1, "Resposta sintética " + str(n))]]
            if kind != "pending":
                if kind == "missing": quote["messageID"] = "msg_missing"; quote["partID"] = "msg_missing:text:0"
                messages += [user(70, "Comentário enviado.", {"displayText": "Comentário enviado.", "comments": [], "quotes": [quote]}), assistant(71, "Decisão registrada.")]
            api("/api/experimental/session/import", {"info": {"id": session, "title": "Citações " + theme + " " + kind,
                "projectID": "global", "location": {"directory": str(directory)}, "agent": "build", "model": model,
                "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
                "location": {"directory": str(directory)}, "messages": messages})
            sessions.append({"theme": theme, "kind": kind, "id": session, "source": mid(1), "carrier": mid(70), "quote": quote, "directory": str(directory)})
            ledger.write_text(json.dumps(sessions, indent=2))
    print("Imported", len(sessions), "owned histories")
    raise SystemExit()

owned = json.loads(ledger.read_text())
if args.action == "cleanup":
    for session in owned:
        assert Path(session["directory"]).is_relative_to(home / "repos")
        api("/api/session/" + session["id"], method="DELETE")
    ledger.rename(evidence / "removed-sessions.json")
    print("Removed", len(owned), "owned histories")
    raise SystemExit()

products = temporary / "ios-citacoes-derived/Build/Products"
restored = next(item for item in owned if item["theme"] == "web" and item["kind"] == "pending")
subprocess.run(["xcrun", "simctl", "terminate", args.device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["xcrun", "simctl", "install", args.device, str(products / "Debug-iphonesimulator/OpenCode.app")], check=True)
container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.device, "br.com.alexandrem.opencode", "data"], text=True).strip())
draft = container / "Library/Application Support/OpenCode/Drafts" / hashlib.sha256(b"http://127.0.0.1:4184").hexdigest() / restored["id"] / "draft.json"
draft.parent.mkdir(parents=True, exist_ok=True)
draft.write_text(json.dumps({"document": {"text": "", "tokens": []}, "attachments": [], "cursor": 0,
    "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}, "quotes": [restored["quote"]]}))
draft.chmod(0o600)
live = any(case == "OpenCodeUITests/QuoteSendingTests" for case in args.tests)
pending = next(item for item in owned if item["theme"] == ("light" if args.theme.endswith("light") else "dark") and item["kind"] == "pending")
if live:
    live_draft = draft.parent.parent / pending["id"] / "draft.json"
    live_draft.parent.mkdir(parents=True, exist_ok=True)
    live_draft.write_text(json.dumps({"document": {"text": "", "tokens": []}, "attachments": [], "cursor": 0,
        "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}, "quotes": []}))
    live_draft.chmod(0o600)
run = plistlib.loads(next(products.glob("OpenCode_*.xctestrun")).read_bytes())
targets = ([target for config in run["TestConfigurations"] for target in config["TestTargets"]]
    if "TestConfigurations" in run else [value for key, value in run.items() if key != "__xctestrun_metadata__"])
for target in targets:
    environment = target.setdefault("EnvironmentVariables", {})
    environment.update(OPENCODE_TEST_PASSWORD=password, OPENCODE_SERVER_PASSWORD=password,
        OPENCODE_TEST_THEME=args.theme, OPENCODE_TEST_SERVER_URL="http://127.0.0.1:4184")
    environment.update(OPENCODE_QUOTE_RESTORED=restored["id"], OPENCODE_QUOTE_RESTORED_SOURCE=restored["source"])
    for item in owned:
        if item["theme"] == ("light" if args.theme.endswith("light") else "dark"):
            key = "OPENCODE_QUOTE_" + item["kind"].upper()
            environment[key] = item["id"]
            environment[key + "_SOURCE"] = item["source"]
            environment[key + "_CARRIER"] = item["carrier"]
    arguments = ["-OpenCodeServerURL", "http://127.0.0.1:4184", "-OpenCodeTheme", args.theme]
    target["CommandLineArguments"] = arguments
    target["UITargetAppCommandLineArguments"] = arguments
    target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
configured = products / (args.label + ".xctestrun")
configured.write_bytes(plistlib.dumps(run))
configured.chmod(0o600)
try:
    started = time.monotonic()
    result = evidence / (args.label + ".xcresult")
    with (evidence / (args.label + ".log")).open("w") as log:
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=" + args.device, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)] +
            ["-only-testing:" + case for case in (args.tests or ["OpenCodeUITests/QuoteHighlightTests"])], stdout=log, stderr=subprocess.STDOUT)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(evidence / (args.label + "-attachments"))], check=True, stdout=subprocess.DEVNULL)
    if live and status == 0:
        messages = api("/api/session/" + pending["id"] + "/message?limit=20&order=desc", method="GET")["data"]
        sent = next(message for message in messages if message["type"] == "user" and message.get("metadata", {}).get("quotes"))
        assert sent["metadata"]["model"] == {"providerID": "llm-proxy", "modelID": "gpt-6-luna", "variant": "low"}
        assert sent["metadata"]["quotes"][0]["anchor"]["coordinate"] == "source"
        assert sent["metadata"]["quotes"][0]["comment"] == "Comentário sintético de verificação."
        (evidence / (args.label + "-wire.json")).write_text(json.dumps({"sessionID": pending["id"],
            "messageID": sent["id"], "model": sent["metadata"]["model"], "quotes": sent["metadata"]["quotes"]}, indent=2))
    (evidence / (args.label + ".json")).write_text(json.dumps({"status": status, "seconds": time.monotonic() - started, "device": args.device}))
    raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "terminate", args.device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

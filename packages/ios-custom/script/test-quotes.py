#!/usr/bin/env python3
"""Owned quote histories on sandbox 4184; no seed mutations or model calls."""
import argparse
import base64
import json
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import time
import urllib.request
import urllib.parse
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("action", choices=["prepare", "test", "cleanup"])
parser.add_argument("--theme", default="openchamber-dark")
parser.add_argument("--device", default="C8FF24A6-89EE-42D4-B7E2-4BEDBE5E5060")
parser.add_argument("--label", default="quotes-dark")
parser.add_argument("--server-url", default=os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4184"))
parser.add_argument("--home", type=Path)
parser.add_argument("--derived", type=Path)
parser.add_argument("--evidence", type=Path)
parser.add_argument("--content-size")
parser.add_argument("--quotes-unavailable", action="store_true", help="Run against a server without custom.quotes (local mode)")
parser.add_argument("tests", nargs="*")
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
url = urllib.parse.urlparse(args.server_url)
if url.scheme != "http" or url.hostname not in ["127.0.0.1", "localhost"] or url.port in [None, 4096, 4178]:
    parser.error("Quotation verification requires an isolated loopback sandbox")
server_url = args.server_url.rstrip("/")
home = args.home or Path(os.environ.get("OPENCODE_TEST_HOME", temporary / ("custom-sandbox-" + str(url.port))))
owner = json.loads((home / "sandbox.json").read_text())
assert Path(owner["home"]).resolve() == home.resolve() and owner["port"] == url.port
evidence = args.evidence or Path(os.environ.get("OPENCODE_TEST_EVIDENCE", temporary / "ios-citacoes-prints"))
evidence.mkdir(parents=True, exist_ok=True)
ledger = evidence / "owned-sessions.json"
password = (home / "password").read_text().strip()
live_source = "**Uma escolha** que deixei: o botão Meu negócio aparece para ela. Depois, o botão Meu negócio some."
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}

def api(path, body=None, method="POST"):
    request = urllib.request.Request(server_url + path,
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
        for kind in ["pending", "sent", "paged", "missing", "multiple", "removable", "failing",
            "create", "live", "send", "migrate", "local"]:
            token = uuid.uuid4().hex
            session = "ses_" + token
            def mid(n): return "msg_" + token + f"{n:04d}"
            def user(n, text, metadata=None):
                return {"id": mid(n), "type": "user", "text": text, "time": {"created": now + n}, "metadata": metadata or {}}
            def assistant(n, text):
                return {"id": mid(n), "type": "assistant", "agent": "build", "model": model,
                    "time": {"created": now + n, "completed": now + n + 1}, "finish": "stop", "content": [{"type": "text", "text": text}]}
            messages = [user(0, "Confira a decisão de apresentação."), assistant(1, "**Uma escolha que deixei como está:**" + source[len("Uma escolha que deixei como está:"):])]
            if kind in ["live", "send"]:
                # Repeated phrase: the web anchor below resolves to the second one by its prefix.
                messages[1]["content"][0]["text"] = live_source
            quote = {"id": "quote-owned-" + token, "messageID": mid(1), "partID": mid(1) + ":text:0",
                "text": source, "comment": "Confira esta decisão antes de continuar."}
            if kind == "paged":
                messages += [item for n in range(2, 64, 2) for item in [user(n, "Pedido sintético " + str(n)), assistant(n + 1, "Resposta sintética " + str(n))]]
            if kind not in ["pending", "failing", "create", "live", "send", "migrate", "local"]:
                if kind == "missing": quote["messageID"] = "msg_missing"; quote["partID"] = "msg_missing:text:0"
                quotes = [quote] if kind != "multiple" else [
                    {**quote, "id": quote["id"] + "-1", "text": "Uma escolha que deixei como está:", "comment": "Primeiro comentário."},
                    {**quote, "id": quote["id"] + "-2", "text": "Faz sentido se ela também vender outra marca;", "comment": "Segundo comentário."}]
                messages += [user(70, "Comentário enviado.", {"displayText": "Comentário enviado.", "comments": [], "quotes": quotes}), assistant(71, "Decisão registrada.")]
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

products = (args.derived or Path(os.environ.get("OPENCODE_TEST_DERIVED", temporary / "ios-citacoes-derived"))) / "Build/Products"
restored = next(item for item in owned if item["theme"] == "web" and item["kind"] == "pending")
subprocess.run(["xcrun", "simctl", "terminate", args.device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["xcrun", "simctl", "install", args.device, str(products / "Debug-iphonesimulator/OpenCode.app")], check=True)
container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.device, "br.com.alexandrem.opencode", "data"], text=True).strip())
draft = container / "Library/Application Support/OpenCode/Drafts" / hashlib.sha256(server_url.encode()).hexdigest() / restored["id"] / "draft.json"
draft.parent.mkdir(parents=True, exist_ok=True)
draft.write_text(json.dumps({"document": {"text": "", "tokens": []}, "attachments": [], "cursor": 0,
    "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}, "quotes": [restored["quote"]]}))
draft.chmod(0o600)
theme = "light" if args.theme.endswith("light") else "dark"
# Removal and rejected-send cases must start from their imported state on every run.
marks = container / "Library/Application Support/OpenCode/QuoteMarks" / (hashlib.sha256(server_url.encode()).hexdigest() + ".json")
removable = {item["id"] for item in owned if item["kind"] == "removable"}
if marks.exists():
    marks.write_text(json.dumps([entry for entry in json.loads(marks.read_text()) if entry["sessionID"] not in removable]))
failing = next(item for item in owned if item["theme"] == theme and item["kind"] == "failing")
failing_draft = draft.parent.parent / failing["id"] / "draft.json"
failing_draft.parent.mkdir(parents=True, exist_ok=True)
failing_draft.write_text(json.dumps({"document": {"text": "", "tokens": []}, "attachments": [], "cursor": 0,
    "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}, "quotes": []}))
failing_draft.chmod(0o600)
def rpc(method, session, **input):
    query = "?location%5Bdirectory%5D=" + urllib.parse.quote(session["directory"], safe="")
    return api("/api/rpc/custom.quotes/" + method + query, {"input": {"sessionID": session["id"], **input}})["output"]
def owned_kind(kind): return next(item for item in owned if item["theme"] == theme and item["kind"] == kind)
server_cases = any("QuoteServerTests" in case for case in args.tests)
if server_cases:
    subprocess.run(["xcrun", "simctl", "addmedia", args.device, str(Path(__file__).parent / "icon-source.png")], check=True)
    for kind in ["create", "live", "send", "migrate", "local"]:
        item = owned_kind(kind)
        rpc("clear", item, reason="discarded")
        (draft.parent.parent / item["id"]).mkdir(parents=True, exist_ok=True)
        local = draft.parent.parent / item["id"] / "draft.json"
        local.unlink(missing_ok=True)
    live_item, send_item, migrate_item = owned_kind("live"), owned_kind("send"), owned_kind("migrate")
    rpc("save", live_item, quote={"id": "seed-" + uuid.uuid4().hex, "messageID": live_item["source"],
        "partID": live_item["source"] + ":text:0", "text": "Uma escolha", "comment": "Comentário semeado.",
        "anchor": {"start": 2, "end": 13, "exact": "Uma escolha", "coordinate": "source", "prefix": "", "suffix": " que deixei"}})
    for n in [1, 2]:
        rpc("save", send_item, quote={"id": "seed-" + uuid.uuid4().hex, "messageID": send_item["source"],
            "partID": send_item["source"] + ":text:0", "text": "o botão Meu negócio", "comment": "Comentário semeado " + str(n) + "."})
    # The pre-server shape: quote, photo file beside draft.json, and a hidden mark in QuoteMarks.
    legacy = draft.parent.parent / migrate_item["id"]
    image = {"id": "legacy-photo", "name": "legado.png", "mime": "image/png", "size": (Path(__file__).parent / "icon-source.png").stat().st_size, "quoteID": "legacy-quote"}
    (legacy / "legacy-photo").write_bytes((Path(__file__).parent / "icon-source.png").read_bytes())
    legacy_quote = {"id": "legacy-quote", "messageID": migrate_item["source"], "partID": migrate_item["source"] + ":text:0",
        "text": "Uma escolha que deixei como está:", "comment": "Comentário legado.",
        "commentPrompt": [{"type": "text", "start": 0, "end": 18, "content": "Comentário legado."},
            {"type": "image", "id": "legacy-photo", "filename": "legado.png", "mime": "image/png"}]}
    (legacy / "draft.json").write_text(json.dumps({"document": {"text": "Texto local preservado.", "tokens": []},
        "attachments": [image], "cursor": 0, "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
        "quotes": [legacy_quote]}))
    entries = json.loads(marks.read_text()) if marks.exists() else []
    marks.parent.mkdir(parents=True, exist_ok=True)
    marks.write_text(json.dumps([entry for entry in entries if entry["sessionID"] != migrate_item["id"]]
        + [{"sessionID": migrate_item["id"], "quotes": ["legacy-sent"]}]))
live = any(case == "OpenCodeUITests/QuoteSendingTests" for case in args.tests)
pending = next(item for item in owned if item["theme"] == theme and item["kind"] == "pending")
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
        OPENCODE_TEST_THEME=args.theme, OPENCODE_TEST_SERVER_URL=server_url)
    if args.content_size: environment["OPENCODE_TEST_CONTENT_SIZE"] = args.content_size
    environment.update(OPENCODE_QUOTE_RESTORED=restored["id"], OPENCODE_QUOTE_RESTORED_SOURCE=restored["source"])
    for item in owned:
        if item["theme"] == ("light" if args.theme.endswith("light") else "dark"):
            key = "OPENCODE_QUOTE_" + item["kind"].upper()
            environment[key] = item["id"]
            environment[key + "_SOURCE"] = item["source"]
            environment[key + "_CARRIER"] = item["carrier"]
            environment["OPENCODE_QUOTE_DIRECTORY"] = item["directory"]
    environment["OPENCODE_QUOTE_LIVE_TEXT"] = live_source
    arguments = ["-OpenCodeServerURL", server_url, "-OpenCodeTheme", args.theme]
    target["CommandLineArguments"] = arguments
    target["UITargetAppCommandLineArguments"] = arguments
    target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
    if args.quotes_unavailable:
        target["UITargetAppEnvironmentVariables"]["OPENCODE_TEST_QUOTES_UNAVAILABLE"] = "1"
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
    if server_cases and status == 0:
        # Server mode keeps quotes out of draft.json; local mode keeps them there, as before.
        # Installing for the run can move the app's data container.
        after = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.device, "br.com.alexandrem.opencode", "data"], text=True).strip())
        drafts = after / "Library/Application Support/OpenCode/Drafts" / hashlib.sha256(server_url.encode()).hexdigest()
        marks = after / "Library/Application Support/OpenCode/QuoteMarks" / (hashlib.sha256(server_url.encode()).hexdigest() + ".json")
        def local_draft(kind): return json.loads((drafts / owned_kind(kind)["id"] / "draft.json").read_text())
        migrated = local_draft("migrate")
        assert migrated["quotes"] == [] and migrated["document"]["text"] == "Texto local preservado.", migrated
        assert not (drafts / owned_kind("migrate")["id"] / "legacy-photo").exists()
        assert all(entry["sessionID"] != owned_kind("migrate")["id"] for entry in (json.loads(marks.read_text()) if marks.exists() else []))
        assert local_draft("create")["quotes"] == []
        assert [quote["comment"] for quote in local_draft("local")["quotes"]] == ["Comentário local."]
        (evidence / (args.label + "-server.json")).write_text(json.dumps({kind: rpc("list", owned_kind(kind))
            for kind in ["create", "live", "send", "migrate", "local"]}, indent=2))
    if live and status == 0:
        messages = api("/api/session/" + pending["id"] + "/message?limit=20&order=desc", method="GET")["data"]
        # The comment-photo case may have sent after it; pick the synthetic comment's own message.
        sent = next(message for message in messages if message["type"] == "user" and any(
            quote.get("comment") == "Comentário sintético de verificação." for quote in message.get("metadata", {}).get("quotes", [])))
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

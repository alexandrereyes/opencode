#!/usr/bin/env python3
"""Owned-only live fixtures and native undo verification; sandbox 4177 unless OPENCODE_TEST_* overrides it."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import time
import urllib.request
import uuid
import zlib

parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=["prepare", "resume", "test", "verify"])
parser.add_argument("--role", default="dark", choices=["dark", "light", "web"])
parser.add_argument("tests", nargs="*")
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
server = os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4177")
assert server.startswith("http://127.0.0.1:") and server.rsplit(":", 1)[1] not in ["4096", "4178"]
home = Path(os.environ.get("OPENCODE_TEST_HOME", temporary / "custom-sandbox-4177"))
evidence = Path(os.environ.get("OPENCODE_TEST_EVIDENCE", temporary / "ios-desfazer-prints"))
evidence.mkdir(exist_ok=True)
derived = Path(os.environ.get("OPENCODE_TEST_DERIVED", temporary / "ios-desfazer-derived"))
device = os.environ.get("OPENCODE_TEST_DEVICE", "8AE067E9-2D79-4BBF-80A5-A8965804CB6E")
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
ledger_path = Path(os.environ.get("OPENCODE_REVERT_LEDGER", Path(__file__).resolve().parents[3] / ".agent-artifacts/desfazer/LEDGER.json"))
ledger = json.loads(ledger_path.read_text()) if ledger_path.exists() else {"sandbox": server, "runs": {}}

def save():
    ledger_path.write_text(json.dumps(ledger, indent=2) + "\n")

def api(path, body=None, method="GET"):
    request = urllib.request.Request(server + path, headers=headers,
        data=json.dumps(body).encode() if body is not None else None, method=method)
    with urllib.request.urlopen(request, timeout=240) as response:
        data = response.read()
        return json.loads(data) if data else None

def messages(session):
    return api("/api/session/" + session + "/message?limit=100&order=asc")["data"]

def family(session):
    return api("/api/rpc/custom.session-family/page", {"input": {"sessionID": session, "limit": 100}}, "POST")["output"]["data"]

def import_history(run, role, rows, directory=None):
    session = "ses_" + uuid.uuid4().hex
    now = int(time.time() * 1000)
    directory = directory or run["repo"]
    api("/api/experimental/session/import", {"info": {"id": session, "title": "Teste", "projectID": "global",
        "location": {"directory": directory}, "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
        "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": directory}, "messages": rows}, "POST")
    run["created"].append(session)
    save()
    return session

def prompt(session, text, display):
    response = api("/api/session/" + session + "/prompt", {"text": text, "metadata": {"displayText": display, "comments": []}}, "POST")
    api("/api/experimental/session/" + session + "/wait", method="POST")
    return response

if args.mode == "prepare":
    assert args.role not in ledger["runs"], "Do not overwrite an owned run"
    token = uuid.uuid4().hex[:10]
    repo = home / "repos" / ("ios-desfazer-" + args.role + "-" + token)
    repo.mkdir(parents=True)
    (repo / "child.txt").write_text("baseline\n")
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=OpenCode Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "Owned revert baseline"], check=True)
    session = "ses_" + uuid.uuid4().hex
    run = {"session": session, "repo": str(repo), "created": [], "checks": {}}
    ledger["runs"][args.role] = run
    save()
    api("/api/session", {"id": session, "title": "Desfazer — " + args.role, "location": {"directory": str(repo)},
        "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}}, "POST")
    run["created"].append(session)
    save()
    prompt(session, "Responda apenas BASE. Não use ferramentas.", "Mensagem preservada.")
    prompt(session, "Teste isolado autorizado. Use a ferramenta subagent exatamente uma vez com agente general e modelo llm-proxy/gpt-6-luna#low. Peça que use patch para substituir baseline por changed em child.txt neste repositório. Aguarde o resultado; não edite você mesmo e responda apenas PRONTO.", "Criar alteração pelo subagente.")
    run["children"] = [item["id"] for item in family(session)]
    run["created"] += run["children"]
    save()
    assert run["children"], "Expected a real child launched by the parent"
    assert (repo / "child.txt").read_text().strip() == "changed", "Expected real child file edit"
    prompt(session, "Responda apenas FIM. Não use ferramentas.", "Última mensagem para desfazer.")
    run["users"] = [{"id": m["id"], "text": m["metadata"]["displayText"], "created": m["time"]["created"]} for m in messages(session) if m["type"] == "user"]
    run["checks"]["beforeFile"] = (repo / "child.txt").read_text()
    run["checks"]["beforeCount"] = len(messages(session))
    save()
    print(json.dumps(run, indent=2))
elif args.mode == "resume":
    run = ledger["runs"][args.role]
    session = run["session"]
    assert not run.get("users"), "Only resume incomplete setup"
    prompt(session, "O agente correto é general. Use subagent com agente general e modelo llm-proxy/gpt-6-luna#low para usar patch e substituir baseline por changed em child.txt neste repositório. Aguarde o resultado e responda apenas PRONTO.", "Criar alteração pelo subagente.")
    run["children"] = [item["id"] for item in family(session)]
    run["created"] += run["children"]
    save()
    assert run["children"]
    assert (Path(run["repo"]) / "child.txt").read_text().strip() == "changed"
    prompt(session, "Responda apenas FIM. Não use ferramentas.", "Última mensagem para desfazer.")
    users = [m for m in messages(session) if m["type"] == "user"]
    run["users"] = [{"id": m["id"], "text": m["metadata"]["displayText"], "created": m["time"]["created"]} for m in [users[0], users[-2], users[-1]]]
    run["checks"]["beforeFile"] = (Path(run["repo"]) / "child.txt").read_text()
    run["checks"]["beforeCount"] = len(messages(session))
    save()
elif args.mode == "verify":
    run = ledger["runs"][args.role]
    info = api("/api/session/" + run["session"])["data"]
    run["checks"]["afterRevert"] = info.get("revert")
    run["checks"]["afterFile"] = (Path(run["repo"]) / "child.txt").read_text()
    run["checks"]["afterCount"] = len(messages(run["session"]))
    run["checks"]["children"] = [{"id": child, "revert": api("/api/session/" + child)["data"].get("revert")} for child in run["children"]]
    save()
    assert info["revert"]["messageID"] == run["users"][1]["id"]
    assert all(item["revert"] for item in run["checks"]["children"])
    assert all(item["revert"].get("files") == [] for item in run["checks"]["children"])
    assert any(file["file"] == "child.txt" for file in info["revert"]["files"])
    assert run["checks"]["afterFile"] == "baseline\n"
    after_ids = {message["id"] for message in messages(run["session"])}
    assert all(user["id"] in after_ids for user in run["users"]), "Stage hides, but does not delete user history"
    assert run["checks"]["afterCount"] >= run["checks"]["beforeCount"], "Idle notices may be appended during interruption"
    run["checks"]["userHistoryRetained"] = True
    if run.get("commit") and not run["checks"].get("newPromptCommitted"):
        committed = api("/api/session/" + run["commit"])["data"]
        assert not committed.get("revert")
        assert all(message["id"] != run["commitMessage"] for message in messages(run["commit"]))
        run["checks"]["newPromptCommitted"] = True
        run["checks"]["committedSession"] = run["commit"]
        save()
    web = ledger["runs"].get("web", {}).get("checks", {})
    if args.role != "web" and web.get("afterRevert"):
        assert info["revert"]["files"] == web["afterRevert"]["files"]
        assert run["checks"]["afterFile"] == web["afterFile"]
        run["checks"]["equivalentToWeb"] = True
        save()
    print(json.dumps(run["checks"], indent=2))
else:
    run = ledger["runs"][args.role]
    if not run.get("sticky"):
        sticky_message = "msg_" + uuid.uuid4().hex
        now = int(time.time()*1000)
        run["sticky"] = import_history(run, "sticky", [
            {"id": sticky_message, "type": "user", "text": "Pedido fixado para desfazer.", "time": {"created": now-1000}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
             "time": {"created": now-900,"completed": now-800}, "finish": "stop", "content": [{"type": "text", "text": "\n\n".join(f"## Etapa {n}\n\nResposta longa para testar o pedido fixado e sua ação de desfazer." for n in range(1,35))}]}])
        run["stickyMessage"] = sticky_message
        save()
    if not args.tests or any("testUndoLastEarlierCascadeAndRedo" in test or test == "OpenCodeUITests/SessionRevertUITests" for test in args.tests):
        if api("/api/session/" + run["session"])["data"].get("revert"):
            boundaries = api("/api/rpc/custom.session-family/clear", {"input": {"sessionID": run["session"]}}, "POST")["output"]
            for boundary in boundaries:
                api("/api/session/" + boundary["sessionID"] + "/revert", method="DELETE")
            api("/api/session/" + run["session"] + "/revert", method="DELETE")
    needs_commit = not args.tests or any(test == "OpenCodeUITests/SessionRevertUITests" or "testNewPromptCommitsStagedBoundary" in test for test in args.tests)
    if not run.get("commit") or (needs_commit and all(message["id"] != run["commitMessage"] for message in messages(run["commit"]))):
        commit_message = "msg_" + uuid.uuid4().hex
        run["commit"] = import_history(run, "commit", [{"id": commit_message, "type": "user",
            "text": "Responda apenas NOVO. Não use ferramentas.", "time": {"created": int(time.time()*1000)-1000}}])
        run["commitMessage"] = commit_message
        run["checks"].pop("newPromptCommitted", None)
        save()
    if not run.get("failure"):
        failure = "ses_" + uuid.uuid4().hex
        failure_message = "msg_" + uuid.uuid4().hex
        now = int(time.time() * 1000)
        api("/api/experimental/session/import", {"info": {"id": failure, "title": "Desfazer — falha simulada", "projectID": "global",
            "location": {"directory": run["repo"]}, "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
            "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
            "location": {"directory": run["repo"]}, "messages": [{"id": failure_message, "type": "user", "text": "Mensagem da falha simulada.", "time": {"created": now - 1000}}]}, "POST")
        run["failure"] = failure
        run["failureMessage"] = failure_message
        run["created"].append(failure)
        save()
    env = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
        "OPENCODE_TEST_THEME": "openchamber-" + args.role, "OPENCODE_REVERT_SESSION": run["session"],
        "OPENCODE_REVERT_FIRST": run["users"][0]["id"], "OPENCODE_REVERT_EARLIER": run["users"][1]["id"],
        "OPENCODE_REVERT_LAST": run["users"][2]["id"], "OPENCODE_REVERT_CHILD": run["children"][0],
        "OPENCODE_REVERT_FAILURE": run["failure"], "OPENCODE_REVERT_FAILURE_MESSAGE": run["failureMessage"]}
    env["OPENCODE_REVERT_COMMIT"] = run["commit"]
    env["OPENCODE_REVERT_COMMIT_MESSAGE"] = run["commitMessage"]
    env["OPENCODE_REVERT_STICKY"] = run["sticky"]
    env["OPENCODE_REVERT_STICKY_MESSAGE"] = run["stickyMessage"]
    if any("SessionReadingTests" in test or "UserBubble" in test for test in args.tests):
        now = int(time.time() * 1000)
        fixtures = {}
        roles = ["BUBBLE", "SHORT", "SESSION_ACTIONS", "SESSION_MISSING", "C"]
        if any("UserBubbleAttachmentTests" in test for test in args.tests):
            roles += ["REVIEW_" + kind + "_" + placement for placement in ["LIST", "PINNED"] for kind in ["IMAGE", "FILE", "QUOTE", "PLAIN", "MIXED"]]
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 60, 180, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress((b"\0" + bytes([210, 118, 52])*60)*180)) + chunk(b"IEND", b"")
        for role in roles:
            user = "msg_" + uuid.uuid4().hex
            text = "Teste isolado."
            answer = "Histórico preservado para conferir os controles nativos."
            metadata = {}
            files = []
            if role == "BUBBLE":
                text = "Pedido longo de comparação.\n" + "\n".join(f"Detalhe {n}: preserve a leitura da resposta e o contexto do pedido sintético." for n in range(1,25)) + "\nDetalhe final exclusivo."
                answer = "\n\n".join(f"## Etapa {n}\n\nResposta sintética para conferir a rolagem. O pedido fica fixado sem mudar de tamanho por conta própria.\n\n- Leitura preservada.\n- Expansão apenas manual." for n in range(1,35))
                metadata = {"quotes": [{"id": "quote-bolha", "messageID": "msg_quote_bolha", "partID": "part_quote_bolha", "text": "Citação sintética preservada.", "comment": "Comentário preservado."}], "attachments": [{"name": "nota-sintetica.txt"}]}
            if role.startswith("REVIEW_"):
                kind = role.split("_")[1]
                text = "Pedido sintético " + kind.lower() + ".\n" + "\n".join("Linha " + str(n) + ": mantenha o conteúdo completo e a leitura estável." for n in range(1,13))
                answer = "Resposta curta sintética." if role.endswith("_LIST") else "\n\n".join(f"## Etapa {n}\n\nResposta sintética para conferir a rolagem.\n\n- Leitura preservada." for n in range(1,35))
                metadata = {"attachments": []}
                if kind in ["IMAGE", "MIXED"]:
                    name = "captura-sintetica-com-nome-muito-longo.png"
                    files.append({"mime": "image/png", "name": name, "data": base64.b64encode(png).decode(), "source": {"type": "inline"}})
                    metadata["attachments"].append({"name": name})
                if kind in ["FILE", "MIXED"]:
                    name = "documento-sintetico-com-nome-muito-longo.txt"
                    files.append({"mime": "text/plain", "name": name, "data": base64.b64encode(b"Arquivo sintetico preservado.").decode(), "source": {"type": "inline"}})
                    metadata["attachments"].append({"name": name})
                if kind in ["QUOTE", "MIXED"]:
                    metadata["quotes"] = [{"id": "quote-review", "messageID": "msg_review_source", "partID": "part_review_source", "text": "\n".join("Trecho citado " + str(n) + "." for n in range(1,9)), "comment": "Comentário da citação preservado."}]
                    metadata["comments"] = [{"path": "docs/referencia-sintetica.md", "comment": "Comentário de arquivo preservado."}]
            rows = [{"id": user, "type": "user", "text": text, "time": {"created": now-1000}, "metadata": metadata, "files": files},
                {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                 "time": {"created": now-900,"completed": now-800}, "finish": "stop", "content": [{"type": "text", "text": answer}]}]
            if role == "C":
                rows = []
                for n in range(1,31):
                    rows += [{"id": f"msg_{n:03d}_u_{uuid.uuid4().hex}", "type": "user", "text": f"Pedido {n}", "time": {"created": now+n*10}},
                        {"id": f"msg_{n:03d}_a_{uuid.uuid4().hex}", "type": "assistant", "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                         "time": {"created": now+n*10+1,"completed": now+n*10+2}, "finish": "stop", "content": [{"type": "text", "text": f"Revisão {n} concluída. PR fictício preservado."}]}]
            directory = str(home / ("missing-desfazer-" + uuid.uuid4().hex)) if role == "SESSION_MISSING" else None
            fixtures[role] = import_history(run, role, rows, directory)
            env["OPENCODE_TEST_" + role] = fixtures[role]
            env["OPENCODE_TEST_" + role + "_MESSAGE"] = user
        env["OPENCODE_TEST_A"] = run["session"]
        env["OPENCODE_TEST_CHILD"] = run["children"][0]
        run["regressionFixtures"] = fixtures
        save()
    actual = {message["id"]: message for message in messages(run["session"])}
    for key, index in [("EARLIER_TEXT", 1), ("LAST_TEXT", 2)]:
        message = actual[run["users"][index]["id"]]
        metadata = message.get("metadata", {})
        env["OPENCODE_REVERT_" + key] = metadata.get("displayText", message["text"]) if isinstance(metadata.get("comments"), list) else message["text"]
    definition = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = [target for config in definition["TestConfigurations"] for target in config["TestTargets"]] if "TestConfigurations" in definition else [v for k,v in definition.items() if k != "__xctestrun_metadata__"]
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(env)
        target["EnvironmentVariables"]["OPENCODE_TEST_SERVER_URL"] = server
        target["CommandLineArguments"] = ["-OpenCodeServerURL", server]
    configured = derived / "Build/Products/Desfazer.xctestrun"
    configured.write_bytes(plistlib.dumps(definition))
    configured.chmod(0o600)
    try:
        subprocess.run(["xcrun", "simctl", "boot", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True)
        subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
        result = evidence / (args.role + "-" + str(int(time.time())) + ".xcresult")
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)] + ["-only-testing:" + t for t in (args.tests or ["OpenCodeUITests/SessionRevertUITests"])])
        run["test"] = {"status": status, "result": str(result)}
        run.setdefault("tests", []).append({**run["test"], "selection": args.tests or ["OpenCodeUITests/SessionRevertUITests"]})
        save()
        exported = evidence / result.stem
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(exported)], check=True)
        for test in json.loads((exported / "manifest.json").read_text()):
            for attachment in test["attachments"]:
                source = exported / attachment["exportedFileName"]
                if source.suffix == ".png" and not attachment["isAssociatedWithFailure"]:
                    shutil.copyfile(source, evidence / (attachment["suggestedHumanReadableName"].split("_0_")[0] + ".png"))
        raise SystemExit(status)
    finally:
        configured.unlink(missing_ok=True)
        subprocess.run(["xcrun", "simctl", "terminate", device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

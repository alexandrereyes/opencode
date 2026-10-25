#!/usr/bin/env python3
"""Owned Bolha simulator and synthetic imports; explicit sandbox credentials, no model calls."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import signal
import struct
import subprocess
import time
import urllib.request
import uuid
import zlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--prepare", action="store_true")
parser.add_argument("--cleanup", action="store_true")
parser.add_argument("--label", default="user-bubble")
parser.add_argument("--review-attachments", action="store_true")
parser.add_argument("--evidence", type=Path)
parser.add_argument("--additional-fixtures", type=Path)
parser.add_argument("tests", nargs="*")
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
server = os.environ.get("OPENCODE_TEST_SERVER_URL", "http://127.0.0.1:4177")
assert server.startswith("http://127.0.0.1:") and server.rsplit(":", 1)[1] not in ["4096", "4178"]
home = Path(os.environ.get("OPENCODE_TEST_HOME", temporary / "custom-sandbox-4177"))
products = Path(os.environ.get("OPENCODE_TEST_DERIVED", temporary / "ios-bolha-derived")) / "Build/Products"
evidence = args.evidence or temporary / "ios-bolha-prints"
evidence.mkdir(parents=True, exist_ok=True)
manifest_path = evidence / "owned-sessions.json"
device = os.environ.get("OPENCODE_TEST_DEVICE", "49BFE0E0-8D48-406C-A5D1-491DE91CA392")
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}

def api(path, body=None, method="POST"):
    request = urllib.request.Request(server + path,
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
    roles = (["REVIEW_" + kind + "_" + placement for kind in ["IMAGE", "FILE", "QUOTE", "PLAIN", "MIXED"]
        for placement in ["LIST", "PINNED"]] if args.review_attachments else ["BUBBLE", "SHORT", "IMAGE_LONG", "IMAGE_SHORT",
            "QUOTES_LONG", "QUOTE_SHORT", "QUOTE_ONLY", "QUOTES_SIX"])
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 60, 180, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress((b"\0" + bytes([210, 118, 52]) * 60) * 180)) + chunk(b"IEND", b""))
    image_name = "captura-sintetica-com-nome-muito-longo.png"
    file_name = "documento-sintetico-com-nome-muito-longo.txt"
    for role in roles:
        session = "ses_" + uuid.uuid4().hex
        user = "msg_" + uuid.uuid4().hex
        text = "Primeira linha.\nSegunda linha." if role in ["SHORT", "IMAGE_SHORT"] else "Pedido longo de comparação.\n" + "\n".join(
            f"Detalhe {n}: preserve a leitura da resposta e o contexto do pedido sintético." for n in range(1, 25)) + "\nDetalhe final exclusivo."
        answer = "\n\n".join(f"## Etapa {n}\n\nResposta sintética para conferir a rolagem. O pedido fica fixado sem mudar de tamanho por conta própria.\n\n- Leitura preservada.\n- Expansão apenas manual."
            for n in range(1, 35))
        files = []
        metadata = {"quotes": [{"id": "quote-bolha", "messageID": "msg_quote_bolha", "partID": "part_quote_bolha", "text": "Citação sintética preservada.", "comment": "Comentário preservado."}],
            "attachments": [{"name": "nota-sintetica.txt"}]} if role == "BUBBLE" else {}
        if role.startswith("QUOTE"):
            if role != "QUOTES_LONG":
                text = "Primeira linha.\nSegunda linha." if role == "QUOTE_SHORT" else "Comments on earlier assistant messages:\n> Trecho citado 1."
            metadata = {"displayText": "" if role == "QUOTE_ONLY" else text, "comments": [], "quotes": [
                {"id": "quote-bolha-" + str(n), "messageID": "msg_quote_bolha", "partID": "part_quote_bolha",
                    "text": "Trecho citado " + str(n) + ".", "comment": "Comentário " + str(n) + " preservado."}
                for n in range(1, 4 if role == "QUOTES_LONG" else 2)]}
        if role == "QUOTES_SIX":
            comments = ["Fase 1", "", "Durante o envio, a bolha precisa continuar compacta.", "Mac", "Mestra",
                "Não entendi este ponto da resposta."]
            metadata = {"displayText": "", "comments": [], "quotes": [
                {"id": "quote-seis-" + str(n), "messageID": "msg_quote_bolha", "partID": "part_quote_bolha",
                    "text": "Trecho citado " + str(n) + ".", "comment": comment} for n, comment in enumerate(comments, 1)]}
        if role.startswith("IMAGE_"):
            files.append({"mime": "image/png", "name": image_name,
                "data": base64.b64encode(png).decode(), "source": {"type": "inline"}})
            metadata = {"attachments": [{"name": image_name}]}
        if args.review_attachments:
            kind = role.split("_")[1]
            text = "Pedido sintético " + kind.lower() + ".\n" + "\n".join(
                "Linha " + str(n) + ": mantenha o conteúdo completo e a leitura estável." for n in range(1, 13))
            metadata = {"attachments": []}
            if kind in ["IMAGE", "MIXED"]:
                files.append({"mime": "image/png", "name": image_name,
                    "data": base64.b64encode(png).decode(), "source": {"type": "inline"}})
                metadata["attachments"].append({"name": image_name})
            if kind in ["FILE", "MIXED"]:
                files.append({"mime": "text/plain", "name": file_name,
                    "data": base64.b64encode(b"Arquivo sintetico preservado.").decode(), "source": {"type": "inline"}})
                metadata["attachments"].append({"name": file_name})
            if kind in ["QUOTE", "MIXED"]:
                metadata["quotes"] = [{"id": "quote-review", "messageID": "msg_review_source", "partID": "part_review_source",
                    "text": "\n".join("Trecho citado " + str(n) + "." for n in range(1, 9)), "comment": "Comentário da citação preservado."}]
                metadata["comments"] = [{"path": "docs/referencia-sintetica.md", "comment": "Comentário de arquivo preservado."}]
            if role.endswith("_LIST"):
                answer = "Resposta curta sintética para conferir a mensagem no fluxo normal."
        api("/api/experimental/session/import", {"info": {"id": session, "title": "Bolha — " + role,
            "projectID": "global", "location": {"directory": str(directory)}, "agent": "build", "model": model,
            "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
            "location": {"directory": str(directory)}, "messages": [
                {"id": user, "type": "user", "text": text, "time": {"created": now - 1000},
                    "metadata": metadata, "files": files},
                {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
                    "time": {"created": now - 900, "completed": now - 800}, "finish": "stop",
                    "content": [{"type": "text", "text": answer}]},
            ]})
        sessions.append({"role": role, "id": session, "userMessageID": user, "directory": str(directory), "text": metadata.get("displayText", text)})
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
fixtures = owned + (json.loads(args.additional_fixtures.read_text()) if args.additional_fixtures else [])
for target in targets:
    environment = target.setdefault("EnvironmentVariables", {})
    environment.update({"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
        "OPENCODE_TEST_THEME": os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark"), "OPENCODE_FOLLOW_LIVE": "0"})
    for session in fixtures:
        environment["OPENCODE_TEST_" + session["role"]] = session["id"]
        environment["OPENCODE_TEST_" + session["role"] + "_MESSAGE"] = session["userMessageID"]
        if "text" in session: environment["OPENCODE_TEST_" + session["role"] + "_TEXT"] = session["text"]
    for key, role in [("A", "working"), ("B", "permission"), ("C", "history"), ("CHILD", "child-1")]:
        environment["OPENCODE_TEST_" + key] = next(s["id"] for s in seed["sessions"] if s["role"] == role)
    environment["OPENCODE_TEST_SERVER_URL"] = server
    arguments = ["-OpenCodeServerURL", server]
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

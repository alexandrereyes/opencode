#!/usr/bin/env python3
"""Native file viewers against owned fake-repository imports; no seed/model/production changes."""
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import sys
import time
import urllib.request
import uuid
import zlib

signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
home = temporary / "custom-sandbox-4177"
derived = temporary / "ios-imagens-derived"
device = "C70D22D2-4EFC-4C70-A7D4-F085C26D40D6"
evidence = temporary / "ios-arquivos-prints"
evidence.mkdir(exist_ok=True)
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
def api(path, body=None, method="POST"):
    request = urllib.request.Request("http://127.0.0.1:4177" + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

manifest = json.loads((home / "seed-conversation.json").read_text())
root = Path(manifest["directory"]).resolve()
assert root.is_relative_to((home / "repos").resolve())
token = uuid.uuid4().hex[:10]
folder = root / ("ios-files-" + token)
outside = root / ("ios-files-outside-" + token)
folder.mkdir()
outside.mkdir()
created = []
configured = derived / ("Build/Products/Files-" + token + ".xctestrun")
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme}
try:
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\0" + bytes((40 + y // 2, 130, 210)) * 400 for y in range(200))
    (folder / "image.png").write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 400, 200, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    (folder / "notes.txt").write_text("Arquivo de verificação\n\nTexto preservado no Quick Look.\n", encoding="utf8")
    (folder / "source.ts").write_text('const arquivo = "Código TypeScript preservado"\n', encoding="utf8")
    (outside / "outside.txt").write_text("Arquivo fora do diretório da sessão, dentro do repositório fictício.\n", encoding="utf8")
    (folder / "sample.opaque").write_bytes(bytes(range(256)))
    with (folder / "large.bin").open("wb") as output:
        output.truncate(51 * 1024 * 1024)
    # A self-contained, one-page PDF fixture, including its byte-accurate cross-reference table.
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    stream = b"BT /F1 20 Tf 40 220 Td (OpenCode - PDF fixture) Tj ET"
    objects.append(b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream")
    pdf = b"%PDF-1.4\n"
    offsets = [0]
    for number, obj in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf += str(number).encode() + b" 0 obj\n" + obj + b"\nendobj\n"
    start = len(pdf)
    pdf += b"xref\n0 6\n0000000000 65535 f \n" + b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets[1:])
    pdf += b"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n" + str(start).encode() + b"\n%%EOF\n"
    (folder / "example.pdf").write_bytes(pdf)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24", "-t", "90", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "32", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(folder / "video.mp4")], check=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440", "-t", "90", str(folder / "audio.wav")], check=True)
    server_home = Path(api("/api/rpc/custom.directories/home", {"input": {}})["output"]["path"])
    messages = {"INLINE": "- `notes.txt`", "CODE": "[Abrir código](source.ts)", "PDF": "[Abrir PDF](example.pdf)", "IMAGE": "[Abrir imagem](image.png)",
        "VIDEO": "[Abrir vídeo](video.mp4)", "AUDIO": "[Abrir áudio](audio.wav)",
        "IMAGEVIDEO": "![Vídeo incorporado](video.mp4)",
        "ABSOLUTE": "[Abrir externo](" + str(outside / "outside.txt") + ")",
        "TILDE": "[Abrir pasta pessoal](~/" + os.path.relpath(folder / "notes.txt", server_home) + ")",
        "MISSING": "[Abrir ausente](missing.pdf)", "UNKNOWN": "[Abrir binário](sample.opaque)", "BIG": "[Abrir grande](large.bin)",
        "TABLE": "| Imagem | Arquivo |\n| --- | --- |\n| ![Quadro](image.png) | [Abrir texto](notes.txt) |",
        "PLAIN_TABLE": "| Nome | Descrição |\n| --- | --- |\n| Curto | Um texto que ocupa várias linhas e permite conferir o alinhamento superior de todas as células desta linha. |\n| Outro | Rápido |",
        "WIDE_TABLE": "| Identificador | Descrição | Responsável | Estado | Observação |\n| --- | --- | --- | --- | --- |\n| ios-table-001 | Conteúdo largo para conferir a rolagem horizontal da tabela. | Alexandre | Concluído | Coluna final visível |"}
    formatting = (Path(__file__).resolve().parents[1] / "OpenCode/Fixtures/markdown-fixture.md").read_text()
    tables = re.findall(r"(?m)(?:^\|[^\n]*(?:\n|$))+", formatting)
    assert len(tables) == 4
    for index, table in enumerate(tables, 1):
        messages["FORMAT_" + str(index)] = "# Formatação " + str(index) + "\n\n" + table
    now = int(time.time() * 1000)
    for role, text in messages.items():
        session = "ses_" + uuid.uuid4().hex
        api("/api/experimental/session/import", {"info": {"id": session, "title": "Arquivos · " + role, "projectID": "global",
            "location": {"directory": str(folder)}, "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
            "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}, "outcome": "succeeded",
            "time": {"created": now, "updated": now, "idle": now, "viewed": now}}, "location": {"directory": str(folder)},
            "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Verificação isolada de arquivos.", "time": {"created": now - 1000}},
                {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                 "time": {"created": now - 900, "completed": now - 600}, "finish": "stop", "content": [{"type": "text", "text": text}]}]})
        created.append(session)
        environment["OPENCODE_FILE_" + role] = session
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["CommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
        target["UITargetAppCommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
        target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    result = evidence / ("files-" + theme + "-" + token + ".xcresult")
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", "platform=iOS Simulator,id=" + device,
        "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance",
        "900" if any("MarkdownRenderingTests" in test for test in sys.argv[1:]) else "300", "-resultBundlePath", str(result)]
    for test in sys.argv[1:] or ["OpenCodeUITests/FileViewerTests", "OpenCodeTests/MarkdownFileLinkTests",
            "OpenCodeTests/MarkdownRenderingTests", "OpenCodeTests/ResponseMeasurementTests"]:
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
    for file in folder.iterdir():
        file.unlink()
    folder.rmdir()
    (outside / "outside.txt").unlink(missing_ok=True)
    outside.rmdir()

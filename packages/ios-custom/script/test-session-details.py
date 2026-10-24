#!/usr/bin/env python3
"""Detalhes da sessão UI test: MCP toggles, skills loaded by this session, collapsed lists, plugins last, no LSP.

It owns a temporary git checkout with seven fixture skills and six fixture plugins, imports a session there and loads
the skills for real: one through the model's `skill` tool (Luna 6 / low), two attached to a prompt, four by direct
activation without resuming. The session and checkout are deleted afterwards. Run after `build-for-testing`:
  python3 packages/ios-custom/script/test-session-details.py --device <sim-udid> --derived <DerivedData> \
    --home <sandbox-home> --server-url http://127.0.0.1:<port> --evidence <prints-dir> [--theme openchamber-light]
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
import urllib.parse
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
fixture = Path(tempfile.mkdtemp(prefix="ios-session-details-" + token + "-")).resolve()
root = fixture / "repo"
configured = next(args.derived.glob("Build/Products/OpenCode_*.xctestrun")).with_name("Details-" + token + ".xctestrun")
args.evidence.mkdir(parents=True, exist_ok=True)
skills = ["fixture-skill-%d" % index for index in range(1, 8)]
session = None
def wait_idle(predicate, label, timeout=240):
    deadline = time.time() + timeout
    while time.time() < deadline:
        active = api("/api/session/active", method="GET")["data"]
        value = predicate()
        if session not in active and value:
            return value
        time.sleep(2)
    raise SystemExit("Timed out waiting for " + label)
def loaded():
    return [item["id"] for item in api("/api/rpc/custom.transcript/skills", {"input": {"sessionID": session}})["output"]["data"]]
try:
    root.mkdir()
    for name in skills:
        (root / ".opencode/skills" / name).mkdir(parents=True)
        (root / ".opencode/skills" / name / "SKILL.md").write_text("---\nname: " + name + "\ndescription: Skill de teste do app iOS. Use somente quando pedido explicitamente.\n---\n\nNada a fazer além de responder OK.\n", encoding="utf8")
    (root / ".opencode/plugins").mkdir(parents=True)
    for index in range(1, 7):
        (root / ".opencode/plugins" / ("fixture-plugin-%d.ts" % index)).write_text(
            'export default { id: "fixture.plugin-%d", async setup() {} }\n' % index, encoding="utf8")
    (root / "README.md").write_text("# Detalhes da sessão\n", encoding="utf8")
    git = ["git", "-C", str(root), "-c", "user.email=fixture@example.invalid", "-c", "user.name=Fixture"]
    subprocess.run(git[:3] + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-qm", "fixture"], check=True)

    now = int(time.time() * 1000)
    session = "ses_" + uuid.uuid4().hex
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    api("/api/experimental/session/import", {"info": {"id": session, "title": "Detalhes da sessão", "projectID": "global",
        "location": {"directory": str(root)}, "agent": "build", "model": model, "cost": 0,
        "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}, "outcome": "succeeded",
        "time": {"created": now, "updated": now, "idle": now, "viewed": now}}, "location": {"directory": str(root)},
        "messages": [{"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Verificação dos detalhes.", "time": {"created": now - 1000}},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
             "time": {"created": now - 900, "completed": now - 600}, "finish": "stop", "content": [{"type": "text", "text": "Pronto."}]}]})
    q = "?" + urllib.parse.urlencode({"location[directory]": str(root)})
    api("/api/session/" + session + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "delivery": "steer",
        "text": "Chame a ferramenta skill uma única vez com id=\"" + skills[0] + "\". Depois responda apenas: OK."})
    wait_idle(lambda: skills[0] in loaded(), "the model's skill tool call")
    api("/api/session/" + session + "/prompt", {"id": "msg_" + uuid.uuid4().hex, "delivery": "steer",
        "text": "Responda apenas: OK. Não use ferramentas.", "skills": [{"id": skills[1]}, {"id": skills[2]}]})
    wait_idle(lambda: skills[2] in loaded(), "the prompt-attached skills")
    for name in skills[3:]:
        api("/api/experimental/session/" + session + "/skill" + q, {"id": name, "resume": False})
    order = wait_idle(lambda: loaded() if len(loaded()) == len(skills) else None, "the direct activations")
    if order != skills:
        raise SystemExit("Unexpected loaded skill order: " + json.dumps(order))
    # A Location's plugins and MCPs finish starting after its first request; the model calls above leave ample time.
    mcp = next(m["name"] for m in api("/api/mcp" + q, method="GET")["data"] if m["status"]["status"] == "connected")
    plugins = [p for p in api("/api/plugin" + q, method="GET")["data"] if p.get("source", {}).get("type") != "builtin"]
    verification = {"session": session, "loaded": order, "mcp": mcp,
        "plugins": [(p.get("id") or p["source"].get("path", "").rsplit("/", 1)[-1], p["state"]["status"]) for p in plugins],
        "available": len(api("/api/skill" + q, method="GET")["data"])}

    environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password, "OPENCODE_TEST_THEME": args.theme,
        "OPENCODE_TEST_SERVER_URL": args.server_url, "OPENCODE_DETAILS_SESSION": session, "OPENCODE_DETAILS_SKILLS": ",".join(skills),
        "OPENCODE_DETAILS_MCP": mcp, "OPENCODE_DETAILS_PLUGINS": str(len(plugins))}
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
    result = args.evidence / ("details-" + args.theme + "-" + token + ".xcresult")
    status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
        "-destination", "platform=iOS Simulator,id=" + args.device, "-parallel-testing-enabled", "NO",
        "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "300",
        "-resultBundlePath", str(result), "-only-testing:OpenCodeUITests/SessionDetailsTests"])
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
    verification["status"] = status
    verification["mcpAfter"] = [(m["name"], m["status"]["status"]) for m in api("/api/mcp" + q, method="GET")["data"]]
    (args.evidence / ("verification-" + args.theme + ".json")).write_text(json.dumps(verification, indent=2, ensure_ascii=False))
    print(json.dumps(verification, ensure_ascii=False))
    sys.exit(status)
finally:
    configured.unlink(missing_ok=True)
    if session:
        api("/api/session/" + session, method="DELETE")
    shutil.rmtree(fixture)

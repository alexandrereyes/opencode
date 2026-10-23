#!/usr/bin/env python3
"""Own Novas simulator/DerivedData; explicit sandbox credentials, no seed resets."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--label", required=True)
parser.add_argument("--live", action="store_true", help="Import owned parent/child histories for the live scenarios")
parser.add_argument("--baseline", action="store_true", help="Measure the copied, verified previous follow binary")
parser.add_argument("tests", nargs="*")
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
home = temporary / "custom-sandbox-4177"
products = temporary / ("ios-novas-derived/BaselineProducts" if args.baseline else "ios-novas-derived/Build/Products")
if args.baseline and (args.live or not args.tests or any(not test.startswith("OpenCodeUITests/ScrollingPerformanceTests/") for test in args.tests)):
    parser.error("Baseline mode only measures explicit offline scrolling tests")
evidence = temporary / "ios-novas-prints"
device = "66EA82DF-D048-4E54-85D0-FB32A02CEC20"
password = (home / "password").read_text().strip()
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}
manifest = json.loads((home / "seed-conversation.json").read_text())
directory = manifest["directory"]
assert Path(directory).is_relative_to(home / "repos")
owned = []
environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password}
if "OPENCODE_TEST_THEME" in os.environ:
    environment["OPENCODE_TEST_THEME"] = os.environ["OPENCODE_TEST_THEME"]
model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}

def api(path, body=None, method="GET"):
    request = urllib.request.Request("http://127.0.0.1:4177" + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

def create(session, title, count=1, parent=None, child=None, path=directory):
    now = int(time.time() * 1000)
    messages = []
    for index in range(count):
        created = now - 120000 + index * 1000
        messages.append({"id": "msg_" + uuid.uuid4().hex, "type": "user", "time": {"created": created}, "text": "Verifique a etapa " + str(index + 1) + "."})
        content = [{"type": "text", "text": "### Etapa " + str(index + 1) + "\n\n" + "\n".join("- Item " + str(i) + ": conteúdo sintético para leitura." for i in range(1, 9))}]
        if child and index == count - 1:
            content.append({"type": "tool", "id": "tool_" + uuid.uuid4().hex, "name": "subagent",
                "time": {"created": created + 2, "ran": created + 3, "completed": created + 500},
                "state": {"status": "completed", "input": {"agent": "explore", "description": "Abrir filho de teste"},
                    "metadata": {"sessionID": child}, "content": [{"type": "text", "text": "Conferência concluída."}]}})
        messages.append({"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "time": {"created": created + 1, "completed": created + 500},
            "agent": "build", "model": model, "finish": "stop", "content": content})
    info = {"id": session, "title": title, "projectID": "global", "location": {"directory": path}, "agent": "build", "model": model,
        "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": "succeeded", "time": {"created": now - 120000, "updated": now, "idle": now, "viewed": now - 110000}}
    if parent:
        info["parentID"] = parent
    api("/api/experimental/session/import", {"info": info, "location": {"directory": path}, "messages": messages}, "POST")
    owned.append(session)
    return session

configured = products / ("Novas-" + args.label + ".xctestrun")
try:
    if args.live:
        for theme in ["DARK", "LIGHT"]:
            root, child = "ses_" + uuid.uuid4().hex, "ses_" + uuid.uuid4().hex
            create(root, "Novas — pai " + theme.lower(), count=24, child=child)
            create(child, "Novas — filho " + theme.lower(), count=3, parent=root)
            environment["OPENCODE_NOVAS_ROOT_" + theme] = root
            environment["OPENCODE_NOVAS_CHILD_" + theme] = child
    for key, role in [("A", "working"), ("B", "permission"), ("C", "history"), ("CHILD", "child-1")]:
        environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
    if any(test == "OpenCodeUITests/SessionReadingTests" or test.endswith(("testMenuRenameAndArchiveOwnSession", "testMissingDirectoryKeepsHistoryAndBlocksComposer")) for test in args.tests):
        environment["OPENCODE_TEST_SESSION_ACTIONS"] = create("ses_" + uuid.uuid4().hex, "Novas — ações")
        missing = home / "repos" / ("novas-missing-" + uuid.uuid4().hex)
        missing.mkdir()
        environment["OPENCODE_TEST_SESSION_MISSING"] = create("ses_" + uuid.uuid4().hex, "Novas — diretório ausente", path=str(missing))
        missing.rmdir()
    run = plistlib.loads(next(products.glob("OpenCode_*.xctestrun")).read_bytes())
    targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
        if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(environment)
        arguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
        target["CommandLineArguments"] = arguments
        target["UITargetAppCommandLineArguments"] = arguments
        target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    result = evidence / (args.label + ".xcresult")
    tests = args.tests or ["OpenCodeTests/ConversationLoadingTests", "OpenCodeTests/ConversationFollowGeometryTests",
        "OpenCodeUITests/ConversationFollowTests/testEmptyTailRestorationCompletes",
        "OpenCodeUITests/ConversationFollowTests/testHistoryJumpToLatestInBothThemes",
        "OpenCodeUITests/ConversationFollowTests/testHeightChangesFollowMonotonicallyInBothThemes",
        "OpenCodeUITests/ReadingContinuityTests/testJumpToLatestWithoutUnreadStateInBothThemes"]
    with (evidence / (args.label + "-test.log")).open("w") as output:
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=" + device, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance",
            "600" if args.live and any("/NewMessagesTests" in test for test in tests) and "OPENCODE_TEST_THEME" not in environment else "300",
            "-resultBundlePath", str(result)] + ["-only-testing:" + test for test in tests], stdout=output, stderr=subprocess.STDOUT)
    attachments = evidence / (args.label + "-attachments")
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(attachments)], check=True, stdout=subprocess.DEVNULL)
    for test in json.loads((attachments / "manifest.json").read_text()):
        for item in test["attachments"]:
            source = attachments / item["exportedFileName"]
            if source.suffix == ".png" and not item["isAssociatedWithFailure"]:
                name = item["suggestedHumanReadableName"].split("_0_")[0]
                shutil.copyfile(source, evidence / (name + ".png"))
    subprocess.run(["xcrun", "xcresulttool", "export", "metrics", "--path", str(result), "--output-path", str(evidence / (args.label + "-metrics"))], check=True, stdout=subprocess.DEVNULL)
    summary = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)])
    (evidence / (args.label + "-summary.json")).write_bytes(summary)
    print(args.label, "status", status)
    raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    snapshots = []
    for session in owned:
        for attempt in range(120):
            if session not in api("/api/session/active")["data"]:
                break
            time.sleep(0.5)
        else:
            api("/api/session/" + session + "/interrupt", {}, "POST")
        snapshots.append(api("/api/session/" + session)["data"])
    (evidence / (args.label + "-sessions.json")).write_text(json.dumps({"created": snapshots, "retained": owned}, indent=2))
    subprocess.run(["xcrun", "simctl", "terminate", device, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

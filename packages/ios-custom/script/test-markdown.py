#!/usr/bin/env python3
"""Isolated Markdown simulator checks; all launches explicitly use sandbox credentials."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--label", required=True)
parser.add_argument("--simulator", default="7C70FB07-A886-43BD-8A39-42D92E0C9937")
parser.add_argument("--regressions", action="store_true")
parser.add_argument("--fixed-wrap", action="store_true", help="Hold code/table wrapping on for reproducible scroll benchmarks")
parser.add_argument("--derived", type=Path)
parser.add_argument("--evidence", type=Path)
parser.add_argument("--server-url", default="http://127.0.0.1:4177")
parser.add_argument("--home", type=Path, help="Sandbox home (ignored in --offline mode)")
parser.add_argument("--offline", action="store_true", help="Run only server-free Markdown rendering suites")
parser.add_argument("tests", nargs="*")
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
home = args.home or temporary / "custom-sandbox-4177"
products = (args.derived or temporary / "ios-formatacao-derived") / "Build/Products"
evidence = args.evidence or temporary / "ios-formatacao-prints"
evidence.mkdir(exist_ok=True)
if args.offline:
    assert not args.regressions
    assert all(test.startswith(("OpenCodeTests/MarkdownRenderingTests", "OpenCodeTests/ResponseMeasurementTests",
        "OpenCodeUITests/MarkdownRenderingTests")) for test in args.tests)
password = "offline-markdown-fixture" if args.offline else (home / "password").read_text().strip()
run = plistlib.loads(next(products.glob("OpenCode_iphonesimulator*.xctestrun")).read_bytes())
targets = ([target for configuration in run["TestConfigurations"] for target in configuration["TestTargets"]]
           if "TestConfigurations" in run else [value for key, value in run.items() if key != "__xctestrun_metadata__"])
owned = []
extra = {}
headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(), "Content-Type": "application/json"}

def api(path, body=None, method="POST"):
    request = urllib.request.Request(args.server_url.rstrip("/") + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None

def create(role, directory):
    session = "ses_" + uuid.uuid4().hex
    now = int(time.time() * 1000)
    model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
    api("/api/experimental/session/import", {"info": {"id": session, "title": "Formatação — " + role,
        "projectID": "global", "location": {"directory": directory}, "agent": "build", "model": model,
        "cost": 0, "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "outcome": "succeeded", "time": {"created": now, "updated": now, "idle": now, "viewed": now}},
        "location": {"directory": directory}, "messages": [
            {"id": "msg_" + uuid.uuid4().hex, "type": "user", "time": {"created": now - 1000}, "text": "Verificação isolada."},
            {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "time": {"created": now - 500, "completed": now},
             "agent": "build", "model": model, "finish": "stop", "content": [{"type": "text", "text": "Histórico preservado para conferir os controles nativos."}]},
        ]})
    owned.append(session)
    return session

configured = products / ("Markdown-" + args.label + ".xctestrun")
try:
    if args.regressions:
        manifest = json.loads((home / "seed-conversation.json").read_text())
        directory = Path(manifest["directory"])
        assert directory.is_relative_to(home / "repos")
        extra["OPENCODE_TEST_SESSION_ACTIONS"] = create("ações", str(directory))
        missing = home / "repos" / ("ios-markdown-missing-" + uuid.uuid4().hex)
        missing.mkdir()
        extra["OPENCODE_TEST_SESSION_MISSING"] = create("diretório ausente", str(missing))
        missing.rmdir()
        for key, role in [("A", "working"), ("C", "history"), ("CHILD", "child-1")]:
            extra["OPENCODE_TEST_" + key] = next(session["id"] for session in manifest["sessions"] if session["role"] == role)
    arguments = ["-OpenCodeServerURL", args.server_url, "-OpenCodeScrollFixture", "sessions"]
    for target in targets:
        environment = target.setdefault("EnvironmentVariables", {})
        environment.update({"OPENCODE_TEST_SERVER_URL": args.server_url, "OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
            "OPENCODE_TEST_THEME": os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark")})
        environment.update(extra)
        target["CommandLineArguments"] = arguments
        target["UITargetAppCommandLineArguments"] = ["-OpenCodeServerURL", args.server_url] + (
            ["-OpenCodeMarkdownCodeWrap", "YES", "-OpenCodeMarkdownTableWrap", "YES"] if args.fixed_wrap else [])
        target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    root = Path(__file__).resolve().parents[1]
    (evidence / (args.label + "-state.json")).write_text(json.dumps({
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "markdownSHA256": hashlib.sha256((root / "OpenCode/Fixtures/markdown-fixture.md").read_bytes()).hexdigest(),
        "binarySHA256": hashlib.sha256((products / "Debug-iphonesimulator/OpenCode.app/OpenCode.debug.dylib").read_bytes()).hexdigest(),
        "ownedSessions": owned,
        "fixedWrap": args.fixed_wrap,
    }, indent=2) + "\n")
    result = evidence / (args.label + ".xcresult")
    tests = args.tests or ["OpenCodeTests/MarkdownRenderingTests", "OpenCodeTests/ResponseMeasurementTests", "OpenCodeUITests/MarkdownRenderingTests"]
    with (evidence / (args.label + "-test.log")).open("w") as output:
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=" + args.simulator, "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)] +
            ["-only-testing:" + test for test in tests], stdout=output, stderr=subprocess.STDOUT)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
        "--output-path", str(evidence / (args.label + "-attachments"))], check=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "metrics", "--path", str(result),
        "--output-path", str(evidence / (args.label + "-metrics"))], check=True)
    summary = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)])
    (evidence / (args.label + "-summary.json")).write_bytes(summary)
    print(args.label, "status", status)
    raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "terminate", args.simulator, "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for session in owned:
        api("/api/session/" + session, method="DELETE")

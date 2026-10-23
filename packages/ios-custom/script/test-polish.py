#!/usr/bin/env python3
"""Run selected native checks on OpenCode Polimento with explicit sandbox credentials."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import urllib.parse
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--label", required=True)
parser.add_argument("--usage-fixtures", action="store_true")
parser.add_argument("tests", nargs="*", default=["OpenCodeTests/AppTypographyTests", "OpenCodeTests/SessionRowLayoutTests",
    "OpenCodeTests/ResponseMeasurementTests", "OpenCodeUITests/ScrollingPerformanceTests"])
args = parser.parse_args()
temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
products = temporary / "ios-polimento-derived/Build/Products"
evidence = temporary / "ios-polimento-prints"
evidence.mkdir(exist_ok=True)
password = (temporary / "custom-sandbox-4177/password").read_text().strip()
run = plistlib.loads(next(products.glob("OpenCode_iphonesimulator*.xctestrun")).read_bytes())
targets = ([target for configuration in run["TestConfigurations"] for target in configuration["TestTargets"]]
    if "TestConfigurations" in run else [value for key, value in run.items() if key != "__xctestrun_metadata__"])
for target in targets:
    target.setdefault("EnvironmentVariables", {}).update({
        "OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password,
        "OPENCODE_TEST_THEME": os.environ.get("OPENCODE_TEST_THEME", "openchamber-dark"),
    })
    target["CommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeScrollFixture", "sessions"]
    target["UITargetAppCommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
    target.setdefault("UITargetAppEnvironmentVariables", {})["OPENCODE_SERVER_PASSWORD"] = password
configured = products / ("Polish-" + args.label + ".xctestrun")
result = evidence / (args.label + ".xcresult")
owned = []

def api(path, body=None, method="GET"):
    request = urllib.request.Request("http://127.0.0.1:4177" + path,
        headers={"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode(),
                 "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        value = response.read()
        return json.loads(value) if value else None

try:
    if args.usage_fixtures:
        home = temporary / "custom-sandbox-4177"
        directory = json.loads((home / "seed-conversation.json").read_text())["directory"]
        assert Path(directory).is_relative_to(home / "repos")
        model = {"providerID": "llm-proxy", "id": "gpt-6-luna", "variant": "low"}
        catalog = api("/api/model?location%5Bdirectory%5D=" + urllib.parse.quote(directory, safe=""))["data"]
        limit = next(item["limit"]["context"] for item in catalog if item["providerID"] == model["providerID"] and item["id"] == model["id"])
        measured = {"input": limit * 25 / 1050, "output": limit * 14 / 1050, "reasoning": 0,
            "cache": {"read": limit / 3, "write": limit / 105}}
        now = int(time.time() * 1000)
        for role in ["COMPLETE", "MISSING", "EMPTY"]:
            session = "ses_" + uuid.uuid4().hex
            owned.append(session)
            assistant = {"id": "msg_" + uuid.uuid4().hex, "type": "assistant", "agent": "build", "model": model,
                "time": {"created": now - 2000, "completed": now - 1000}, "finish": "stop",
                "content": [{"type": "text", "text": "Conferência concluída. O contexto e o cache ficam abaixo do compositor."}]}
            if role == "COMPLETE":
                assistant["tokens"] = measured
            api("/api/experimental/session/import", {"info": {"id": session, "title": "Polimento — uso " + role,
                "projectID": "global", "location": {"directory": directory}, "agent": "build", "model": model,
                "cost": 0, "tokens": measured, "outcome": "succeeded",
                "time": {"created": now - 5000, "updated": now, "idle": now, "viewed": now}},
                "location": {"directory": directory}, "messages": [] if role == "EMPTY" else [
                    {"id": "msg_" + uuid.uuid4().hex, "type": "user", "text": "Confira o contexto e o cache.", "time": {"created": now - 3000}}, assistant]}, "POST")
            for target in targets:
                target["EnvironmentVariables"]["OPENCODE_TEST_USAGE_" + role] = session
                if role == "COMPLETE":
                    target["EnvironmentVariables"]["OPENCODE_VOICE_BAR_SESSION"] = session
    configured.write_bytes(plistlib.dumps(run))
    configured.chmod(0o600)
    subprocess.run(["xcrun", "simctl", "status_bar", "4FB557F1-6CF3-4478-B33F-CBAB25F04A24", "override",
        "--time", "10:58", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
        "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"], check=True)
    with (evidence / (args.label + "-test.log")).open("w") as output:
        status = subprocess.call(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
            "-destination", "platform=iOS Simulator,id=4FB557F1-6CF3-4478-B33F-CBAB25F04A24",
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)] +
            ["-only-testing:" + test for test in args.tests], stdout=output, stderr=subprocess.STDOUT)
    summary = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)])
    (evidence / (args.label + "-summary.json")).write_bytes(summary)
    subprocess.run(["xcrun", "xcresulttool", "export", "metrics", "--path", str(result),
        "--output-path", str(evidence / (args.label + "-metrics"))], check=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
        "--output-path", str(evidence / (args.label + "-attachments"))], check=True, stdout=subprocess.DEVNULL)
    print(json.dumps({"status": status, "result": str(result)}))
    raise SystemExit(status)
finally:
    configured.unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "terminate", "4FB557F1-6CF3-4478-B33F-CBAB25F04A24",
        "br.com.alexandrem.opencode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for session in owned:
        api("/api/session/" + session, method="DELETE")
    if owned:
        (evidence / (args.label + "-cleanup.json")).write_text(json.dumps({"deleted": owned, "modelCalls": 0}) + "\n")

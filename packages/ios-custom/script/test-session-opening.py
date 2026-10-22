#!/usr/bin/env python3
"""Measure navigation on the owned simulator; only reads existing sandbox histories."""
import fcntl
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import uuid

temporary = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode")
products = temporary / "ios-abertura-derived/Build/Products"
home = temporary / "custom-sandbox-4177"
lease = (temporary / "ios-abertura-test.lock").open("a")
fcntl.flock(lease, fcntl.LOCK_EX)
stage = sys.argv[1] if len(sys.argv) > 1 else "after"
assert stage.replace("-", "").isalnum()
token = stage + "-" + uuid.uuid4().hex[:8]
run = plistlib.loads(next(products.glob("OpenCode_*.xctestrun")).read_bytes())
manifest = json.loads((home / "seed-conversation.json").read_text())
password = (home / "password").read_text().strip()
environment = {"OPENCODE_TEST_PASSWORD": password, "OPENCODE_SERVER_PASSWORD": password}
for key, role in [("HISTORY", "history"), ("WORKING", "working"), ("CHILD", "child-1"),
                  ("PERMISSION", "permission"), ("QUESTION", "question"), ("A", "working"), ("C", "history")]:
    environment["OPENCODE_TEST_" + key] = next(s["id"] for s in manifest["sessions"] if s["role"] == role)
targets = ([t for c in run["TestConfigurations"] for t in c["TestTargets"]]
           if "TestConfigurations" in run else [v for k, v in run.items() if k != "__xctestrun_metadata__"])
for target in targets:
    target.setdefault("EnvironmentVariables", {}).update(environment)
    target["CommandLineArguments"] = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
configured = products / ("Opening-" + token + ".xctestrun")
configured.write_bytes(plistlib.dumps(run))
configured.chmod(0o600)
try:
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination",
               "platform=iOS Simulator,id=3CD95181-75A3-4225-B919-6B1C4DCFA77E",
               "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
               "-resultBundlePath", str(temporary / ("ios-abertura-" + token + ".xcresult"))]
    for test in sys.argv[2:] or ["OpenCodeUITests/SessionOpeningTests"]:
        command.append("-only-testing:" + test)
    sys.exit(subprocess.call(command))
finally:
    configured.unlink(missing_ok=True)

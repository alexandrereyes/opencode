"""Host-side publication for a Linux release. Input arrives through stdin, never a shared mount."""
import hashlib
import io
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid


def atomic(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".publish-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def proxy(home, data):
    plist = home / "Library/LaunchAgents/com.alexandrem.opencode2-ui.plist"
    target = home / ".local/share/opencode-custom-v2/bin/proxy.mjs"
    if not plist.is_file():
        return "proxy skipped (job not installed)"
    with plist.open("rb") as stream:
        definition = plistlib.load(stream)
    if str(target) not in definition.get("ProgramArguments", []):
        return "proxy skipped (job not installed for this runtime)"
    if target.is_file() and target.read_bytes() == data:
        return "proxy unchanged"
    atomic(target, data, 0o644)
    return "proxy installed"


def hub(home, commit, data):
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("Expected a full commit SHA")
    if not (home / "Library/LaunchAgents/local.opencode.resources-hub.plist").is_file():
        return "resources hub skipped (job not installed)"
    root = home / ".local/share/opencode-resources-hub"
    releases = root / "releases"
    releases.mkdir(parents=True, exist_ok=True)
    target = releases / commit
    if not (target / "plugin/index.js").is_file():
        staging = pathlib.Path(tempfile.mkdtemp(prefix=".publish-", dir=releases))
        try:
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                for entry in archive.getmembers():
                    parts = pathlib.PurePosixPath(entry.name).parts
                    if not parts or parts[0] not in ("plugin", "serve-sim") or ".." in parts:
                        raise ValueError("Unexpected path in hub archive")
                archive.extractall(staging, filter="data")
            if not (staging / "plugin/index.js").is_file():
                raise ValueError("Hub archive is missing plugin/index.js")
            for directory, dirs, files in os.walk(staging, followlinks=False):
                for name in [".", *dirs, *files]:
                    path = pathlib.Path(directory) / name
                    if not path.is_symlink():
                        os.chmod(path, path.stat().st_mode | 0o200)
            os.rename(staging, target)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
    temporary = root / (".current-" + uuid.uuid4().hex)
    temporary.symlink_to("releases/" + commit)
    os.replace(temporary, root / "current")
    others = sorted(
        (p for p in releases.iterdir() if p.name != commit and re.fullmatch(r"[a-f0-9]{40}", p.name)),
        key=lambda p: p.stat().st_mtime, reverse=True,
    )
    for old in others[3:]:
        shutil.rmtree(old)
    return "resources hub installed"


CONTROLLER_APP = "OpenCode Custom Controller.app"


def controller_plist(bundle_id):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>{bundle_id}</string>
<key>CFBundleExecutable</key><string>mac-controller</string>
<key>CFBundleName</key><string>OpenCode Custom Controller</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
""".encode()


def run(args):
    result = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout


def controller(home, bundle_id, subject, data):
    """`mac-controller` app (custom-mac-controller.ts): its C source arrives on stdin; built and signed here."""
    runtime = home / ".local/share/opencode-custom-v2"
    keychain = runtime / "signing/signing.keychain-db"
    if not keychain.is_file():
        return f"mac controller skipped ({keychain} missing)"
    root = runtime / "mac-controller"
    app = root / CONTROLLER_APP
    link = runtime / "bin/mac-controller"
    plist = controller_plist(bundle_id)
    digest = hashlib.sha256(data + plist).hexdigest()
    stamp = root / "source.sha256"
    if (
        stamp.is_file()
        and stamp.read_text().strip() == digest
        and link.exists()
        and subprocess.run(["codesign", "--verify", "--strict", str(app)], capture_output=True).returncode == 0
    ):
        return "mac controller unchanged"
    # Processes started through `mac` have no umask: every mode below is explicit.
    root.mkdir(parents=True, exist_ok=True)
    os.chmod(root, 0o755)
    work = pathlib.Path(tempfile.mkdtemp(prefix=".build-", dir=root))
    try:
        built = work / CONTROLLER_APP
        executable = built / "Contents/MacOS/mac-controller"
        executable.parent.mkdir(parents=True)
        source = work / "mac-controller.c"
        source.write_bytes(data)
        (built / "Contents/Info.plist").write_bytes(plist)
        run(["clang", "-O2", "-Wall", "-Werror", "-o", str(executable), str(source)])
        for path, mode in [
            (built, 0o755),
            (built / "Contents", 0o755),
            (executable.parent, 0o755),
            (executable, 0o755),
            (built / "Contents/Info.plist", 0o644),
        ]:
            os.chmod(path, mode)
        run(["security", "unlock-keychain", "-p", "", str(keychain)])
        found = re.search(
            r'\b([A-F0-9]{40}) "' + re.escape(subject) + '"',
            run(["security", "find-identity", "-p", "codesigning", str(keychain)]),
        )
        if not found:
            raise ValueError(f'Signing identity "{subject}" is missing from {keychain}')
        run(["codesign", "--force", "--sign", found.group(1), "--keychain", str(keychain), str(built)])
        run(["codesign", "--verify", "--strict", str(built)])
        if app.exists():
            os.rename(app, work / "previous.app")
        os.rename(built, app)
        atomic(stamp, (digest + "\n").encode(), 0o644)
        link.parent.mkdir(parents=True, exist_ok=True)
        pending = work / "link"
        os.symlink(os.path.relpath(app / "Contents/MacOS/mac-controller", link.parent), pending)
        os.replace(pending, link)
        # Before the bundle, the controller was a bare bin/mac-controller with this stamp beside it.
        (runtime / "bin/mac-controller.sha256").unlink(missing_ok=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return "mac controller installed"


if __name__ == "__main__":
    operation, directory, *args = sys.argv[1:]
    data = sys.stdin.buffer.read()
    home = pathlib.Path(directory)
    if operation == "proxy":
        print(proxy(home, data))
    elif operation == "hub":
        print(hub(home, args[0], data))
    elif operation == "controller":
        print(controller(home, args[0], args[1], data))
    else:
        raise SystemExit(f"Unknown operation: {operation}")

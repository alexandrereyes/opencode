"""Host-side publication for a Linux release. Input arrives through stdin, never a shared mount."""
import io
import os
import pathlib
import plistlib
import re
import shutil
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


if __name__ == "__main__":
    operation, directory, *args = sys.argv[1:]
    data = sys.stdin.buffer.read()
    home = pathlib.Path(directory)
    print(proxy(home, data) if operation == "proxy" else hub(home, args[0], data))

#!/usr/bin/env python3
"""Offline native Mac voice/dictation checks and locked-screen-compatible captures.

Uses an isolated Debug bundle, the existing in-memory Mac server, the iOS voice
fixtures and recorded PCM. No microphone, GPT Live call or master inference.
--parakeet downloads the pinned model to the evidence folder and checks real ASR.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--evidence", type=Path, default=Path(os.environ["TMPDIR"]) / "opencode/mac-voz-prints")
parser.add_argument("--parakeet", action="store_true")
parser.add_argument("--only", help="Run only a named capture (for focused verification).")
args = parser.parse_args()
package = Path(__file__).resolve().parents[1]
args.evidence.mkdir(parents=True, exist_ok=True)
domain = "br.com.alexandrem.opencode.mac.debug.voice-tests"
manifest = []
with tempfile.TemporaryDirectory(prefix="mac-voice-", dir=args.evidence) as temporary:
    copy = Path(temporary) / "OpenCodeMacVoiceTests.app"
    shutil.copytree(args.app, copy, symlinks=True)
    info = copy / "Contents/Info.plist"
    metadata = plistlib.loads(info.read_bytes())
    metadata["CFBundleIdentifier"] = domain
    info.write_bytes(plistlib.dumps(metadata))
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(copy)], check=True, capture_output=True)
    executable = copy / "Contents/MacOS/OpenCodeMac"

    def run(name, flags, theme="openchamber-dark", timeout=90):
        if args.only and name != args.only:
            return
        command = [str(executable), "-OpenCodeMacFixture", "contexto", "-OpenCodeMacFixtureRoot", str(package.parents[1]),
                   "-OpenCodeMacDraftRoot", str(Path(temporary) / f"drafts-{name}"),
                   "-OpenCodeServerURL", "http://127.0.0.1:4203", "-OpenCodeTheme", theme,
                   "-OpenCodeMacCapture", str(args.evidence), "-OpenCodeMacCaptureName", name,
                   "-OpenCodeMacCaptureSize", "1500x940", *flags, "-OpenCodeMacCaptureQuit"]
        with (args.evidence / f"{name}.log").open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        if result.returncode != 0 or not (args.evidence / f"{name}.png").exists():
            raise RuntimeError(f"{name} failed; see {args.evidence / (name + '.log')}")
        manifest.append({"name": name, "capture": str(args.evidence / f"{name}.png"), "exit": result.returncode})
        print(name, "ok", flush=True)

    try:
        for theme in ["openchamber-dark", "openchamber-light"]:
            suffix = theme.rsplit("-", 1)[1]
            for state in ["listening", "speaking", "thinking", "connecting", "reconnecting", "offline", "muted", "error", "idle", "long", "interrupted"]:
                run(f"{state}-{suffix}", ["-OpenCodeVoiceBarFixture", state, "-OpenCodeVoiceBarExpanded"], theme)
            run(f"compact-{suffix}", ["-OpenCodeVoiceBarFixture", "listening"], theme)
            run(f"engine-{suffix}", ["-OpenCodeVoiceFixture"], theme)
            run(f"read-aloud-{suffix}", ["-OpenCodeMacReadAloudFixture"], theme)
            for action in ["recording", "paused", "review", "checks"]:
                run(f"dictation-{action}-{suffix}", ["-OpenCodeDictationFixture", "fake", "-OpenCodeMacDictationAction", action], theme)
            run(f"settings-voice-{suffix}", ["-OpenCodeMacSettings", "voz"], theme)
            run(f"settings-transcription-{suffix}", ["-OpenCodeMacSettings", "transcricao"], theme)
        if args.parakeet:
            run("parakeet", ["-OpenCodeMacParakeetRoot", str(args.evidence / "parakeet-model")], timeout=900)
    finally:
        subprocess.run(["defaults", "delete", domain], capture_output=True)
        saved = Path.home() / "Library/Saved Application State" / f"{domain}.savedState"
        if saved.exists():
            shutil.rmtree(saved)
        name = f"verification-{args.only}.json" if args.only else "verification.json"
        (args.evidence / name).write_text(json.dumps(manifest, indent=2))

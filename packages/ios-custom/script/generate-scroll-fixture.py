#!/usr/bin/env python3
"""Keep only transcript shapes/lengths; every displayed character is synthetic.

Usage: generate-scroll-fixture.py RAW_MESSAGE_PAGE... --output PATH
Raw GET responses must live outside the repository and must be removed afterwards.
"""
import argparse
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("pages", nargs="+", type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()

words = "Conteúdo sintético para medir a rolagem com texto, ferramentas e resultados de exemplo. "


def prose(length):
    return (words * (length // len(words) + 1))[:length]


def markdown(source):
    lines = []
    fenced = False
    for line in source.splitlines():
        if re.match(r"\s*(```|~~~)", line):
            lines.append("```" if fenced else "```swift")
            fenced = not fenced
            continue
        if not line.strip():
            lines.append("")
            continue
        if fenced:
            lines.append(("let exemplo = \"conteudo sintetico\" // " + prose(len(line)))[:len(line)])
            continue
        prefix = re.match(r"\s*(?:#{1,6} |[-*+] |\d+\. |> )", line)
        text = prose(max(1, len(line) - (len(prefix[0]) if prefix else 0)))
        if "**" in line and len(text) > 32:
            text = "**" + text[:16] + "**" + text[16:]
        if "`" in line and len(text) > 48:
            text = text[:32] + "`exemplo`" + text[40:]
        lines.append((prefix[0] if prefix else "") + text)
    if fenced:
        lines.append("```")
    return "\n".join(lines)


tools = {"read", "shell", "grep", "glob", "subagent", "write", "edit", "patch", "skill", "execute", "question", "webfetch", "websearch"}
messages = []
shape_stats = []
for page_number, path in enumerate(args.pages):
    raw = json.loads(path.read_text())["data"]
    shape_stats.append({"messages": len(raw), "parts": sum(len(m.get("content", [])) for m in raw)})
    for original in reversed(raw):
        index = len(messages)
        time = 1792576800000 + index * 5000
        kind = original["type"] if original["type"] in {"user", "assistant", "idle", "synthetic", "system", "compaction"} else "synthetic"
        message = {"id": f"msg_scroll_{index:04}", "type": kind,
                   "time": {"created": time, "completed": time + 4000}}
        if kind == "assistant":
            message.update(agent="build", model={"id": "modelo-exemplo", "providerID": "fixture", "variant": "high"}, finish="stop")
            parts = []
            for part_index, original_part in enumerate(original.get("content", [])):
                part_kind = original_part["type"]
                if part_kind in {"text", "reasoning"}:
                    parts.append({"type": part_kind, "text": markdown(original_part.get("text", "")),
                                  "time": {"created": time, "completed": time + 3000}})
                    continue
                if part_kind != "tool":
                    continue
                name = original_part.get("name")
                name = name if name in tools else "read"
                output_length = sum(len(c.get("text", "")) for c in original_part.get("state", {}).get("content", []))
                parts.append({"type": "tool", "id": f"tool_scroll_{index}_{part_index}", "name": name,
                              "time": {"created": time, "ran": time + 100, "completed": time + 3000},
                              "state": {"status": "completed", "input": {
                                  "path": "Sources/Exemplo.swift", "command": "swift test --filter Exemplo",
                                  "pattern": "exemplo", "description": "Verificar exemplo sintético", "id": "exemplo"},
                                  "content": [{"type": "text", "text": prose(output_length)}],
                                  "metadata": {"exit": 0}}})
            message["content"] = parts
        elif kind == "idle":
            message["outcome"] = "succeeded"
        else:
            message["text"] = markdown(original.get("text", ""))
            if original.get("description"):
                message["description"] = prose(len(original["description"]))
        messages.append(message)

projects = [{"id": f"project_scroll_{i}", "canonical": f"/Projetos/exemplo-{i}", "name": f"Projeto Exemplo {i}", "sandboxes": [], "vcs": "git"} for i in range(6)]
entries = []
for index in range(300):
    time = 1792576800000 - index * 600000
    entries.append({"session": {"id": f"ses_scroll_{index:04}", "projectID": projects[index % 6]["id"],
                    "title": f"Sessão de exemplo {index:03} — revisão do projeto e ferramentas",
                    "location": {"directory": projects[index % 6]["canonical"]}, "agent": "build",
                    "model": {"id": "modelo-exemplo", "providerID": "fixture", "variant": "high"},
                    "time": {"created": time, "updated": time, "idle": time, "viewed": time if index % 3 else 0}, "outcome": "succeeded"},
                    "messageAt": time})

fixture = {"provenance": {"description": "Three real 100-message page shapes; no original strings or identifiers retained.", "pages": shape_stats},
           "messages": messages, "entries": entries, "projects": projects,
           "preferences": {"revision": 1, "data": {"projects": {"local": {"projects": [{"worktree": p["canonical"], "expanded": True} for p in projects]}},
                           "pinnedSessions": [], "mutedSessions": [], "settings": {"autoApprove": False}}},
           "models": [{"id": "modelo-exemplo", "providerID": "fixture", "name": "Modelo Exemplo", "limit": {"context": 200000}}]}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(fixture, ensure_ascii=False, separators=(",", ":")) + "\n")
print(json.dumps({"messages": len(messages), "sessions": len(entries), "pages": shape_stats, "bytes": args.output.stat().st_size}))

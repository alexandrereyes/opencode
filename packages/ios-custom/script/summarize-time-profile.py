#!/usr/bin/env python3
"""Main-thread summary of an exported Time Profiler table (`xctrace export --xpath '…table[@schema="time-profile"]'`):
total sampled time, and the inclusive time of the frames whose names match `--match` (by default the app's own
modules), heaviest first.

    python3 packages/ios-custom/script/summarize-time-profile.py <time-profile.xml> [--match OpenCode] [--top 40]
"""
import argparse
from collections import Counter
import re
import xml.etree.ElementTree as ElementTree

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("xml")
parser.add_argument("--match", default="", help="regular expression on frame names; empty lists every frame")
parser.add_argument("--top", type=int, default=40)
args = parser.parse_args()

root = ElementTree.parse(args.xml).getroot()
elements = {element.get("id"): element for element in root.iter() if element.get("id")}


def resolve(element):
    return elements.get(element.get("ref"), element) if element is not None and element.get("ref") else element


total = Counter()
inclusive = Counter()
pattern = re.compile(args.match) if args.match else None
for row in root.iter("row"):
    thread = resolve(row.find("thread"))
    name = thread.get("fmt", "") if thread is not None else ""
    if not name.startswith("Main Thread"):
        continue
    weight = resolve(row.find("weight"))
    nanos = int(weight.text) if weight is not None and weight.text else 0
    total["main"] += nanos
    backtrace = resolve(row.find("tagged-backtrace") if row.find("tagged-backtrace") is not None else row.find("backtrace"))
    if backtrace is None:
        continue
    names = []
    for frame in backtrace.iter("frame"):
        frame = resolve(frame)
        names.append(frame.get("name", "?"))
    for name in set(names):
        if pattern is None or pattern.search(name):
            inclusive[name] += nanos

print(f"main thread sampled: {total['main'] / 1e6:.0f} ms")
for name, nanos in inclusive.most_common(args.top):
    print(f"{nanos / 1e6:8.0f} ms  {name[:150]}")

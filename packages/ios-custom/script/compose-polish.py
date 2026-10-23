#!/usr/bin/env python3
"""Pair unmodified before/after simulator screenshots for review."""
from pathlib import Path
from PIL import Image, ImageDraw

root = Path("/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-polimento-prints")
for before in sorted(root.glob("before-*.png")):
    suffix = before.name.removeprefix("before-")
    after = root / ("after-" + suffix)
    if not after.exists():
        continue
    images = [Image.open(path).convert("RGB") for path in [before, after]]
    canvas = Image.new("RGB", (sum(image.width for image in images) + 16, max(image.height for image in images) + 40), "white")
    draw = ImageDraw.Draw(canvas)
    x = 0
    for label, image in zip(["Antes", "Depois"], images):
        draw.text((x + 12, 12), label, fill="black")
        canvas.paste(image, (x, 40))
        x += image.width + 16
    output = root / ("comparison-" + suffix)
    canvas.save(output)
    print(output)

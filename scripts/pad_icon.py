#!/usr/bin/env python3
"""Render macOS app icon: shrink + apply squircle mask onto 1024 transparent canvas."""
import sys
from PIL import Image, ImageDraw

src_path, dst_path = sys.argv[1], sys.argv[2]
inset = int(sys.argv[3]) if len(sys.argv) > 3 else 100
mask_corner_ratio = float(sys.argv[4]) if len(sys.argv) > 4 else 0.225  # macOS BS+ ~22.5%

inner = 1024 - 2 * inset
src = Image.open(src_path).convert("RGBA")
src = src.resize((inner, inner), Image.LANCZOS)

# Rounded-rect mask (squircle approximation)
mask = Image.new("L", (inner, inner), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    (0, 0, inner - 1, inner - 1),
    radius=int(inner * mask_corner_ratio),
    fill=255,
)
src.putalpha(mask)

canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
canvas.paste(src, (inset, inset), src)
canvas.save(dst_path, "PNG")
print(f"wrote {dst_path}")

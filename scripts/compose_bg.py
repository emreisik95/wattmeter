#!/usr/bin/env python3
"""Composite /Applications folder icon onto DMG background image at drop-zone position."""
import sys
from io import BytesIO
from AppKit import NSWorkspace
from PIL import Image

src_bg, dst_bg = sys.argv[1], sys.argv[2]
center_x = int(sys.argv[3])
center_y = int(sys.argv[4])
icon_size = int(sys.argv[5]) if len(sys.argv) > 5 else 128

ws = NSWorkspace.sharedWorkspace()
ns_icon = ws.iconForFile_('/Applications')
ns_icon.setSize_((icon_size, icon_size))
tiff = ns_icon.TIFFRepresentation()
icon = Image.open(BytesIO(bytes(tiff))).convert('RGBA').resize((icon_size, icon_size), Image.LANCZOS)

bg = Image.open(src_bg).convert('RGBA')
top_left = (center_x - icon_size // 2, center_y - icon_size // 2)
bg.paste(icon, top_left, icon)
bg.save(dst_bg, 'PNG')
print(f"composited Applications icon @ ({center_x},{center_y}) size={icon_size} -> {dst_bg}")

#!/usr/bin/env python3
"""Copy /Applications folder icon onto a target file (e.g. DMG symlink)."""
import sys
from AppKit import NSWorkspace

target = sys.argv[1]
ws = NSWorkspace.sharedWorkspace()
icon = ws.iconForFile_('/Applications')
ok = ws.setIcon_forFile_options_(icon, target, 0)
print(f"setIcon_ -> {ok} for {target}")

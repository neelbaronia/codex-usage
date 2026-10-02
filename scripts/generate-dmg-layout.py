#!/usr/bin/env python3
"""Regenerate the checked-in Finder layout (requires ds-store==1.3.3).

Packaging uses the generated file directly and does not require Python.
The template contains only view settings and relative filenames.
"""

from pathlib import Path

from ds_store import DSStore


layout = Path(__file__).resolve().parents[1] / "Resources/dmg-layout.dsstore"
with DSStore.open(str(layout), "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = ("type", b"icnv")
    store["."]["bwsp"] = {
        "WindowBounds": "{{180, 160}, {600, 340}}",
        "ShowToolbar": False,
        "ShowSidebar": False,
        "ContainerShowSidebar": False,
        "ShowStatusBar": False,
        "ShowPathbar": False,
        "ShowTabView": False,
        "PreviewPaneVisibility": False,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 0,
        "arrangeBy": "none",
        "iconSize": 80.0,
        "textSize": 13.0,
        "labelOnBottom": True,
        "showItemInfo": False,
        "showIconPreview": False,
        "gridSpacing": 100.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }
    store["Codex Usage.app"]["Iloc"] = (160, 100)
    store["Applications"]["Iloc"] = (440, 100)
    store["Install Codex Usage.txt"]["Iloc"] = (300, 250)

print(layout)

#!/usr/bin/env python3
"""Create Finder geometry or attach a background to a mounted DMG's layout.

Requires ds-store==1.3.3 and mac-alias==2.2.3. With no arguments, regenerate
Resources/dmg-layout.dsstore, which intentionally contains no background alias.
Packaging supplies --volume-root after creating a writable HFS+ image, then
converts that same filesystem to the final read-only DMG. This preserves the
alias's real volume date and file IDs without embedding private build paths.
"""

import argparse
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias


DEFAULT_LAYOUT = Path(__file__).resolve().parents[1] / "Resources/dmg-layout.dsstore"
VOLUME_NAME = "Codex Usage"
BACKGROUND_PATH = ".background.tiff"


def write_geometry(layout):
    with DSStore.open(str(layout), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["icvl"] = ("type", b"icnv")
        store["."]["bwsp"] = {
            "WindowBounds": "{{180, 160}, {600, 340}}",
            "ShowToolbar": False,
            "ShowSidebar": False,
            "SidebarWidth": 180,
            "ContainerShowSidebar": False,
            "ShowStatusBar": False,
            "ShowPathbar": False,
            "ShowTabView": False,
            "PreviewPaneVisibility": False,
        }
        store["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "backgroundType": 0,
            "backgroundColorRed": 1.0,
            "backgroundColorGreen": 1.0,
            "backgroundColorBlue": 1.0,
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


def write_volume_layout(volume_root, layout, template):
    root = volume_root.resolve(strict=True)
    background = root / BACKGROUND_PATH
    if not background.is_file() or background.resolve() != background:
        raise ValueError(f"Expected a regular background image at {BACKGROUND_PATH}")

    alias = Alias.for_file(str(background))
    mount_path = alias.volume.posix_path
    if isinstance(mount_path, bytes):
        mount_path = mount_path.decode("utf-8")
    if Path(mount_path).resolve() != root:
        raise ValueError("--volume-root must be the mounted disk image root")
    volume_name = alias.volume.name
    if isinstance(volume_name, bytes):
        volume_name = volume_name.decode("utf-8")
    if volume_name != VOLUME_NAME:
        raise ValueError(f"Expected disk image volume name {VOLUME_NAME!r}")

    # Keep this image's real creation dates and CNIDs: Finder uses them to
    # distinguish it from older images with the same volume name. The canonical
    # mount hint is public. Preserve Alias.for_file's native target metadata,
    # including the root-level background path, exactly as dmgbuild does.
    alias.volume.posix_path = f"/Volumes/{VOLUME_NAME}"
    alias.volume.disk_image_alias = None

    # Load before opening output so a caller may patch a template in place.
    # Do not include pBBk: it breaks backgrounds on macOS 26.2.
    # https://github.com/dmgbuild/dmgbuild/pull/275
    with DSStore.open(str(template), "r") as source:
        entries = [entry for entry in source if not (
            entry.filename == "." and entry.code in (b"pBBk", b"icvp", b"bwsp")
        )]
        options = dict(source["."]["icvp"])
        window_options = dict(source["."]["bwsp"])
    for channel in ("Red", "Green", "Blue"):
        options.setdefault(f"backgroundColor{channel}", 1.0)
    if "textSize" in options:
        options["textSize"] = float(options["textSize"])
    window_options.setdefault("SidebarWidth", 180)
    options["backgroundType"] = 2
    options["backgroundImageAlias"] = alias.to_bytes()
    # Use the incremental writer, as dmgbuild does. ds-store 1.3.3's bulk
    # initial_entries writer records depth 1 for a leaf-only tree; Finder
    # ignores that layout even though the Python reader can decode it. Insert
    # the final icvp and bwsp once: replacing entries also corrupts its count.
    with DSStore.open(str(layout), "w+") as store:
        for entry in entries:
            store.insert(entry)
        store["."]["icvp"] = options
        store["."]["bwsp"] = window_options


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--volume-root", type=Path, help="Mounted writable HFS+ image")
    parser.add_argument("--output", type=Path, help="Destination .DS_Store")
    parser.add_argument("--template", type=Path, help="Finder geometry to preserve")
    args = parser.parse_args()
    if args.volume_root:
        if not args.output:
            parser.error("--volume-root requires --output")
        write_volume_layout(args.volume_root, args.output, args.template or DEFAULT_LAYOUT)
        layout = args.output
    else:
        if args.template:
            parser.error("--template requires --volume-root")
        layout = args.output or DEFAULT_LAYOUT
        write_geometry(layout)
    print(layout)


if __name__ == "__main__":
    main()

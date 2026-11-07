#!/usr/bin/env python3
"""Install the development build into Adobe's shared MediaCore plug-in folder.

The previous bundle is kept in build/install-backups. Close After Effects and
Premiere Pro first; running hosts keep the code they loaded.
"""
from datetime import datetime, timezone
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = "org.spektrafilm.adobe"


def mac_layout():
    source = ROOT / "build/plugin/SpektraFilm.plugin"
    target = Path.home() / "Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/SpektraFilm.plugin"
    return source, target, source / "Contents/Info.plist"


def windows_layout():
    source = ROOT / "build/plugin/SpektraFilm"
    common = Path(os.environ.get("CommonProgramFiles", r"C:\Program Files\Common Files"))
    # Adobe's shared folder lives under Program Files, beside Common Files.
    target = common.parent / "Adobe/Common/Plug-ins/7.0/MediaCore/SpektraFilm"
    return source, target, source / "Contents/Win64/SpektraFilm.aex"


def identify(bundle):
    """True when the bundle at this path is ours (or absent)."""
    if sys.platform == "darwin":
        with (bundle / "Contents/Info.plist").open("rb") as file:
            return plistlib.load(file).get("CFBundleIdentifier") == IDENTIFIER
    return (bundle / "Contents/Win64/SpektraFilm.aex").is_file()


def verify(bundle):
    if sys.platform == "darwin":
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)


def main():
    if sys.platform == "darwin":
        source, target, marker = mac_layout()
    elif sys.platform == "win32":
        source, target, marker = windows_layout()
    else:
        raise SystemExit("Adobe hosts run on macOS and Windows only.")
    if not marker.is_file() or not identify(source):
        raise SystemExit(f"Build the plugin first; {marker} is missing or not spektrafilm.")
    verify(source)
    if target.is_symlink() or (target.exists() and not identify(target)):
        raise SystemExit(f"Refusing to replace an unrelated bundle or symbolic link at {target}.")
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
    except PermissionError:
        raise SystemExit(f"No write access to {target.parent}. On Windows, run from an administrator terminal.")
    # '~' keeps Adobe's plug-in scanner away from the staging copy.
    stage = target.parent / f"~SpektraFilm-{uuid.uuid4().hex}"
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = ROOT / "build/install-backups" / stamp / target.name
    try:
        shutil.copytree(source, stage)
        verify(stage)
        if target.exists():
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(target), str(backup))
        try:
            stage.rename(target)
        except BaseException:
            if backup.exists() and not target.exists():
                shutil.move(str(backup), str(target))
            raise
        verify(target)
        # copytree keeps the build folder's date, which a rebuild does not
        # change. Premiere keys its plug-in cache to that date and would keep
        # the previous PiPL, so stamp the installed bundle as new.
        os.utime(target)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    print(f"Installed: {target}")
    if backup.exists():
        print(f"Previous bundle kept: {backup}")
    print("Restart After Effects and Premiere Pro to load it.")


if __name__ == "__main__":
    main()

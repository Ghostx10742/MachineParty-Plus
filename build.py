#!/usr/bin/env python3
"""Package MachineParty+ into a release zip for the Machine Party Mod Loader.

The Machine Party Mod Loader loads mods as LOOSE FOLDERS inside the game's
`mods` folder, so there is no compile step. "Building" just zips the mod folder
so that extracting the zip into `mods` gives you `mods/Jarunk-MachinePartyPlus/`.

Usage:  python build.py
Output: dist/Jarunk-MachinePartyPlus.zip
"""
import os
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
MOD_DIR = "Jarunk-MachinePartyPlus"      # folder that goes into the game's mods/
SRC = os.path.join(HERE, MOD_DIR)
OUT_DIR = os.path.join(HERE, "dist")
OUT = os.path.join(OUT_DIR, MOD_DIR + ".zip")


def main() -> None:
    if not os.path.isdir(SRC):
        raise SystemExit("Cannot find mod source folder: " + SRC)
    os.makedirs(OUT_DIR, exist_ok=True)
    if os.path.exists(OUT):
        os.remove(OUT)
    count = 0
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _dirs, files in os.walk(SRC):
            for fn in files:
                full = os.path.join(root, fn)
                rel = os.path.relpath(full, SRC).replace("\\", "/")  # files at zip root
                z.write(full, rel)
                count += 1
    print("Built " + OUT + " (" + str(count) + " files)")
    print("Windows 'Extract All' makes a single " + MOD_DIR + " folder; drop it in mods/.")


if __name__ == "__main__":
    main()

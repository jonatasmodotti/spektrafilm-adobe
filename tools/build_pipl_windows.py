#!/usr/bin/env python3
"""Compile a Windows PiPL using the Adobe SDK's resource tool and MSVC."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("compiler", "sdk", "source", "output"):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--define", action="append", default=[], help="NAME=VALUE for the PiPL source")
    args = parser.parse_args()
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    sdk = Path(args.sdk)
    intermediate = output.with_suffix(".rr")
    resource = output.with_suffix(".rrc")
    command = [args.compiler, "/nologo", "/EP", "/DAE_OS_WIN", "/DAE_PROC_INTELx64",
               *[f"/D{define}" for define in args.define],
               "/I", str(sdk / "Examples/Headers"), "/Tc" + str(Path(args.source))]
    with intermediate.open("wb") as dest:
        subprocess.run(command, stdout=dest, check=True)
    subprocess.run([str(sdk / "Examples/Resources/PiPLtool.exe"), str(intermediate), str(resource)], check=True)
    with output.open("wb") as dest:
        subprocess.run([args.compiler, "/nologo", "/EP", "/DMSWindows", "/Tc" + str(resource)], stdout=dest, check=True)


if __name__ == "__main__":
    main()

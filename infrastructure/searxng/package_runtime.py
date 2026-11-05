#!/usr/bin/env python3
# Created by Sébastien DAGUIN
"""Stage an already prepared relocatable Python/SearXNG runtime before app signing."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path, help="Relocatable Python root containing bin/python3")
    parser.add_argument("app", type=Path, help="Unsigned macOS .app staging directory")
    parser.add_argument("--sign", help="Code signing identity for embedded Mach-O files")
    parser.add_argument("--entitlements", type=Path, help="Sandbox inheritance entitlements for Python")
    args = parser.parse_args()
    if bool(args.sign) != bool(args.entitlements):
        parser.error("--sign and --entitlements must be supplied together")
    source = args.runtime.resolve(strict=True)
    app = args.app.resolve(strict=True)
    destination = app / "Contents/Resources/SearXNG/python"
    if app.suffix != ".app" or not (app / "Contents").is_dir():
        parser.error("app must be an existing .app staging directory")
    if not (source / "bin/python3").is_file():
        parser.error("runtime must contain bin/python3")
    if (source / "pyvenv.cfg").exists():
        parser.error("a development venv is not a standalone relocatable Python distribution")
    if destination.exists() or destination.is_symlink():
        parser.error("destination already exists; refusing to overwrite it")
    if app == source or app.is_relative_to(source) or source.is_relative_to(app):
        parser.error("runtime and application must be separate directories")
    for item in source.rglob("*"):
        if item.is_symlink() and not item.resolve().is_relative_to(source):
            parser.error(f"runtime contains an external symlink: {item.relative_to(source)}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.copytree(source, destination, symlinks=True)
        # Absolute internal symlinks would still point to the original runtime after copying.
        for item in destination.rglob("*"):
            if item.is_symlink() and os.path.isabs(os.readlink(item)):
                relative_target = item.resolve().relative_to(source)
                item.unlink()
                item.symlink_to(os.path.relpath(destination / relative_target, item.parent))
        with tempfile.TemporaryDirectory(prefix="noctis-runtime-check-") as temporary:
            subprocess.run(
                [str(destination / "bin/python3"), "-I", "-B", "-c",
                 "import importlib.util, pathlib, sys; "
                 "import searx, flask, werkzeug; "
                 "root = pathlib.Path(sys.argv[1]).resolve(); "
                 "assert pathlib.Path(sys.prefix).resolve().is_relative_to(root); "
                 "assert pathlib.Path(sys.base_prefix).resolve().is_relative_to(root); "
                 "assert pathlib.Path(searx.__file__).resolve().is_relative_to(root); "
                 "assert importlib.util.find_spec('searx.webapp') is not None; "
                 "assert (pathlib.Path(searx.__file__).parent / 'settings.yml').is_file()",
                 str(destination)],
                env={"PATH": "/usr/bin:/bin", "HOME": temporary, "TMPDIR": temporary},
                cwd=temporary, check=True, timeout=60,
            )
        if args.sign:
            # Sign libraries before the interpreter; only executables inherit the app sandbox.
            binaries = []
            for item in destination.rglob("*"):
                if item.is_symlink() or not item.is_file():
                    continue
                with item.open("rb") as stream:
                    magic = stream.read(4)
                if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
                    binaries.append(item)
            for item in sorted(binaries, key=lambda path: path.parent == destination / "bin"):
                command = ["codesign", "--force", "--options", "runtime", "--sign", args.sign]
                if item.suffix not in (".so", ".dylib"):
                    command += ["--entitlements", str(args.entitlements.resolve(strict=True))]
                subprocess.run(command + [str(item)], check=True)
                subprocess.run(["codesign", "--verify", "--strict", str(item)], check=True)
    except BaseException:
        shutil.rmtree(destination)
        raise
    print(f"Runtime staged at {destination}. Sign the app before distribution.")


if __name__ == "__main__":
    main()

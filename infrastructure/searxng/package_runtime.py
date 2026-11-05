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
    args = parser.parse_args()
    source = args.runtime.resolve(strict=True)
    app = args.app.resolve(strict=True)
    destination = app / "Contents/Helpers/SearXNG/python"
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
    except BaseException:
        shutil.rmtree(destination)
        raise
    print(f"Runtime staged at {destination}. Sign nested code and the app before distribution.")


if __name__ == "__main__":
    main()

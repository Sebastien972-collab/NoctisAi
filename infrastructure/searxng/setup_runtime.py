#!/usr/bin/env python3
# Created by Sébastien DAGUIN
"""Prepare a local or relocatable SearXNG runtime, without Docker."""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import venv


REVISION = "cccbc9e158b0ac3bb2158e9841a647a5bec57b57"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--standalone", action="store_true", help="Prepare Python for embedding in a macOS app (requires uv)")
    parser.add_argument("--destination", type=Path, help="New runtime directory")
    args = parser.parse_args()
    if sys.platform != "darwin" or sys.version_info < (3, 10):
        parser.error("macOS and Python 3.10 or later are required")
    root = (args.destination or Path.home() / "Library/Application Support/Noctis/SearXNG").absolute()
    if root.exists() or root.is_symlink():
        parser.error(f"runtime destination already exists; refusing to overwrite: {root}")
    if args.standalone and shutil.which("uv") is None:
        parser.error("uv is required to download relocatable Python")
    root.mkdir(parents=True, mode=0o700)
    try:
        source = root / "source"
        subprocess.run(["git", "clone", "--no-checkout", "https://github.com/searxng/searxng.git", str(source)], check=True)
        subprocess.run(["git", "-C", str(source), "checkout", "--detach", REVISION], check=True)
        if args.standalone:
            managed = root / "managed"
            subprocess.run(["uv", "--cache-dir", str(root / "cache"), "python", "install",
                            "3.13.13", "--install-dir", str(managed), "--no-bin"], check=True)
            distributions = [path for path in managed.glob("cpython-*") if not path.is_symlink()]
            if len(distributions) != 1:
                raise RuntimeError("Expected one standalone Python distribution")
            environment = root / "python"
            shutil.move(str(distributions[0]), environment)
            python = str(environment / "bin/python3")
            install = ["uv", "--cache-dir", str(root / "cache"), "pip", "install",
                       "--python", python, "--break-system-packages"]
        else:
            environment = root / "venv"
            venv.EnvBuilder(with_pip=True).create(environment)
            python = str(environment / "bin/python")
            install = [python, "-m", "pip", "install"]
        subprocess.run(install + ["setuptools", "wheel"], check=True)
        subprocess.run(install + ["-r", str(source / "requirements.txt")], check=True)
        subprocess.run(install + ["--no-build-isolation", "--no-deps", str(source)], check=True)
        subprocess.run([python, "-I", "-B", "-c", "import searx, flask, werkzeug"], check=True)
    except BaseException:
        shutil.rmtree(root)
        raise
    print(f"SearXNG {REVISION} installed at {environment}.")


if __name__ == "__main__":
    main()

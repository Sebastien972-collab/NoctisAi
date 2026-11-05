#!/usr/bin/env python3
# Created by Sébastien DAGUIN
"""Install the CLI's local SearXNG runtime once, without Docker or global Python packages."""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import venv


REVISION = "cccbc9e158b0ac3bb2158e9841a647a5bec57b57"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    if sys.platform != "darwin" or sys.version_info < (3, 10):
        parser.error("macOS and Python 3.10 or later are required")
    root = Path.home() / "Library/Application Support/Noctis/SearXNG"
    if root.exists() or root.is_symlink():
        parser.error(f"runtime destination already exists; refusing to overwrite: {root}")
    root.mkdir(parents=True, mode=0o700)
    try:
        source = root / "source"
        subprocess.run(["git", "clone", "--no-checkout", "https://github.com/searxng/searxng.git", str(source)], check=True)
        subprocess.run(["git", "-C", str(source), "checkout", "--detach", REVISION], check=True)
        environment = root / "venv"
        venv.EnvBuilder(with_pip=True).create(environment)
        python = str(environment / "bin/python")
        subprocess.run([python, "-m", "pip", "install", "setuptools", "wheel"], check=True)
        subprocess.run([python, "-m", "pip", "install", "-r", str(source / "requirements.txt")], check=True)
        subprocess.run([python, "-m", "pip", "install", "--no-build-isolation", "--no-deps", str(source)], check=True)
        subprocess.run([python, "-I", "-B", "-c", "import searx, flask, werkzeug"], check=True)
    except BaseException:
        shutil.rmtree(root)
        raise
    print(f"SearXNG {REVISION} installed at {root}. Run swift run from Noctis.")


if __name__ == "__main__":
    main()

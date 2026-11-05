#!/usr/bin/env python3
# Created by Sébastien DAGUIN
"""Cross-compile the existing SearXNG dependencies for arm64 iPhone and Simulator."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile


def run(command, **kwargs):
    subprocess.run([str(value) for value in command], check=True, **kwargs)


def download(url, destination, digest=None):
    if not destination.exists():
        urllib.request.urlretrieve(url, destination)
    if digest and hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
        raise RuntimeError(f"Checksum mismatch: {destination.name}")
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mac-runtime", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    host = args.mac_runtime.resolve(strict=True)
    root = args.destination.absolute()
    if root.exists() and not (root / ".noctis-ios-build").exists():
        parser.error("destination already exists and is not an iOS runtime build")
    root.mkdir(parents=True, exist_ok=True)
    (root / ".noctis-ios-build").touch()
    python = host / "python/bin/python3"
    packages = host / "python/lib/python3.13/site-packages"
    requirements = dict(line.split("==", 1) for line in (host / "source/requirements.txt").read_text().splitlines() if "==" in line)
    freeze = "import json,runpy,sys; m=runpy.run_path(sys.argv[1]); print(json.dumps({k:m[k] for k in ['VERSION_STRING','VERSION_TAG','DOCKER_TAG','GIT_URL','GIT_BRANCH']}))"
    version_info = json.loads(subprocess.check_output([str(python), "-c", freeze, str(host / "source/searx/version.py")], cwd=host / "source", text=True))
    archive = download("https://github.com/beeware/Python-Apple-support/releases/download/3.13-b14/Python-3.13-iOS-support.b14.tar.gz", root / "python-ios.tar.gz")
    if not (root / "Python.xcframework").exists():
        with tarfile.open(archive) as bundle:
            bundle.extractall(root, filter="data")
    for framework in (root / "Python.xcframework").glob("ios-*/Python.framework"):
        modules = framework / "Modules"
        modules.mkdir(exist_ok=True)
        modulemap = (framework / "Headers/module.modulemap").read_text()
        (modules / "module.modulemap").write_text(modulemap.replace("module Python {", "framework module Python {").replace('link "Python"', 'link framework "Python"'))
    sources = root / "sources"
    sources.mkdir(exist_ok=True)
    for name in ("lxml", "msgspec", "curl_cffi"):
        version = requirements[name]
        source = sources / f"{name}-{version}"
        if not source.exists():
            with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/{version}/json") as response:
                metadata = json.load(response)
            item = next(item for item in metadata["urls"] if item["packagetype"] == "sdist")
            archive = download(item["url"], root / item["filename"], item["digests"]["sha256"])
            with tarfile.open(archive) as bundle:
                bundle.extractall(sources, filter="data")
    mac_sdk = Path(subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
    headers = root / "headers"
    for name in ("libxslt", "libexslt"):
        shutil.copytree(mac_sdk / "usr/include" / name, headers / name, dirs_exist_ok=True)
    for sdk, slice_name, multiarch, curl_arch in (
        ("iphoneos", "ios-arm64", "arm64-iphoneos", "arm64-apple-ios"),
        ("iphonesimulator", "ios-arm64_x86_64-simulator", "arm64-iphonesimulator", "arm64-apple-ios-simulator"),
    ):
        output = root / sdk
        output.mkdir(exist_ok=True)
        target = root / "Python.xcframework" / slice_name
        cross = output / "cross"
        if not cross.exists():
            run([python, "-m", "venv", cross])
            run([cross / "bin/python", "-m", "pip", "install", "setuptools", "setuptools-scm", "wheel"])
            run([cross / "bin/python", target / "platform-config" / multiarch / "make_cross_venv.py", cross])
        env = os.environ.copy()
        env["PATH"] = f"{target / 'bin'}:/usr/bin:/bin"
        env["PKG_CONFIG"] = "/usr/bin/false"
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        for library, version, libs in (("xml2", "2.9.13", "-lxml2"), ("xslt", "1.1.35", "-lxslt -lexslt")):
            config = output / f"{library}-config"
            config.write_text(f'#!/bin/sh\n# Created by Sébastien DAGUIN\ncase "$*" in\n*--version*) echo {version};;\n*--cflags*) echo "-I{sdk_path}/usr/include/libxml2 -I{headers}";;\n*--libs*) echo "{libs} -lxml2 -lz -liconv";;\nesac\n')
            config.chmod(0o755)
            env[f"{library.upper()}_CONFIG"] = str(config)
        wheels = output / "wheels"
        wheels.mkdir(exist_ok=True)
        for name in ("msgspec", "lxml"):
            if not list(wheels.glob(f"{name}-*.whl")):
                run([cross / "bin/python", "setup.py", "bdist_wheel", "--dist-dir", wheels], cwd=sources / f"{name}-{requirements[name]}", env=env)
        curl = output / "curl"
        curl.mkdir(exist_ok=True)
        archive = download(f"https://github.com/lexiforest/curl-impersonate/releases/download/v2.3.1/libcurl-impersonate-v2.3.1.{curl_arch}.tar.gz", output / "curl.tar.gz")
        with tarfile.open(archive) as bundle:
            bundle.extractall(curl, filter="data")
        curl_source = sources / f"curl_cffi-{requirements['curl_cffi']}"
        generation = os.environ.copy()
        generation.update(IMPERSONATE_BUILD_DIR=str(curl), IMPERSONATE_LINK_TYPE="dynamic")
        code = "import runpy,sys; runpy.run_path(sys.argv[1])['ffibuilder'].emit_c_code(sys.argv[2])"
        run([python, "-c", code, curl_source / "scripts/build.py", output / "wrapper.c"], env=generation)
        setup = output / "setup_curl.py"
        setup.write_text("# Created by Sébastien DAGUIN\nfrom setuptools import setup, Extension\n" +
            f"setup(name='curl_cffi',version={requirements['curl_cffi']!r},ext_modules=[Extension('curl_cffi._wrapper'," +
            repr([str(output / "wrapper.c"), str(curl_source / "ffi/shim.c")]) + ",include_dirs=" +
            repr([str(curl_source / "include"), str(curl_source / "ffi"), str(curl / "include")]) +
            f",library_dirs={[str(curl)]!r},libraries=['curl-impersonate'])])\n")
        run([cross / "bin/python", setup, "build_ext", "--build-lib", output / "native", "--build-temp", output / "objects"], cwd=output, env=env)
        app_packages = output / "app_packages"
        shutil.copytree(packages, app_packages, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("*.so", "*.dylib", "__pycache__", "*.pyc"))
        (app_packages / "searx/version_frozen.py").write_text("# Created by Sébastien DAGUIN\n" + "\n".join(f"{key} = {value!r}" for key, value in version_info.items()) + "\n")
        # iOS has no Unix user database; this dependency uses pwd only for a Valkey error log.
        valkey = app_packages / "searx/valkeydb.py"
        diagnostic = '        _pw = pwd.getpwuid(os.getuid())\n        logger.exception("[%s (%s)] can\'t connect valkey DB ...", _pw.pw_name, _pw.pw_uid)'
        text = valkey.read_text()
        if diagnostic not in text:
            raise RuntimeError("Review the iOS Valkey diagnostic patch for this SearXNG revision")
        valkey.write_text(text.replace("import pwd\n", "").replace(diagnostic, '        logger.exception("can\'t connect valkey DB ...")'))
        run([python, "-m", "pip", "download", "--no-deps", "--only-binary=:all:", "--python-version", "3.13", "--abi", "cp313", "--platform", f"ios_13_0_arm64_{sdk}", "cffi==2.1.1", "MarkupSafe==3.0.4", "--dest", wheels])
        for wheel in wheels.glob("*.whl"):
            with zipfile.ZipFile(wheel) as bundle:
                bundle.extractall(app_packages)
        shutil.copytree(output / "native", app_packages, dirs_exist_ok=True)
        wrapper = next((app_packages / "curl_cffi").glob("_wrapper*.so"))
        run(["install_name_tool", "-change", "@rpath/libcurl-impersonate.4.dylib", "@rpath/CurlImpersonate.framework/CurlImpersonate", wrapper])
    print(f"iOS SearXNG prepared at {root}")


if __name__ == "__main__":
    main()

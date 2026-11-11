#!/bin/sh
# Created by Sébastien DAGUIN
set -eu
umask 077
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
source_root=${NOCTIS_SOURCE_ROOT:-"$project_root"}
[ "$#" -eq 1 ] || { echo 'Usage: scripts/package-cli.sh /empty/output/directory' >&2; exit 1; }
output=$1
case "$output" in /*) ;; *) echo 'Absolute output path required.' >&2; exit 1 ;; esac
[ ! -e "$output" ] && [ ! -L "$output" ] || { echo 'Output already exists.' >&2; exit 1; }
[ "$(uname -m)" = arm64 ] && [ "$(uname -s)" = Darwin ] || exit 1
xcrun --find metal >/dev/null
revision=$(git -C "$source_root" rev-parse HEAD)
printf '%s\n' "$revision" | /usr/bin/grep -Eq '^[0-9a-f]{40}$' || exit 1
stable_pattern='^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
tag=$(git -C "$source_root" tag --points-at HEAD | /usr/bin/grep -E "$stable_pattern" | head -n 1 || true)
channel=stable
if [ -z "$tag" ]; then
    tag=$(git -C "$source_root" tag --merged HEAD --sort=-version:refname | /usr/bin/grep -E "$stable_pattern" | head -n 1 || true)
    [ -n "$tag" ] || { echo 'No stable ancestor tag; cannot derive the build version.' >&2; exit 1; }
    channel=main
fi
version=${tag#v}
if [ "$channel" != stable ]; then version="${version%%+*}-dev"; fi
if [ -n "$(git -C "$source_root" status --porcelain --untracked-files=no)" ]; then
    version="${version%%+*}-dirty"
    channel=local
fi
metadata=$(mktemp "${TMPDIR:-/tmp}/noctis-version.XXXXXX")
trap 'rm -f "$metadata"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
printf '{"version":"%s","channel":"%s","commit":"%s"}\n' "$version" "$channel" "$revision" > "$metadata"
swift build --package-path "$source_root" -c release --product NoctisCLI \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __noctis -Xlinker "$metadata"
products=$(swift build --package-path "$source_root" -c release --show-bin-path)
mkdir -m 700 "$output"
cp -p "$products/NoctisCLI" "$output/NoctisCLI"
chmod 700 "$output/NoctisCLI"
for resource in "$products"/*.bundle "$products"/*.dylib "$products"/*.metallib; do
    [ -e "$resource" ] || continue
    /usr/bin/ditto "$resource" "$output/$(basename "$resource")"
done
cp "$metadata" "$output/version.json"
printf '%s\n' "$version" > "$output/version.txt"
(cd "$output" && find . -type f ! -name checksums.sha256 -exec shasum -a 256 {} \; > checksums.sha256)
(cd "$output" && shasum -a 256 -c checksums.sha256 >/dev/null)
"$output/NoctisCLI" --help >/dev/null
"$output/NoctisCLI" --version
"$output/NoctisCLI" doctor

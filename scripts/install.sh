#!/bin/sh
# Created by Sébastien DAGUIN
set -eu
umask 077

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
prefix=${NOCTIS_PREFIX:-"$HOME/.local"}
case "$prefix" in /*) ;; *) echo 'NOCTIS_PREFIX doit être absolu.' >&2; exit 1 ;; esac
data="$prefix/share/noctis"
bin="$prefix/bin/noctis"
source_root="$project_root"
rollback=false
if [ "${1:-}" = --source ] && [ "$#" -eq 2 ]; then
    source_root=$(CDPATH= cd -- "$2" && pwd -P)
elif [ "${1:-}" = --rollback ] && [ "$#" -eq 1 ]; then
    rollback=true
elif [ "$#" -ne 0 ]; then
    echo 'Utilisation : scripts/install.sh [--source /depot | --rollback]' >&2
    exit 1
fi
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || {
    echo 'macOS sur Apple Silicon est requis.' >&2; exit 1;
}
mkdir -p "$data/versions" "$prefix/bin"
[ ! -L "$data" ] && [ ! -L "$data/versions" ] || { echo 'Dossier d’installation invalide.' >&2; exit 1; }
if [ -e "$bin" ] || [ -L "$bin" ]; then
    [ -L "$bin" ] && [ "$(readlink "$bin")" = "$data/current/NoctisCLI" ] || {
        echo 'Un autre fichier noctis existe déjà ; il ne sera pas remplacé.' >&2; exit 1;
    }
fi
mkdir "$data/.install-lock" 2>/dev/null || { echo 'Une installation est déjà en cours.' >&2; exit 1; }
stage=
link="$data/.current-$$"
old=$(readlink "$data/current" 2>/dev/null || true)
committed=false
switched=false
cleanup() {
    status=$?
    if [ "$switched" = true ] && [ "$committed" = false ]; then
        if [ -n "$old" ]; then
            ln -s "$old" "$link.restore"
            mv -fh "$link.restore" "$data/current"
        else
            rm -f "$data/current" "$bin"
        fi
    fi
    [ -z "$stage" ] || rm -rf "$stage"
    rm -f "$link" "$data/.bin-$$" "$data/.previous-$$"
    rmdir "$data/.install-lock"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

if [ "$rollback" = true ]; then
    target=$(readlink "$data/previous" 2>/dev/null || true)
    case "$target" in
        versions/build-*/*) echo 'Chemin de restauration invalide.' >&2; exit 1 ;;
        versions/build-*) ;;
        *) echo 'Aucune version précédente.' >&2; exit 1 ;;
    esac
    [ -x "$data/$target/NoctisCLI" ] || { echo 'Version précédente absente.' >&2; exit 1; }
    (cd "$data/$target" && shasum -a 256 -c checksums.sha256 >/dev/null)
else
    command -v swift >/dev/null
    command -v xcrun >/dev/null
    [ -f "$source_root/Package.swift" ] || { echo 'Package.swift absent.' >&2; exit 1; }
    xcrun --find metal >/dev/null
    printf 'Compilation Release avec : %s\n' "$(command -v swift)"
    swift --version
    swift build --package-path "$source_root" -c release --product NoctisCLI
    products=$(swift build --package-path "$source_root" -c release --show-bin-path)
    [ -x "$products/NoctisCLI" ] || { echo 'Exécutable SwiftPM absent.' >&2; exit 1; }
    stage=$(mktemp -d "$data/versions/.stage.XXXXXX")
    cp -p "$products/NoctisCLI" "$stage/NoctisCLI"
    chmod 700 "$stage/NoctisCLI"
    # SwiftPM bundles include localization and MLX's compiled Metal library.
    for resource in "$products"/*.bundle "$products"/*.dylib "$products"/*.metallib; do
        [ -e "$resource" ] || continue
        /usr/bin/ditto "$resource" "$stage/$(basename "$resource")"
    done
    git -C "$source_root" describe --tags --always --dirty > "$stage/version.txt"
    (cd "$stage" && find . -type f ! -name checksums.sha256 -exec shasum -a 256 {} \; > checksums.sha256)
    (cd "$stage" && shasum -a 256 -c checksums.sha256 >/dev/null)
    # Exercise the copied resources before publishing the new version.
    "$stage/NoctisCLI" --help >/dev/null
    "$stage/NoctisCLI" --version
    "$stage/NoctisCLI" doctor
    target="versions/build-$(date +%Y%m%d%H%M%S)-${stage##*.}"
    mv "$stage" "$data/$target"
    stage=
fi

ln -s "$target" "$link"
mv -fh "$link" "$data/current"
switched=true
if [ ! -L "$bin" ]; then
    ln -s "$data/current/NoctisCLI" "$data/.bin-$$"
    mv -f "$data/.bin-$$" "$bin"
fi
# This also checks resource discovery through the public symlink, from an unrelated directory.
(cd / && "$bin" --help >/dev/null && "$bin" --version && "$bin" doctor)
if [ -n "$old" ] && [ "$old" != "$target" ]; then
    ln -s "$old" "$data/.previous-$$"
    mv -fh "$data/.previous-$$" "$data/previous"
fi
committed=true
printf '\nInstallé : %s\n' "$bin"
case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) printf 'Ajoute ce dossier au PATH dans ~/.zshrc :\n  export PATH="%s/bin:$PATH"\n' "$prefix" ;;
esac

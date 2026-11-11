#!/bin/sh
# Created by Sébastien DAGUIN
set -eu
prefix=${NOCTIS_PREFIX:-"$HOME/.local"}
case "$prefix" in /*) ;; *) echo 'NOCTIS_PREFIX doit être absolu.' >&2; exit 1 ;; esac
data="$prefix/share/noctis"
bin="$prefix/bin/noctis"
[ ! -L "$data" ] || { echo 'Dossier d’installation invalide.' >&2; exit 1; }
if [ -e "$bin" ] || [ -L "$bin" ]; then
    [ -L "$bin" ] && [ "$(readlink "$bin")" = "$data/current/NoctisCLI" ] || {
        echo 'Ce fichier noctis ne provient pas de cet installateur.' >&2; exit 1;
    }
fi
[ -d "$data" ] || { echo 'Noctis est déjà désinstallé.'; exit 0; }
mkdir "$data/.install-lock" 2>/dev/null || { echo 'Une installation est déjà en cours.' >&2; exit 1; }
trap 'rmdir "$data/.install-lock" 2>/dev/null || true' EXIT
rm -f "$bin" "$data/current" "$data/previous"
# Remove only version folders created by the installer; leave caches, models and user documents alone.
for version in "$data"/versions/build-*; do
    [ -d "$version" ] && [ ! -L "$version" ] || continue
    [ -f "$version/checksums.sha256" ] || continue
    rm -rf "$version"
done
rmdir "$data/versions" 2>/dev/null || true
rmdir "$data/.install-lock"
rmdir "$data" 2>/dev/null || true
trap - EXIT
echo 'Noctis désinstallé. Les modèles et les données personnelles sont conservés.'

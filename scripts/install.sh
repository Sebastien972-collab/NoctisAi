#!/bin/sh
# Created by Sébastien DAGUIN
set -eu
umask 077

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$project_root/scripts/terminal-ui.sh"
prefix=${NOCTIS_PREFIX:-"$HOME/.local"}
case "$prefix" in /*) ;; *) echo 'NOCTIS_PREFIX doit être absolu.' >&2; exit 1 ;; esac
[ "$prefix" != / ] || { echo 'Préfixe racine refusé.' >&2; exit 1; }
# Reject every symlink ancestor before creating or writing any installation directory.
ancestor=$prefix
while [ "$ancestor" != / ]; do
    [ ! -L "$ancestor" ] || { echo 'Préfixe avec lien symbolique refusé.' >&2; exit 1; }
    ancestor=$(dirname "$ancestor")
done
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
for directory in "$prefix" "$prefix/bin" "$prefix/share" "$data" "$data/versions"; do
    [ ! -L "$directory" ] || { echo 'Lien symbolique dans l’installation.' >&2; exit 1; }
    [ -e "$directory" ] || continue
    [ -d "$directory" ] && [ "$(stat -f %u "$directory")" = "$(id -u)" ] || {
        echo 'Dossier d’installation invalide.' >&2; exit 1;
    }
    permissions=$(stat -f %Lp "$directory")
    [ "$((0$permissions & 0022))" -eq 0 ] || { echo 'Dossier accessible en écriture à un tiers.' >&2; exit 1; }
done
mkdir -p "$data/versions" "$prefix/bin"
if [ -e "$bin" ] || [ -L "$bin" ]; then
    [ -L "$bin" ] && [ "$(readlink "$bin")" = "$data/current/NoctisCLI" ] || {
        echo 'Un autre fichier noctis existe déjà ; il ne sera pas remplacé.' >&2; exit 1;
    }
fi
stage=
link="$data/.current-$$"
old=$(readlink "$data/current" 2>/dev/null || true)
case "$old" in
    versions/build-*/*) echo 'Chemin courant invalide.' >&2; exit 1 ;;
    versions/build-*|'') ;;
    *) echo 'Chemin courant invalide.' >&2; exit 1 ;;
esac
mkdir "$data/.install-lock" 2>/dev/null || { echo 'Une installation est déjà en cours.' >&2; exit 1; }
committed=false
switched=false
cleanup() {
    status=$?
    noctis_ui_stop
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
    stage=$(mktemp -d "$data/versions/.stage.XXXXXX")
    rmdir "$stage"
    noctis_ui_run "Compilation et packaging" env NOCTIS_SOURCE_ROOT="$source_root" "$project_root/scripts/package-cli.sh" "$stage"
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

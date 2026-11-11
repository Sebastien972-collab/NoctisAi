#!/bin/sh
# Created by Sébastien DAGUIN
set -eu
umask 077
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ "$#" -eq 1 ] && [ "$1" = --rollback ]; then
    exec "$project_root/scripts/install.sh" --rollback
fi
if [ "$#" -ne 4 ] || [ "$1" != --tag ] || [ "$3" != --revision ]; then
    echo 'Utilisation : scripts/update.sh --tag vX.Y.Z --revision COMMIT_COMPLET_40_CARACTERES' >&2
    echo 'Restauration : scripts/update.sh --rollback' >&2
    exit 1
fi
tag=$2
revision=$4
printf '%s\n' "$tag" | /usr/bin/grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+$' || { echo 'Tag SemVer requis.' >&2; exit 1; }
printf '%s\n' "$revision" | /usr/bin/grep -Eq '^[0-9a-f]{40}$' || { echo 'Commit complet requis.' >&2; exit 1; }
checkout=$(mktemp -d "${TMPDIR:-/tmp}/noctis-update.XXXXXX")
trap 'rm -rf "$checkout"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
# Use an empty configuration so aliases, URL rewrites and hooks cannot replace the official source.
GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git init -q "$checkout"
GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$checkout" \
    -c core.hooksPath=/dev/null fetch --depth 1 \
    https://github.com/Sebastien972-collab/NoctisAi.git "refs/tags/$tag:refs/tags/$tag"
# Cryptographic verification uses the local GPG keyring. Missing or invalid signatures fail closed.
if ! GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$checkout" \
    verify-tag --raw "$tag" 2> "$checkout/signature.status"; then
    cat "$checkout/signature.status" >&2
    exit 1
fi
cat "$checkout/signature.status" >&2
/usr/bin/grep -Eq '^\[GNUPG:\] TRUST_(FULLY|ULTIMATE)' "$checkout/signature.status" || {
    echo 'La clé du signataire doit être approuvée dans le trousseau GPG local.' >&2; exit 1;
}
actual=$(git -C "$checkout" rev-parse "$tag^{commit}")
[ "$actual" = "$revision" ] || { echo 'Le tag ne correspond pas au commit attendu.' >&2; exit 1; }
git -C "$checkout" -c core.hooksPath=/dev/null checkout -q --detach "$revision"
# Execute our trusted installer, never a downloaded update script.
"$project_root/scripts/install.sh" --source "$checkout"

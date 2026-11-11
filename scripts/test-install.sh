#!/bin/sh
# Created by Sébastien DAGUIN
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
fixture=$(mktemp -d /private/tmp/noctis-install-test.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
export NOCTIS_PREFIX="$fixture/prefix with spaces"
"$project_root/scripts/install.sh"
bin="$NOCTIS_PREFIX/bin/noctis"
data="$NOCTIS_PREFIX/share/noctis"
(cd "$fixture" && "$bin" --help && "$bin" --version && "$bin" doctor && "$bin" update)
# No question means no model load or download, even outside the source repository.
printf '/workspace\n/permissions\n/model\n/exit\n' | (cd "$fixture" && "$bin") > "$fixture/chat.txt"
/usr/bin/grep -F "$fixture" "$fixture/chat.txt" >/dev/null
"$project_root/scripts/install.sh"
current=$(readlink "$data/current")
previous=$(readlink "$data/previous")
[ "$current" != "$previous" ]
"$project_root/scripts/update.sh" --rollback
[ "$(readlink "$data/current")" = "$previous" ]
"$project_root/scripts/update.sh" --rollback
[ "$(readlink "$data/current")" = "$current" ]
# A failed compiler must not replace the working installation.
mkdir "$fixture/fail-bin"
printf '#!/bin/sh\nexit 42\n' > "$fixture/fail-bin/swift"
chmod +x "$fixture/fail-bin/swift"
if PATH="$fixture/fail-bin:$PATH" "$project_root/scripts/install.sh"; then
    echo 'Une compilation en échec a été acceptée.' >&2; exit 1
fi
[ "$(readlink "$data/current")" = "$current" ]
# Corrupted rollback candidates are rejected before switching the active version.
printf 'tampered\n' >> "$data/$previous/version.txt"
if "$project_root/scripts/update.sh" --rollback; then
    echo 'Une version altérée a été acceptée.' >&2; exit 1
fi
[ "$(readlink "$data/current")" = "$current" ]
"$project_root/scripts/uninstall.sh"
[ ! -e "$bin" ] && [ ! -L "$bin" ]
"$project_root/scripts/uninstall.sh"
# Refuse to overwrite someone else's executable.
printf 'unrelated\n' > "$NOCTIS_PREFIX/bin/noctis"
if "$project_root/scripts/install.sh"; then
    echo 'Un fichier existant a été écrasé.' >&2; exit 1
fi
[ "$(cat "$NOCTIS_PREFIX/bin/noctis")" = unrelated ]
if "$project_root/scripts/update.sh" --tag main --revision invalid; then exit 1; fi
echo 'Installation, rollback, échecs et désinstallation : OK'

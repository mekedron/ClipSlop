#!/bin/bash
# Install repo-tracked git hooks into .git/hooks/.
# Run once per clone: ./Scripts/install-hooks.sh

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_SRC="$REPO_ROOT/Scripts/hooks"
HOOKS_DST="$REPO_ROOT/.git/hooks"

if [ ! -d "$REPO_ROOT/.git" ]; then
    echo "Error: $REPO_ROOT is not a git repository"
    exit 1
fi

if [ ! -d "$HOOKS_SRC" ]; then
    echo "Error: $HOOKS_SRC does not exist"
    exit 1
fi

mkdir -p "$HOOKS_DST"

installed=0
for hook in "$HOOKS_SRC"/*; do
    [ -f "$hook" ] || continue
    name=$(basename "$hook")
    dst="$HOOKS_DST/$name"
    cp "$hook" "$dst"
    chmod +x "$dst"
    echo "Installed: $name"
    installed=$((installed + 1))
done

if [ "$installed" -eq 0 ]; then
    echo "No hooks found in $HOOKS_SRC"
    exit 1
fi

echo ""
echo "Done. $installed hook(s) active. Re-run this script whenever Scripts/hooks/ changes."

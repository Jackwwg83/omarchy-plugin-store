#!/bin/bash

# Copy the working tree into ~/.config/omarchy/plugins/io.github.jackwwg83.plugin-store/ and
# make the running shell pick it up. This is the development loop: the shell
# only loads plugins from that directory, and it hot-reloads whatever lands
# there. `omarchy plugin add <repo> --enable` is what users run instead.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ID="io.github.jackwwg83.plugin-store"
DEST="${OMARCHY_PLUGINS_DIR:-$HOME/.config/omarchy/plugins}/$ID"

command -v rsync >/dev/null 2>&1 || {
  echo "dev-install: rsync is required" >&2
  exit 1
}

omarchy-plugin-validate "$ROOT" >/dev/null || {
  echo "dev-install: $ROOT does not validate as a plugin" >&2
  exit 1
}

mkdir -p "$DEST"
rsync -a --delete \
  --exclude '.git' \
  --exclude '.gitignore' \
  --exclude 'test' \
  --exclude 'scripts' \
  --exclude '*.md' \
  "$ROOT/" "$DEST/"

echo "dev-install: installed $ID to $DEST"

# The shell only knows about a plugin folder after a rescan; enabling is
# recorded in shell.json, which only omarchy-plugin-enable may write.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

if omarchy-plugin-list --json 2>/dev/null | jq -e --arg id "$ID" 'any(.[]; .id == $id and .enabled)' >/dev/null 2>&1; then
  echo "dev-install: $ID is enabled"
else
  echo "dev-install: enabling $ID"
  omarchy-plugin-enable "$ID"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

echo "dev-install: summon it with: omarchy-shell shell toggle $ID"

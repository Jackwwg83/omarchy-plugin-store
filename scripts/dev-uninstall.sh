#!/bin/bash

# Remove the dev-installed copy of the plugin and let the shell forget it.

set -euo pipefail

ID="jackom.plugin-store"
DEST="${OMARCHY_PLUGINS_DIR:-$HOME/.config/omarchy/plugins}/$ID"

omarchy-shell shell hide "$ID" >/dev/null 2>&1 || true

# Take it out of shell.json first: removing the folder while it is still
# listed leaves the shell warning about a missing plugin on every rescan.
omarchy-plugin-disable "$ID" >/dev/null 2>&1 || true

if [[ -d $DEST ]]; then
  rm -rf "$DEST"
  echo "dev-uninstall: removed $DEST"
else
  echo "dev-uninstall: $DEST was not installed"
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

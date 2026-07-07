#!/bin/bash
#
# uninstall.sh -- remove the Isaac macOS launch fix.
#
# Deletes ~/Library/Application Support/IsaacDyldShim/. Remember to also clear
# the game's Launch Options in Steam (Properties -> General -> Launch Options).
#
set -euo pipefail
DEST="${HOME}/Library/Application Support/IsaacDyldShim"

if [ -d "$DEST" ]; then
    rm -rf "$DEST"
    echo "Removed $DEST"
else
    echo "Nothing to remove ($DEST not present)."
fi
echo
echo "IMPORTANT: also clear the game's Launch Options in Steam:"
echo "  right-click the game -> Properties -> General -> Launch Options -> empty it."

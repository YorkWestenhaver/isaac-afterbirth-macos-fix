#!/bin/bash
#
# install.sh -- build and install the Isaac macOS launch fix.
#
# Compiles the SIGSEGV shim, installs it and the launch wrapper into
# ~/Library/Application Support/IsaacDyldShim/, and prints the exact Steam
# Launch Options line to paste. Does NOT modify any game or Steam file.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT="${HOME}/Library/Application Support"
DEST="${SUPPORT}/IsaacDyldShim"
STEAMLOADER="${SUPPORT}/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamloader.dylib"

echo "==> The Binding of Isaac -- macOS launch fix installer"
echo

# --- sanity checks --------------------------------------------------------
if [ "$(uname)" != "Darwin" ]; then
    echo "This fix is macOS-only." >&2; exit 1
fi
if ! command -v clang >/dev/null 2>&1; then
    echo "ERROR: 'clang' not found. Install Apple's Command Line Tools first:" >&2
    echo "       xcode-select --install" >&2
    exit 1
fi
if [ ! -f "$STEAMLOADER" ]; then
    echo "WARNING: steamloader.dylib not found at:" >&2
    echo "         $STEAMLOADER" >&2
    echo "         The fix needs it. If your Steam is installed elsewhere, edit the" >&2
    echo "         STEAMLOADER path in isaac_launch_wrapper.sh after install." >&2
    echo
fi

# --- build ----------------------------------------------------------------
mkdir -p "$DEST"
echo "==> Compiling shim (x86_64, for Rosetta)..."
clang -arch x86_64 -dynamiclib -O2 \
    "${SCRIPT_DIR}/src/isaac_dyld_shim.c" \
    -o "${DEST}/isaac_dyld_shim.dylib"
echo "    -> ${DEST}/isaac_dyld_shim.dylib"

# --- install wrapper ------------------------------------------------------
cp "${SCRIPT_DIR}/src/isaac_launch_wrapper.sh" "${DEST}/isaac_launch_wrapper.sh"
chmod +x "${DEST}/isaac_launch_wrapper.sh"
echo "    -> ${DEST}/isaac_launch_wrapper.sh"
# keep the source around for reference/troubleshooting
cp "${SCRIPT_DIR}/src/isaac_dyld_shim.c" "${DEST}/isaac_dyld_shim.c"

echo
echo "==> Installed. Now set the game's Launch Options in Steam:"
echo
echo "    1. In Steam, right-click 'The Binding of Isaac: Rebirth' -> Properties"
echo "    2. Under the General tab, find 'Launch Options'"
echo "    3. Delete anything there and paste EXACTLY this line:"
echo
echo "-----------------------------------------------------------------------"
echo "\"${DEST}/isaac_launch_wrapper.sh\" %command%"
echo "-----------------------------------------------------------------------"
echo
echo "    4. Close Properties and launch the game normally."
echo
echo "Done. If it still fails to launch, set ISAAC_SHIM_DEBUG=1 near the top of"
echo "${DEST}/isaac_launch_wrapper.sh and check the logs it writes in that folder."

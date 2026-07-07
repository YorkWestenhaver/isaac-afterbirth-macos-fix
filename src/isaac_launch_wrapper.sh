#!/bin/bash
#
# isaac_launch_wrapper.sh
#
# Steam Launch Options wrapper for The Binding of Isaac (Rebirth/Afterbirth/
# Afterbirth+) on macOS. Set this as the game's Launch Options:
#
#     "$HOME/Library/Application Support/IsaacDyldShim/isaac_launch_wrapper.sh" %command%
#
# (Steam Launch Options on macOS do NOT expand ~ or $HOME, so paste the fully
#  resolved absolute path -- the installer prints the exact line for you.)
#
# ---------------------------------------------------------------------------
# Why a wrapper, and why it injects TWO dylibs:
#
# 1. macOS Steam does not support the Linux "VAR=value %command%" env syntax --
#    it would try to exec a file literally named "VAR=value" and fail with
#    "Failed to spawn process / OS Error 260". So we use a real executable that
#    sets the environment itself.
#
# 2. Normally Steam injects its DRM loader (steamloader.dylib) into the game via
#    DYLD_INSERT_LIBRARIES. But this wrapper is a bash script, and /bin/bash is
#    a SIP-protected Apple binary -- macOS strips ALL DYLD_* variables when
#    exec'ing it. So Steam's steamloader injection is lost before this script
#    even runs. Without steamloader the DRM image is never decrypted and the
#    game silently quits at its Steam-DRM startup check. We therefore re-inject
#    steamloader ourselves, alongside the fix shim. The game binary is unsigned,
#    so DYLD_INSERT_LIBRARIES IS honored when this script exec's it.
#
# Order matters: the shim is listed FIRST so its constructor (which installs the
# SIGSEGV/SIGBUS handler) runs before steamloader's CrackMainImage constructor --
# the code that triggers the stale legacy-dyld fault the shim catches.
# ---------------------------------------------------------------------------

SUPPORT="${HOME}/Library/Application Support"
SHIM="${SUPPORT}/IsaacDyldShim/isaac_dyld_shim.dylib"
STEAMLOADER="${SUPPORT}/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamloader.dylib"

# Optional debug logging. Set ISAAC_SHIM_DEBUG=1 in this file to capture the
# game's stdout/stderr (including the shim's diagnostics) for troubleshooting.
ISAAC_SHIM_DEBUG=0
DBGDIR="${SUPPORT}/IsaacDyldShim"
WRAP_LOG="${DBGDIR}/wrapper_debug.log"
GAME_LOG="${DBGDIR}/game_output.log"

if [ ! -f "$SHIM" ]; then
    echo "isaac_launch_wrapper: shim not found at $SHIM -- did you run install.sh?" >&2
fi
if [ ! -f "$STEAMLOADER" ]; then
    echo "isaac_launch_wrapper: steamloader.dylib not found at $STEAMLOADER" >&2
    echo "  (Steam not installed in the default location? Edit STEAMLOADER in this script.)" >&2
fi

# Inject shim (first) + steamloader (second), preserving anything that somehow
# survived the bash DYLD strip (normally nothing does).
NEW_DYLD="${SHIM}:${STEAMLOADER}"
if [ -n "$DYLD_INSERT_LIBRARIES" ]; then
    NEW_DYLD="${NEW_DYLD}:${DYLD_INSERT_LIBRARIES}"
fi
export DYLD_INSERT_LIBRARIES="$NEW_DYLD"

# Steam may hand us the .app bundle path rather than the inner executable.
# posix-exec of a .app directory fails, so resolve to CFBundleExecutable.
target="$1"
if [ -z "$target" ]; then
    echo "isaac_launch_wrapper: no command to run (is %command% in your Launch Options?)" >&2
    exit 1
fi
shift
if [ -d "$target" ] && [[ "$target" == *.app ]]; then
    exe_name="$(/usr/bin/defaults read "$target/Contents/Info" CFBundleExecutable 2>/dev/null)"
    if [ -n "$exe_name" ] && [ -x "$target/Contents/MacOS/$exe_name" ]; then
        target="$target/Contents/MacOS/$exe_name"
    fi
fi

if [ "$ISAAC_SHIM_DEBUG" = "1" ]; then
    mkdir -p "$DBGDIR"
    {
        echo "===== wrapper invoked $(date) ====="
        echo "DYLD_INSERT_LIBRARIES=[$DYLD_INSERT_LIBRARIES]"
        echo "exec target=[$target]"
        echo "args: $*"
    } >> "$WRAP_LOG" 2>&1
    exec "$target" "$@" > "$GAME_LOG" 2>&1
fi

exec "$target" "$@"

#!/bin/bash
#
# install.command -- one-click installer for the Isaac macOS launch fix.
#
# Double-click this file (or run it in Terminal). It checks for what's needed,
# offers to install anything missing, builds the fix, and sets the game's Steam
# Launch Options for you automatically. No paths to paste, no Steam settings to
# edit by hand.
#
# It never modifies any game file or Valve binary. Everything it installs lives
# in one folder (~/Library/Application Support/IsaacDyldShim) and the Steam
# config change is backed up first and reversible with uninstall.command.

# Keep the Terminal window open on any exit so the user can read the result.
trap 'echo; read -r -p "Press Return to close this window. "' EXIT

set -uo pipefail

REPO_RAW="https://raw.githubusercontent.com/YorkWestenhaver/isaac-afterbirth-macos-fix/main"
APPID="250900"
SUPPORT="${HOME}/Library/Application Support"
DEST="${SUPPORT}/IsaacDyldShim"
STEAM="${SUPPORT}/Steam"
STEAMLOADER="${STEAM}/Steam.AppBundle/Steam/Contents/MacOS/steamloader.dylib"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '   \033[31m✗\033[0m %s\n' "$*"; }
ask()  { local a; read -r -p "   $1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

echo "======================================================================"
echo "   The Binding of Isaac — macOS launch fix — installer"
echo "======================================================================"
info "This will get Isaac launching again on your Mac. It's safe: it doesn't"
info "touch any game files, and everything it does can be undone."

# --- 0. locate source files (work from the unzipped repo, else download) ----
SRCDIR=""
selfdir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -n "$selfdir" ] && [ -f "$selfdir/src/isaac_dyld_shim.c" ]; then
    SRCDIR="$selfdir/src"
else
    say "Downloading the fix files…"
    SRCDIR="$(mktemp -d)/src"
    mkdir -p "$SRCDIR"
    for f in isaac_dyld_shim.c isaac_launch_wrapper.sh set_launch_options.py; do
        if curl -fsSL "$REPO_RAW/src/$f" -o "$SRCDIR/$f"; then
            ok "got $f"
        else
            err "couldn't download $f — check your internet connection."
            exit 1
        fi
    done
fi

# --- 1. macOS + architecture -----------------------------------------------
if [ "$(uname)" != "Darwin" ]; then err "This is for macOS only."; exit 1; fi
ARCH="$(uname -m)"

# --- 2. Command Line Tools (for the compiler) ------------------------------
say "Checking for Apple Command Line Tools (needed to build the fix)…"
if command -v clang >/dev/null 2>&1 && xcode-select -p >/dev/null 2>&1; then
    ok "Command Line Tools are installed."
else
    warn "Not installed. A macOS dialog will pop up to install them."
    info "Click \"Install\" in that dialog, wait for it to finish, then run"
    info "this installer again."
    xcode-select --install >/dev/null 2>&1 || true
    exit 1
fi

# --- 3. Rosetta 2 (Apple Silicon only) -------------------------------------
if [ "$ARCH" = "arm64" ]; then
    say "Checking for Rosetta 2 (lets this Intel-built game run on Apple Silicon)…"
    if /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
        ok "Rosetta 2 is installed."
    else
        warn "Rosetta 2 isn't installed. The game can't run without it."
        if ask "Install Rosetta 2 now? (may ask for your password)"; then
            softwareupdate --install-rosetta --agree-to-license || \
                sudo softwareupdate --install-rosetta --agree-to-license || \
                { err "Rosetta install failed. Run 'softwareupdate --install-rosetta' manually."; exit 1; }
            ok "Rosetta 2 installed."
        else
            err "Can't continue without Rosetta 2."; exit 1
        fi
    fi
fi

# --- 4. Steam + the DRM loader ---------------------------------------------
say "Checking for Steam…"
if [ ! -d "$STEAM" ]; then
    err "Steam not found at $STEAM"
    info "Install Steam and The Binding of Isaac first, then run this again."
    exit 1
fi
ok "Steam found."
if [ ! -f "$STEAMLOADER" ]; then
    warn "Couldn't find steamloader.dylib at the usual place."
    info "The fix needs it; if your Steam is in a custom location the wrapper"
    info "may need its STEAMLOADER path edited. Continuing anyway."
else
    ok "Steam DRM loader found."
fi

# --- 5. build + install -----------------------------------------------------
say "Building and installing the fix…"
mkdir -p "$DEST"
if clang -arch x86_64 -dynamiclib -O2 "$SRCDIR/isaac_dyld_shim.c" -o "$DEST/isaac_dyld_shim.dylib"; then
    ok "Compiled the fix."
else
    err "Compilation failed."; exit 1
fi
cp "$SRCDIR/isaac_launch_wrapper.sh" "$DEST/isaac_launch_wrapper.sh"
chmod +x "$DEST/isaac_launch_wrapper.sh"
cp "$SRCDIR/isaac_dyld_shim.c" "$DEST/isaac_dyld_shim.c" 2>/dev/null || true
ok "Installed to $DEST"

WRAPPER="$DEST/isaac_launch_wrapper.sh"
LAUNCH_OPTS="\"$WRAPPER\" %command%"

# --- 6. set Steam Launch Options automatically ------------------------------
say "Setting the game's Steam Launch Options for you…"
set_it() {
    python3 "$SRCDIR/set_launch_options.py" --appid "$APPID" --value "$LAUNCH_OPTS"
}
steam_running() { pgrep -f "Steam.AppBundle/Steam/Contents/MacOS/steam_osx" >/dev/null 2>&1; }

manual_fallback() {
    warn "I couldn't set it automatically, but it's easy to do by hand:"
    info "1. In Steam, right-click The Binding of Isaac: Rebirth → Properties"
    info "2. General tab → Launch Options"
    info "3. Paste exactly this line:"
    printf '\n       %s\n\n' "$LAUNCH_OPTS"
}

if ! command -v python3 >/dev/null 2>&1; then
    manual_fallback
else
    REOPEN=0
    if steam_running; then
        warn "Steam is open. It has to be closed for a moment to save this setting."
        if ask "Close Steam now, apply the setting, and reopen it?"; then
            open "steam://exit" >/dev/null 2>&1 || osascript -e 'quit app "Steam"' >/dev/null 2>&1 || true
            info "Waiting for Steam to close…"
            for _ in $(seq 1 30); do steam_running || break; sleep 1; done
            REOPEN=1
        fi
    fi
    if steam_running; then
        warn "Steam is still running; skipping the automatic step."
        manual_fallback
    elif set_it; then
        ok "Launch Options set automatically."
        [ "$REOPEN" = "1" ] && { info "Reopening Steam…"; open -a Steam >/dev/null 2>&1 || true; }
    else
        manual_fallback
    fi
fi

say "All done! 🎉"
info "Open Steam and press Play — The Binding of Isaac should launch normally."
info "To undo everything later, run uninstall.command."

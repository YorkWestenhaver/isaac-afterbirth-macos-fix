#!/bin/bash
#
# uninstall.command -- one-click removal of the Isaac macOS launch fix.
#
# Double-click this file. It clears the game's Steam Launch Options and deletes
# the fix folder. Nothing else on your system is touched.

trap 'echo; printf "Press Return to close this window. "; read -r _ < /dev/tty 2>/dev/null || true' EXIT
set -uo pipefail

REPO_RAW="https://raw.githubusercontent.com/YorkWestenhaver/isaac-afterbirth-macos-fix/main"
APPID="250900"
SUPPORT="${HOME}/Library/Application Support"
DEST="${SUPPORT}/IsaacDyldShim"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*"; }
# Prompt visibly and default to YES (bare Return proceeds; only n/N declines).
ask()  { local a=""; printf '   %s [Y/n] ' "$1"; read -r a < /dev/tty 2>/dev/null; [[ ! "$a" =~ ^[Nn] ]]; }
steam_running() { pgrep -f "Steam.AppBundle/Steam/Contents/MacOS/steam_osx" >/dev/null 2>&1; }

echo "======================================================================"
echo "   The Binding of Isaac — macOS launch fix — uninstaller"
echo "======================================================================"

# locate the launch-options helper (installed copy, repo copy, or download)
PY=""
for c in "$DEST/set_launch_options.py" \
         "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/src/set_launch_options.py"; do
    [ -f "$c" ] && { PY="$c"; break; }
done
if [ -z "$PY" ] && command -v python3 >/dev/null 2>&1; then
    PY="$(mktemp)"; curl -fsSL "$REPO_RAW/src/set_launch_options.py" -o "$PY" 2>/dev/null || PY=""
fi

say "Clearing the game's Steam Launch Options…"
if [ -n "$PY" ] && command -v python3 >/dev/null 2>&1; then
    REOPEN=0
    if steam_running; then
        warn "Steam is open and must close briefly to save this change."
        if ask "Close Steam, clear the setting, and reopen it?"; then
            open "steam://exit" >/dev/null 2>&1 || osascript -e 'quit app "Steam"' >/dev/null 2>&1 || true
            for _ in $(seq 1 30); do steam_running || break; sleep 1; done
            REOPEN=1
        fi
    fi
    if steam_running; then
        warn "Steam still running — clear the Launch Options yourself in the game's Properties."
    elif python3 "$PY" --appid "$APPID" --clear; then
        ok "Launch Options cleared."
        [ "$REOPEN" = "1" ] && { info "Reopening Steam…"; open -a Steam >/dev/null 2>&1 || true; }
    else
        warn "Couldn't clear automatically — do it in the game's Properties → Launch Options."
    fi
else
    warn "python3 not available — clear the Launch Options yourself in the game's Properties."
fi

say "Removing the fix folder…"
if [ -d "$DEST" ]; then
    rm -rf "$DEST"
    ok "Removed $DEST"
else
    info "Nothing to remove (folder not present)."
fi

say "Uninstalled."

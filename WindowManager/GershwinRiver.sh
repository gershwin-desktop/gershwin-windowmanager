#!/bin/sh
#
# GershwinRiver.sh — Gershwin desktop session startup using River compositor
#
# This is the Wayland equivalent of Gershwin.sh. Instead of starting an X11
# window manager and X11 applications directly, it launches the River Wayland
# compositor with the Gershwin WindowManager as the window management client.
#
# Usage:
#   From a TTY (no X11 running):
#     /System/Library/Scripts/GershwinRiver.sh
#
#   From within an existing X11 session (nested, for testing):
#     WLR_BACKENDS=x11 /System/Library/Scripts/GershwinRiver.sh
#
# Environment:
#   XDG_RUNTIME_DIR  — Required for Wayland socket (default: /run/user/$UID)
#   WLR_BACKENDS     — Set to "x11" to run nested inside X11 for testing
#   RIVER_BIN        — Override path to river binary

# ── GNUstep environment ──────────────────────────────────────────────────────

. /System/Library/Makefiles/GNUstep.sh

export PATH=$HOME/Library/Tools:/Local/Library/Tools:/System/Library/Tools/:$PATH

# Add our fonts path to fontconfig
export FONTCONFIG_PATH=/System/Library/Preferences
export FONTCONFIG_FILE=$FONTCONFIG_PATH/fonts.conf

# ── Wayland runtime directory ─────────────────────────────────────────────────

if [ -z "$XDG_RUNTIME_DIR" ]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
fi

if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || {
        echo "ERROR: Cannot create XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
        echo "Run: sudo mkdir -p $XDG_RUNTIME_DIR && sudo chown $(id -u):$(id -g) $XDG_RUNTIME_DIR"
        exit 1
    }
fi

# ── Restore sound settings ───────────────────────────────────────────────────

if [ -f "$HOME/.config/asound.state" ]; then
    alsactl restore -f "$HOME/.config/asound.state" 2>/dev/null || true
fi

# ── Locate River compositor ──────────────────────────────────────────────────

RIVER_BIN="${RIVER_BIN:-}"
if [ -z "$RIVER_BIN" ]; then
    if [ -x "$HOME/.local/bin/river" ]; then
        RIVER_BIN="$HOME/.local/bin/river"
    elif command -v river >/dev/null 2>&1; then
        RIVER_BIN="$(command -v river)"
    else
        echo "ERROR: River compositor not found."
        echo "Install it to ~/.local/bin/river or set RIVER_BIN."
        exit 1
    fi
fi

# ── Prepare River startup command ─────────────────────────────────────────────
#
# River uses river-window-management-v1 protocol. The WindowManager connects
# as a Wayland client and manages all window placement, decoration, and focus
# via this protocol. River is started with a startup command that launches the
# WindowManager and the rest of the desktop session.

STARTUP_SCRIPT=$(mktemp /tmp/gershwin-river-startup.XXXXXX.sh)
cat > "$STARTUP_SCRIPT" << 'STARTUP'
#!/bin/sh
# Gershwin River session startup — runs inside the River compositor

. /System/Library/Makefiles/GNUstep.sh
export PATH=$HOME/Library/Tools:/Local/Library/Tools:/System/Library/Tools/:$PATH

# ── WindowManager (Wayland mode) ─────────────────────────────────────────────

if command -v WindowManager >/dev/null 2>&1; then
    WindowManager -w &
    WM_PID=$!
elif [ -x "$HOME/gershwin-build/repos/gershwin-windowmanager/WindowManager/WindowManager.app/WindowManager" ]; then
    "$HOME/gershwin-build/repos/gershwin-windowmanager/WindowManager/WindowManager.app/WindowManager" -w &
    WM_PID=$!
else
    echo "WARNING: WindowManager not found. Running without window management."
fi

sleep 2

# ── XWayland / X11 apps environment ──────────────────────────────────────────
# When River is built with -Dxwayland (and wlroots with -Dxwayland=enabled),
# River starts an XWayland server and exports DISPLAY (e.g. :10) into this
# startup script's environment. X11 GNUstep apps (Menu, Workspace, etc.) and
# other X11 apps then connect to XWayland transparently.
#
# Wait briefly for XWayland to set DISPLAY (it starts asynchronously).
if [ -z "$DISPLAY" ]; then
    for _xw_wait in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        [ -n "$DISPLAY" ] && break
    done
fi

# Force GTK and Qt apps to use the X11/XWayland backend rather than pure Wayland,
# since most Gershwin apps are built against X11 GNUstep.
export GDK_BACKEND=x11
export QT_QPA_PLATFORM=xcb

# Propagate cursor theme to X11 apps.
if [ -n "$XCURSOR_THEME" ]; then
    xrdb -merge - 2>/dev/null <<EOF || true
Xcursor.theme: $XCURSOR_THEME
Xcursor.size: ${XCURSOR_SIZE:-24}
EOF
fi

# ── Automounter ───────────────────────────────────────────────────────────────

if command -v devmon >/dev/null 2>&1; then
    devmon &
fi

# ── D-Bus session ─────────────────────────────────────────────────────────────

if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    if command -v dbus-launch >/dev/null 2>&1; then
        export $(dbus-launch)
    fi
fi

# ── Menu ──────────────────────────────────────────────────────────────────────

if command -v Menu >/dev/null 2>&1; then
    # Make GTK applications use Menu (requires appmenu-gtk2-module / appmenu-gtk3-module)
    export GTK_MODULES=appmenu-gtk-module
    Menu &
fi

sleep 2

# ── SudoAskPass ──────────────────────────────────────────────────────────────

if [ -e /System/Library/Tools/SudoAskPass ]; then
    export SUDO_ASKPASS=/System/Library/Tools/SudoAskPass
fi

# ── Workspace ─────────────────────────────────────────────────────────────────
# Workspace is the final process; when it exits, the session ends.

if command -v Workspace >/dev/null 2>&1; then
    exec Workspace
else
    echo "WARNING: Workspace not found. Session will stay open until River exits."
    # Keep the session alive
    wait "$WM_PID" 2>/dev/null
fi
STARTUP

# ── Launch River ──────────────────────────────────────────────────────────────

echo "Starting Gershwin desktop session (River/Wayland)..."
echo "  Compositor: $RIVER_BIN"
echo "  Runtime:    $XDG_RUNTIME_DIR"

exec "$RIVER_BIN" -c "sh $STARTUP_SCRIPT"

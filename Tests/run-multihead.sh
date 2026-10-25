#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause
#
# CI entry point for the multi-monitor checks of the WindowManager
# (gershwin-components issue #135): the headless unit suites for window
# rescue, monitor geometry and per-output scale, then a live check on a
# private Xorg with the "dummy" video driver (16 RandR outputs; Xvfb has
# one): a window and the pointer on a monitor that is unplugged come back to
# the primary, and the monitor's return does not disturb the window.
# Prints a summary and exits non-zero when anything failed.
#
#   sh Tests/run-multihead.sh
#
# Environment:
#   MULTIHEAD_DISPLAY   display number to use, 200 or higher (default: the
#                       first free one from 200 up)
#   MULTIHEAD_REQUIRE   1 = a missing dummy driver or tool is a failure (CI
#                       sets it where the packages are installable);
#                       otherwise the live part is skipped with a message
#   MULTIHEAD_KEEP      directory for the logs (default: a fresh temp dir)
#   MULTIHEAD_WM        WindowManager executable (default: the installed one)
#   MULTIHEAD_USER      run the WindowManager as this user (via sudo); for a
#                       developer machine, where it must not run as the
#                       user who owns the live desktop
#
# It never uses an inherited DISPLAY and never touches a display below 200;
# the Xorg and WindowManager it starts are stopped on exit, nothing else is
# killed.  The WindowManager runs with a private HOME.

root=$(cd "$(dirname "$0")/.." && pwd)

# An inherited DISPLAY may be a user's desktop; every command below gets its
# own explicit one.
unset DISPLAY

[ -r "${GNUSTEP_MAKEFILES:-/System/Library/Makefiles}/GNUstep.sh" ] || {
  echo "FATAL: GNUstep.sh not found; install the Gershwin stack first" >&2
  exit 1
}
. "${GNUSTEP_MAKEFILES:-/System/Library/Makefiles}/GNUstep.sh"

# GNUstep.sh reads unset variables, so -u only starts here.
set -u

passes=0
fails=0
skips=0
started=""
wmpid=""
msgpids=""

say() { echo "== $*"; }
ok() { passes=$((passes + 1)); echo "PASS: $1"; }
bad() { fails=$((fails + 1)); echo "FAIL: $1"; }

work=$(mktemp -d "${TMPDIR:-/tmp}/multihead.XXXXXX") || exit 1
logs=${MULTIHEAD_KEEP:-$work/logs}
mkdir -p "$logs" "$work/home" "$work/xorg"
chmod a+rwx "$work" "$work/home" "$logs"

SUDO=sudo
[ "$(id -u)" = 0 ] && SUDO=
wmuser=${MULTIHEAD_USER:-}

cleanup() {
  [ -n "$msgpids" ] && kill $msgpids 2>/dev/null
  stop_wm
  stop_server
  # Only the private temp dir made above.
  # The WindowManager starts a GNUstep notification daemon that outlives it;
  # MULTIHEAD_USER must be a user dedicated to this.
  if [ -n "$wmuser" ]; then
    # Its leftovers (gdnc, dbus) are owned by that user, so are its files.
    sudo pkill -u "$wmuser"
    sleep 1
    sudo rm -rf "$work"
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------- unit tests

unit_tests() {
  say "unit tests (headless)"
  # gnustep-tests builds each suite and runs it; it exits 1 on a failed
  # test, file or build.
  if ( cd "$root" && gnustep-tests --sequential test-displayrescue test-outputscale ) \
       > "$logs/unit.log" 2>&1; then
    ok "test-displayrescue and test-outputscale ($(grep -c '^Passed test:' "$root/tests.log" 2>/dev/null) tests)"
  else
    bad "unit suites (log $logs/unit.log)"
    tail -n 30 "$logs/unit.log"
  fi
  cp "$root/tests.log" "$logs/unit-tests.log" 2>/dev/null
}

# ------------------------------------------------------------- dummy Xorg

driver_installed() {
  for d in /usr/lib/xorg/modules/drivers /usr/lib64/xorg/modules/drivers \
           /usr/lib/x86_64-linux-gnu/xorg/modules/drivers \
           /usr/local/lib/xorg/modules/drivers /usr/X11R6/lib/modules/drivers; do
    [ -e "$d/dummy_drv.so" ] && return 0
  done
  return 1
}

display_in_use() {
  [ -e "/tmp/.X11-unix/X$1" ] || [ -e "/tmp/.X$1-lock" ] && return 0
  # Linux abstract sockets leave no file.
  grep -q "@/tmp/.X11-unix/X$1\$" /proc/net/unix 2>/dev/null
}

pick_display() {
  if [ -n "${MULTIHEAD_DISPLAY:-}" ]; then
    n=$MULTIHEAD_DISPLAY
    case $n in ''|*[!0-9]*) echo "FATAL: MULTIHEAD_DISPLAY must be a number" >&2; exit 2;; esac
    [ "$n" -ge 200 ] || { echo "FATAL: refusing display :$n, use 200 or higher" >&2; exit 2; }
    display_in_use "$n" && { echo "FATAL: display :$n is in use" >&2; exit 2; }
    echo "$n"; return
  fi
  n=200
  while [ $n -lt 400 ]; do
    display_in_use "$n" || { echo "$n"; return; }
    n=$((n + 1))
  done
  echo "FATAL: no free display from 200 to 399" >&2
  exit 2
}

start_server() {
  # Debian's /usr/bin/Xorg is a wrapper that wants a console; the server
  # binary itself runs without one.
  xorg=/usr/lib/xorg/Xorg
  [ -x "$xorg" ] || xorg=$(command -v Xorg)
  conf=$work/xorg/xorg-dummy-$num.conf
  cat > "$conf" <<'EOF'
Section "ServerFlags"
    Option "AutoAddDevices" "false"
    Option "AutoAddGPU" "false"
    Option "DontVTSwitch" "true"
EndSection
Section "Device"
    Identifier "dummy"
    Driver "dummy"
    VideoRam 256000
EndSection
Section "Monitor"
    Identifier "mon"
    HorizSync 5.0-1000.0
    VertRefresh 5.0-200.0
EndSection
Section "Screen"
    Identifier "screen"
    Device "dummy"
    Monitor "mon"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Virtual 8192 4096
    EndSubSection
EndSection
EOF
  chmod a+r "$conf"
  # Root, like the uitest session's Xvfb.
  $SUDO "$xorg" ":$num" -noreset -nolisten tcp -ac -config "$conf" \
    -logfile "$logs/xorg-dummy-$num.log" >/dev/null 2>&1 &
  i=0
  while [ $i -lt 50 ] && ! DISPLAY=:$num xrandr >/dev/null 2>&1; do sleep 0.2; i=$((i + 1)); done
  DISPLAY=:$num xrandr | grep -q '^DUMMY0 connected' || {
    bad "dummy Xorg did not start on :$num"
    tail -n 30 "$logs/xorg-dummy-$num.log" 2>/dev/null
    return 1
  }
  started=$num
}

stop_server() {
  [ -n "$started" ] || return 0
  # Only the server we started: its lock file names a process of Xorg :N.
  pid=$(tr -d ' ' < "/tmp/.X$started-lock" 2>/dev/null)
  if [ -n "$pid" ] && ps -o args= -p "$pid" | grep -q "Xorg :$started "; then
    $SUDO kill "$pid"
  fi
  started=""
}

xr() { DISPLAY=:$num xrandr "$@"; }

# An output becomes "connected" once a mode has been set on it, and stays
# connected after it is switched off: a monitor plugged in after X started.
plug() {
  xr --addmode "$1" 1024x768 2>/dev/null
  xr --output "$1" --mode 1024x768 --right-of DUMMY0 &&
  xr --output "$1" --off
  xr | grep -q "^$1 connected"
}

# The non-desktop property makes the server report the output as
# disconnected and send the same change event as a real unplug.
unplug() { xr --output "$1" --set non-desktop 1; }

geom() {  # geometry of an output as xrandr prints it, "" when off
  xr | awk -v o="$1" '$1 == o { for (i = 3; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+/) { print $i; exit } }'
}

# ----------------------------------------------------------- WindowManager

stop_wm() {
  [ -n "$wmpid" ] || return 0
  if [ -n "$wmuser" ]; then sudo kill "$wmpid" 2>/dev/null; else kill "$wmpid" 2>/dev/null; fi
  # A TERM'd WindowManager can hang; it is our own pid, so KILL is safe.
  i=0
  while [ $i -lt 20 ] && kill -0 "$wmpid" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
  if kill -0 "$wmpid" 2>/dev/null; then
    if [ -n "$wmuser" ]; then sudo kill -9 "$wmpid" 2>/dev/null; else kill -9 "$wmpid" 2>/dev/null; fi
  fi
  wmpid=""
}

frame_of() {  # frame geometry WxH+X+Y of the frame titled $1
  DISPLAY=:$num xwininfo -root -tree | awk -v t="\"$1\":" '$2 == t && $3 == "()" { print $4; exit }'
}

frame_pos() {  # X,Y of a frame
  g=$(frame_of "$1"); [ -n "$g" ] || return 1
  echo "$g" | sed 's/^[0-9]*x[0-9]*+\([-0-9]*\)+\([-0-9]*\)$/\1,\2/'
}

pointer() {
  DISPLAY=:$num xdotool getmouselocation | sed 's/x:\([0-9]*\) y:\([0-9]*\).*/\1,\2/'
}

# inside X,Y W H RECT: the frame fits in the monitor RECT (WxH+X+Y)
inside() {
  pos=$1; fw=$2; fh=$3; rect=$4
  px=${pos%,*}; py=${pos#*,}
  rw=${rect%%x*}; rest=${rect#*x}; rh=${rest%%+*}; rest=${rest#*+}; rx=${rest%%+*}; ry=${rest#*+}
  [ "$px" -ge "$rx" ] && [ "$py" -ge "$ry" ] &&
  [ $((px + fw)) -le $((rx + rw)) ] && [ $((py + fh)) -le $((ry + rh)) ]
}

wait_for() {  # wait_for SECONDS COMMAND...
  t=$(($1 * 5)); shift
  i=0
  while [ $i -lt $t ]; do "$@" && return 0; sleep 0.2; i=$((i + 1)); done
  return 1
}

live_tests() {
  wm=${MULTIHEAD_WM:-/System/Library/CoreServices/Applications/WindowManager.app/WindowManager}
  [ -x "$wm" ] || { bad "no WindowManager executable at $wm"; return; }
  for tool in xdotool xmessage xwininfo; do
    command -v $tool >/dev/null 2>&1 || { bad "$tool is not installed"; return; }
  done

  say "live: window and pointer rescue on a dummy Xorg (:$num)"
  start_server || return
  plug DUMMY1 || { bad "cannot plug DUMMY1"; return; }
  xr --output DUMMY0 --mode 1024x768 --pos 0x0 --primary \
     --output DUMMY1 --mode 1024x768 --pos 1024x0
  [ "$(geom DUMMY1)" = 1024x768+1024+0 ] && ok "two 1024x768 monitors side by side" ||
    bad "two monitors side by side (DUMMY1 is '$(geom DUMMY1)')"

  # Started directly (no shell function) so that $! is the WindowManager.
  if [ -n "$wmuser" ]; then
    sudo -u "$wmuser" env DISPLAY=:$num HOME="$work/home" \
      sh -c ". '$GNUSTEP_MAKEFILES/GNUstep.sh'; exec '$wm'" > "$logs/wm.log" 2>&1 &
  else
    env DISPLAY=:$num HOME="$work/home" \
      sh -c ". '$GNUSTEP_MAKEFILES/GNUstep.sh'; exec '$wm'" > "$logs/wm.log" 2>&1 &
  fi
  wmpid=$!
  wait_for 20 sh -c "DISPLAY=:$num xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q window" ||
    { bad "the WindowManager did not come up (log $logs/wm.log)"; tail -n 20 "$logs/wm.log"; return; }
  ok "the WindowManager is managing :$num"

  DISPLAY=:$num xmessage -title rescue-me -geometry 300x150+1200+300 "on the second monitor" &
  msgpids="$msgpids $!"
  wait_for 10 sh -c "[ -n \"\$(DISPLAY=:$num xwininfo -root -tree | grep '\"rescue-me\":')\" ]" ||
    { bad "the test window did not appear"; return; }
  # The frame appears after the client; wait for it.
  have_frame() { [ -n "$(frame_of rescue-me)" ]; }
  wait_for 10 have_frame || { bad "the WindowManager did not frame the test window"; return; }
  sleep 1
  DISPLAY=:$num xwininfo -root -tree > "$logs/tree.txt" 2>&1
  before=$(frame_of rescue-me)
  bpos=$(frame_pos rescue-me)
  fw=${before%%x*}; fh=${before#*x}; fh=${fh%%+*}
  inside "$bpos" "$fw" "$fh" 1024x768+1024+0 &&
    ok "the window starts on the second monitor ($before)" ||
    bad "the window starts on the second monitor ($before)"
  DISPLAY=:$num xdotool mousemove 1500 400

  say "live: the second monitor is unplugged"
  unplug DUMMY1
  # Real hardware loses the CRTC with the monitor; the server leaves it
  # running until a client, normally displayconfig, switches it off.  The
  # WindowManager under test runs without that tool.
  xr --output DUMMY1 --off --fb 1024x768
  xr | grep -q '^DUMMY1 disconnected' && ok "DUMMY1 reported disconnected" || bad "DUMMY1 reported disconnected"
  on_primary() { p=$(frame_pos rescue-me) && inside "$p" "$fw" "$fh" 1024x768+0+0; }
  wait_for 8 on_primary && ok "the window came back onto the primary ($before -> $(frame_of rescue-me))" ||
    bad "the window came back onto the primary ($before -> $(frame_of rescue-me))"
  # The server itself clamps the pointer when the screen shrinks, so a warp
  # by the WindowManager cannot be told apart here; the unit suite covers
  # the decision.  This only proves the pointer is usable afterwards.
  ptr=$(pointer); inside "$ptr" 1 1 1024x768+0+0 &&
    ok "the pointer is on the primary monitor ($ptr)" ||
    bad "the pointer is on the primary monitor (at $ptr)"
  grep -q 'Layout settled: 1 monitor' "$logs/wm.log" &&
    ok "the WindowManager logged the layout with 1 monitor" ||
    bad "the WindowManager logged the layout with 1 monitor"
  kill -0 "$wmpid" 2>/dev/null && ok "the WindowManager survived the unplug" ||
    bad "the WindowManager survived the unplug"

  say "live: the monitor is plugged in again"
  xr --output DUMMY1 --set non-desktop 0
  xr --output DUMMY1 --mode 1024x768 --pos 1024x0
  wait_for 8 grep -q 'Layout settled: 2 monitor' "$logs/wm.log" &&
    ok "the WindowManager logged the layout with 2 monitors" ||
    bad "the WindowManager logged the layout with 2 monitors"
  on_primary && ok "the window stays on the primary" || bad "the window stays on the primary"
  kill -0 "$wmpid" 2>/dev/null && ok "the WindowManager survived the replug" ||
    bad "the WindowManager survived the replug"
}

# --------------------------------------------------------------------- main

echo "gershwin-windowmanager multi-monitor checks, $(uname -s)"
unit_tests

missing=""
command -v xrandr >/dev/null 2>&1 || missing="xrandr"
driver_installed || missing="$missing the Xorg dummy video driver"
if [ -n "$missing" ]; then
  if [ "${MULTIHEAD_REQUIRE:-}" = 1 ]; then bad "not installed:$missing"
  else skips=$((skips + 1)); echo "SKIP: live checks, not installed:$missing"; fi
else
  num=$(pick_display) || exit 2
  echo "private Xorg on :$num"
  live_tests
fi

echo
echo "multihead summary: $passes passed, $fails failed, $skips skipped"
[ $fails -eq 0 ]

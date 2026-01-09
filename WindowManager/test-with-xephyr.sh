#!/bin/bash
# Test script for uroswm with compositing in Xephyr
# This creates a nested X server to test without disturbing your main session

set -e

DISPLAY_NUM="${1:-:10}"
SCREEN_SIZE="${2:-1024x768}"

echo "============================================"
echo "UROSWM Compositor Test with Xephyr"
echo "============================================"
echo "Display: $DISPLAY_NUM"
echo "Screen size: $SCREEN_SIZE"
echo ""

# Check if Xephyr is running on this display already
if pgrep -f "Xephyr.*$DISPLAY_NUM" > /dev/null 2>&1; then
    echo "Xephyr already running on $DISPLAY_NUM, killing it..."
    pkill -f "Xephyr.*$DISPLAY_NUM" || true
    sleep 1
fi

# Start Xephyr with white background
echo "Starting Xephyr nested X server..."
Xephyr $DISPLAY_NUM -screen $SCREEN_SIZE -ac +extension RANDR +extension RENDER +extension GLX &
XEPHYR_PID=$!
sleep 2

# Verify Xephyr started
if ! kill -0 $XEPHYR_PID 2>/dev/null; then
    echo "ERROR: Failed to start Xephyr"
    exit 1
fi
echo "Xephyr started with PID $XEPHYR_PID"

# Set DISPLAY for child processes
export DISPLAY=$DISPLAY_NUM

# Build the window manager if needed
WM_DIR="$(cd "$(dirname "$0")" && pwd)"
WM_APP="$WM_DIR/WindowManager.app"

if [ ! -d "$WM_APP" ]; then
    echo "Building window manager..."
    cd "$WM_DIR"
    gnustep-make clean 2>/dev/null || true
    gnustep-make
fi

echo ""
echo "============================================"
echo "Starting uroswm WITH compositing..."
echo "============================================"
echo ""

# Start window manager with compositing enabled
cd "$WM_DIR"
export URSCompositingEnabled=YES
openapp ./WindowManager.app &
WM_PID=$!
sleep 2

# Check if WM started
if ! kill -0 $WM_PID 2>/dev/null; then
    echo "ERROR: Window manager failed to start"
    kill $XEPHYR_PID 2>/dev/null || true
    exit 1
fi
echo "Window manager started with PID $WM_PID"

# Start some test windows
echo ""
echo "Starting test windows..."
xterm -display $DISPLAY_NUM -geometry 80x24+50+50 -title "Test Terminal 1" &
sleep 1
xclock -display $DISPLAY_NUM -geometry 100x100+400+50 &
sleep 1

echo ""
echo "============================================"
echo "Test environment is ready!"
echo "============================================"
echo ""
echo "The Xephyr window should now show the window manager"
echo "with the test windows running."
echo ""
echo "Look for:"
echo "  - Windows appearing correctly"
echo "  - Window content updates properly (type in xterm)"
echo "  - Window movement updates screen correctly"
echo "  - No black rectangles or rendering glitches"
echo ""
echo "Press Ctrl+C to stop all processes and exit."
echo ""

# Wait for user to stop
trap "echo 'Cleaning up...'; kill $WM_PID 2>/dev/null || true; kill $XEPHYR_PID 2>/dev/null || true" EXIT

wait $WM_PID 2>/dev/null || true

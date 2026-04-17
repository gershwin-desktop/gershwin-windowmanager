#!/bin/bash
# test-xephyr-compositor.sh - Test window manager compositing in Xephyr
#
# This script launches a nested X session with Xephyr to safely test
# the window manager without disturbing your main session.

set -e

# Configuration
DISPLAY_NUM=":2"
SCREEN_SIZE="1024x768"
WM_DIR="/home/devuan/gershwin-build/repos/gershwin-uroswm"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Window Manager Xephyr Test ===${NC}"
echo -e "Display: $DISPLAY_NUM"
echo -e "Screen Size: $SCREEN_SIZE"
echo ""

# Source GNUstep environment
. /System/Library/Makefiles/GNUstep.sh

# Check if Xephyr is already running on this display
if xdpyinfo -display $DISPLAY_NUM >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: Display $DISPLAY_NUM already in use${NC}"
    echo "Trying :3 instead..."
    DISPLAY_NUM=":3"
    if xdpyinfo -display $DISPLAY_NUM >/dev/null 2>&1; then
        echo -e "${RED}Display :3 also in use. Please close existing Xephyr sessions.${NC}"
        exit 1
    fi
fi

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    if [ -n "$XEPHYR_PID" ]; then
        kill $XEPHYR_PID 2>/dev/null || true
    fi
    if [ -n "$WM_PID" ]; then
        kill $WM_PID 2>/dev/null || true
    fi
    echo -e "${GREEN}Done.${NC}"
}

trap cleanup EXIT

# Start Xephyr
echo -e "${GREEN}Starting Xephyr on $DISPLAY_NUM...${NC}"
Xephyr $DISPLAY_NUM -screen $SCREEN_SIZE -resizeable -title "uroswm Test" &
XEPHYR_PID=$!
sleep 2

# Check if Xephyr started successfully
if ! kill -0 $XEPHYR_PID 2>/dev/null; then
    echo -e "${RED}Failed to start Xephyr${NC}"
    exit 1
fi

echo -e "${GREEN}Xephyr started (PID: $XEPHYR_PID)${NC}"

# Set DISPLAY for the nested session
export DISPLAY=$DISPLAY_NUM

# Option to enable/disable compositing
COMPOSITOR_FLAG=""
if [ "$1" == "--disable-compositing" ] || [ "$1" == "-dc" ]; then
    echo -e "${YELLOW}Starting window manager WITHOUT compositing${NC}"
    COMPOSITOR_FLAG="-URSCompositingEnabled NO"
else
    echo -e "${GREEN}Starting window manager with COMPOSITING ENABLED${NC}"
    COMPOSITOR_FLAG="-URSCompositingEnabled YES"
    echo "(Use --disable-compositing or -dc to disable compositing)"
fi

# Start the window manager
echo -e "${GREEN}Launching WindowManager...${NC}"
cd "$WM_DIR"
./WindowManager.app/WindowManager $COMPOSITOR_FLAG 2>&1 &
WM_PID=$!
sleep 2

# Check if WM started successfully
if ! kill -0 $WM_PID 2>/dev/null; then
    echo -e "${RED}Window manager crashed on startup!${NC}"
    echo "Check the output above for errors."
    exit 1
fi

echo -e "${GREEN}Window manager started (PID: $WM_PID)${NC}"

# Launch a test application (xterm)
echo -e "${GREEN}Launching test applications...${NC}"
xterm -geometry 80x24+50+50 -title "Test Terminal 1" &
sleep 1
xterm -geometry 80x24+100+100 -title "Test Terminal 2" &
sleep 1

echo ""
echo -e "${GREEN}=== Test Environment Ready ===${NC}"
echo "- Xephyr is running on $DISPLAY_NUM"
echo "- Window manager is running"
echo "- Two xterm windows launched for testing"
echo ""
echo "Try the following tests:"
echo "  1. Move/resize windows - check for visual artifacts"
echo "  2. Alt-Tab to switch between windows"
echo "  3. Close windows and open new ones"
echo "  4. Check if damage events are handled (window updates)"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop the test and cleanup${NC}"

# Wait for user to stop
wait $WM_PID 2>/dev/null || true

# Window Open Animations


> [!NOTE]
> This is not working yet. This page contains a draft of how it might work;
> other/better solutions are welcome.

## Overview
Window open animations are coordinated between Workspace (producer of the start rectangle) and WindowManager (consumer + renderer). Workspace encodes the start rectangle into an X11 property on the client window before mapping; WindowManager reads it at map time and chooses the animation implementation based on compositing mode.

## Workspace (producer)
- File: Workspace/FileViewer/GWViewersManager.m
- Trigger: When opening a folder window with a pending open-animation rect.
- Action:
  - Sets the window to its final frame without animating.
  - Writes X11 property `_GERSHWIN_WINDOW_OPEN_ANIMATION_RECT` on the client X window.
  - Property format: four 32-bit integers `{x, y, width, height}` in **X11 screen coordinates** (origin top-left; Y is flipped from AppKit screen coords).
- Implementation details:
  - Uses `GSDisplayServer` to resolve the X11 window ID (`windowDevice`) and display.
  - Logs when the property is set or when the X11 window/device is unavailable.

## WindowManager (consumer)
- File: gershwin-windowmanager/XCBKit/XCBConnection.m
- Trigger: `handleMapRequest` for a non-minimized window.
- Action:
  - Reads `_GERSHWIN_WINDOW_OPEN_ANIMATION_RECT` from the client window.
  - Deletes the property after reading (one-shot usage).
  - Computes the end rect from the framed window.
  - Chooses animation based on compositing state:

### Compositing mode (smooth transition)
- File: gershwin-windowmanager/WindowManager/URSCompositingManager.m
- Method: `animateWindowTransition:fromRect:toRect:duration:fade:`
- Behavior: Animated scale/position with optional fade-in.

### Non-compositing mode (fast outline)
- File: gershwin-windowmanager/WindowManager/URSCompositingManager.m
- Method: `animateZoomRectsFromRect:toRect:connection:screen:duration:`
- Behavior: XOR-drawn outline rectangles interpolated between start and end.

## Logging
- Workspace logs when the property is set and when X11 window access fails.
- WindowManager logs when it successfully finds the animation rect.

## Debugging tips (xprop)
- To inspect the animation property on a client X window run:

  xprop -id <window-id> _GERSHWIN_WINDOW_OPEN_ANIMATION_RECT

  Expected output: a CARDINAL list of four 32-bit integers, e.g.
  _GERSHWIN_WINDOW_OPEN_ANIMATION_RECT(ATOM) = 100, 200, 64, 64

- If the atom is missing or the length is not 4, the WindowManager will log a message: "Animation property present but length=..." or "Animation atom not found/couldn't be interned".
- Check WindowManager logs for these messages:
  - "[MapRequest] Found animation rect" — the property was read and parsed
  - "[MapRequest] Called compositor animateWindowTransition" — compositor was invoked
  - "[Compositor] animateWindow called" — compositor received the start/end rects

- If you want to pause to inspect the property before the window is mapped, you can temporarily add a small delay in Workspace after setting the property (useful for manual xprop checks).
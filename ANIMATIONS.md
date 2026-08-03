# Window Open Animations

Window open animations are coordinated between Workspace (producer of the
source rectangle) and WindowManager (consumer + renderer). Workspace encodes
the source rectangle into an X11 property on the client window before
mapping; WindowManager reads it at map time and animates the new window.

## Overview

Every newly mapped window gets a "birth" animation: it fades in from fully
transparent while growing from a source rectangle to its final size,
preserving the window's own aspect ratio throughout.  When the source
rectangle comes from the desktop icon (Workspace sets the birth property),
the window visibly grows from the icon.

The aspect ratio used for the whole animation is always that of the final
window, regardless of the source rectangle's shape.

## The property: `_WINDOW_BIRTH`

Workspace sets this property on the client X window before it is mapped.
Format: 9 x 32-bit integers (CARDINAL):

    src-x, src-y, src-w, src-h,   // source rectangle, X11 screen coords
    dst-x, dst-y, dst-w, dst-h,   // target rectangle (informational)
    animationType                 // 0 = animate, 1 = NoAnimation

Coordinates are in **X11 screen coordinates** (origin top-left).  AppKit
uses a bottom-left origin, so Workspace flips the Y coordinate when writing
the property.

WindowManager deletes the property after reading it (one-shot usage).

## Workspace (producer)

- File: Workspace/FileViewer/GWViewersManager.m
- Trigger: opening a folder window by double-clicking an icon, from the
  desktop or from any viewer (icon view, list view, path view, spatial
  viewer).
- Action: `setWindowBirthRect:targetRect:animationType:forWindow:` writes
  the property on the client X window, derived from the activated icon's
  on-screen rect.  The source rect is obtained via
  `setPendingOpenAnimationRectFromViewer:forNode:`, which reads the icon's
  position from the viewer's node view (or from the desktop view for
  desktop icons).
- Note: `XChangeProperty` with `format=32` reads the data array as C `long`
  elements (8 bytes on LP64), so Workspace must pass a `long[9]` array, not
  `int32_t[9]` — otherwise every other 4-byte word is picked up and the
  property is corrupted.
- Limitation: the property is currently only written on Linux and only when
  there is an icon to derive the source rect from.  Windows opened without a
  source rect fall back to WindowManager's default 90%-size grow.

## WindowManager (consumer)

- File: gershwin-windowmanager/WindowManager/xcb/XCBConnection.m
- Method: `animateMappedWindow:clientId:windowRect:`
- Trigger: `handleMapRequest` for a new or re-mapped window.
- Action:
  - Reads `_WINDOW_BIRTH` from the client window.
  - Deletes the property after reading.
  - If the property has a valid source rect, animates from it (longer,
    0.8s effect); otherwise grows from 90% of the final size (0.22s).
  - Honours `animationType == 1` (NoAnimation) by skipping the animation.
  - Skips desktop windows and windows adopted at startup.
- If a window belonging to Workspace is mapped without the birth property,
  WindowManager logs a warning, since that indicates the producer side is
  not setting the property.

### Compositing mode (smooth transition)
- File: gershwin-windowmanager/WindowManager/URSCompositingManager.m
- Method: `animateWindowTransition:fromRect:toRect:duration:fade:`
- Behavior: animated scale/position with fade-in from transparent.

## Logging

- WindowManager warns when a Workspace window is mapped without the birth
  property ("WARNING: Workspace window ... mapped without
  _WINDOW_BIRTH atom").

## Debugging tips (xprop)

To inspect the birth property on a client X window:

    xprop -id <window-id> _WINDOW_BIRTH

Expected output: a CARDINAL list of nine 32-bit integers, e.g.

    _WINDOW_BIRTH(CARDINAL) = 100, 200, 64, 64, 400, 300, 400, 300, 0

The first four are the source rectangle (X11 screen coordinates), the next
four the target rectangle, and the last is the animation type.

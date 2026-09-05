# Window Open and Close Animations

Window animations are coordinated between Workspace (producer of the source /
target rectangle) and WindowManager (consumer + renderer).  Both the birth
(open) and close animations use the same pattern:

- **Birth**: Workspace encodes the source rectangle into an X11 property on
  the client window before mapping; WindowManager reads it at map time and
  animates the new window.
- **Close**: Workspace sends a client message with the target rectangle while
  the window is still mapped; WindowManager captures a snapshot, then the
  client's `UnmapNotify` (the close event) triggers the shrink/fade, mirroring
  how KDE fades any window on unmap.

Both halves are negotiated: WindowManager advertises the protocol atoms in its
`_NET_SUPPORTED` root property, and Workspace only participates when the
running window manager advertises them.

## Overview

### Birth (open)

Every newly mapped window gets a "birth" animation: it fades in from fully
transparent while growing from a source rectangle to its final size, preserving
the window's own aspect ratio throughout.  When the source rectangle comes from
the desktop icon (Workspace sets the birth property), the window visibly grows
from the icon.

The aspect ratio used for the whole animation is always that of the final
window, regardless of the source rectangle's shape.

### Close

Every folder window that carries a close-animation message gets a "close"
animation on `UnmapNotify`: it fades out while shrinking from its natural size
toward the folder icon's current position.  This is the exact reverse of birth
(the window is the start rect, the icon is the end rect).  The animation runs
on the WM frame's composite window, painting a **frozen snapshot** taken while
the client was still mapped (the live drawable loses the client content the
moment the app orders the window out).

## Capability negotiation

WindowManager advertises both protocol atoms in `_NET_SUPPORTED`
(EWMHService `putPropertiesForRootWindow:`), interning them first so the
advertised list carries real atom ids:

    _WINDOW_BIRTH_ANIMATION
    _WINDOW_CLOSE_ANIMATION

Workspace checks `windowManagerSupportsWindowAnimation` (X11AppSupport.m),
which reads `_NET_SUPPORTED` fresh on every call, before writing the birth
property or sending the close message.  Startup order (which of Workspace /
WindowManager starts first) is therefore irrelevant.

## The birth property: `_WINDOW_BIRTH_ANIMATION`

Workspace sets this property on the client X window before it is mapped.
Format: 9 x 32-bit integers (CARDINAL):

    src-x, src-y, src-w, src-h,   // source rectangle, X11 screen coords
    dst-x, dst-y, dst-w, dst-h,   // target rectangle (informational)
    animationType                 // 0 = animate, 1 = NoAnimation

Coordinates are in **X11 screen coordinates** (origin top-left).  AppKit uses
a bottom-left origin, so Workspace flips the Y coordinate when writing the
property.

WindowManager deletes the property after reading it (one-shot usage).  The
property is present only when a folder was actually opened; a re-mapped window
without a fresh property (e.g. unminimized) must not use it and gets its own
separate restore animation instead.

## The close message: `_WINDOW_CLOSE_ANIMATION`

Workspace sends this as an X11 client message to the root window (with
`SubstructureRedirectMask | SubstructureNotifyMask`) from `windowWillClose:`
while the window is still mapped.  `data32` layout:

    [0] = animationType            // 0 = shrink-to-icon, 2 = plain fade
    [1] = target-x                 // X11 root coords
    [2] = target-y
    [3] = target-w
    [4] = target-h

The message only **prepares** the animation:

1. WindowManager stores the target rect and animation type on the frame.
2. The compositor captures a frozen snapshot of the still-mapped window
   (the client has not been ordered out yet).

The client's subsequent `UnmapNotify` **is the close event**: it triggers the
shrink/fade (`startCloseAnimationForFrame:`), and the animation completion
tears down the frame (reparents the already-unmapped client to root,
undecorates, unregisters, destroys the frame).  A window without a prepared
close animation is torn down immediately on unmap, as before.

## Workspace (producer)

- Files:
  - Workspace/FileViewer/GWViewersManager.m (rect resolution + property/message)
  - Workspace/X11AppSupport.m (`animateWindowClose:targetRect:`,
    `windowManagerSupportsWindowAnimation`)
- Birth trigger: opening a folder window by double-clicking an icon, from the
  desktop or from any viewer (icon view, list view, path view, spatial viewer).
- Birth action: `setWindowBirthRect:targetRect:animationType:forWindow:` writes
  the property on the client X window, derived from the activated icon's
  on-screen rect via `resolveIconScreenRectForNode:`.
- Close trigger: `windowWillClose:` in `GWViewer` / `GWSpatialViewer`.
- Close action: `prepareCloseAnimationForViewer:` resolves the folder's
  CURRENT on-screen representation by identity (`resolveIconScreenRectForNode:`
  - desktop icon preferred, then the key/focused viewer, then all viewers;
  hidden/minimized windows yield `NSZeroRect`) and sends the close message with
  the target rect.  `NSZeroRect` makes WindowManager fall back to a plain fade.
- Note: `XChangeProperty` with `format=32` reads the data array as C `long`
  elements (8 bytes on LP64), so Workspace must pass a `long[]` array, not
  `int32_t[]` — otherwise every other 4-byte word is picked up and the
  property is corrupted.
- Limitation: the birth property is currently only written on Linux and only
  when there is an icon to derive the source rect from.  Windows opened
  without a source rect fall back to WindowManager's default 90%-size grow.

## WindowManager (consumer)

- File: gershwin-windowmanager/WindowManager/xcb/XCBConnection.m
- Birth method: `animateMappedWindow:clientId:windowRect:`
- Close methods: `prepareCloseAnimationForClient:animationType:targetRect:`
  (message handler) and `startCloseAnimationForFrame:` (unmap handler).
- Birth trigger: `handleMapRequest` for a new or re-mapped window.
- Birth action:
  - Reads `_WINDOW_BIRTH_ANIMATION` from the client window.
  - Deletes the property after reading.
  - If the property has a valid source rect, animates from it (0.20s);
    otherwise grows from 90% of the final size (0.11s).
  - Honours `animationType == 1` (NoAnimation) by skipping the animation.
  - Skips desktop windows and windows adopted at startup.
- Close action: the animation runs on the **frame** composite window (the
  compositor only paints top-level windows), shrinking from `natural = start`
  to the icon rect with a fade-out, over 0.20s (matching birth).  The frozen
  snapshot is protected from the compositor's four picture-recreation paths
  (damage notify, expose, focus-change invalidation, and lazy picture
  creation) so the animation never repaints an empty live drawable.
- If a window belonging to Workspace is mapped without the birth property,
  WindowManager logs a warning, since that indicates the producer side is not
  setting the property.

### Compositing mode (smooth transition)
- File: gershwin-windowmanager/WindowManager/URSCompositingManager.m
- Methods: `animateWindowTransition:fromRect:toRect:duration:fade:`,
  `captureCloseSnapshotNowForWindow:`, `setCloseAnimating:forWindow:`
- Behavior: animated scale/position with fade-in from transparent for birth;
  shrink + fade-out for close, painted from the frozen snapshot.

## Logging

- WindowManager warns when a Workspace window is mapped without the birth
  property ("WARNING: Workspace window ... mapped without
  _WINDOW_BIRTH_ANIMATION atom").

## Debugging tips (xprop)

To inspect the birth property on a client X window:

    xprop -id <window-id> _WINDOW_BIRTH_ANIMATION

Expected output: a CARDINAL list of nine 32-bit integers, e.g.

    _WINDOW_BIRTH_ANIMATION(CARDINAL) = 100, 200, 64, 64, 400, 300, 400, 300, 0

The first four are the source rectangle (X11 screen coordinates), the next
four the target rectangle, and the last is the animation type.

To confirm the running window manager advertises the protocol:

    xprop -root _NET_SUPPORTED

should include `_WINDOW_BIRTH_ANIMATION` and `_WINDOW_CLOSE_ANIMATION`.

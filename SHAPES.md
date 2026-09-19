# Window Outlines (`_WM_SHAPE_PATH`)

A window can ask the window manager to show it with an outline other than a
rectangle: a curved bottom edge, rounded or cut corners, any shape made of
lines and curves. The app describes the outline as a vector path in a window
property. The window manager draws the edge antialiased and casts the drop
shadow along it. Because the outline is worked out again for every size, it
stays exact while the window is being resized, without waiting for the app to
redraw.

The X Shape extension only knows whether a pixel belongs to the window or
not, so its edges are always stepped. An ARGB window would need the app to
draw its own translucent edge and shadow, which lags behind a resize and
costs a blend of the whole window on every repaint. There is no existing
X11 convention for a vector outline, hence this property.

## Is it supported?

The window manager lists the atom `_WM_SHAPE_PATH` in the `_NET_SUPPORTED`
property of the root window. Check for it before setting the property; with
a window manager that does not list it, the window stays a rectangle.
Read `_NET_SUPPORTED` again when it matters (for example each time the
outline is set), since the window manager may have been replaced.

## The property

Set `_WM_SHAPE_PATH` on the client window (the app's own top-level window,
not the frame), type `INTEGER`, format 32:

    version                 always 1
    command, points...      any number of commands

Commands, each followed by its points:

| Value | Command  | Points                                  |
|-------|----------|-----------------------------------------|
| 0     | move to  | 1 (starts a new figure)                 |
| 1     | line to  | 1                                       |
| 2     | curve to | 3 (cubic Bezier: control, control, end) |
| 3     | close    | 0                                       |

A point is four 16.16 fixed-point numbers (the value times 65536, rounded):

    fx, ox, fy, oy    ->    x = fx * width  + ox
                            y = fy * height + oy

`width` and `height` are the current size of the client window in device
pixels. The origin is its top left corner and y grows downwards (X11
coordinates, not AppKit's). `fx`/`fy` are fractions of the size (0 = left or
top, 1 = right or bottom); `ox`/`oy` are pixels. So `(1, -10, 1, 0)` is 10
pixels left of the bottom right corner at every size.

The window shows what the path encloses. A figure that is not closed is
closed with a straight line. Keep figures simple (no self-intersections);
overlapping figures are not combined in a defined way. Points outside the
window are clipped to it. A property the window manager cannot read (wrong
version, unknown command, a command cut short, no line or curve at all) is
ignored and the window stays a rectangle.

Remove the property (`XDeleteProperty`) to make the window rectangular again,
for example when it goes full screen. Replacing it takes effect at once.

## What the window manager does

- It cuts the frame below the titlebar to the outline (the titlebar keeps
  its own look) and works the outline out again on every size change, so it
  is right on every step of a resize.
- With compositing, the edge is antialiased and the drop shadow follows the
  outline. Only the edge strip is blended; the inside is copied like any
  other window. Without compositing (`-dc`) the outline still applies, as a
  plain X shape with a stepped edge.
- The outline goes along when the compositor bends or scales the window
  (wobbly windows while it is dragged, open and close animations).
- The part of the window outside the outline takes no clicks.
- If the outline leaves the bottom right corner (where the resize grip is),
  the window manager's grip area moves up to where the outline ends at the
  right side. The app's theme should draw its grip there too: the Eau theme
  asks the window for `-resizeIndicatorBottomInset` (points), see
  `EauGrowBoxView.h`.

Only the client area is outlined; the app draws its content as usual and
whatever lies outside the outline is simply not shown.

## Example: a bottom edge that curves down to the middle

The sides end `d` pixels above the bottom; a parabola (a cubic with its
control points a third in from each end) touches the bottom in the middle:

    1,                                      version
    0,  0, 0,     0, 0,                     move to the top left corner
    1,  1, 0,     0, 0,                     line to the top right corner
    1,  1, 0,     1, -d,                    line down the right side
    2,  2/3, 0,   1, d/3,                   curve: first control point
        1/3, 0,   1, d/3,                   second control point
        0, 0,     1, -d,                    to the left side
    3                                       close

(every number above as 16.16, so `1` is 65536). Player builds exactly this in
`PlayerBottomCurveShapePath()` (gershwin-components, `Player/PlayerViews.m`).

## Setting it with Xlib

Xlib passes 32-bit property items as `long`:

```c
Atom pathAtom = XInternAtom(display, "_WM_SHAPE_PATH", False);
long items[count];                  /* the int32 values above */
XChangeProperty(display, window, pathAtom, XA_INTEGER, 32, PropModeReplace,
                (unsigned char *)items, count);
```

A GNUstep app gets its X window from
`[GSServerForWindow(window) windowDevice:[window windowNumber]]` and the
display from `serverDevice`; see `PlayerWindow` in `Player/PlayerViews.m`,
which also checks `_NET_SUPPORTED` first.

## Where it lives

- `WindowManager/URSShapePath.h/.m`: reading the property and working out
  how much of each pixel the outline covers, at any size
  (headless test: `gnustep-tests test-shapepath`).
- `WindowManager/xcb/XCBFrame.m`: reading the property
  (`-clientShapePathChanged`, also on `PropertyNotify`), cutting the frame,
  moving the grip area.
- `WindowManager/URSCompositingManager.m`: the coverage mask the frame is
  painted through (`-setShapePath:clientOriginX:y:forWindow:`) and the
  shadow.
- `WindowManager/xcb/services/EWMHService.m`: `_WM_SHAPE_PATH` in
  `_NET_SUPPORTED`.

# Theming the window decorations

## Overview

WindowManager draws the decorations around every window itself: it reparents a
client into a frame, puts a titlebar window on top of it, and renders that
titlebar into a pixmap. What the pixmap looks like is the theme's business, so
the window manager asks the current `GSTheme` for it.

The theme is found through `[GSTheme theme]`, which means whatever
`NSGlobalDomain GSTheme` names when the window manager starts. A theme that is
switched at runtime takes effect on the next start of the window manager.

Nothing here is a protocol a theme has to adopt. Every call is guarded by
`respondsToSelector:`, so a theme answers as much of this as it wants to and
gets the window manager's own decorations for the rest. There are three levels:

| The theme answers | What it gets |
| --- | --- |
| nothing | the window manager's titlebar and its square edge buttons, and a one pixel frame |
| `drawtitleRect:...` | the bar and the title are the theme's, the buttons stay the window manager's |
| `drawsTitlebarButtons`, `titlebarButtonRectForButton:...` | the buttons are the theme's too, and the window manager does not overlay its own |
| `windowFrameBorderWidth`, `windowFrameBorderColorAtDepth:...` | the border around the client is the theme's |

The two Gershwin themes stand at different levels: **Eau** draws its own
buttons only while it is set to the orb style (`EauTitleBarButtonStyle`), and
**George** draws its buttons and its window border at all times.

## Coordinates

Two systems meet here, and mixing them up is the usual bug.

- A **theme** works in AppKit coordinates: the origin is the **bottom left** of
  the titlebar, y grows upwards. Every rect a theme returns or is handed is in
  these.
- **X11** counts from the **top left**, y grows downwards. Pointer events
  arrive like that.

The window manager flips between them, in
`+[URSThemeIntegration buttonIndexAtPoint:titlebarSize:styleMask:]`:

```objc
r.origin.y = height - NSMaxY(r);   // theme rect -> X11 rect
```

Sizes are in pixels, already multiplied by the scale factor. A theme that draws
pixel art should keep its rows whole rather than follow a fractional factor;
`titlebarHeight` is the theme's answer, not `22 * scale`.

## The titlebar

### Size

```objc
- (float)titlebarHeight;          // pixels, including the scale factor
- (CGFloat)titlebarCornerRadius;  // 0 for a square bar
```

`titlebarHeight` sets the height of the titlebar window and the frame offsets
published to GNUstep apps. `titlebarCornerRadius` rounds the top corners of the
frame's shape.

### Drawing the bar

```objc
- (void)drawtitleRect:(NSRect)rect
         forStyleMask:(unsigned int)styleMask
                state:(int)inputState
             andTitle:(NSString *)title;
```

This is the whole bar: background, title, and, for a theme that says so, the
buttons. It is called into an offscreen context whose size is the titlebar, so
`rect` starts at the origin.

`inputState` is `GSThemeNormalState` for the focused window and
`GSThemeSelectedState` for the others.

A theme may spell the selector `drawTitleBarRect:forStyleMask:state:andTitle:`
instead, which is what the base `GSTheme` calls it. The window manager tries
the lower case spelling first and falls back to the other.

### The style mask

The mask tells the theme which buttons the window has, and what kind of window
it is. It is computed once per window, in
`+[URSThemeIntegration buttonStyleMaskForFrame:]`, and the same mask is used
for drawing and for hit testing, so a button is always hit where it was drawn.

| Bit | Set when |
| --- | --- |
| `NSTitledWindowMask` | always |
| `NSClosableWindowMask` | the client can be closed and carries `WM_DELETE_WINDOW` |
| `NSMiniaturizableWindowMask` | the client answers `canMinimize` |
| `NSResizableWindowMask` | the client is not a fixed size window |
| `NSUtilityWindowMask` | `_GNUSTEP_WM_ATTR` says the window is a panel, or `_NET_WM_WINDOW_TYPE` is utility |

`NSUtilityWindowMask` is what lets a theme give panels a narrower bar. GNUstep
publishes the real style mask in `_GNUSTEP_WM_ATTR` whether or not the toolkit
found EWMH support, so it is read from there for GNUstep windows and from the
window type for everything else.

### Buttons

Buttons are numbered, and the number is what the window manager passes around:

| Index | Button |
| --- | --- |
| 0 | close |
| 1 | miniaturize |
| 2 | zoom |

```objc
- (BOOL)drawsTitlebarButtons;
- (NSRect)titlebarButtonRectForButton:(NSInteger)button
                        titlebarWidth:(CGFloat)width
                            styleMask:(NSUInteger)styleMask;
```

`drawsTitlebarButtons` returning `YES` means two things: the theme has already
drawn its buttons inside `drawtitleRect:`, so the window manager must not
overlay its own, and the theme lays them out, so the window manager must ask
where they are rather than assume. A theme may decide this at runtime; Eau
answers `YES` only while it is set to the orb style.

`titlebarButtonRectForButton:titlebarWidth:styleMask:` returns the slot of one
button in titlebar coordinates, and `NSZeroRect` for a button this window does
not have - test the style mask, do not return a rect for a button that is not
there or the window manager will find it under the pointer. The slot is the
click target as well as the artwork, so include whatever padding belongs to the
button.

The window manager redraws the button under the pointer in its highlighted
state, through whichever of these the theme answers:

```objc
- (void)drawCloseButtonInRect:(NSRect)rect state:(GSThemeControlState)state active:(BOOL)active;
- (void)drawMinimizeButtonInRect:(NSRect)rect state:(GSThemeControlState)state active:(BOOL)active;
- (void)drawMaximizeButtonInRect:(NSRect)rect state:(GSThemeControlState)state active:(BOOL)active;
```

`rect` is the slot the theme itself returned, `state` is
`GSThemeHighlightedState` while hovered, and `active` is the focus state of the
window. A theme with no hover look can ignore `state` and draw the same thing.

## The window border

A theme that wants a border of its own around the client answers:

```objc
- (CGFloat)windowFrameBorderWidth;
- (NSColor *)windowFrameBorderColorAtDepth:(NSInteger)depth
                                      edge:(NSInteger)edge
                                    active:(BOOL)active;
```

`windowFrameBorderWidth` is how many pixels the frame reserves around the
client on the left, right and bottom; the titlebar covers the top. Returning 0,
or not answering at all, keeps the one pixel border the window manager has
always drawn.

The border is painted one line at a time, so a theme can carve a bevel out of
it:

- `depth` counts from the outside in, `0` being the outermost line.
- `edge` is `0` left, `1` right, `2` bottom.
- `active` is the focus state of the window.

The window manager paints the border whenever it renders the titlebar, and
repaints it with the state it last used when X clears the frame (an expose, a
resize). The graphics context and that state are kept per frame and let go of
when the window is unregistered.

Borders are painted opaque: the frame is an ARGB window while a compositor
runs, and a colour with alpha would composite away.

## Writing a theme against this

1. Start with `titlebarHeight` and `drawtitleRect:forStyleMask:state:andTitle:`.
   That alone gives a themed bar with the window manager's edge buttons.
2. To own the buttons, answer `drawsTitlebarButtons` with `YES`, draw them
   inside `drawtitleRect:`, and return their slots from
   `titlebarButtonRectForButton:titlebarWidth:styleMask:`. Add the three
   `draw...ButtonInRect:state:active:` methods if the buttons have a hover
   look.
3. To own the border, answer `windowFrameBorderWidth` and
   `windowFrameBorderColorAtDepth:edge:active:`.

Keep the answers cheap. They are asked while drawing and on pointer motion, so
anything that reads a default or measures a font belongs in a cached value, not
in the call.

Worked examples in the Gershwin tree:

- `gershwin-eau-theme`, `Eau+TitleBarButtons.m` - buttons at the left of the
  bar, switched on by a user default.
- `gershwin-george-theme`, `George+TitleBar.m` and `George+Frame.m` - Platinum
  widgets and a six pixel bevelled window frame.

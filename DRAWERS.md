# Drawers

A drawer is a panel that slides out from under one edge of its window, the
way a drawer comes out of a desk: an inspector on the side, a list below. The
window manager keeps it attached to that edge: it moves and resizes with the
window in the same frame, stays behind the window (whose shadow falls on it),
bends along when the window wobbles, never gets a titlebar, and slides out
from under the edge when opened and back when closed.

Toolkits show a drawer as a separate top-level window, as AppKit always did
(`NSDrawer` is a child window ordered below its parent). Only the window
manager can move it together with its parent without lag: the client learns
of a move one round trip later and then has to ask for its own move.

## The contract with clients: `WM_WINDOW_ROLE` = `drawer`

Two standard ICCCM properties, set before the window is mapped:

| Property           | Type     | Value                                   |
|--------------------|----------|-----------------------------------------|
| `WM_TRANSIENT_FOR` | `WINDOW` | the client window it is a drawer of     |
| `WM_WINDOW_ROLE`   | `STRING` | `drawer` (a trailing NUL is ignored)    |

Nothing else is needed: the client maps the drawer where it wants it, next
to its parent, and the window manager reads the rest off that rect when it
is mapped:

- the edge: the side of the parent's frame the rect's middle lies beyond
  (a rect over the parent is no drawer and is shown as an ordinary window);
- the leading and trailing offsets: its distance from either end of that
  side of the parent's client window (leading is the top of a side edge and
  the left end of a top or bottom edge);
- its thickness: its width (side edges) or height.

Later configure requests may change only the thickness (a new content size);
position and length follow the parent. An outline in `_WM_SHAPE_PATH`
(SHAPES.md) is honoured with compositing, as for framed windows. A drawer of
an undecorated or unknown window is framed like any other window.

The Eau theme sets the role for every `NSDrawer`, places the drawer flush
against its parent's edge and rounds its outer corners; see the theme's
README.

## What the window manager does with a drawer

| Event | Behaviour |
|-------|-----------|
| Map request | Not framed. Edge, offsets and thickness are read off its rect; it is placed flush against that edge of the parent's frame, directly below the frame in the stacking order, and mapped. It does not take the focus. |
| Mapped | Slides out from under the edge in 0.25 s, easing out (needs the compositor). A stall of the window manager postpones the slide instead of skipping it. |
| Configure request | Only the thickness is taken; it is placed again, and stays below the parent. |
| Parent dragged or resized by the window manager | Moved in the same batch of requests as the frame and handed to the compositor before it paints, so no frame shows the parent moved and the drawer not; a new length follows on the ConfigureNotify. |
| Parent moved, resized or restacked otherwise | Placed again from the parent's ConfigureNotify. |
| Parent wobbles (`URSWobblyWindows`) | Bent as a continuation of the parent's mesh: every point moves as far as the nearest point of the parent, so the seam stays closed. |
| The window manager restacks the application (a click, a sheet shown) | The drawer is put back directly below its parent's frame (`XCBWindow stackedBelowWindow`), never above the parent, the Dock or the menu bar. |
| Drawer gets the focus (a click into it) | The parent's titlebar is drawn active; the drawer stays below the parent. |
| Parent's frame unmapped (minimised) | The drawer is unmapped with it and stays attached; mapped again with it, without a slide. |
| Drawer unmapped by the client (closed) | Slides back under the edge after the unmap; the focus returns to the parent if the drawer had it. |
| Window manager starts with a drawer open | Adopted after its parent, not framed; its offsets are read against where the parent was before it was framed again. |
| Parent or drawer destroyed | The attachment and the outline are forgotten. |

A parent can have several drawers, on different edges.

## Code

Sheets and drawers share `URSAttachmentController` (recognising the role,
attaching without a frame, following, hiding, the slide, focus hand-back,
adoption); `URSDrawerController` only says where a drawer goes, like
`URSSheetController` for sheets (SHEETS.md).

| File | Role |
|------|------|
| `URSAttachmentController.h/m` | Attached windows in general; hooked into `URSHybridEventHandler` (map/configure requests, Map/Unmap/Configure/Destroy notify, FocusIn, start-up adoption, and `followFrame:` from the drag and resize motion). |
| `URSDrawerController.h/m` | Where a drawer hangs, that it stacks below and keeps its thickness. |
| `URSDrawerLayout.h/m` | Reading edge, offsets and thickness off a rect; the rect for a parent (pure geometry). |
| `URSAttachmentSlideEffect.h/m` | The slide out from under any edge (`-clipRectForWindowRect:`, `-playsEveryFrame`). |
| `URSAttachedDeformation.h/m` | A window's mesh continuing a wobbling parent's; stepped after it (`-followsOtherDeformation`). |
| `URSAttachmentRegistry.h/m` | Which windows hang from which, and which are hidden with their parent. |
| `URSWindowRole.h/m` | Reading `WM_WINDOW_ROLE`. |

## Tests

`gnustep-tests test-drawers` (headless): `drawerlayout.m` (placement on each
edge, reading the attachment back, following a moved parent, tracking a
resized one), `drawerslide.m` (the slide on each edge, its curve and clip),
`attachedwobble.m` (the seam stays on the parent's bent edge, rows ride
along rigidly, it rests with the parent).

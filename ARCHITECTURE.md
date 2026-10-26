# WindowManager Architecture

## Overview

WindowManager is a standalone X11 window manager built with Objective-C,
GNUstep, and XCB. All source code lives under `WindowManager/` in a
unified build target — there is no separate framework or library.

## Directory Layout

```
WindowManager/
├── main.m                          Application entry point
├── UROSWMApplication.h/m           Custom NSApplication subclass
├── GNUmakefile                     Single build target
│
├── xcb/                            XCB abstraction layer
│   ├── XCBConnection.h/m           X11 connection, event dispatch, window map
│   ├── XCBWindow.h/m               Base window abstraction
│   ├── XCBFrame.h/m                Reparenting frame (borders, resize zones)
│   ├── XCBTitleBar.h/m             Titlebar window (pixmap, buttons, drag)
│   ├── XCBScreen.h/m               Screen geometry and root window
│   ├── XCBVisual.h/m               Visual/depth selection
│   ├── XCBCursor.h/m               Cursor management
│   ├── XCBSelection.h/m            X11 selection ownership (WM_Sn)
│   ├── XCBRegion.h/m               XFixes region wrapper
│   ├── XCBShape.h/m                X11 Shape extension (rounded corners)
│   ├── XCBReply.h/m                Base class for XCB reply wrappers
│   ├── XCBAttributesReply.h/m      Window attributes reply
│   ├── XCBGeometryReply.h/m        Window geometry reply
│   ├── XCBQueryTreeReply.h/m       Query tree reply
│   ├── XCBTypes.h                  Geometry primitives (XCBPoint, XCBSize, XCBRect, XCBColor)
│   │
│   ├── enums/                      Enumeration constants
│   │   ├── EEwmh.h                 EWMH property identifiers
│   │   ├── EIcccm.h                ICCCM protocol constants
│   │   ├── EMousePosition.h        Mouse position on frame edges
│   │   ├── EResizeDirection.h      Resize direction flags
│   │   ├── ETitleBarColor.h        Titlebar color state (up/down)
│   │   └── EXErrorMessages.h       X protocol error strings
│   │
│   ├── services/                   X11 protocol services
│   │   ├── EWMHService.h/m         Extended Window Manager Hints
│   │   ├── ICCCMService.h/m        Inter-Client Communication Conventions
│   │   ├── XCBAtomService.h/m      Atom interning and lookup
│   │   └── TitleBarSettingsService.h/m  Titlebar geometry configuration
│   │
│   └── utils/                      Utility classes and functions
│       ├── XCBCreateWindowTypeRequest.h/m  Window creation request builder
│       ├── XCBWindowTypeResponse.h/m       Window creation response
│       ├── Comparators.h/m         Color and struct comparison helpers
│       └── Transformers.h/m        Coordinate and struct transformation helpers
│
├── URSHybridEventHandler.h/m       Event coordinator (XCB → manager dispatch)
├── URSFocusManager.h/m             Focus tracking and window resolution
├── URSKeyboardManager.h/m          Alt-Tab keyboard grabs and key events
├── URSWorkareaManager.h/m          EWMH strut tracking and workarea calculation
├── URSTitlebarController.h/m       Titlebar button hit-test, hover, resize
├── URSSnappingMenuController.h/m   Right-click window snapping menu
│
├── URSCompositingManager.h/m       XRender compositing manager
├── URSRenderingContext.h/m         Per-window rendering state
├── URSWindowEffect.h               Effect played on a window where it stands
├── URSAttentionHopEffect.h/m       Hop effect for the window switched to
├── URSWindowPresentation.h         Shows windows elsewhere while installed
├── URSOverviewController.h/m       Window overview: input, selection
├── URSOverviewLayout.h/m           Window overview layout (pure geometry)
├── URSOverviewTitleLabel.h/m       Title of the window under the pointer
├── URSShowDesktopController.h/m    Show Desktop: windows to the edges, slivers
├── URSShowDesktopLayout.h/m        Show Desktop layout (pure geometry)
├── URSGlobalKey.h/m                A key grabbed on the root window
├── URSHotCorner.h/m                A screen corner watched for the pointer
├── URSPresentationTransition.h/m   Eased 0..1 progress of a presentation
├── URSScreenWindow.h/m             Decorated windows on the screen, stacked
├── URSWindowDeformation.h          Bends a window's picture over a mesh
├── URSWobblyModel.h/m              Spring mesh of a wobbly window (pure physics)
├── URSTriangleSpans.h/m            Watertight triangle spans for bent windows
├── URSWobblyWindowsController.h/m  Wobbly windows while dragging
├── URSAttachmentController.h/m     Sheets and drawers attached to a parent
├── URSSheetController.h/m          Sheets attached to their parent (SHEETS.md)
├── URSDrawerController.h/m         Drawers attached to their parent (DRAWERS.md)
├── URSDrawerLayout.h/m             Drawer placement (pure geometry)
├── URSAttachedDeformation.h/m      Attached window bending with a wobbling parent
├── URSAttachmentRegistry.h/m       Which sheet or drawer hangs from which window
├── URSSheetLayout.h/m              Sheet placement and slide (pure geometry)
├── URSAttachmentSlideEffect.h/m    Slide of an attached window out from under its parent
├── URSSheetSlideEffect.h/m         Slide of a sheet out of the titlebar
├── URSWindowRole.h/m               WM_WINDOW_ROLE (sheet, drawer) of a window
│
├── URSWindowSwitcher.h/m           Alt-Tab window switcher logic
├── URSWindowSwitcherOverlay.h/m    Window switcher overlay rendering
├── URSWindowFlowController.h/m     Alt-Tab flow: windows flown into a row
├── URSFlowLayout.h/m               Alt-Tab flow layout (pure geometry)
├── URSDeckLayout.h/m               Alt-Tab deck layout, a carousel (pure geometry)
├── URSSourceDirectory.h/m         Source directory of an app, from APP_NAME in the GNUmakefiles
├── URSFlipSideController.h/m       Terminal on the back of a flipped window (flip side)
├── URSFlipSideGeometry.h/m         Titlebar strip and flip side on the back (pure geometry)
├── URSFlipSidePlan.h/m             What "Flip Window" does next (pure logic)
├── URSFlipSideOrphans.h/m          Terminals that outlived their window (pure logic)
├── URSSnapPreviewOverlay.h/m       Snap preview overlay rendering
├── URSThemeIntegration.h/m         GSTheme titlebar decoration bridge
└── GSThemeTitleBar.h/m             GSTheme drawing surface adapter
```

## Layered Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    main.m / UROSWMApplication            │
│                   (NSApplication run loop)               │
├──────────────────────────────────────────────────────────┤
│                  URSHybridEventHandler                   │
│              (event coordinator / dispatcher)            │
├────────┬──────────┬───────────┬──────────┬──────────────┤
│ Focus  │ Keyboard │ Workarea  │ Titlebar │   Snapping   │
│Manager │ Manager  │ Manager   │Controller│   Menu Ctrl  │
├────────┴──────────┴───────────┴──────────┴──────────────┤
│                   Compositing Manager                    │
│                   (optional XRender)                     │
├──────────────────────────────────────────────────────────┤
│                   URSThemeIntegration                    │
│               (GSTheme ↔ XCB bridge)                    │
├──────────────────────────────────────────────────────────┤
│                        xcb/                              │
│   XCBConnection · XCBWindow · XCBFrame · XCBTitleBar     │
│   XCBScreen · services/ · utils/ · enums/                │
├──────────────────────────────────────────────────────────┤
│                libxcb · libxcb-icccm · GNUstep           │
└──────────────────────────────────────────────────────────┘
```

### Layer Responsibilities

**Application Layer** — `main.m`, `UROSWMApplication`
Bootstraps GNUstep, parses arguments, installs signal handlers, starts
`NSApplication` run loop.

**Event Coordinator** — `URSHybridEventHandler`
Bridges the XCB file descriptor into the NSRunLoop. Receives raw XCB events
and dispatches to the appropriate manager. Does not contain domain logic
itself — only routing.

**Manager Layer** — Five single-responsibility managers
Each manager owns one concern: focus tracking, keyboard grabs, workarea
calculation, titlebar interactions, or the snapping context menu.

**Compositing Layer** — `URSCompositingManager`, `URSRenderingContext`
Optional XRender-based compositor. Activated with `-c` flag. Manages
off-screen buffers, damage tracking, and animated transitions.

**Theme Layer** — `URSThemeIntegration`, `GSThemeTitleBar`
Bridges GNUstep's GSTheme drawing API to XCB pixmaps. Renders titlebar
decorations, buttons, and text using the active GSTheme.

**XCB Abstraction Layer** — `xcb/`
Objective-C wrapper around libxcb. Provides object-oriented access to
X11 windows, screens, cursors, selections, EWMH/ICCCM services, and
GNUstep/XCB rendering. No window management policy — only mechanism.

## Flip side

"Flip Window" (titlebar menu) goes through `URSFlipSideController`, which
decides with `URSFlipSidePlan` whether the window turns to its plain back, to
its flip side, or first starts one: `Terminal.app/Terminal -FlipSideDirectory
<dir> -FlipSideParent <client xid>` from the System domain, in the directory
`URSSourceDirectory` finds for the client's application (its WM_CLASS class,
the `APP_NAME` of the GNUmakefile under `/Developer/Library/Sources`,
subdirectories included, indexed in one walk). The terminal marks its window with `WM_WINDOW_ROLE`
`flipside` and `WM_TRANSIENT_FOR` = the client, but only after asking for the
map, so a map request from a terminal the controller started is held until
the role arrives (PropertyNotify). The flip side is an attached window like a
sheet or drawer (`URSAttachmentController`): it covers the client area, is
never framed, never slides, lies directly below the frame while the front
shows and directly above it, with the focus, once the back is at rest.

The compositor never paints it as a window (nor lets it bypass compositing):
`setFlipSideWindow:ofFrame:` makes `paintProjectedWindow:` compose the back
from the grey panel, the frame's titlebar strip and the flip side's picture
(`URSFlipSideGeometry`), and its damage repaints the frame's back while that
rests at 180 degrees. The first turn waits for the terminal's first content
(`performWhenWindowHasContent:block:`), at most 10 s. When the terminal goes
by itself, the window turns back to its front.

The terminal is the user's shell and outlives its window. When the parent's
client or frame is destroyed, the controller releases the flip side from the
attachment machinery (`releaseAttachedWindow:`) and the compositor
(`releaseFlipSideWindow:`), deletes its `WM_TRANSIENT_FOR` (so no controller
claims it again) and has the event handler frame it where it is
(`frameWindowAsOrdinary:closeHandler:` ->
`-[XCBConnection frameNextMapOfWindow:asOrdinaryClosedBy:]`): framed although
its Motif hints say undecorated, sizable although its normal hints pin its
size (`XCBWindow framedAsOrdinary`), and closed through `closeHandler`
(SIGTERM to the terminal), because its borderless window offers no
`WM_DELETE_WINDOW`. `URSFlipSideOrphans` keeps it with its application
(WM_CLASS class) and source directory. Right after a new plain window is
framed (`clientWindowFramed:`), the oldest orphan of the same application and
directory is unframed (`unframeClientWindow:root:`, with the frame's and the
window's event masks cleared first so the X server's unmap and remap during
the reparent end nothing), gets `WM_TRANSIENT_FOR` = the new client and is
attached like a freshly started flip side. A terminal that never showed its
window is still told to quit with its window. At startup a `flipside` window
without a parent (an orphan of the window manager before) is framed the same
way, but is no longer matched to a window.

## Build

```sh
cd WindowManager && make
```

Single `make` invocation. No framework to build first. All XCB abstraction
sources compile directly into the application binary.

## Key Design Decisions

1. **No separate framework.** XCBKit was merged into the application to
   eliminate the two-stage build, simplify deployment, and remove circular
   dependency potential. The XCB abstraction layer remains logically
   separated via the `xcb/` directory.

2. **Geometry types in XCBTypes.h.** The geometry primitives (`XCBPoint`,
   `XCBSize`, `XCBRect`, `XCBColor`) live in `xcb/XCBTypes.h` — distinct
   from `XCBShape.h/m` which wraps the X11 Shape extension class.

3. **Include paths over path prefixes.** The GNUmakefile adds `-Ixcb`,
   `-Ixcb/services`, `-Ixcb/enums`, `-Ixcb/utils` so all headers can be
   imported by name alone: `#import "XCBConnection.h"`,
   `#import "EWMHService.h"`. No `../` or `<XCBKit/...>` paths.

4. **Dead code removed.** The following unused files were deleted during
   the merge: `XCBKit.h/m` (empty class), `XCBEvent.h/m` (unused wrapper),
   `ERequests.h` (unused enum), `Client.h`/`Server.h` (unused protocols),
   `UROSTitleBar.h/m` (superseded), `UROSWindowDecorator.h/m` (superseded),
   `URSTitlebarTheming.h` (superseded), `URSCompositingManager.m.backup`.

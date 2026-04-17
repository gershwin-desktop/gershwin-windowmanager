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
│
├── URSWindowSwitcher.h/m           Alt-Tab window switcher logic
├── URSWindowSwitcherOverlay.h/m    Window switcher overlay rendering
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

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <xcb/xcb.h>

@class XCBConnection;
@class XCBFrame;
@class XCBWindow;
@class URSFocusManager;
@class URSCompositingManager;

// Live miniatures: with the compositor running, a minimized window can stay
// mapped and be shown, scaled down and live, in a Dock tile of its own
// instead of disappearing into its application's icon.  The window becomes
// invisible and untouchable at its own place (empty input shape) and keeps
// WM_STATE Iconic and _NET_WM_STATE_HIDDEN, so everybody else still sees a
// minimized window; the compositor paints it into the tile.
//
// The protocol with the Dock, advertised as _WINDOW_LIVE_MINIATURE in
// _NET_SUPPORTED:
//
//  - When a minimize starts, the client window is added to the root window's
//    _WINDOW_LIVE_MINIATURES (WINDOW[]), the list of windows that are being
//    minimized or are shown as live miniatures.
//  - A Dock that shows the window makes a tile for it, writes the tile's
//    rect (root pixels) to the client's _NET_WM_ICON_GEOMETRY and then sets
//    the client's _WINDOW_LIVE_MINIATURE (WINDOW) to its own window, above
//    which the miniature is painted.  It keeps _NET_WM_ICON_GEOMETRY current
//    while the tile moves.
//  - A window that has its tile when the minimize animation ends becomes a
//    live miniature; one without is unmapped as always and leaves the list.
//  - A window leaves the list when it is restored, withdrawn or destroyed,
//    and the Dock drops its tile then.  It also leaves it, unmapped as an
//    ordinary minimized window, when its Dock window goes away.
@interface URSLiveMiniatureController : NSObject

@property (weak, nonatomic) URSCompositingManager *compositingManager;
@property (weak, nonatomic) URSFocusManager *focusManager;

- (instancetype)initWithConnection:(XCBConnection *)connection;

// A minimize animation starts for this window.
- (void)minimizeWillStartForFrame:(XCBFrame *)frame client:(XCBWindow *)client;

// The minimize animation has ended.  YES when the window became a live
// miniature, which the caller then must not unmap.
- (BOOL)minimizeDidEndForFrame:(XCBFrame *)frame client:(XCBWindow *)client;

// The window is restored, by whichever path: it is shown at its own place
// again.  Does nothing for a frame that is no live miniature.
- (void)restoreFrame:(XCBFrame *)frame;

- (BOOL)isLiveMiniature:(XCBFrame *)frame;

// Input from the event loop.
- (void)propertyChanged:(xcb_atom_t)atom ofWindow:(xcb_window_t)window;
// A Dock that hides may unmap its window, so only its destruction ends the
// miniatures shown above it.
- (void)windowUnmapped:(xcb_window_t)window;
- (void)windowDestroyed:(xcb_window_t)window;

@end

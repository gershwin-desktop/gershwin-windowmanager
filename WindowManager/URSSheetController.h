/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <xcb/xcb.h>

@class XCBConnection;
@class URSCompositingManager;

// The property a client puts on a window before mapping it to say that the
// window is a sheet of the window its WM_TRANSIENT_FOR names (CARDINAL, 1).
// The Eau theme sets it for every NSApp/NSWindow -beginSheet:...
extern NSString * const URSSheetPropertyName;

// Document-modal sheets: a window marked as a sheet of a decorated window
// hangs from the bottom of that window's titlebar, centred on it, without a
// titlebar of its own.  It moves and resizes along with its parent, stays
// directly above it in the stacking order, and slides out from under the
// titlebar when shown and back when dismissed.
//
// Placement and stacking work with or without compositing; the slide needs
// the compositor.
@interface URSSheetController : NSObject

@property (weak, nonatomic) URSCompositingManager *compositingManager;

- (instancetype)initWithConnection:(XCBConnection *)connection;

// YES when the window is a sheet and has been placed and mapped; the map
// request must then not be handled any further.
- (BOOL)handleMapRequest:(xcb_map_request_event_t *)event;
// YES when the window is a sheet; its position is not the client's to set.
- (BOOL)handleConfigureRequest:(xcb_configure_request_event_t *)event;

- (void)windowMapped:(xcb_window_t)window;
// Call before the compositor learns of the unmap: the slide back starts
// while it still has the sheet's picture.
- (void)windowWillUnmap:(xcb_window_t)window;
- (void)windowDestroyed:(xcb_window_t)window;
- (void)windowConfigured:(xcb_configure_notify_event_t *)event;

@end

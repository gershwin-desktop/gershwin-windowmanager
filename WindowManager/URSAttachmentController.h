/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <xcb/xcb.h>
#import "URSAttachmentSlideEffect.h"

@class XCBConnection;
@class XCBFrame;
@class URSCompositingManager;
@class URSAttachmentRegistry;

// Windows that hang from a decorated parent window instead of being framed
// themselves: sheets and drawers.  A client marks such a window with its
// ICCCM WM_WINDOW_ROLE (see URSWindowRole) and names the parent in
// WM_TRANSIENT_FOR.  The window is never framed; it is placed against its
// parent, moves and resizes along with it, keeps its place in the stacking
// order next to it, is hidden with it, and slides out from under it when
// shown and back when dismissed.  Subclasses say where it goes.
//
// Placement and stacking work with or without compositing; the slide needs
// the compositor.
@interface URSAttachmentController : NSObject

@property (weak, nonatomic) URSCompositingManager *compositingManager;

- (instancetype)initWithConnection:(XCBConnection *)connection;

// The WM_WINDOW_ROLE this controller attaches.
@property (readonly, nonatomic) NSString *role;
// YES when a newly shown window of this kind is what the user answers
// next, so it gets the focus (a sheet, not a drawer).
@property (readonly, nonatomic) BOOL focusesOnMap;

// YES when the window has been attached, placed and mapped; the map
// request must then not be handled any further.
- (BOOL)handleMapRequest:(xcb_map_request_event_t *)event;
// YES when the window carries this controller's role and a parent (whether
// or not it can be attached to it).
- (BOOL)isAttachedKind:(xcb_window_t)window;
// For a window already mapped when the window manager starts: YES when it
// has been attached to its (by then decorated) parent and must not be
// framed.
- (BOOL)adoptMappedWindow:(xcb_window_t)window;
// The client an attached window hangs from, or XCB_NONE.
- (xcb_window_t)parentOfWindow:(xcb_window_t)window;
// The attached windows hanging from a frame or its client.
- (NSArray<NSNumber *> *)attachedWindowsOfWindow:(xcb_window_t)window;
// YES when the window, a client or its frame, has an attached window that
// takes its input, which has then been given the focus.
- (BOOL)passFocusToAttachedWindowOfWindow:(xcb_window_t)window;

// YES when the window is attached; its position is not the client's to set.
- (BOOL)handleConfigureRequest:(xcb_configure_request_event_t *)event;

// The frame was moved or resized by the window manager itself (a drag, an
// interactive resize): its attached windows go along at once, in the same
// batch of requests and before the compositor paints, instead of one
// round trip later on the ConfigureNotify.
- (void)followFrame:(XCBFrame *)frame;

// Also for parents: a restored parent brings its hidden windows back.
- (void)windowMapped:(xcb_window_t)window;
// Call before the compositor learns of the unmap: the slide back starts
// while it still has the window's picture.  Also for parents: a minimised
// parent hides its attached windows.
- (void)windowWillUnmap:(xcb_window_t)window;
- (void)windowDestroyed:(xcb_window_t)window;
- (void)windowConfigured:(xcb_configure_notify_event_t *)event;

// What a subclass decides; the base class does not attach anything by
// itself.  Rects are root pixels, y down; parentFrame is the parent's
// frame, parentContent its client window.

@property (readonly, nonatomic) URSAttachmentRegistry *registry;

// A parent can have only one (a sheet) rather than several (drawers).
- (BOOL)attachesExclusively;
// Directly above the parent's frame (a sheet over the content) or directly
// below it (a drawer behind the parent's edge).
- (BOOL)stacksAboveParent;
// A focus the parent gets belongs to its attached window (a sheet).
- (BOOL)takesParentFocus;
// The way the window comes out of its parent.
- (URSAttachmentEdge)slideEdgeOfWindow:(xcb_window_t)window;

// Called before the window is attached, with the rect its client gave it:
// NO when it cannot hang from this parent and is shown as an ordinary
// window.
- (BOOL)prepareAttachmentOfWindow:(xcb_window_t)window
                             rect:(NSRect)rect
                      parentFrame:(NSRect)parentFrame
                    parentContent:(NSRect)parentContent;
// The size an attached window asks for in a configure request, given its
// current one; what the window manager does not take from the client is
// left as it is.
- (NSSize)sizeOfWindow:(xcb_window_t)window
            forRequest:(xcb_configure_request_event_t *)event
           currentSize:(NSSize)size;
- (NSRect)rectForWindow:(xcb_window_t)window
                   size:(NSSize)size
            parentFrame:(NSRect)parentFrame
          parentContent:(NSRect)parentContent
                 screen:(NSRect)screen;
// The window is no longer attached.
- (void)forgetAttachmentOfWindow:(xcb_window_t)window;

@end

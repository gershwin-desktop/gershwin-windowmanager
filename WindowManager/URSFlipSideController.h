/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSAttachmentController.h"

@class XCBFrame;
@class XCBWindow;

// Defaults key (domain WindowManager), YES unless set to NO: a window turned
// over ("Flip Window") shows a terminal in its application's source
// directory on its back.  Read at every flip.
extern NSString * const URSWindowFlipSideTerminalKey;

// The flip side of a window (WM_WINDOW_ROLE "flipside", WM_TRANSIENT_FOR
// naming the window's client): a terminal the window manager starts in the
// source directory of the window's application (URSSourceDirectory) the first
// time the window is turned over, and shows on the window's back from then on.
//
// It hangs from the client like a sheet but is never seen as a window of its
// own: it covers the client area, stays mapped for as long as the window
// lives (so its shell keeps running and its picture is there to paint), lies
// directly below the frame while the front is shown and directly above it,
// taking the keyboard and the clicks over the client area, once the back is
// in view.  The compositor paints its picture on the back, under the front's
// titlebar, which stays usable (setFlipSideWindow:ofFrame:).
//
// The terminal is the user's shell, so it does not go with its window: when
// the window goes (its application quits, is killed or closes it), the
// terminal stays where it was as a window of its own, decorated, an
// orphan.  The next plain window of the same application (WM_CLASS) in the
// same source directory takes the oldest such orphan back as its flip side.
// Closing the orphan ends its terminal.
@protocol URSFlipSideFraming <NSObject>
// Frames a mapped window that has no frame as an ordinary window although
// its hints ask for none (-[XCBConnection
// frameNextMapOfWindow:asOrdinaryClosedBy:]), with what any newly framed
// window gets; its client, or nil when it could not be framed.
- (XCBWindow *)frameWindowAsOrdinary:(xcb_window_t)window closeHandler:(void (^)(void))closeHandler;
@end

@interface URSFlipSideController : URSAttachmentController

@property (weak, nonatomic) id<URSFlipSideFraming> framer;

// "Flip Window": turns the frame over to its back (with its flip side if it
// has one or can get one) or back to its front.
- (void)flipFrame:(XCBFrame *)frame;

// Whether "Flip Window" can do something for the frame.  With the flip side
// on, a window whose application has no source directory has nothing to put
// on its back, so it is not offered; a window that already shows or waits
// for its back always can, so that it can go back to the front.
- (BOOL)canFlipFrame:(XCBFrame *)frame;

// Every PropertyNotify: the terminal names its window's role and parent only
// after asking for the map.
- (void)windowPropertyChanged:(xcb_property_notify_event_t *)event;

// A client window has just been framed: an orphan of its application may
// go back onto it.
- (void)clientWindowFramed:(XCBWindow *)client;

// When the window manager starts, for a window not yet adopted: YES for an
// orphan from the window manager before this one, which is framed as an
// ordinary window (it no longer goes back onto a window: what it belonged
// to is not known any more).
- (BOOL)isOrphanedFlipSide:(xcb_window_t)window;
// The close handler of such a window: it ends the window's process.
- (void (^)(void))closeHandlerForAdoptedOrphan:(xcb_window_t)window;

// The terminals outlive the window manager; it only lets go of them.
- (void)windowManagerWillExit;

@end

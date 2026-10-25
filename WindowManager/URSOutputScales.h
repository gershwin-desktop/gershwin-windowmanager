/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The scale factor of every lit monitor, from its RandR output property
// "DPI" (96 = 1.0x, written by XLibre or by the display configuration), and
// which monitor each window frame is decorated for.  The one place in the
// window manager that knows the factors; a frame only keeps the output and
// factor it is decorated at (XCBFrame decorationOutput/decorationScaleFactor).
//
// Per-monitor factors apply only while the monitors are mixed (two or more
// factors) and the theme can draw at a given factor; otherwise every frame
// stays at factor 0, the global GSScaleFactor, as before.

#import <Foundation/Foundation.h>
#import <xcb/xcb.h>

@class XCBConnection;
@class XCBFrame;

@interface URSOutputScales : NSObject

+ (instancetype)sharedScales;

// Read the lit outputs, their rectangles and DPI properties again.
- (void)reloadWithConnection:(XCBConnection *)connection;

// Whether per-monitor factors are in force.
- (BOOL)mixed;

// The atom of the "DPI" output property, XCB_NONE until it exists.
- (xcb_atom_t)scaleAtom;

// The factor and output for a frame about to be created at `rect`;
// 0 and XCB_NONE when the global factor applies.
- (CGFloat)factorForNewFrameRect:(NSRect)rect utility:(BOOL)utility
                          output:(uint32_t *)output;

// Decide again which output `frame` (now at `rect`) belongs to and store
// it on the frame.  YES when the frame's factor changed, so its decoration
// has to follow.
- (BOOL)updateFrame:(XCBFrame *)frame forRect:(NSRect)rect;

// The same, also when the frame has not moved since it was last decided
// (map time, a monitor or DPI change); -updateFrame:forRect: decides only
// after a move.
- (BOOL)updateFrame:(XCBFrame *)frame forRect:(NSRect)rect force:(BOOL)force;

@end

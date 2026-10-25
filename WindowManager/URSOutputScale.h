/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The arithmetic behind per-monitor scale factors: a monitor's factor from
// its RandR "DPI" output property, whether the monitors are mixed, which
// monitor a window frame belongs to while it is dragged across, and the
// frame extents a client is told.  Foundation only, so it is tested
// headless (test-outputscale).  Rectangles are X screen coordinates.

#import <Foundation/Foundation.h>

// The DPI that means a factor of 1.0 (XLibre's default for the property).
extern const long URSOutputBaseDPI;

// How far, in pixels across the frame, another monitor must hold more of a
// frame than its current monitor before the frame changes monitors.
extern const CGFloat URSOutputHysteresis;

// The factor a monitor with the given DPI property asks for, or 0 when the
// value cannot be a DPI (no property, zero, negative).
CGFloat URSScaleFactorForDPI(long dpi);

// YES when at least two of `factors` (NSNumber, 0 = unknown, ignored)
// differ.  Only then are per-monitor factors used; with one factor
// everywhere the global GSScaleFactor stays in force as before.
BOOL URSOutputScalesAreMixed(NSArray *factors);

// How a frame is decorated at some factor: the title bar height and the
// client border it gets there.
typedef struct {
    CGFloat factor;
    CGFloat titleHeight;
    CGFloat border;
} URSDecoration;

// The index into `outputs` (NSValue rects) of the monitor `frame` belongs
// to.  `factors` holds the factor of each output, `now` how the frame is
// decorated at present, `current` the output it is decorated for (or
// NSNotFound) and `content` the client's size in points, as laid out at the
// factor it last followed.  This is the rule libs-gui applies to the window
// inside, so that both switch at the same place.  Only the output holding
// the largest part of the frame as it is (libs-gui's -screen) can take it,
// and only when it holds more of the frame as libs-gui would make it there
// - the content at that output's factor in whole pixels plus the present
// title bar and border (the extents the client knows), top-left corner kept
// - than the outputs of the present factor hold of the frame now, by
// URSOutputHysteresis * the shorter side of that frame.  When the frame lies
// on no output of its present factor, the output with the largest overlap
// wins; NSNotFound when it overlaps none.  Without a switch the output of
// the present factor holding most of the frame is answered.
NSUInteger URSOutputForFrame(NSRect frame, NSArray *outputs, const CGFloat *factors,
                             NSUInteger current, URSDecoration now, NSSize content);

// _NET_FRAME_EXTENTS of a framed client: left, right, top, bottom.
typedef struct {
    uint32_t left, right, top, bottom;
} URSFrameExtents;

// The client border is one pixel per whole scale step without the
// compositor and none with it (the shadow separates the window), unless the
// theme draws a border of its own (`themeBorder` > 0), which then decides.
uint32_t URSClientBorderFor(CGFloat scaleFactor, BOOL compositorActive,
                            CGFloat themeBorder);

URSFrameExtents URSFrameExtentsFor(uint16_t titleHeight, CGFloat scaleFactor,
                                   BOOL compositorActive, CGFloat themeBorder);

// Utility panels have a fixed 16 pt title bar at every theme.
uint16_t URSUtilityTitleHeightFor(CGFloat scaleFactor);

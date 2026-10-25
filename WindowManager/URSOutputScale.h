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

// The index into `outputs` (NSValue rects) of the monitor `frame` belongs
// to.  `titleHeights` holds the title bar height a frame gets on each
// output, `current` the output the frame is decorated for now (or
// NSNotFound) and `currentTitleHeight` the title bar height it has there.
// Without a current output, or when the frame left it entirely, the output
// with the largest overlap wins; NSNotFound when it overlaps none.
// Otherwise another output takes the frame only when, with the frame
// resized to that output's title bar height (top edge fixed), it holds more
// than URSOutputHysteresis * min(width, height) pixels more of it than the
// current one.
NSUInteger URSOutputForFrame(NSRect frame, NSArray *outputs,
                             NSArray *titleHeights, NSUInteger current,
                             CGFloat currentTitleHeight);

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

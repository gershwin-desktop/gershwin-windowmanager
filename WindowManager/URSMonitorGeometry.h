/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Geometry of several monitors: the area of each monitor that windows may
// use under the panels' struts, the one rectangle published as
// _NET_WORKAREA, and where a window goes when the monitor it was on went
// away.  All rectangles are X screen coordinates (y grows downwards).
// Foundation only, so it is tested headless (test-displayrescue).

#import <Foundation/Foundation.h>

// A strut as the workarea manager stores it: NSNumbers under "left",
// "right", "top", "bottom" (pixels from the screen edge, per EWMH) and, for
// _NET_WM_STRUT_PARTIAL, "left_start_y" ... "bottom_end_x".  A strut without
// ranges covers the whole edge.

// The part of `monitor` that is not reserved by any strut.  A strut belongs
// to the monitor its inner edge lies on, within its start/end range, and
// reserves from that monitor's edge to the inner edge: a menu bar along the
// top of a monitor that sits below another one reserves only the bar on the
// lower monitor, not the whole upper one.
NSRect URSUsableRectForMonitor(NSRect monitor, NSSize screen, NSArray *struts);

// The single _NET_WORKAREA rectangle: the screen minus the struts that
// belong to a monitor touching the same screen edge.  Struts on inner edges
// are left out, because clients (and window dragging) treat _NET_WORKAREA
// as the area of every monitor.
NSRect URSWorkareaForScreen(NSSize screen, NSArray *monitors, NSArray *struts);

// The monitor a window belongs to: the one its frame overlaps most, else
// the primary.  Indexes `monitors` (NSValue rects).
NSUInteger URSMonitorIndexForRect(NSRect frame, NSArray *monitors, NSUInteger primary);

// What maximize fills: the usable rect (`usable`, same order as `monitors`)
// of the window's monitor, never the whole screen across monitors.
NSRect URSMaximizedRect(NSRect frame, NSArray *monitors, NSArray *usable, NSUInteger primary);

// What fullscreen fills: the window's whole monitor, struts included.
NSRect URSFullscreenRect(NSRect frame, NSArray *monitors, NSUInteger primary);

// Whether `point` lies on one of `rects` (NSValue rects).
BOOL URSPointIsOnRects(NSPoint point, NSArray *rects);

// Where a window frame goes after the monitors changed.  `usable` holds the
// usable rect of every lit monitor (NSValue), `primary` indexes it.  A frame
// whose title bar (the top `titlebarHeight` pixels) lies on a monitor with
// at least a grip's width keeps its place.  Otherwise it goes onto the
// monitor it overlaps most, or, when it overlaps none, centered onto the
// primary; it keeps its size where it fits and is shrunk to the monitor
// when `resizable`, else it is put at the monitor's top-left corner.
NSRect URSRescueFrame(NSRect frame, CGFloat titlebarHeight, NSArray *usable,
                      NSUInteger primary, BOOL resizable);

// The narrowest piece of title bar a user can still grab and drag.
extern const CGFloat URSRescueMinimumGrip;

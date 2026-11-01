/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The pointer's size per monitor: the theme cursor is loaded at
// URSCursorBaseSize x the factor of the monitor it is shown on, the same
// rule libs-back applies inside GNUstep windows, so the pointer keeps its
// size when it passes from a window to its frame or to the desktop.
// Foundation only, so it is tested headless (test-cursorsize).  Rectangles
// are X screen coordinates.

#import <Foundation/Foundation.h>

// The pixel size of a theme cursor at factor 1.0: what libXcursor picks by
// itself for a 1920x1080 screen and the nominal size of the common themes.
extern const uint32_t URSCursorBaseSize;

// The pixel size to load a theme cursor at for `factor`, or 0 for the size
// libXcursor chooses itself, which is kept when every monitor runs at
// exactly 1.0 (`allFactorsOne`) so such setups look as before.
uint32_t URSCursorPixelSize(CGFloat factor, BOOL allFactorsOne);

// Whether every monitor runs at 1.0: `factors` (NSNumber per output) are
// not mixed and the global factor (GSScaleFactor, 0 = unset) is 1.0.
BOOL URSCursorFactorsAllOne(NSArray *factors, CGFloat globalFactor);

// The factor the pointer has at `point`: the factor of the output there
// while the outputs' factors are mixed (the first output's when the point is
// on none), the global factor otherwise (1.0 when it is unset).
CGFloat URSCursorFactorAtPoint(NSPoint point, NSArray *rects, NSArray *factors,
                               CGFloat globalFactor);

// `resources` (the RESOURCE_MANAGER string) with Xcursor.size set to
// `size`, or without an Xcursor.size line when `size` is 0.  Other
// applications read it once at startup and cannot follow the monitors.
NSString *URSResourcesWithCursorSize(NSString *resources, uint32_t size);

// The value of `key` in a resource string, nil when it is not set.
NSString *URSResourceValue(NSString *resources, NSString *key);

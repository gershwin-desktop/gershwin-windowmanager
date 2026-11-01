/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Edge snap detection constants
#define SNAP_EDGE_THRESHOLD 5    // Pixels from screen edge to trigger snap detection
#define SNAP_CORNER_THRESHOLD 50 // Pixels from corner to trigger quarter snap
#define SNAP_LINGER_TIME 300     // Milliseconds to linger before snap activates
#define SNAP_LEAVE_DISTANCE 8    // Pixels a snapped window is dragged before it unsnaps

// Snap zone types for drag-to-edge window snapping
typedef NS_ENUM(NSInteger, SnapZone) {
    SnapZoneNone = 0,
    SnapZoneTop,         // Maximize window
    SnapZoneLeft,        // Snap to left half
    SnapZoneRight,       // Snap to right half
    SnapZoneTopLeft,     // Snap to top-left quarter
    SnapZoneTopRight,    // Snap to top-right quarter
    SnapZoneBottomLeft,  // Snap to bottom-left quarter
    SnapZoneBottomRight  // Snap to bottom-right quarter
};

// The zone a window dragged by its titlebar snaps into when the pointer is
// released at (x, y), given the workarea.  Every snap resizes the window,
// so a window whose size is fixed has no zone at all: no preview may offer
// it a size it cannot take.
SnapZone URSSnapZoneForPointer(int32_t x, int32_t y,
                               int32_t areaX, int32_t areaY,
                               uint32_t areaWidth, uint32_t areaHeight,
                               BOOL windowResizable);

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef URSResizeGeometry_h
#define URSResizeGeometry_h

#include <stdint.h>

// Frame-relative rectangle of one input-only resize zone.
typedef struct {
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
} URSZoneRect;

// Where every resize zone sits for a frame of a given size.  growBox is
// all zero when the theme has none; se is then the bottom-right zone.
typedef struct {
    URSZoneRect nw, n, ne, e, se, s, sw, w;
    URSZoneRect growBox;
} URSResizeZoneLayout;

// growBoxSize 0 means the theme has no grow box.
URSResizeZoneLayout URSResizeZoneLayoutForFrame(int32_t frameWidth,
                                                int32_t frameHeight,
                                                int32_t cornerSize,
                                                int32_t edgeThickness,
                                                int32_t growBoxSize);

// Distance from the pointer to each frame edge at the moment a resize
// starts.  An edge being dragged keeps that distance to the pointer, so
// the window does not jump to the pointer on the first motion and comes
// back to its old size when the pointer comes back to where it pressed.
typedef struct {
    int32_t toLeft;
    int32_t toTop;
    int32_t toRight;
    int32_t toBottom;
} URSResizeGrab;

// pointerX/pointerY are relative to the frame.
URSResizeGrab URSResizeGrabMake(int32_t pointerX, int32_t pointerY,
                                int32_t frameWidth, int32_t frameHeight);

// Root x/y of the left/top edge for a root pointer position.
int32_t URSResizeGrabLeftEdge(URSResizeGrab grab, int32_t rootX);
int32_t URSResizeGrabTopEdge(URSResizeGrab grab, int32_t rootY);

// Frame width/height for a frame-relative pointer position.
int32_t URSResizeGrabWidth(URSResizeGrab grab, int32_t pointerX);
int32_t URSResizeGrabHeight(URSResizeGrab grab, int32_t pointerY);

#endif

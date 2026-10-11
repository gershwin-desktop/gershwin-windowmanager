/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

// Without a compositor there is no drop shadow, and a window whose content
// is white melts into a white window or desktop behind it.  The window
// manager then draws a thin mid grey line all around each window: the frame
// shows it in the strips it leaves beside and below the client, and the
// titlebar draws it along its top and sides with these.

// The grey as an X pixel, for the frame's background.
uint32_t URSWindowOutlinePixel(void);

// The same grey for drawing into a titlebar image.
NSColor *URSWindowOutlineColor(void);

// How many pixels a rounded corner of the radius cuts from the side of a
// window in its row-th row, counted from the outermost row: the pixels
// whose centres lie outside the corner's circle.  XCBShape cuts the
// corners with this, rather than letting the X server fill arcs, so that
// the line below can be put exactly on the pixels the shape keeps.
int URSCornerCut(int radius, int row);

// The pixels of the line along the left, top and right edge of a
// titlebar's visible part (y up, whole pixels), as rectangles to fill: the
// outermost pixels the shape keeps, following the corners URSCornerCut
// rounds.  Open at the bottom, where the frame's strips carry the line on.
NSArray *URSTitlebarOutlineRects(NSRect visibleRect,
                                 int cornerRadius,
                                 int lineWidth);

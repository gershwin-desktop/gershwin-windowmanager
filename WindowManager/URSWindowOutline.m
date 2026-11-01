/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWindowOutline.h"
#import <math.h>
#import <limits.h>

// Dark enough to stand out against white, light enough not to look like a
// heavy frame against the dark desktop.
static const uint8_t kOutlineGrey = 0x80;

uint32_t URSWindowOutlinePixel(void)
{
    return ((uint32_t)kOutlineGrey << 16) | ((uint32_t)kOutlineGrey << 8) | kOutlineGrey;
}

NSColor *URSWindowOutlineColor(void)
{
    CGFloat level = kOutlineGrey / 255.0;
    return [NSColor colorWithDeviceRed:level green:level blue:level alpha:1.0];
}

int URSCornerCut(int radius, int row)
{
    double dy, halfChord;

    if (row < 0) {
        return INT_MAX;
    }
    if (radius <= 0 || row >= radius) {
        return 0;
    }
    // The circle's centre is radius pixels in from both edges; pixel x is
    // kept when its centre x + 0.5 lies within the chord of its row.
    dy = radius - (row + 0.5);
    halfChord = sqrt((double)radius * radius - dy * dy);
    return (int)ceil(radius - halfChord - 0.5);
}

static void addRun(NSMutableArray *rects, int x0, int x1, int y)
{
    if (x1 > x0) {
        [rects addObject:[NSValue valueWithRect:NSMakeRect(x0, y, x1 - x0, 1)]];
    }
}

NSArray *URSTitlebarOutlineRects(NSRect visibleRect,
                                 int cornerRadius,
                                 int lineWidth)
{
    NSMutableArray *rects = [NSMutableArray array];
    int left = (int)NSMinX(visibleRect);
    int right = (int)NSMaxX(visibleRect);
    int bottom = (int)NSMinY(visibleRect);
    int top = (int)NSMaxY(visibleRect);
    int width = right - left;
    // A tiny window cannot hold the full radius; XCBShape clamps the same.
    int radius = MAX(0, MIN(cornerRadius, MIN(width / 2, top - bottom)));
    int y;

    if (lineWidth <= 0 || width <= 0 || top <= bottom) {
        return rects;
    }
    for (y = bottom; y < top; y++) {
        int row = top - 1 - y;
        int cut = URSCornerCut(radius, row);
        int above = URSCornerCut(radius, row - lineWidth);
        // A kept pixel is on the line when the pixel a line width further
        // out, sideways or upwards, is cut away (or outside the window).
        int span = (above == INT_MAX) ? width : MAX(cut + lineWidth, MIN(above, width));
        int leftEnd = left + MIN(span, width);
        int rightStart = right - MIN(span, width);

        if (leftEnd >= rightStart) {
            addRun(rects, left + cut, right - cut, y);
        } else {
            addRun(rects, left + cut, leftEnd, y);
            addRun(rects, rightStart, right - cut, y);
        }
    }
    return rects;
}

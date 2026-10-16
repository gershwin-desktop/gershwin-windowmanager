/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSTriangleSpans.h"
#import <math.h>

// Two pixel rows per span halve what is sent to the X server for every
// triangle; the outline of a moving window does not show the steps.
const int16_t URSTriangleSpanHeight = 2;

// Where the edge crosses the row sampled at y.  The end points are ordered
// the same way for both triangles sharing the edge, so both get the very
// same number and meet without a gap or an overlap.
static BOOL URSEdgeCrossing(NSPoint p, NSPoint q, double y, double *x) {
    if (p.y > q.y) {
        NSPoint t = p;
        p = q;
        q = t;
    } else if (p.y == q.y && p.x > q.x) {
        NSPoint t = p;
        p = q;
        q = t;
    }
    // Half open, so a row through a shared vertex is counted once.
    if (!(p.y <= y && y < q.y)) {
        return NO;
    }
    *x = p.x + (y - p.y) * (q.x - p.x) / (q.y - p.y);
    return YES;
}

NSUInteger URSTriangleSpans(NSPoint a, NSPoint b, NSPoint c,
                            xcb_rectangle_t *spans, NSUInteger capacity) {
    double top = MIN(a.y, MIN(b.y, c.y));
    double bottom = MAX(a.y, MAX(b.y, c.y));
    // Rows on one grid for every triangle, each sampled at its middle.
    int32_t firstRow = (int32_t)floor(top / URSTriangleSpanHeight) * URSTriangleSpanHeight;
    NSUInteger count = 0;
    for (int32_t row = firstRow; row < bottom && count < capacity; row += URSTriangleSpanHeight) {
        double sampleY = row + URSTriangleSpanHeight * 0.5;
        double crossings[3];
        int found = 0;
        double x;
        if (URSEdgeCrossing(a, b, sampleY, &x)) crossings[found++] = x;
        if (URSEdgeCrossing(b, c, sampleY, &x)) crossings[found++] = x;
        if (URSEdgeCrossing(c, a, sampleY, &x)) crossings[found++] = x;
        if (found < 2) {
            continue;
        }
        double left = MIN(crossings[0], crossings[1]);
        double right = MAX(crossings[0], crossings[1]);
        // A pixel belongs to the span when its middle lies in [left, right).
        int32_t x1 = (int32_t)ceil(left - 0.5);
        int32_t x2 = (int32_t)ceil(right - 0.5);
        if (x2 <= x1) {
            continue;
        }
        spans[count++] = (xcb_rectangle_t){ (int16_t)x1, (int16_t)row,
                                            (uint16_t)(x2 - x1), (uint16_t)URSTriangleSpanHeight };
    }
    return count;
}

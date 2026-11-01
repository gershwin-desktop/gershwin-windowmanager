/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <xcb/xcb.h>

// Rows of URSTriangleSpanHeight pixels a triangle is cut into.
extern const int16_t URSTriangleSpanHeight;

// The pixel rows (spans) a triangle covers, as rectangles.  Two triangles
// that share an edge get spans that neither overlap nor leave a gap, so a
// mesh of triangles painted one by one covers every pixel exactly once.
// This is what lets a bent window be painted with plain composites, which
// the X server can do on the GPU, where RenderTriangles is done on the CPU.
// Writes at most capacity spans and returns how many there are.
NSUInteger URSTriangleSpans(NSPoint a, NSPoint b, NSPoint c,
                            xcb_rectangle_t *spans, NSUInteger capacity);

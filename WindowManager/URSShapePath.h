/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * The outline a client asks for with the _WM_SHAPE_PATH property on its
 * window: a path of lines and cubic Bezier curves.  Every point is a
 * fraction of the window's size plus an offset in pixels, so the outline
 * fits any size the window is given, also in the middle of a resize.
 *
 * Property format: 32-bit integers, first the version (1), then commands:
 *   0 move to   (1 point)     2 curve to (3 points: control, control, end)
 *   1 line to   (1 point)     3 close
 * A point is four 16.16 fixed-point numbers fx, ox, fy, oy standing for
 * x = fx * width + ox and y = fy * height + oy, in pixels of the client
 * window, origin at its top left, y growing downwards.  The window shows
 * what the path encloses.
 */

enum {
    URSShapePathMove = 0,
    URSShapePathLine = 1,
    URSShapePathCurve = 2,
    URSShapePathClose = 3
};

typedef struct {
    int16_t x;
    int16_t y;
    uint16_t width;
    uint16_t height;
} URSShapeRect;

@interface URSShapePath : NSObject
{
    NSData *_values;
    int _cachedWidth;
    int _cachedHeight;
    NSData *_cachedCoverage;
}

/// nil when the values are not a path this version understands.
+ (instancetype)shapePathWithValues:(const int32_t *)values count:(NSUInteger)count;

/// How much of each pixel the outline covers at this window size, 0-255,
/// row by row from the top.  The last size asked for is kept.
- (NSData *)coverageForWidth:(int)width height:(int)height;

- (BOOL)isEqualToShapePath:(URSShapePath *)other;

@end

/// The pixels covered at least `threshold` (1-255) as rectangles, rows with
/// the same runs merged into one rectangle.  NSData of URSShapeRect.
NSData *URSShapeRects(NSData *coverage, int width, int height, unsigned threshold);

/// The rectangles grown by `margin` on every side, kept within the window.
NSData *URSShapeRectsGrown(NSData *rects, int margin, int width, int height);


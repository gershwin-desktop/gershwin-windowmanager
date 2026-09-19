/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSShapePath.h"
#include <math.h>

static const int32_t URSShapePathVersion = 1;
static const int URSShapePathValuesPerPoint = 4;

static int pointsForCommand(int32_t command)
{
    switch (command) {
    case URSShapePathMove:
    case URSShapePathLine:
        return 1;
    case URSShapePathCurve:
        return 3;
    case URSShapePathClose:
        return 0;
    default:
        return -1;
    }
}

static double fixedToDouble(int32_t v)
{
    return v / 65536.0;
}

/*
 * Coverage is found by accumulating, for every edge, how much it adds to or
 * takes from the area to its right in each pixel it passes (signed by its
 * direction); a running sum over each row then gives the covered part of
 * every pixel exactly, which is what makes the edges smooth.
 */
typedef struct {
    float *cells;       // width * height + 2, the extra for edges at x = width
    int width;
    int height;
} URSAccumulator;

static void accumulateLine(URSAccumulator *acc, double x0, double y0, double x1, double y1)
{
    if (fabs(y0 - y1) < 1e-9) {
        return;
    }
    double dir = 1.0;
    if (y0 > y1) {
        double t;
        t = x0; x0 = x1; x1 = t;
        t = y0; y0 = y1; y1 = t;
        dir = -1.0;
    }
    // Outside the window left or right counts as its edge
    x0 = fmin(fmax(x0, 0.0), acc->width);
    x1 = fmin(fmax(x1, 0.0), acc->width);

    double dxdy = (x1 - x0) / (y1 - y0);
    double x = x0;
    if (y0 < 0) {
        x -= y0 * dxdy;
    }
    int yStart = (int)fmax(0.0, floor(y0));
    int yEnd = (int)fmin(acc->height, ceil(y1));

    for (int y = yStart; y < yEnd; y++) {
        long rowStart = (long)y * acc->width;
        double dy = fmin(y + 1.0, y1) - fmax((double)y, y0);
        double xNext = x + dxdy * dy;
        double d = dy * dir;
        double left = fmin(x, xNext);
        double right = fmax(x, xNext);
        double leftFloor = floor(left);
        int leftCell = (int)leftFloor;
        double rightCeil = ceil(right);
        int rightCell = (int)rightCeil;

        if (rightCell <= leftCell + 1) {
            double middle = 0.5 * (x + xNext) - leftFloor;
            acc->cells[rowStart + leftCell] += d - d * middle;
            acc->cells[rowStart + leftCell + 1] += d * middle;
        } else {
            double s = 1.0 / (right - left);
            double leftFrac = left - leftFloor;
            double a0 = 0.5 * s * (1.0 - leftFrac) * (1.0 - leftFrac);
            double rightFrac = right - rightCeil + 1.0;
            double am = 0.5 * s * rightFrac * rightFrac;
            acc->cells[rowStart + leftCell] += d * a0;
            if (rightCell == leftCell + 2) {
                acc->cells[rowStart + leftCell + 1] += d * (1.0 - a0 - am);
            } else {
                double a1 = s * (1.5 - leftFrac);
                acc->cells[rowStart + leftCell + 1] += d * (a1 - a0);
                for (int cell = leftCell + 2; cell < rightCell - 1; cell++) {
                    acc->cells[rowStart + cell] += d * s;
                }
                double a2 = a1 + (rightCell - leftCell - 3) * s;
                acc->cells[rowStart + rightCell - 1] += d * (1.0 - a2 - am);
            }
            acc->cells[rowStart + rightCell] += d * am;
        }
        x = xNext;
    }
}

@implementation URSShapePath

+ (instancetype)shapePathWithValues:(const int32_t *)values count:(NSUInteger)count
{
    if (count < 1 || values[0] != URSShapePathVersion) {
        return nil;
    }
    BOOL hasOutline = NO;
    NSUInteger i = 1;
    while (i < count) {
        int points = pointsForCommand(values[i]);
        if (points < 0) {
            return nil;
        }
        if (values[i] != URSShapePathMove && values[i] != URSShapePathClose) {
            hasOutline = YES;
        }
        i += 1 + (NSUInteger)points * URSShapePathValuesPerPoint;
    }
    if (i != count || !hasOutline) {
        return nil;
    }

    URSShapePath *path = [[self alloc] init];
    path->_values = [[NSData alloc] initWithBytes:values length:count * sizeof(int32_t)];
    return path;
}

- (BOOL)isEqualToShapePath:(URSShapePath *)other
{
    return other != nil && [_values isEqualToData:other->_values];
}

- (NSData *)coverageForWidth:(int)width height:(int)height
{
    if (width <= 0 || height <= 0) {
        return [NSData data];
    }
    if (_cachedCoverage && width == _cachedWidth && height == _cachedHeight) {
        return _cachedCoverage;
    }

    URSAccumulator acc;
    acc.width = width;
    acc.height = height;
    acc.cells = calloc((size_t)width * height + 2, sizeof(float));
    if (!acc.cells) {
        return [NSData data];
    }

    const int32_t *v = [_values bytes];
    NSUInteger count = [_values length] / sizeof(int32_t);
    double startX = 0, startY = 0, penX = 0, penY = 0;
    NSUInteger i = 1;
    while (i < count) {
        int32_t command = v[i++];
        double px[3], py[3];
        int points = pointsForCommand(command);
        for (int p = 0; p < points; p++) {
            const int32_t *q = v + i + p * URSShapePathValuesPerPoint;
            px[p] = fixedToDouble(q[0]) * width + fixedToDouble(q[1]);
            py[p] = fixedToDouble(q[2]) * height + fixedToDouble(q[3]);
        }
        i += (NSUInteger)points * URSShapePathValuesPerPoint;

        switch (command) {
        case URSShapePathMove:
            // An open figure is closed before the next one starts
            accumulateLine(&acc, penX, penY, startX, startY);
            startX = penX = px[0];
            startY = penY = py[0];
            break;
        case URSShapePathLine:
            accumulateLine(&acc, penX, penY, px[0], py[0]);
            penX = px[0];
            penY = py[0];
            break;
        case URSShapePathCurve: {
            // Short enough straight pieces that no step shows at any size
            double length = hypot(px[0] - penX, py[0] - penY)
                          + hypot(px[1] - px[0], py[1] - py[0])
                          + hypot(px[2] - px[1], py[2] - py[1]);
            int pieces = (int)fmin(512.0, fmax(4.0, ceil(length / 4.0)));
            double lastX = penX, lastY = penY;
            for (int k = 1; k <= pieces; k++) {
                double t = (double)k / pieces;
                double u = 1.0 - t;
                double x = u * u * u * penX + 3 * u * u * t * px[0]
                         + 3 * u * t * t * px[1] + t * t * t * px[2];
                double y = u * u * u * penY + 3 * u * u * t * py[0]
                         + 3 * u * t * t * py[1] + t * t * t * py[2];
                accumulateLine(&acc, lastX, lastY, x, y);
                lastX = x;
                lastY = y;
            }
            penX = px[2];
            penY = py[2];
            break;
        }
        case URSShapePathClose:
            accumulateLine(&acc, penX, penY, startX, startY);
            penX = startX;
            penY = startY;
            break;
        }
    }
    accumulateLine(&acc, penX, penY, startX, startY);

    NSMutableData *coverage = [NSMutableData dataWithLength:(NSUInteger)width * height];
    uint8_t *out = [coverage mutableBytes];
    double sum = 0.0;
    for (long k = 0; k < (long)width * height; k++) {
        sum += acc.cells[k];
        out[k] = (uint8_t)lround(fmin(fabs(sum), 1.0) * 255.0);
    }
    free(acc.cells);

    _cachedCoverage = coverage;
    _cachedWidth = width;
    _cachedHeight = height;
    return coverage;
}

@end

NSData *URSShapeRects(NSData *coverage, int width, int height, unsigned threshold)
{
    NSMutableData *rects = [NSMutableData data];
    const uint8_t *c = [coverage bytes];
    if ([coverage length] < (NSUInteger)width * height) {
        return rects;
    }
    // Rectangles of the rows above that are still growing downwards
    NSUInteger openStart = 0;

    for (int y = 0; y < height; y++) {
        const uint8_t *row = c + (long)y * width;
        NSMutableData *runs = [NSMutableData data];
        int x = 0;
        while (x < width) {
            while (x < width && row[x] < threshold) x++;
            if (x >= width) break;
            int start = x;
            while (x < width && row[x] >= threshold) x++;
            URSShapeRect r = { (int16_t)start, (int16_t)y, (uint16_t)(x - start), 1 };
            [runs appendBytes:&r length:sizeof(r)];
        }

        URSShapeRect *open = (URSShapeRect *)[rects mutableBytes] + openStart;
        NSUInteger openCount = [rects length] / sizeof(URSShapeRect) - openStart;
        const URSShapeRect *now = [runs bytes];
        NSUInteger nowCount = [runs length] / sizeof(URSShapeRect);
        BOOL same = (openCount == nowCount);
        for (NSUInteger k = 0; same && k < nowCount; k++) {
            same = (open[k].x == now[k].x && open[k].width == now[k].width);
        }
        if (same && openCount > 0) {
            for (NSUInteger k = 0; k < openCount; k++) {
                open[k].height++;
            }
        } else {
            openStart = [rects length] / sizeof(URSShapeRect);
            [rects appendData:runs];
        }
    }
    return rects;
}

NSData *URSShapeRectsGrown(NSData *rects, int margin, int width, int height)
{
    NSMutableData *grown = [NSMutableData dataWithData:rects];
    URSShapeRect *r = [grown mutableBytes];
    NSUInteger count = [grown length] / sizeof(URSShapeRect);
    for (NSUInteger i = 0; i < count; i++) {
        int x0 = MAX(0, r[i].x - margin);
        int y0 = MAX(0, r[i].y - margin);
        int x1 = MIN(width, r[i].x + r[i].width + margin);
        int y1 = MIN(height, r[i].y + r[i].height + margin);
        r[i].x = (int16_t)x0;
        r[i].y = (int16_t)y0;
        r[i].width = (uint16_t)(x1 - x0);
        r[i].height = (uint16_t)(y1 - y0);
    }
    return grown;
}

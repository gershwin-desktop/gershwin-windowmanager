/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSAttachedDeformation.h"
#import "URSWobblyModel.h"
#import <math.h>

// Below this the parent's bend is invisible; the same resting threshold as
// the wobbly model's, in pixels.
static const double URSAttachedRestBend = 0.25;

@implementation URSAttachedDeformation
{
    NSRect _windowRect;
    NSRect _reach;
}

- (instancetype)initWithParent:(URSWobblyModel *)parent
{
    self = [super init];
    if (self) {
        _parent = parent;
    }
    return self;
}

- (BOOL)followsOtherDeformation
{
    return YES;
}

// As fine as the parent's, so the seam has as many points on either side.
- (NSUInteger)columns
{
    return [_parent columns];
}

- (NSUInteger)rows
{
    return [_parent rows];
}

// How far the parent's picture is moved at a point of its flat rect: its
// mesh displacements blended across the cell the point falls in.  Points
// outside the parent take the displacement of the nearest point on its
// edge, so an attached window rides along that edge.
- (NSPoint)parentDisplacementAt:(NSPoint)p
{
    NSRect r = [_parent windowRect];
    NSUInteger columns = [_parent columns], rows = [_parent rows];
    double u = (MIN(MAX(p.x, NSMinX(r)), NSMaxX(r)) - NSMinX(r)) / MAX(1.0, NSWidth(r)) * columns;
    double v = (MIN(MAX(p.y, NSMinY(r)), NSMaxY(r)) - NSMinY(r)) / MAX(1.0, NSHeight(r)) * rows;
    NSUInteger c = MIN((NSUInteger)u, columns - 1);
    NSUInteger w = MIN((NSUInteger)v, rows - 1);
    double fu = u - c, fv = v - w;
    double dx = 0, dy = 0;
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            double weight = (i ? fu : 1.0 - fu) * (j ? fv : 1.0 - fv);
            NSPoint point = [_parent pointAtColumn:c + i row:w + j];
            dx += weight * (point.x - (NSMinX(r) + NSWidth(r) * (c + i) / columns));
            dy += weight * (point.y - (NSMinY(r) + NSHeight(r) * (w + j) / rows));
        }
    }
    return NSMakePoint(dx, dy);
}

- (BOOL)stepToTime:(NSTimeInterval)now windowRect:(NSRect)windowRect
{
    // Nothing of its own to move on: the parent was stepped first.
    _windowRect = windowRect;
    double x1 = INFINITY, y1 = INFINITY, x2 = -INFINITY, y2 = -INFINITY;
    double bend = 0;
    for (NSUInteger r = 0; r <= [self rows]; r++) {
        for (NSUInteger c = 0; c <= [self columns]; c++) {
            NSPoint p = [self pointAtColumn:c row:r];
            NSPoint h = [self homeAtColumn:c row:r];
            bend = MAX(bend, hypot(p.x - h.x, p.y - h.y));
            x1 = MIN(x1, p.x);
            y1 = MIN(y1, p.y);
            x2 = MAX(x2, p.x);
            y2 = MAX(y2, p.y);
        }
    }
    _reach = NSMakeRect(x1, y1, x2 - x1, y2 - y1);
    return [_parent grabbed] || bend > URSAttachedRestBend;
}

- (NSPoint)homeAtColumn:(NSUInteger)column row:(NSUInteger)row
{
    return NSMakePoint(NSMinX(_windowRect) + NSWidth(_windowRect) * column / [self columns],
                       NSMinY(_windowRect) + NSHeight(_windowRect) * row / [self rows]);
}

- (NSPoint)pointAtColumn:(NSUInteger)column row:(NSUInteger)row
{
    NSPoint h = [self homeAtColumn:column row:row];
    NSPoint d = [self parentDisplacementAt:h];
    return NSMakePoint(h.x + d.x, h.y + d.y);
}

- (NSRect)reach
{
    return _reach;
}

@end

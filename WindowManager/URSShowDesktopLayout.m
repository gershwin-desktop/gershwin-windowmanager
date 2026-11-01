/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSShowDesktopLayout.h"

@implementation URSShowDesktopLayout

+ (NSPoint)offsetForWindowRect:(NSRect)rect inArea:(NSRect)area sliver:(CGFloat)sliver {
    NSRect visible = NSIntersectionRect(rect, area);
    if (NSWidth(visible) <= sliver || NSHeight(visible) <= sliver) {
        return NSZeroPoint;
    }
    // The window leaves over the edge its centre is nearest to, so it goes
    // the way the eye expects it to.
    NSPoint centre = NSMakePoint(NSMidX(rect), NSMidY(rect));
    CGFloat nearLeft = centre.x - NSMinX(area);
    CGFloat nearRight = NSMaxX(area) - centre.x;
    CGFloat nearTop = centre.y - NSMinY(area);
    CGFloat nearBottom = NSMaxY(area) - centre.y;
    CGFloat nearest = MIN(MIN(nearLeft, nearRight), MIN(nearTop, nearBottom));
    if (nearest == nearLeft) {
        return NSMakePoint((NSMinX(area) + sliver) - NSMaxX(rect), 0);
    }
    if (nearest == nearRight) {
        return NSMakePoint((NSMaxX(area) - sliver) - NSMinX(rect), 0);
    }
    if (nearest == nearTop) {
        return NSMakePoint(0, (NSMinY(area) + sliver) - NSMaxY(rect));
    }
    return NSMakePoint(0, (NSMaxY(area) - sliver) - NSMinY(rect));
}

+ (NSArray *)offsetsForWindowRects:(NSArray *)windowRects
                            inArea:(NSRect)area
                            sliver:(CGFloat)sliver {
    NSMutableArray *offsets = [NSMutableArray arrayWithCapacity:[windowRects count]];
    for (NSValue *value in windowRects) {
        NSPoint offset = [self offsetForWindowRect:[value rectValue] inArea:area sliver:sliver];
        [offsets addObject:[NSValue valueWithPoint:offset]];
    }
    return offsets;
}

@end

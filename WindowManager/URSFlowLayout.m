/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSFlowLayout.h"

// The chosen window fits a box this share of the area; the rest of the row
// and the title below need the remainder.
static const double URSFlowCoverWidth = 0.40;
static const double URSFlowCoverHeight = 0.60;
// Where the row's middle line lies, from the top of the area; above the
// middle so the title under the chosen window stays well on the screen.
static const double URSFlowRowCentre = 0.45;

// ItemFlow's camera distance (CAMERA_Z) and the depth its side items move
// back to (zSide): a picture that far back shows at CameraDistance /
// (CameraDistance + depth) of its size.
static const double URSFlowCameraDistance = 3.8;
static const double URSFlowSideDepth = 2.5;
// ItemFlow turns side items by 70 degrees and lets the perspective taper
// show the turn.  A scaled rectangle has no taper, so a milder turn keeps
// the narrowed windows recognizable.
static const double URSFlowSideAngle = 60.0;
// Horizontal distances, in half widths of the chosen window's box, from the
// middle to the first neighbour and between further neighbours.  ItemFlow
// gives them in space (CENTER_SPACING 1.3, COVER_SPACING 0.45) before its
// perspective; these are the distances on the screen, chosen so that each
// window is partly tucked under the one in front of it, as there.
static const double URSFlowCenterSpacing = 1.12;
static const double URSFlowCoverSpacing = 0.40;

@implementation URSFlowLayout

+ (NSRect)slotForWindowSize:(NSSize)windowSize
                    atIndex:(NSUInteger)index
                   position:(double)position
                     inArea:(NSRect)area {
    double boxWidth = NSWidth(area) * URSFlowCoverWidth;
    double boxHeight = NSHeight(area) * URSFlowCoverHeight;
    double halfBox = boxWidth * 0.5;
    // Like the overview, never enlarged: a blown up window turns blurry.
    double fit = MIN(1.0, MIN(boxWidth / MAX(windowSize.width, 1.0),
                              boxHeight / MAX(windowSize.height, 1.0)));

    // Within one item of the middle a window moves out, back and turns in
    // proportion; beyond it every window has the side depth and turn, so a
    // slide changes nothing but where they are.
    double offset = (double)index - position;
    double distance = MIN(fabs(offset), 1.0);
    double side = offset < 0 ? -1.0 : 1.0;
    double across = fabs(offset) < 1.0
        ? URSFlowCenterSpacing * offset
        : side * (URSFlowCenterSpacing + URSFlowCoverSpacing * (fabs(offset) - 1.0));
    double depthScale = URSFlowCameraDistance /
        (URSFlowCameraDistance + URSFlowSideDepth * distance);
    double turn = cos(URSFlowSideAngle * distance * M_PI / 180.0);

    double width = windowSize.width * fit * depthScale * turn;
    double height = windowSize.height * fit * depthScale;
    double midX = NSMidX(area) + across * halfBox;
    double midY = NSMinY(area) + NSHeight(area) * URSFlowRowCentre;
    return NSMakeRect(midX - width * 0.5, midY - height * 0.5, width, height);
}

+ (NSArray *)slotsForWindowSizes:(NSArray *)windowSizes
                        position:(double)position
                          inArea:(NSRect)area {
    NSMutableArray *slots = [NSMutableArray arrayWithCapacity:[windowSizes count]];
    for (NSUInteger i = 0; i < [windowSizes count]; i++) {
        NSRect slot = [self slotForWindowSize:[[windowSizes objectAtIndex:i] sizeValue]
                                      atIndex:i
                                     position:position
                                       inArea:area];
        [slots addObject:[NSValue valueWithRect:slot]];
    }
    return slots;
}

+ (NSArray *)paintOrderForCount:(NSUInteger)count position:(double)position {
    NSMutableArray *order = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [order addObject:@(i)];
    }
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        double da = fabs([a doubleValue] - position);
        double db = fabs([b doubleValue] - position);
        if (da > db) {
            return NSOrderedAscending;
        }
        return da < db ? NSOrderedDescending : NSOrderedSame;
    }];
    return order;
}

+ (NSUInteger)indexFrom:(NSUInteger)index step:(NSInteger)step count:(NSUInteger)count {
    if (count == 0) {
        return 0;
    }
    NSInteger n = (NSInteger)count;
    return (NSUInteger)((((NSInteger)index + step) % n + n) % n);
}

+ (NSArray *)stack:(NSArray *)stack reorderedAs:(NSArray *)order {
    NSSet *moved = [NSSet setWithArray:order];
    NSMutableArray *places = [NSMutableArray arrayWithCapacity:[order count]];
    for (NSUInteger i = 0; i < [stack count]; i++) {
        if ([moved containsObject:[stack objectAtIndex:i]]) {
            [places addObject:@(i)];
        }
    }
    if ([places count] != [order count]) {
        [NSException raise:NSInvalidArgumentException
                    format:@"order holds %lu objects, %lu of them in the stack",
                           (unsigned long)[order count], (unsigned long)[places count]];
    }
    NSMutableArray *result = [NSMutableArray arrayWithArray:stack];
    for (NSUInteger k = 0; k < [order count]; k++) {
        [result replaceObjectAtIndex:[[places objectAtIndex:k] unsignedIntegerValue]
                          withObject:[order objectAtIndex:k]];
    }
    return result;
}

@end

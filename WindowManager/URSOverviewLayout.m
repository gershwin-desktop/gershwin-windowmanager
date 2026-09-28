/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSOverviewLayout.h"
#import <math.h>

@implementation URSOverviewLayout

// Rows of window indices, top to bottom: the windows sorted by their
// vertical centre and cut into at most rowCount runs of about equal width,
// so a window high on the screen lands in a high row.  Each row is sorted
// left to right.
+ (NSArray *)rowsOfRects:(NSArray *)rects rowCount:(NSUInteger)rowCount {
    NSMutableArray *order = [NSMutableArray array];
    double totalWidth = 0;
    for (NSUInteger i = 0; i < [rects count]; i++) {
        [order addObject:@(i)];
        totalWidth += NSWidth([[rects objectAtIndex:i] rectValue]);
    }
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        double ya = NSMidY([[rects objectAtIndex:[a unsignedIntegerValue]] rectValue]);
        double yb = NSMidY([[rects objectAtIndex:[b unsignedIntegerValue]] rectValue]);
        return ya < yb ? NSOrderedAscending : (ya > yb ? NSOrderedDescending : NSOrderedSame);
    }];

    NSMutableArray *rows = [NSMutableArray array];
    NSMutableArray *row = [NSMutableArray array];
    double rowTarget = totalWidth / rowCount;
    double placedWidth = 0;
    for (NSNumber *index in order) {
        double w = NSWidth([[rects objectAtIndex:[index unsignedIntegerValue]] rectValue]);
        BOOL rowFull = placedWidth + w * 0.5 > rowTarget * ([rows count] + 1);
        if (rowFull && [row count] > 0 && [rows count] + 1 < rowCount) {
            [rows addObject:row];
            row = [NSMutableArray array];
        }
        [row addObject:index];
        placedWidth += w;
    }
    [rows addObject:row];

    for (NSMutableArray *r in rows) {
        [r sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            double xa = NSMidX([[rects objectAtIndex:[a unsignedIntegerValue]] rectValue]);
            double xb = NSMidX([[rects objectAtIndex:[b unsignedIntegerValue]] rectValue]);
            return xa < xb ? NSOrderedAscending : (xa > xb ? NSOrderedDescending : NSOrderedSame);
        }];
    }
    return rows;
}

// The largest common shrink factor with which the rows fit the area, at
// most 1; 0 when they cannot fit at all.
+ (double)scaleForRows:(NSArray *)rows rects:(NSArray *)rects
                inArea:(NSRect)area spacing:(CGFloat)spacing {
    double scale = 1.0;
    double heightSum = 0;
    for (NSArray *row in rows) {
        double widthSum = 0, maxHeight = 0;
        for (NSNumber *index in row) {
            NSRect r = [[rects objectAtIndex:[index unsignedIntegerValue]] rectValue];
            widthSum += NSWidth(r);
            maxHeight = MAX(maxHeight, NSHeight(r));
        }
        double room = NSWidth(area) - spacing * ([row count] - 1);
        if (room <= 0) return 0;
        scale = MIN(scale, room / widthSum);
        heightSum += maxHeight;
    }
    double room = NSHeight(area) - spacing * ([rows count] - 1);
    if (room <= 0) return 0;
    return MIN(scale, room / heightSum);
}

+ (NSArray *)slotsForWindowRects:(NSArray *)windowRects
                          inArea:(NSRect)area
                         spacing:(CGFloat)spacing {
    NSUInteger count = [windowRects count];
    if (count == 0) {
        return [NSArray array];
    }

    NSArray *bestRows = nil;
    double bestScale = -1;
    for (NSUInteger rowCount = 1; rowCount <= count; rowCount++) {
        NSArray *rows = [self rowsOfRects:windowRects rowCount:rowCount];
        double scale = [self scaleForRows:rows rects:windowRects inArea:area spacing:spacing];
        if (scale > bestScale) {
            bestScale = scale;
            bestRows = rows;
        }
    }

    NSMutableArray *slots = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [slots addObject:[NSValue valueWithRect:NSZeroRect]];
    }

    double rowHeights[[bestRows count]];
    double totalHeight = spacing * ([bestRows count] - 1);
    for (NSUInteger r = 0; r < [bestRows count]; r++) {
        double maxHeight = 0;
        for (NSNumber *index in [bestRows objectAtIndex:r]) {
            maxHeight = MAX(maxHeight, NSHeight([[windowRects objectAtIndex:[index unsignedIntegerValue]] rectValue]));
        }
        rowHeights[r] = floor(maxHeight * bestScale);
        totalHeight += rowHeights[r];
    }

    double y = NSMinY(area) + (NSHeight(area) - totalHeight) * 0.5;
    for (NSUInteger r = 0; r < [bestRows count]; r++) {
        NSArray *row = [bestRows objectAtIndex:r];
        double rowWidth = spacing * ([row count] - 1);
        for (NSNumber *index in row) {
            rowWidth += floor(NSWidth([[windowRects objectAtIndex:[index unsignedIntegerValue]] rectValue]) * bestScale);
        }
        double x = NSMinX(area) + (NSWidth(area) - rowWidth) * 0.5;
        for (NSNumber *index in row) {
            NSRect w = [[windowRects objectAtIndex:[index unsignedIntegerValue]] rectValue];
            double sw = floor(NSWidth(w) * bestScale);
            double sh = floor(NSHeight(w) * bestScale);
            NSRect slot = NSMakeRect(round(x), round(y + (rowHeights[r] - sh) * 0.5), sw, sh);
            [slots replaceObjectAtIndex:[index unsignedIntegerValue]
                             withObject:[NSValue valueWithRect:slot]];
            x += sw + spacing;
        }
        y += rowHeights[r] + spacing;
    }
    return slots;
}

@end

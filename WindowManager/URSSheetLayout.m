/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSheetLayout.h"

@implementation URSSheetLayout

+ (NSRect)frameForSheetSize:(NSSize)sheetSize
          parentContentRect:(NSRect)parentContent
                 screenRect:(NSRect)screen
{
    double x = NSMidX(parentContent) - sheetSize.width / 2.0;
    // Right edge first, so a sheet wider than the screen ends up at its
    // left edge, where its leading controls can still be reached.
    x = MIN(x, NSMaxX(screen) - sheetSize.width);
    x = MAX(x, NSMinX(screen));
    double y = MAX(NSMinY(parentContent), NSMinY(screen));
    return NSMakeRect(floor(x), floor(y), sheetSize.width, sheetSize.height);
}

+ (double)hiddenFractionAtProgress:(double)t appearing:(BOOL)appearing
{
    t = MIN(MAX(t, 0.0), 1.0);
    if (appearing) {
        // Cubic ease-out: quickly out from under the titlebar, soft landing.
        double remaining = 1.0 - t;
        return remaining * remaining * remaining;
    }
    // The exact reverse of coming out: it leaves gently, then is gone fast.
    return t * t * t;
}

@end

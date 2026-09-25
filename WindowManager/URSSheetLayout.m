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
    return NSZeroRect;
}

+ (double)hiddenFractionAtProgress:(double)t appearing:(BOOL)appearing
{
    return 0.0;
}

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Where the window overview shows each window: all windows side by side, none
// covering another, shrunk by the same factor (never enlarged, never
// distorted) and still roughly where they are on the screen, so a window is
// found where the eye expects it.  Rects are in root pixels, y down.
@interface URSOverviewLayout : NSObject

// One slot per window rect, in the same order.
+ (NSArray *)slotsForWindowRects:(NSArray *)windowRects
                          inArea:(NSRect)area
                         spacing:(CGFloat)spacing;

@end

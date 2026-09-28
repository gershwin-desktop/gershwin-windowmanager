/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Where Show Desktop puts each window: pushed straight out over the nearest
// edge of the work area nearest to it, until only a sliver of it is left
// inside to click.  Windows keep their size, so they come back unchanged.
// Rects are in root pixels, y down.
@interface URSShowDesktopLayout : NSObject

// One offset (NSValue of NSPoint) per window rect, in the same order.  A
// window that already shows no more than a sliver is not moved.
+ (NSArray *)offsetsForWindowRects:(NSArray *)windowRects
                            inArea:(NSRect)area
                            sliver:(CGFloat)sliver;

@end

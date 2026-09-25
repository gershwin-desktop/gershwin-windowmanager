/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSUtilityRestackOrder.h"

@implementation URSUtilityRestackOrder

+ (NSArray<NSNumber *> *)raiseOrderForRequestedWindow:(uint32_t)requestedWindowId
                                 currentStackingOrder:(NSArray<NSNumber *> *)currentStackingOrder
{
    // 0 never names a real X window, so it means "this restack was not
    // triggered by a specific raise request" - keep the server's own
    // order rather than inventing one.
    NSNumber *requested = requestedWindowId ? @(requestedWindowId) : nil;

    if (!requested)
        return [currentStackingOrder copy];

    NSMutableArray<NSNumber *> *order =
        [NSMutableArray arrayWithCapacity:[currentStackingOrder count] + 1];

    for (NSNumber *windowId in currentStackingOrder)
    {
        if (![windowId isEqual:requested])
            [order addObject:windowId];
    }

    // Last in this list is the one -stackAbove is sent to last, so it is
    // the one left on top once every call has run.
    [order addObject:requested];

    return order;
}

@end

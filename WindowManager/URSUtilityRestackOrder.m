/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSUtilityRestackOrder.h"

@implementation URSUtilityRestackOrder

// Moves 'requested' to the end of 'ids' (append it there if it is not
// already present) while every other id keeps its existing relative
// order.  Shared by the plain and modal groups below, so "the requested
// window ends up on top of its own group" is decided in exactly one
// place regardless of which group that is.
+ (NSArray<NSNumber *> *)groupOrder:(NSArray<NSNumber *> *)ids
                    withRequestedLast:(NSNumber *)requested
{
    if (!requested)
        return [ids copy];

    NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity:[ids count] + 1];
    for (NSNumber *windowId in ids)
    {
        if (![windowId isEqual:requested])
            [order addObject:windowId];
    }
    [order addObject:requested];
    return order;
}

+ (NSArray<NSNumber *> *)raiseOrderForRequestedWindow:(uint32_t)requestedWindowId
                                 currentStackingOrder:(NSArray<NSNumber *> *)currentStackingOrder
                                        modalWindowIds:(NSSet<NSNumber *> *)modalWindowIds
{
    // 0 never names a real X window, so it means "this restack was not
    // triggered by a specific raise request" - keep the server's own
    // order rather than inventing one.
    NSNumber *requested = requestedWindowId ? @(requestedWindowId) : nil;

    NSMutableArray<NSNumber *> *plainIds = [NSMutableArray array];
    NSMutableArray<NSNumber *> *modalIds = [NSMutableArray array];
    for (NSNumber *windowId in currentStackingOrder)
    {
        if ([modalWindowIds containsObject:windowId])
            [modalIds addObject:windowId];
        else
            [plainIds addObject:windowId];
    }

    // A requested window absent from currentStackingOrder (just mapped)
    // still needs a group: go by whether the caller already knows it is
    // modal, so a fresh modal dialog does not briefly count as plain.
    BOOL requestedIsModal = requested && [modalWindowIds containsObject:requested];
    BOOL requestedIsKnown = requested &&
        ([plainIds containsObject:requested] || [modalIds containsObject:requested]);
    if (requested && !requestedIsKnown)
    {
        if (requestedIsModal)
            [modalIds addObject:requested];
        else
            [plainIds addObject:requested];
    }

    NSArray<NSNumber *> *orderedPlain =
        [self groupOrder:plainIds withRequestedLast:requestedIsModal ? nil : requested];
    NSArray<NSNumber *> *orderedModal =
        [self groupOrder:modalIds withRequestedLast:requestedIsModal ? requested : nil];

    // Modal windows always come last (topmost): stackAbove is sent to
    // every plain window first, then to every modal one, so a modal
    // dialog can never end up buried under a plain sibling that happens
    // to raise itself afterwards.
    NSMutableArray<NSNumber *> *order =
        [NSMutableArray arrayWithCapacity:[orderedPlain count] + [orderedModal count]];
    [order addObjectsFromArray:orderedPlain];
    [order addObjectsFromArray:orderedModal];
    return order;
}

@end

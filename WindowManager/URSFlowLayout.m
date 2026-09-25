/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSFlowLayout.h"

@implementation URSFlowLayout

+ (NSRect)slotForWindowSize:(NSSize)windowSize
                    atIndex:(NSUInteger)index
                   position:(double)position
                     inArea:(NSRect)area {
    return NSZeroRect;
}

+ (NSArray *)slotsForWindowSizes:(NSArray *)windowSizes
                        position:(double)position
                          inArea:(NSRect)area {
    NSMutableArray *slots = [NSMutableArray array];
    for (NSUInteger i = 0; i < [windowSizes count]; i++) {
        [slots addObject:[NSValue valueWithRect:NSZeroRect]];
    }
    return slots;
}

+ (NSArray *)paintOrderForCount:(NSUInteger)count position:(double)position {
    NSMutableArray *order = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [order addObject:@(i)];
    }
    return order;
}

+ (NSUInteger)indexFrom:(NSUInteger)index step:(NSInteger)step count:(NSUInteger)count {
    return index;
}

+ (NSArray *)stack:(NSArray *)stack reorderedAs:(NSArray *)order {
    return stack;
}

@end

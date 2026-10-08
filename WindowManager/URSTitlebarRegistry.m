/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSTitlebarRegistry.h"

@implementation URSTitlebarRegistry
{
    // Weak: a titlebar's frame owns it, and the titlebar points back at that
    // frame, so a strong reference here kept every closed window alive.
    NSHashTable *titlebars;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        titlebars = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)addTitlebar:(XCBTitleBar *)titlebar
{
    if (titlebar != nil) {
        [titlebars addObject:titlebar];
    }
}

- (NSUInteger)count
{
    // Counts only the titlebars that are still alive
    return [[titlebars allObjects] count];
}

- (NSArray *)titlebars
{
    return [titlebars allObjects];
}

@end

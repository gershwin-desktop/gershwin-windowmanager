/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSTitlebarRegistry.h"

@implementation URSTitlebarRegistry
{
    NSMutableArray *titlebars;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        titlebars = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)addTitlebar:(XCBTitleBar *)titlebar
{
    if (titlebar != nil && ![titlebars containsObject:titlebar]) {
        [titlebars addObject:titlebar];
    }
}

- (NSUInteger)count
{
    return [titlebars count];
}

- (NSArray *)titlebars
{
    return [titlebars copy];
}

@end

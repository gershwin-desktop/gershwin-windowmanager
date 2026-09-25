/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSheetSlideEffect.h"
#import "URSSheetLayout.h"

@implementation URSSheetSlideEffect
{
    BOOL _appearing;
}

- (instancetype)initAppearing:(BOOL)appearing
{
    self = [super init];
    if (self) {
        _appearing = appearing;
    }
    return self;
}

- (NSTimeInterval)duration
{
    return 0.0;
}

- (NSRect)paintRectAtProgress:(double)t forWindowRect:(NSRect)windowRect
{
    return windowRect;
}

- (NSRect)reachOfWindowRect:(NSRect)windowRect
{
    return windowRect;
}

- (NSRect)clipRectForWindowRect:(NSRect)windowRect
{
    return windowRect;
}

@end

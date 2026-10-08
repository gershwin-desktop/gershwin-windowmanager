/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSHoldLastFrameEffect.h"

@implementation URSHoldLastFrameEffect
{
    NSTimeInterval _duration;
}

- (instancetype)initWithDuration:(NSTimeInterval)duration
{
    self = [super init];
    if (self) {
        _duration = duration;
    }
    return self;
}

- (NSTimeInterval)duration
{
    return _duration;
}

// Never moves: the whole point is to keep painting the window exactly
// where it already is.
- (NSRect)paintRectAtProgress:(double)t forWindowRect:(NSRect)windowRect
{
    return windowRect;
}

// Nothing outside the window's own rect is ever painted.
- (NSRect)reachOfWindowRect:(NSRect)windowRect
{
    return windowRect;
}

@end

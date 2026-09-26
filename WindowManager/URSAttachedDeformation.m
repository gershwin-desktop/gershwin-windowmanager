/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSAttachedDeformation.h"
#import "URSWobblyModel.h"

@implementation URSAttachedDeformation

- (instancetype)initWithParent:(URSWobblyModel *)parent
{
    self = [super init];
    if (self) {
        _parent = parent;
    }
    return self;
}

- (NSUInteger)columns
{
    return 1;
}

- (NSUInteger)rows
{
    return 1;
}

- (BOOL)stepToTime:(NSTimeInterval)now windowRect:(NSRect)windowRect
{
    return NO;
}

- (NSPoint)pointAtColumn:(NSUInteger)column row:(NSUInteger)row
{
    return NSZeroPoint;
}

- (NSRect)reach
{
    return NSZeroRect;
}

@end

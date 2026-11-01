/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSAttachmentRegistry.h"

@implementation URSAttachmentRegistry
{
    // Attached window -> parent.
    NSMutableDictionary<NSNumber *, NSNumber *> *_parents;
    NSMutableSet<NSNumber *> *_hidden;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _parents = [NSMutableDictionary new];
        _hidden = [NSMutableSet new];
    }
    return self;
}

- (void)attachWindow:(uint32_t)window toParent:(uint32_t)parent exclusive:(BOOL)exclusive
{
    if (exclusive) {
        for (NSNumber *previous in [self windowsOfParent:parent]) {
            if ([previous unsignedIntValue] != window) {
                [self detachWindow:[previous unsignedIntValue]];
            }
        }
    }
    _parents[@(window)] = @(parent);
}

- (void)detachWindow:(uint32_t)window
{
    [_parents removeObjectForKey:@(window)];
    [_hidden removeObject:@(window)];
}

- (void)forgetWindow:(uint32_t)window
{
    [self detachWindow:window];
    for (NSNumber *attached in [self windowsOfParent:window]) {
        [self detachWindow:[attached unsignedIntValue]];
    }
}

- (uint32_t)parentOfWindow:(uint32_t)window
{
    return [_parents[@(window)] unsignedIntValue];
}

- (NSArray<NSNumber *> *)windowsOfParent:(uint32_t)parent
{
    if (parent == 0) {
        return @[];
    }
    return [_parents allKeysForObject:@(parent)];
}

- (uint32_t)windowOfParent:(uint32_t)parent
{
    return [[[self windowsOfParent:parent] firstObject] unsignedIntValue];
}

- (NSArray<NSNumber *> *)windows
{
    return [_parents allKeys];
}

- (void)setWindow:(uint32_t)window hiddenWithParent:(BOOL)hidden
{
    if (hidden && _parents[@(window)] != nil) {
        [_hidden addObject:@(window)];
    } else {
        [_hidden removeObject:@(window)];
    }
}

- (BOOL)isWindowHiddenWithParent:(uint32_t)window
{
    return [_hidden containsObject:@(window)];
}

@end

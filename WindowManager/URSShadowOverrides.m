/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSShadowOverrides.h"

@implementation URSShadowOverrides {
    NSMutableSet<NSNumber *> *_shadowless;
    NSMutableDictionary<NSNumber *, NSNumber *> *_cornerRadii;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _shadowless = [[NSMutableSet alloc] init];
        _cornerRadii = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)setSkipsShadow:(BOOL)skips forWindow:(uint32_t)windowId {
    if (skips) {
        [_shadowless addObject:@(windowId)];
    } else {
        [_shadowless removeObject:@(windowId)];
    }
}

- (BOOL)skipsShadowForWindow:(uint32_t)windowId {
    return [_shadowless containsObject:@(windowId)];
}

- (BOOL)setCornerRadius:(double)radius forWindow:(uint32_t)windowId {
    NSNumber *key = @(windowId);
    if ([_cornerRadii[key] doubleValue] == radius) {
        return NO;
    }
    if (radius > 0) {
        _cornerRadii[key] = @(radius);
    } else {
        [_cornerRadii removeObjectForKey:key];
    }
    return YES;
}

- (double)cornerRadiusForWindow:(uint32_t)windowId {
    return [_cornerRadii[@(windowId)] doubleValue];
}

- (void)forgetWindow:(uint32_t)windowId {
    [_cornerRadii removeObjectForKey:@(windowId)];
}

@end

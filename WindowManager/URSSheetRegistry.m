/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSheetRegistry.h"

@implementation URSSheetRegistry
{
    // Sheet -> parent.
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

- (void)attachSheet:(uint32_t)sheet toParent:(uint32_t)parent
{
    uint32_t previous = [self sheetOfParent:parent];
    if (previous != 0 && previous != sheet) {
        [self detachSheet:previous];
    }
    _parents[@(sheet)] = @(parent);
}

- (void)detachSheet:(uint32_t)sheet
{
    [_parents removeObjectForKey:@(sheet)];
    [_hidden removeObject:@(sheet)];
}

- (void)forgetWindow:(uint32_t)window
{
    [self detachSheet:window];
    uint32_t sheet = [self sheetOfParent:window];
    if (sheet != 0) {
        [self detachSheet:sheet];
    }
}

- (uint32_t)parentOfSheet:(uint32_t)sheet
{
    return [_parents[@(sheet)] unsignedIntValue];
}

- (uint32_t)sheetOfParent:(uint32_t)parent
{
    if (parent == 0) {
        return 0;
    }
    NSArray *sheets = [_parents allKeysForObject:@(parent)];
    return [[sheets firstObject] unsignedIntValue];
}

- (NSArray<NSNumber *> *)sheets
{
    return [_parents allKeys];
}

- (void)setSheet:(uint32_t)sheet hiddenWithParent:(BOOL)hidden
{
    if (hidden && _parents[@(sheet)] != nil) {
        [_hidden addObject:@(sheet)];
    } else {
        [_hidden removeObject:@(sheet)];
    }
}

- (BOOL)isSheetHiddenWithParent:(uint32_t)sheet
{
    return [_hidden containsObject:@(sheet)];
}

@end

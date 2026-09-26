/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSheetSlideEffect.h"

@implementation URSSheetSlideEffect

- (instancetype)initAppearing:(BOOL)appearing
{
    return [super initAppearing:appearing outward:URSAttachmentEdgeBottom];
}

@end

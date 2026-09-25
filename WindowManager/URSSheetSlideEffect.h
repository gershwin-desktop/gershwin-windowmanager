/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "URSWindowEffect.h"

// A sheet sliding out from under its parent's titlebar, or back under it.
// The sheet window stays where it is attached; only its picture moves, and
// everything of it above the attachment line is clipped away, so it looks
// as if it came out of the titlebar.
@interface URSSheetSlideEffect : NSObject <URSWindowEffect>

- (instancetype)initAppearing:(BOOL)appearing;

@end

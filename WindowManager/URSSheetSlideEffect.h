/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSAttachmentSlideEffect.h"

// A sheet sliding down out from under its parent's titlebar, or back up
// under it: everything of it above the attachment line is clipped away.
@interface URSSheetSlideEffect : URSAttachmentSlideEffect

- (instancetype)initAppearing:(BOOL)appearing;

@end

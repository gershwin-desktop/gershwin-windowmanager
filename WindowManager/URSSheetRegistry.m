/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSheetRegistry.h"

@implementation URSSheetRegistry

- (void)attachSheet:(uint32_t)sheet toParent:(uint32_t)parent {}
- (void)detachSheet:(uint32_t)sheet {}
- (void)forgetWindow:(uint32_t)window {}
- (uint32_t)parentOfSheet:(uint32_t)sheet { return 0; }
- (uint32_t)sheetOfParent:(uint32_t)parent { return 0; }
- (NSArray<NSNumber *> *)sheets { return @[]; }
- (void)setSheet:(uint32_t)sheet hiddenWithParent:(BOOL)hidden {}
- (BOOL)isSheetHiddenWithParent:(uint32_t)sheet { return NO; }

@end

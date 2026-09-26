/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWindowRole.h"

NSString * const URSWindowRolePropertyName = @"WM_WINDOW_ROLE";
NSString * const URSWindowRoleSheet = @"sheet";
NSString * const URSWindowRoleDrawer = @"drawer";

@implementation URSWindowRole

+ (NSString *)roleFromPropertyBytes:(const void *)bytes length:(NSUInteger)length
{
    return nil;
}

@end

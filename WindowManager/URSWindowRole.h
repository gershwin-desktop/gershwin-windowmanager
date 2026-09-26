/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// The ICCCM WM_WINDOW_ROLE property (STRING) says what a window is for.
// A client marks the windows the window manager attaches to their parent
// (WM_TRANSIENT_FOR) with one of the roles below; any other role, or none,
// leaves the window an ordinary window.  A toolkit-neutral convention
// rather than a private property, so that any client can take part.
extern NSString * const URSWindowRolePropertyName;
extern NSString * const URSWindowRoleSheet;
extern NSString * const URSWindowRoleDrawer;

@interface URSWindowRole : NSObject

// The role held by a WM_WINDOW_ROLE value as the server returns it, or nil
// for an empty one.  Clients differ in whether they store the terminating
// NUL, so it is ignored.
+ (NSString *)roleFromPropertyBytes:(const void *)bytes length:(NSUInteger)length;

@end

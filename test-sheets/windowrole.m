/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Reading the WM_WINDOW_ROLE a client marks sheets and drawers with.
// Headless.  Run with:  gnustep-tests test-sheets

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSWindowRole.m"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("WM_WINDOW_ROLE")
    PASS_EQUAL([URSWindowRole roleFromPropertyBytes: "sheet" length: 5],
               URSWindowRoleSheet, "a sheet is recognised");
    PASS_EQUAL([URSWindowRole roleFromPropertyBytes: "drawer" length: 6],
               URSWindowRoleDrawer, "a drawer is recognised");
    PASS_EQUAL([URSWindowRole roleFromPropertyBytes: "sheet\0" length: 6],
               URSWindowRoleSheet, "a stored terminating NUL is ignored");
    PASS([URSWindowRole roleFromPropertyBytes: "" length: 0] == nil,
         "an empty role is no role");
    PASS([URSWindowRole roleFromPropertyBytes: NULL length: 0] == nil,
         "a missing role is no role");
    PASS_EQUAL([URSWindowRole roleFromPropertyBytes: "sheetx" length: 5],
               URSWindowRoleSheet, "only the property's length counts");
    PASS(![[URSWindowRole roleFromPropertyBytes: "browser" length: 7]
            isEqual: URSWindowRoleSheet],
         "another application's role is not a sheet");
  END_SET("WM_WINDOW_ROLE")

  [arp release];
  return 0;
}

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Activating the desktop window from a pager left _ACTIVE_APPLICATION on the
// application that was frontmost before, so Menu.app kept showing that
// application's menu over the desktop.  Headless.
// Run with:  gnustep-tests test-activeapplication

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "URSActiveApplicationPolicy.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  PASS(URSActiveWindowMakesItsApplicationFrontmost(NO, NO),
       "An application window that gets the focus brings its application to the front");
  PASS(URSActiveWindowMakesItsApplicationFrontmost(NO, YES),
       "An application window a pager activates brings its application to the front");
  PASS(!URSActiveWindowMakesItsApplicationFrontmost(YES, NO),
       "The desktop getting the focus by itself keeps the frontmost application");
  PASS(URSActiveWindowMakesItsApplicationFrontmost(YES, YES),
       "The desktop a pager activates brings Workspace to the front");

  [arp release];
  return 0;
}

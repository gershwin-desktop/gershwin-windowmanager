/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Which frame changes are allowed for windows of fixed size, so that Center
// works for them.  Headless.  Run with:  gnustep-tests test-framemove

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "URSFrameMove.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("a window whose size is fixed")
    PASS(URSFrameSizeChangeAllowed(300, 200, 300, 200, NO),
         "moving it to another place keeps its size and is allowed");
    PASS(!URSFrameSizeChangeAllowed(300, 200, 400, 200, NO),
         "a wider frame is refused");
    PASS(!URSFrameSizeChangeAllowed(300, 200, 300, 300, NO),
         "a taller frame is refused");
  END_SET("a window whose size is fixed")

  START_SET("a resizable window")
    PASS(URSFrameSizeChangeAllowed(300, 200, 300, 200, YES), "moving is allowed");
    PASS(URSFrameSizeChangeAllowed(300, 200, 800, 600, YES), "resizing is allowed");
  END_SET("a resizable window")

  [arp release];
  return 0;
}

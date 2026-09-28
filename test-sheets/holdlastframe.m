/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Rules URSHoldLastFrameEffect must keep: it exists only to keep a parent
// window's picture alive across its own unmap for as long as an attached
// window's dismiss effect is still playing, so the parent must never move,
// resize, or reveal anything outside its own rect while it runs.  Headless.
// Run with:  gnustep-tests test-sheets

#import <Foundation/Foundation.h>
#import <math.h>
#import "Testing.h"
#include "../WindowManager/URSHoldLastFrameEffect.m"

static BOOL near(double a, double b)
{
  return fabs(a - b) < 1e-9;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSRect w = NSMakeRect(80, 60, 400, 300);
  URSHoldLastFrameEffect *hold =
    [[[URSHoldLastFrameEffect alloc] initWithDuration: 0.25] autorelease];

  START_SET("duration")
    PASS(near([hold duration], 0.25),
         "the hold lasts exactly as long as it was told to");
  END_SET("duration")

  START_SET("never moves")
    for (int i = 0; i <= 10; i++) {
      double t = i / 10.0;
      PASS(NSEqualRects([hold paintRectAtProgress: t forWindowRect: w], w),
           "the window is painted at its own rect at every progress");
    }
  END_SET("never moves")

  START_SET("reach")
    PASS(NSEqualRects([hold reachOfWindowRect: w], w),
         "nothing outside the window's own rect is ever painted");
  END_SET("reach")

  [arp release];
  return 0;
}

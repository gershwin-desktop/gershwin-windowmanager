/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Rules the sheet slide effect must keep.  Headless.
// Run with:  gnustep-tests test-sheets

#import <Foundation/Foundation.h>
#import <math.h>
#import "Testing.h"
#include "../WindowManager/URSSheetSlideEffect.m"

static BOOL near(double a, double b)
{
  return fabs(a - b) < 1e-9;
}

// What of the picture can be seen at progress t: the painted rect cut by the
// clip.
static NSRect shown(URSSheetSlideEffect *e, double t, NSRect w)
{
  return NSIntersectionRect([e paintRectAtProgress: t forWindowRect: w],
                            [e clipRectForWindowRect: w]);
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSRect w = NSMakeRect(250, 130, 300, 160);
  URSSheetSlideEffect *in = [[[URSSheetSlideEffect alloc] initAppearing: YES] autorelease];
  URSSheetSlideEffect *out = [[[URSSheetSlideEffect alloc] initAppearing: NO] autorelease];

  START_SET("timing")
    PASS([in duration] >= 0.2 && [in duration] <= 0.3,
         "the slide takes about a quarter of a second");
    PASS(near([in duration], [out duration]),
         "going back takes as long as coming out");
  END_SET("timing")

  START_SET("slide in")
    PASS(NSIsEmptyRect(shown(in, 0.0, w)),
         "nothing of the sheet shows at the start");
    PASS(NSEqualRects([in paintRectAtProgress: 1.0 forWindowRect: w], w),
         "the sheet ends exactly where the window is");
    NSRect half = [in paintRectAtProgress: 0.5 forWindowRect: w];
    PASS(near(NSMinY(half), NSMinY(w) - 0.125 * NSHeight(w)),
         "at half time 7/8 of the sheet is out");
    PASS(near(NSMinX(half), NSMinX(w)) && near(NSWidth(half), NSWidth(w)) &&
         near(NSHeight(half), NSHeight(w)),
         "the sheet slides straight down without scaling");
    PASS(near(NSMinY(shown(in, 0.5, w)), NSMinY(w)),
         "the part above the attachment line stays hidden under the titlebar");
  END_SET("slide in")

  START_SET("slide out")
    PASS(NSEqualRects([out paintRectAtProgress: 0.0 forWindowRect: w], w),
         "going back starts where the window is");
    PASS(NSIsEmptyRect(shown(out, 1.0, w)),
         "nothing of the sheet shows at the end");
  END_SET("slide out")

  START_SET("clip and reach")
    NSRect clip = [in clipRectForWindowRect: w];
    PASS(near(NSMinY(clip), NSMinY(w)),
         "the clip starts at the attachment line");
    PASS(NSMinX(clip) < NSMinX(w) - 40 && NSMaxX(clip) > NSMaxX(w) + 40 &&
         NSMaxY(clip) > NSMaxY(w) + 40,
         "the clip leaves room for the shadow at the sides and below");
    NSRect reach = [in reachOfWindowRect: w];
    BOOL covered = YES;
    for (int i = 0; i <= 20; i++) {
      NSRect s = shown(in, i / 20.0, w);
      if (!NSIsEmptyRect(s) && !NSContainsRect(reach, s)) covered = NO;
      s = shown(out, i / 20.0, w);
      if (!NSIsEmptyRect(s) && !NSContainsRect(reach, s)) covered = NO;
    }
    PASS(covered, "the reach covers every part that can be seen");
    PASS(NSHeight(reach) <= NSHeight(w) + 1e-9,
         "the reach stays within the window's own rect (the rest is clipped)");
  END_SET("clip and reach")

  [arp release];
  return 0;
}

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// A drawer sliding out from under its parent's edge and back.  Headless.
// Run with:  gnustep-tests test-drawers

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSAttachmentSlideEffect.m"

static BOOL near(double a, double b)
{
  return fabs(a - b) < 1e-9;
}

static NSRect shown(URSAttachmentSlideEffect *e, double t, NSRect w)
{
  return NSIntersectionRect([e paintRectAtProgress: t forWindowRect: w],
                            [e clipRectForWindowRect: w]);
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSRect w = NSMakeRect(802, 122, 170, 390);   /* right drawer of a parent ending at 802 */

  START_SET("a right drawer")
    URSAttachmentSlideEffect *in = [[[URSAttachmentSlideEffect alloc]
      initAppearing: YES outward: URSAttachmentEdgeRight] autorelease];
    URSAttachmentSlideEffect *out = [[[URSAttachmentSlideEffect alloc]
      initAppearing: NO outward: URSAttachmentEdgeRight] autorelease];

    PASS([in duration] >= 0.2 && [in duration] <= 0.3, "the slide takes about a quarter second");
    PASS([in respondsToSelector: @selector(playsEveryFrame)] && [in playsEveryFrame],
         "a stall postpones the slide rather than letting it jump half way out");
    PASS(NSIsEmptyRect(shown(in, 0.0, w)), "nothing shows at the start: it is under the parent");
    PASS(near(NSMaxX([in paintRectAtProgress: 0.0 forWindowRect: w]), NSMinX(w)),
         "it starts fully tucked under the parent's edge");
    NSRect half = [in paintRectAtProgress: 0.5 forWindowRect: w];
    PASS(near(NSMinX(half), NSMinX(w) - 0.125 * NSWidth(w)),
         "eased: 7/8 of the way out at half time");
    PASS(near(NSMinY(half), NSMinY(w)) && near(NSHeight(half), NSHeight(w)),
         "it slides sideways only");
    PASS(NSEqualRects([in paintRectAtProgress: 1.0 forWindowRect: w], w),
         "it ends where it is attached");
    PASS(NSEqualRects([out paintRectAtProgress: 0.0 forWindowRect: w], w)
         && NSIsEmptyRect(shown(out, 1.0, w)),
         "closing goes the same way back and ends hidden");
    PASS(near(NSMinX([out paintRectAtProgress: 0.5 forWindowRect: w]),
              NSMinX(w) - 0.125 * NSWidth(w)),
         "closing leaves gently: 1/8 under the parent at half time");
    NSRect clip = [in clipRectForWindowRect: w];
    PASS(near(NSMinX(clip), NSMinX(w)) && NSMaxX(clip) > NSMaxX(w) + 40
         && NSMinY(clip) < NSMinY(w) - 40 && NSMaxY(clip) > NSMaxY(w) + 40,
         "only the parent's side of the edge is cut; the shadow keeps the other three");

    BOOL monotonic = YES;
    double last = -1;
    for (int i = 0; i <= 100; i++)
      {
        double x = NSMaxX(shown(in, i / 100.0, w));
        if (i > 0 && x < last - 1e-9)
          monotonic = NO;
        last = x;
      }
    PASS(monotonic, "the visible part only ever grows while opening (never pops)");
  END_SET("a right drawer")

  START_SET("the other edges")
    NSRect lw = NSMakeRect(30, 122, 170, 390);
    URSAttachmentSlideEffect *left = [[[URSAttachmentSlideEffect alloc]
      initAppearing: YES outward: URSAttachmentEdgeLeft] autorelease];
    PASS(near(NSMinX([left paintRectAtProgress: 0.0 forWindowRect: lw]), NSMaxX(lw))
         && near(NSMaxX([left clipRectForWindowRect: lw]), NSMaxX(lw)),
         "a left drawer comes out leftwards from under the left edge");

    NSRect bw = NSMakeRect(211, 523, 570, 120);
    URSAttachmentSlideEffect *bottom = [[[URSAttachmentSlideEffect alloc]
      initAppearing: YES outward: URSAttachmentEdgeBottom] autorelease];
    PASS(near(NSMaxY([bottom paintRectAtProgress: 0.0 forWindowRect: bw]), NSMinY(bw))
         && near(NSMinY([bottom clipRectForWindowRect: bw]), NSMinY(bw)),
         "a bottom drawer comes down from under the bottom edge");

    NSRect tw = NSMakeRect(211, 0, 570, 100);
    URSAttachmentSlideEffect *top = [[[URSAttachmentSlideEffect alloc]
      initAppearing: YES outward: URSAttachmentEdgeTop] autorelease];
    PASS(near(NSMinY([top paintRectAtProgress: 0.0 forWindowRect: tw]), NSMaxY(tw))
         && near(NSMaxY([top clipRectForWindowRect: tw]), NSMaxY(tw)),
         "a top drawer comes up from behind the titlebar");
  END_SET("the other edges")

  [arp release];
  return 0;
}

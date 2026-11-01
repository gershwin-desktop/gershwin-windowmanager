/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Rules the wobbly window model must keep.  Headless.
// Run with:  gnustep-tests test-wobbly

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSWobblyModel.m"

static const NSTimeInterval frame = 1.0 / 60.0;

// Largest distance of any mesh point from its place on the flat window.
static double maxBend(URSWobblyModel *m, NSRect w)
{
  double worst = 0;
  for (NSUInteger r = 0; r <= [m rows]; r++) {
    for (NSUInteger c = 0; c <= [m columns]; c++) {
      NSPoint p = [m pointAtColumn: c row: r];
      double hx = NSMinX(w) + NSWidth(w) * c / [m columns];
      double hy = NSMinY(w) + NSHeight(w) * r / [m rows];
      worst = MAX(worst, hypot(p.x - hx, p.y - hy));
    }
  }
  return worst;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSRect w = NSMakeRect(100, 100, 600, 400);
  NSTimeInterval t = 1000.0;

  {
    URSWobblyModel *m = [[URSWobblyModel alloc] initWithWindowRect: w
                                                         grabPoint: NSMakePoint(400, 110)
                                                              time: t];
    PASS([m stepToTime: t + frame windowRect: w], "a held window stays deformable while held");
    PASS(maxBend(m, w) < 0.01, "a window held still lies flat");
    PASS(NSEqualRects([m reach], w) || NSContainsRect(NSInsetRect([m reach], -0.01, -0.01), w),
         "a flat window reaches over itself");
  }

  {
    URSWobblyModel *m = [[URSWobblyModel alloc] initWithWindowRect: w
                                                         grabPoint: NSMakePoint(400, 110)
                                                              time: t];
    NSRect moved = w;
    for (int i = 1; i <= 10; i++) {
      moved = NSOffsetRect(w, 20 * i, 0);
      [m stepToTime: t + i * frame windowRect: moved];
    }
    NSPoint bottomLeft = [m pointAtColumn: 0 row: [m rows]];
    NSPoint top = [m pointAtColumn: [m columns] / 2 row: 0];
    PASS(bottomLeft.x < NSMinX(moved) - 5,
         "the far end of a window dragged right trails behind to the left");
    PASS(fabs(top.x - (NSMinX(moved) + NSWidth(moved) * 0.5)) < 2.0,
         "the part the pointer holds stays under the pointer");
    PASS(NSPointInRect(bottomLeft, NSInsetRect([m reach], -0.5, -0.5)),
         "the reach covers the bent mesh");

    [m releaseGrab];
    PASS(![m grabbed], "letting go releases the grab");
    NSTimeInterval now = t + 10 * frame;
    BOOL wobbledPast = NO;
    for (int i = 0; i < 30; i++) {
      now += frame;
      [m stepToTime: now windowRect: moved];
      if ([m pointAtColumn: 0 row: [m rows]].x > NSMinX(moved) + 1.0) wobbledPast = YES;
    }
    PASS(wobbledPast, "a let go window wobbles past its shape before it settles");

    BOOL stillMoving = YES;
    for (int i = 0; i < 600 && stillMoving; i++) {
      now += frame;
      stillMoving = [m stepToTime: now windowRect: moved];
    }
    PASS(!stillMoving, "a let go window comes to rest within ten seconds");
    PASS(maxBend(m, moved) < 0.5, "at rest the mesh lies flat on the window");
  }

  {
    URSWobblyModel *m = [[URSWobblyModel alloc] initWithWindowRect: w
                                                         grabPoint: NSMakePoint(120, 110)
                                                              time: t];
    NSTimeInterval now = t;
    for (int i = 0; i < 300; i++) {
      now += frame;
      NSRect shaken = NSOffsetRect(w, (i % 2) ? 150 : -150, (i % 3) ? 90 : -90);
      [m stepToTime: now windowRect: shaken];
    }
    PASS(maxBend(m, w) < 2000, "violent shaking never blows the mesh up");
  }

  {
    URSWobblyModel *m = [[URSWobblyModel alloc] initWithWindowRect: w
                                                         grabPoint: NSMakePoint(400, 110)
                                                              time: t];
    [m stepToTime: t + frame windowRect: NSOffsetRect(w, 300, 0)];
    [m stepToTime: t + 5.0 windowRect: NSOffsetRect(w, 300, 0)];
    PASS(maxBend(m, NSOffsetRect(w, 300, 0)) < 400,
         "a long pause between frames does not fling the mesh away");
  }

  [arp release];
  return 0;
}

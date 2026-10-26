/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// A drawer attached to a wobbling parent bends along with it.  Headless.
// Run with:  gnustep-tests test-drawers

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSWobblyModel.m"
#include "../WindowManager/URSAttachedDeformation.m"

static const NSTimeInterval frameTime = 1.0 / 60.0;

static NSPoint home(id<URSWindowDeformation> d, NSRect w, NSUInteger c, NSUInteger r)
{
  return NSMakePoint(NSMinX(w) + NSWidth(w) * c / [d columns],
                     NSMinY(w) + NSHeight(w) * r / [d rows]);
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSRect parent = NSMakeRect(100, 100, 600, 400);
  // A right drawer exactly as tall as the parent, so its seam points fall
  // on the parent's right column of mesh points.
  NSRect drawer = NSMakeRect(700, 100, 170, 400);
  NSTimeInterval t = 1000.0;

  URSWobblyModel *m = [[URSWobblyModel alloc] initWithWindowRect: parent
                                                       grabPoint: NSMakePoint(400, 110)
                                                            time: t];
  URSAttachedDeformation *d = [[URSAttachedDeformation alloc] initWithParent: m];

  PASS([d respondsToSelector: @selector(followsOtherDeformation)]
       && [d followsOtherDeformation],
       "it is stepped after the parent's mesh, which it reads");

  // Drag both to the right in the same frames, as the window manager does.
  BOOL keptUp = YES;
  for (int i = 1; i <= 12; i++)
    {
      t += frameTime;
      parent = NSOffsetRect(parent, 15, 0);
      drawer = NSOffsetRect(drawer, 15, 0);
      [m stepToTime: t windowRect: parent];
      keptUp = [d stepToTime: t windowRect: drawer] && keptUp;
    }
  PASS(keptUp, "it keeps bending while the parent is held");

  BOOL seamClosed = YES;
  for (NSUInteger r = 0; r <= [d rows]; r++)
    {
      NSPoint mine = [d pointAtColumn: 0 row: r];
      NSPoint theirs = [m pointAtColumn: [m columns] row: r * [m rows] / [d rows]];
      if (hypot(mine.x - theirs.x, mine.y - theirs.y) > 0.01)
        seamClosed = NO;
    }
  PASS(seamClosed, "the drawer's inner edge stays on the parent's bent edge");

  double bend = 0;
  for (NSUInteger r = 0; r <= [d rows]; r++)
    for (NSUInteger c = 0; c <= [d columns]; c++)
      {
        NSPoint p = [d pointAtColumn: c row: r];
        NSPoint h = home(d, drawer, c, r);
        bend = MAX(bend, hypot(p.x - h.x, p.y - h.y));
      }
  PASS(bend > 1.0, "the drawer's mesh moves with the parent's (it trails the drag)");

  BOOL rigidRows = YES;
  for (NSUInteger r = 0; r <= [d rows]; r++)
    {
      NSPoint in = [d pointAtColumn: 0 row: r];
      NSPoint out = [d pointAtColumn: [d columns] row: r];
      NSPoint hin = home(d, drawer, 0, r), hout = home(d, drawer, [d columns], r);
      if (fabs((out.x - hout.x) - (in.x - hin.x)) > 1e-6
          || fabs((out.y - hout.y) - (in.y - hin.y)) > 1e-6)
        rigidRows = NO;
    }
  PASS(rigidRows, "beyond the seam each row moves as one piece with the edge");

  NSRect reach = [d reach];
  BOOL inside = YES;
  for (NSUInteger r = 0; r <= [d rows]; r++)
    for (NSUInteger c = 0; c <= [d columns]; c++)
      if (!NSPointInRect([d pointAtColumn: c row: r], NSInsetRect(reach, -0.5, -0.5)))
        inside = NO;
  PASS(inside, "its reach covers every mesh point");

  [m releaseGrab];
  BOOL parentResting = YES, drawerResting = YES;
  for (int i = 0; i < 600 && (parentResting || drawerResting); i++)
    {
      t += frameTime;
      parentResting = [m stepToTime: t windowRect: parent];
      drawerResting = [d stepToTime: t windowRect: drawer];
    }
  PASS(!parentResting && !drawerResting, "it lies flat once the parent does");

  [d release];
  [m release];
  [arp release];
  return 0;
}

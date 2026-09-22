/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Rules the Show Desktop layout must keep.  Headless.
// Run with:  gnustep-tests test-showdesktop

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSShowDesktopLayout.m"

static const NSRect area = {{0, 22}, {1920, 998}};
static const CGFloat sliver = 20;

static NSPoint offsetOf(NSRect window)
{
  NSArray *offsets = [URSShowDesktopLayout offsetsForWindowRects:
                        @[[NSValue valueWithRect: window]]
                                                          inArea: area
                                                          sliver: sliver];
  return [[offsets objectAtIndex: 0] pointValue];
}

static NSRect moved(NSRect window)
{
  NSPoint offset = offsetOf(window);
  return NSOffsetRect(window, offset.x, offset.y);
}

// What is left of the window inside the area is a strip one sliver thick,
// lying along one edge of the area.
static BOOL leavesSliver(NSRect window)
{
  NSRect visible = NSIntersectionRect(moved(window), area);
  BOOL alongSide = fabs(NSWidth(visible) - sliver) < 0.5
    && (fabs(NSMinX(visible) - NSMinX(area)) < 0.5
        || fabs(NSMaxX(visible) - NSMaxX(area)) < 0.5);
  BOOL alongTopOrBottom = fabs(NSHeight(visible) - sliver) < 0.5
    && (fabs(NSMinY(visible) - NSMinY(area)) < 0.5
        || fabs(NSMaxY(visible) - NSMaxY(area)) < 0.5);
  return alongSide || alongTopOrBottom;
}

int main()
{
  START_SET("Show Desktop layout")

  NSRect leftish = NSMakeRect(100, 300, 600, 400);
  NSRect rightish = NSMakeRect(1300, 300, 500, 400);
  NSRect topish = NSMakeRect(700, 40, 500, 200);
  NSRect bottomish = NSMakeRect(700, 780, 500, 200);
  NSRect maximized = area;
  NSRect centered = NSMakeRect(660, 321, 600, 400);

  PASS(offsetOf(leftish).x < 0 && offsetOf(leftish).y == 0,
       "a window near the left edge leaves to the left");
  PASS(offsetOf(rightish).x > 0 && offsetOf(rightish).y == 0,
       "a window near the right edge leaves to the right");
  PASS(offsetOf(topish).y < 0 && offsetOf(topish).x == 0,
       "a window near the top leaves upwards");
  PASS(offsetOf(bottomish).y > 0 && offsetOf(bottomish).x == 0,
       "a window near the bottom leaves downwards");

  PASS(leavesSliver(leftish) && leavesSliver(rightish)
       && leavesSliver(topish) && leavesSliver(bottomish),
       "every window leaves a sliver along one edge to be clicked");
  PASS(leavesSliver(maximized), "a window as big as the area leaves a sliver too");
  PASS(leavesSliver(centered), "a window in the middle leaves a sliver too");

  NSPoint c = offsetOf(centered);
  PASS((c.x == 0) != (c.y == 0), "a window moves along one axis only");

  NSRect alreadyAside = NSMakeRect(-590, 300, 600, 400);
  PASS(NSEqualPoints(offsetOf(alreadyAside), NSZeroPoint),
       "a window showing no more than a sliver stays where it is");
  NSRect offScreen = NSMakeRect(2000, 300, 600, 400);
  PASS(NSEqualPoints(offsetOf(offScreen), NSZeroPoint),
       "a window outside the area stays where it is");

  NSArray *all = [URSShowDesktopLayout offsetsForWindowRects:
                    @[[NSValue valueWithRect: leftish],
                      [NSValue valueWithRect: rightish]]
                                                      inArea: area
                                                      sliver: sliver];
  PASS([all count] == 2
       && [[all objectAtIndex: 0] pointValue].x < 0
       && [[all objectAtIndex: 1] pointValue].x > 0,
       "one offset per window, in the same order");

  END_SET("Show Desktop layout")
  return 0;
}

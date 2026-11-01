/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Which snap zone a window dragged by its titlebar is in, and so whether a
// snap preview comes up.  Headless.  Run with:  gnustep-tests test-snap

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "URSSnapZone.h"

// A 1600x1000 screen below a 22 pixel menu bar
static SnapZone zoneAt(int32_t x, int32_t y, BOOL resizable)
{
  return URSSnapZoneForPointer(x, y, 0, 22, 1600, 978, resizable);
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("a resizable window")
    PASS(zoneAt(800, 500, YES) == SnapZoneNone, "in the middle of the screen nothing snaps");
    PASS(zoneAt(800, 23, YES) == SnapZoneTop, "at the top edge the window would fill the screen");
    PASS(zoneAt(1, 500, YES) == SnapZoneLeft, "at the left edge it would take the left half");
    PASS(zoneAt(1599, 500, YES) == SnapZoneRight, "at the right edge it would take the right half");
    PASS(zoneAt(1, 23, YES) == SnapZoneTopLeft, "in the top left corner it would take that quarter");
    PASS(zoneAt(1599, 23, YES) == SnapZoneTopRight, "in the top right corner it would take that quarter");
    PASS(zoneAt(1, 999, YES) == SnapZoneBottomLeft, "in the bottom left corner it would take that quarter");
    PASS(zoneAt(1599, 999, YES) == SnapZoneBottomRight, "in the bottom right corner it would take that quarter");
    PASS(zoneAt(30, 23, YES) == SnapZoneTopLeft, "near a corner along the top edge it still takes the quarter");
    PASS(zoneAt(800, 999, YES) == SnapZoneNone, "the bottom edge away from the corners does not snap");
    PASS(zoneAt(800, 40, YES) == SnapZoneNone, "a little below the top edge does not snap yet");
  END_SET("a resizable window")

  START_SET("a window whose size is fixed")
    int32_t points[][2] = { {800, 23}, {1, 500}, {1599, 500}, {1, 23},
                            {1599, 23}, {1, 999}, {1599, 999} };
    BOOL none = YES;
    size_t i;
    for (i = 0; i < sizeof(points) / sizeof(points[0]); i++)
      if (zoneAt(points[i][0], points[i][1], NO) != SnapZoneNone)
        none = NO;
    PASS(none, "no edge or corner is a snap zone, so no preview offers a size it cannot take");
  END_SET("a window whose size is fixed")

  [arp release];
  return 0;
}

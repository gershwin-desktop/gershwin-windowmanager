/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// A client resizing its own window (xdotool windowsize, Workspace restoring
// a viewer size) left the bottom-right grow box where the old size had put
// it, and pressing an edge or the grow box snapped that edge to the pointer:
// the window shrank on the first motion and ended smaller than it started
// after dragging back to the press point.  Headless.
// Run with:  gnustep-tests test-resizegeometry

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSResizeGeometry.m"

static BOOL rectIs(URSZoneRect r, int32_t x, int32_t y, int32_t w, int32_t h)
{
  BOOL same = r.x == x && r.y == y && r.width == w && r.height == h;
  if (!same)
    NSLog(@"zone is %dx%d%+d%+d", r.width, r.height, r.x, r.y);
  return same;
}

int main(void)
{
  START_SET("zone layout")
  URSResizeZoneLayout l = URSResizeZoneLayoutForFrame(1000, 726, 12, 4, 16);
  PASS(rectIs(l.growBox, 984, 710, 16, 16),
       "grow box sits in the bottom-right corner of a 1000x726 frame");
  PASS(rectIs(l.se, 988, 714, 12, 12), "SE corner follows the frame size");
  PASS(rectIs(l.e, 996, 12, 4, 702), "E edge follows the frame width");
  PASS(rectIs(l.s, 12, 722, 976, 4), "S edge follows the frame height");
  PASS(rectIs(l.nw, 0, 0, 12, 12), "NW corner stays at the origin");

  URSResizeZoneLayout g = URSResizeZoneLayoutForFrame(981, 707, 12, 4, 16);
  PASS(!rectIs(g.growBox, l.growBox.x, l.growBox.y, 16, 16),
       "a different frame size moves the grow box");

  URSResizeZoneLayout none = URSResizeZoneLayoutForFrame(1000, 726, 12, 4, 0);
  PASS(rectIs(none.growBox, 0, 0, 0, 0), "no grow box when the theme has none");
  END_SET("zone layout")

  START_SET("grab keeps press offset")
  // Pressed 6 px left of and 5 px above the bottom-right corner.
  URSResizeGrab grab = URSResizeGrabMake(994, 721, 1000, 726);
  PASS(URSResizeGrabWidth(grab, 994) == 1000, "no motion keeps the width");
  PASS(URSResizeGrabHeight(grab, 721) == 726, "no motion keeps the height");
  PASS(URSResizeGrabWidth(grab, 1034) == 1040, "width grows by the pointer delta");
  PASS(URSResizeGrabHeight(grab, 701) == 706, "height shrinks by the pointer delta");

  // Pressed 3 px right of the left edge and 2 px below the top, frame at 200,200.
  URSResizeGrab tl = URSResizeGrabMake(3, 2, 1000, 726);
  PASS(URSResizeGrabLeftEdge(tl, 203) == 200, "no motion keeps the left edge");
  PASS(URSResizeGrabTopEdge(tl, 202) == 200, "no motion keeps the top edge");
  PASS(URSResizeGrabLeftEdge(tl, 150) == 147, "left edge follows the pointer delta");
  END_SET("grab keeps press offset")

  return 0;
}

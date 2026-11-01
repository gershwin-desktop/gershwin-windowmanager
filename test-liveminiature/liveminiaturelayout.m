/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Rules the live miniature geometry must keep.  Headless.
// Run with:  gnustep-tests test-liveminiature

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSLiveMiniatureLayout.m"

static BOOL sameRect(NSRect a, NSRect b)
{
  return fabs(NSMinX(a) - NSMinX(b)) < 0.01 && fabs(NSMinY(a) - NSMinY(b)) < 0.01
    && fabs(NSWidth(a) - NSWidth(b)) < 0.01 && fabs(NSHeight(a) - NSHeight(b)) < 0.01;
}

static BOOL whole(NSRect r)
{
  return NSMinX(r) == floor(NSMinX(r)) && NSMinY(r) == floor(NSMinY(r))
    && NSWidth(r) == floor(NSWidth(r)) && NSHeight(r) == floor(NSHeight(r));
}

int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  NSRect tile = NSMakeRect(1000, 1020, 60, 60);
  NSRect r;

  START_SET("paint rect")
    r = [URSLiveMiniatureLayout paintRectForTile: tile
                                      windowSize: NSMakeSize(800, 600)
                                           inset: 4];
    PASS(sameRect(r, NSMakeRect(1004, 1030, 52, 39)),
         "a wide window fills the width less the inset and is centred vertically");
    PASS(whole(r), "the rect lies on whole pixels");

    r = [URSLiveMiniatureLayout paintRectForTile: tile
                                      windowSize: NSMakeSize(300, 900)
                                           inset: 4];
    PASS(fabs(NSHeight(r) - 52) < 0.01 && fabs(NSMidX(r) - NSMidX(tile)) <= 0.5,
         "a tall window fills the height less the inset and is centred horizontally");
    PASS(NSContainsRect(NSInsetRect(tile, 4, 4), r), "the rect stays inside the inset tile");

    r = [URSLiveMiniatureLayout paintRectForTile: tile
                                      windowSize: NSMakeSize(1000, 1)
                                           inset: 4];
    PASS(NSHeight(r) >= 1, "a sliver of a window still gets one pixel");

    r = [URSLiveMiniatureLayout paintRectForTile: tile
                                      windowSize: NSMakeSize(0, 600)
                                           inset: 4];
    PASS(NSIsEmptyRect(r), "a window without a size shows nothing");

    r = [URSLiveMiniatureLayout paintRectForTile: NSMakeRect(0, 0, 6, 6)
                                      windowSize: NSMakeSize(800, 600)
                                           inset: 4];
    PASS(NSIsEmptyRect(r), "a tile smaller than its inset shows nothing");

    r = [URSLiveMiniatureLayout paintRectForTile: NSMakeRect(1000, 1020, 80, 80)
                                      windowSize: NSMakeSize(40, 30)
                                           inset: 0];
    PASS(fabs(NSWidth(r) - 80) < 0.01 && fabs(NSHeight(r) - 60) < 0.01,
         "a window smaller than its tile is scaled up to fit");
  END_SET("paint rect")

  START_SET("repaint throttle")
    PASS([URSLiveMiniatureLayout repaintDelaySinceLastPaint: 0 now: 100 minInterval: 1.0/30] == 0,
         "a miniature never painted is painted at once");
    PASS([URSLiveMiniatureLayout repaintDelaySinceLastPaint: 100 now: 100.1 minInterval: 1.0/30] == 0,
         "a miniature painted long enough ago is painted at once");
    PASS(fabs([URSLiveMiniatureLayout repaintDelaySinceLastPaint: 100 now: 100.01 minInterval: 1.0/30]
              - (1.0/30 - 0.01)) < 1e-9,
         "a miniature painted just now waits for the rest of the interval");
    PASS([URSLiveMiniatureLayout repaintDelaySinceLastPaint: 100 now: 99 minInterval: 1.0/30] == 0,
         "a clock that went back does not hold the miniature");
  END_SET("repaint throttle")

  [pool release];
  return 0;
}

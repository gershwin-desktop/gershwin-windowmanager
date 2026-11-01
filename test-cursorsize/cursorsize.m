/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The pointer's size per monitor: 24 px x the factor of the monitor, the
// size libXcursor picks itself when every monitor runs at 1.0, which factor
// the pointer has where, and the Xcursor.size resource for other
// applications.  Headless.  Run with:  gnustep-tests test-cursorsize

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "URSCursorSize.h"

static NSValue *R(CGFloat x, CGFloat y, CGFloat w, CGFloat h)
{
  return [NSValue valueWithRect:NSMakeRect(x, y, w, h)];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("pixel size")
  PASS(URSCursorPixelSize(1.0, YES) == 0, "every monitor at 1.0: libXcursor's own size");
  PASS(URSCursorPixelSize(1.0, NO) == 24, "a 1.0 monitor next to a scaled one: 24 px");
  PASS(URSCursorPixelSize(1.25, NO) == 30, "a 1.25 monitor: 30 px");
  PASS(URSCursorPixelSize(2.0, NO) == 48, "a 2.0 monitor: 48 px");
  PASS(URSCursorPixelSize(1.1, NO) == 26, "rounded to whole pixels");
  PASS(URSCursorPixelSize(0, NO) == 24, "an unknown factor counts as 1.0");
  END_SET("pixel size")

  START_SET("all factors one")
  PASS(URSCursorFactorsAllOne(@[@1.0], 0), "one monitor, no GSScaleFactor");
  PASS(URSCursorFactorsAllOne(@[@1.0, @1.0], 1.0), "two monitors at 1.0, GSScaleFactor 1");
  PASS(!URSCursorFactorsAllOne(@[@1.0], 1.25), "GSScaleFactor 1.25 scales the one monitor");
  PASS(!URSCursorFactorsAllOne(@[@1.25, @1.0], 1.0), "mixed monitors");
  PASS(!URSCursorFactorsAllOne(@[@1.25, @1.0], 0), "mixed monitors, no GSScaleFactor");
  END_SET("all factors one")

  START_SET("factor at a point")
  {
    NSArray *rects = @[R(0, 0, 1920, 1080), R(1920, 463, 1920, 1080)];
    NSArray *mixed = @[@1.25, @1.0];
    NSArray *same = @[@1.0, @1.0];

    PASS(URSCursorFactorAtPoint(NSMakePoint(1500, 500), rects, mixed, 1.25) == 1.25,
         "on the 1.25 monitor");
    PASS(URSCursorFactorAtPoint(NSMakePoint(1919, 600), rects, mixed, 1.25) == 1.25,
         "its last column");
    PASS(URSCursorFactorAtPoint(NSMakePoint(1920, 600), rects, mixed, 1.25) == 1.0,
         "the first column of the 1.0 monitor");
    PASS(URSCursorFactorAtPoint(NSMakePoint(3000, 1542), rects, mixed, 1.25) == 1.0,
         "its last row");
    PASS(URSCursorFactorAtPoint(NSMakePoint(3000, 100), rects, mixed, 1.25) == 1.25,
         "on no monitor: the first monitor's factor");
    PASS(URSCursorFactorAtPoint(NSMakePoint(3000, 1000), rects, same, 1.25) == 1.25,
         "one factor everywhere: GSScaleFactor");
    PASS(URSCursorFactorAtPoint(NSMakePoint(3000, 1000), rects, same, 0) == 1.0,
         "one factor everywhere, GSScaleFactor unset: 1.0");
  }
  END_SET("factor at a point")

  START_SET("Xcursor.size resource")
  PASS_EQUAL(URSResourcesWithCursorSize(@"", 30), @"Xcursor.size:\t30\n",
             "added to empty resources");
  PASS_EQUAL(URSResourcesWithCursorSize(nil, 30), @"Xcursor.size:\t30\n",
             "added when there are none");
  PASS_EQUAL(URSResourcesWithCursorSize(@"Xft.dpi:\t120\n", 30),
             @"Xft.dpi:\t120\nXcursor.size:\t30\n", "other resources stay");
  PASS_EQUAL(URSResourcesWithCursorSize(@"Xcursor.size:\t24\nXft.dpi:\t96\n", 30),
             @"Xft.dpi:\t96\nXcursor.size:\t30\n", "an old size is replaced");
  PASS_EQUAL(URSResourcesWithCursorSize(@"Xft.dpi:\t96\nXcursor.size:\t30\n", 0),
             @"Xft.dpi:\t96\n", "size 0 removes it");
  PASS_EQUAL(URSResourcesWithCursorSize(@"Xft.dpi:\t96", 24),
             @"Xft.dpi:\t96\nXcursor.size:\t24\n", "a last line without newline");
  PASS_EQUAL(URSResourcesWithCursorSize(@"Xcursor.sizeX:\t1\n", 24),
             @"Xcursor.sizeX:\t1\nXcursor.size:\t24\n", "only the exact name is replaced");
  PASS_EQUAL(URSResourceValue(@"Xft.dpi:\t96\nXcursor.theme:  Adwaita \n", @"Xcursor.theme"),
             @"Adwaita", "a value, trimmed");
  PASS(URSResourceValue(@"Xft.dpi:\t96\n", @"Xcursor.theme") == nil, "an unset value");
  END_SET("Xcursor.size resource")

  [arp release];
  return 0;
}

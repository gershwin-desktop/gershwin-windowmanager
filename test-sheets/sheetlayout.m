/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Rules a sheet's place on its parent window must keep.  Headless.
// Run with:  gnustep-tests test-sheets

#import <Foundation/Foundation.h>
#import <math.h>
#import "Testing.h"
#include "../WindowManager/URSSheetLayout.m"

static const NSRect kScreen = {{0, 0}, {1920, 1080}};

static NSRect sheetOn(NSRect parentContent, NSSize size)
{
  return [URSSheetLayout frameForSheetSize: size
                         parentContentRect: parentContent
                                screenRect: kScreen];
}

static BOOL near(double a, double b)
{
  return fabs(a - b) < 1e-9;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSSize size = NSMakeSize(300, 150);
  NSRect content = NSMakeRect(100, 130, 600, 400);

  START_SET("placement")
    NSRect s = sheetOn(content, size);
    PASS(near(NSWidth(s), 300) && near(NSHeight(s), 150),
         "the sheet keeps its own size");
    PASS(near(NSMinY(s), NSMinY(content)),
         "the sheet hangs from the top of the parent's content, below its titlebar");
    PASS(near(NSMidX(s), NSMidX(content)),
         "the sheet is centred horizontally on its parent");
  END_SET("placement")

  START_SET("following the parent")
    NSRect before = sheetOn(content, size);
    NSRect moved = sheetOn(NSOffsetRect(content, 57, 33), size);
    PASS(near(NSMinX(moved) - NSMinX(before), 57) &&
         near(NSMinY(moved) - NSMinY(before), 33),
         "moving the parent moves the sheet by the same delta");
    PASS(near(NSWidth(moved), NSWidth(before)) &&
         near(NSHeight(moved), NSHeight(before)),
         "moving the parent does not resize the sheet");

    NSRect wider = content;
    wider.size.width += 100;
    wider.size.height += 80;
    NSRect resized = sheetOn(wider, size);
    PASS(near(NSMinX(resized) - NSMinX(before), 50),
         "a parent grown wider keeps the sheet centred (half the growth)");
    PASS(near(NSMinY(resized), NSMinY(before)),
         "a parent grown taller leaves the sheet at its top");
  END_SET("following the parent")

  START_SET("screen edges")
    NSRect offRight = NSMakeRect(1700, 130, 600, 400);
    NSRect s = sheetOn(offRight, size);
    PASS(NSMaxX(s) <= NSMaxX(kScreen) + 1e-9,
         "a parent hanging off the right edge keeps the sheet on the screen");
    PASS(near(NSMinY(s), 130),
         "keeping it on the screen sideways does not detach it from the titlebar");

    NSRect offLeft = NSMakeRect(-500, 130, 600, 400);
    s = sheetOn(offLeft, size);
    PASS(NSMinX(s) >= NSMinX(kScreen) - 1e-9,
         "a parent hanging off the left edge keeps the sheet on the screen");

    s = sheetOn(content, NSMakeSize(2400, 150));
    PASS(near(NSMinX(s), NSMinX(kScreen)),
         "a sheet wider than the screen starts at its left edge");

    s = sheetOn(NSMakeRect(100, -40, 600, 400), size);
    PASS(NSMinY(s) >= NSMinY(kScreen) - 1e-9,
         "a sheet never starts above the top of the screen");
  END_SET("screen edges")

  START_SET("slide curve")
    PASS(near([URSSheetLayout hiddenFractionAtProgress: 0 appearing: YES], 1.0),
         "coming out starts fully tucked under the titlebar");
    PASS(near([URSSheetLayout hiddenFractionAtProgress: 1 appearing: YES], 0.0),
         "coming out ends fully out");
    PASS(near([URSSheetLayout hiddenFractionAtProgress: 0.5 appearing: YES], 0.125),
         "coming out is an ease-out: 7/8 of the way out at half time");
    PASS(near([URSSheetLayout hiddenFractionAtProgress: 0 appearing: NO], 0.0),
         "going back starts fully out");
    PASS(near([URSSheetLayout hiddenFractionAtProgress: 1 appearing: NO], 1.0),
         "going back ends fully tucked away");
    PASS(near([URSSheetLayout hiddenFractionAtProgress: 0.5 appearing: NO], 0.125),
         "going back is an ease-in: only 1/8 of the way at half time");
    PASS(near([URSSheetLayout hiddenFractionAtProgress: -0.3 appearing: YES], 1.0) &&
         near([URSSheetLayout hiddenFractionAtProgress: 1.7 appearing: YES], 0.0),
         "progress outside 0..1 is clamped");

    BOOL monotonic = YES;
    double last = 2.0;
    for (int i = 0; i <= 100; i++) {
      double h = [URSSheetLayout hiddenFractionAtProgress: i / 100.0 appearing: YES];
      if (h > last) monotonic = NO;
      last = h;
    }
    PASS(monotonic, "coming out never slides back (no overshoot over the titlebar)");
  END_SET("slide curve")

  [arp release];
  return 0;
}

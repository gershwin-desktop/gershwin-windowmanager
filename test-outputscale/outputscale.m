/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Per-monitor scale factors: the factor of a monitor's DPI property, when
// monitors count as mixed, which monitor a frame belongs to while it is
// dragged across (with hysteresis), and the frame extents a client is told.
// Headless.  Run with:  gnustep-tests test-outputscale

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "URSOutputScale.h"

static NSValue *R(CGFloat x, CGFloat y, CGFloat w, CGFloat h)
{
  return [NSValue valueWithRect:NSMakeRect(x, y, w, h)];
}

static BOOL sameExtents(URSFrameExtents e, uint32_t l, uint32_t r, uint32_t t, uint32_t b)
{
  return e.left == l && e.right == r && e.top == t && e.bottom == b;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("factor of a DPI")
    PASS(URSScaleFactorForDPI(96) == 1.0, "96 DPI is 1.0x");
    PASS(URSScaleFactorForDPI(192) == 2.0, "192 DPI is 2.0x");
    PASS(URSScaleFactorForDPI(144) == 1.5, "144 DPI is 1.5x");
    PASS(URSScaleFactorForDPI(0) == 0.0, "0 is no DPI");
    PASS(URSScaleFactorForDPI(-5) == 0.0, "a negative value is no DPI");
  END_SET("factor of a DPI")

  START_SET("mixed monitors")
    PASS(!URSOutputScalesAreMixed(@[]), "no monitors are not mixed");
    PASS(!URSOutputScalesAreMixed(@[ @2.0 ]), "one monitor is not mixed");
    PASS(!URSOutputScalesAreMixed(@[ @1.0, @1.0 ]), "equal factors are not mixed");
    PASS(!URSOutputScalesAreMixed(@[ @0.0, @2.0 ]), "an unknown factor does not count");
    PASS(URSOutputScalesAreMixed(@[ @1.0, @2.0 ]), "1.0 and 2.0 are mixed");
    PASS(URSOutputScalesAreMixed(@[ @2.0, @0.0, @1.0 ]), "mixed around an unknown one");
  END_SET("mixed monitors")

  // A: 2048x1536 at 2.0x (title bar 44), B: 1920x1080 to its right at 1.0x (22)
  NSArray *side = @[ R(0, 0, 2048, 1536), R(2048, 0, 1920, 1080) ];
  NSArray *sideTitles = @[ @44, @22 ];

  START_SET("output of a new frame")
    PASS(URSOutputForFrame(NSMakeRect(100, 100, 600, 444), side, sideTitles, NSNotFound, 0) == 0,
         "a frame on A belongs to A");
    PASS(URSOutputForFrame(NSMakeRect(1900, 100, 600, 422), side, sideTitles, NSNotFound, 0) == 1,
         "a frame mostly on B belongs to B");
    PASS(URSOutputForFrame(NSMakeRect(5000, 100, 600, 422), side, sideTitles, NSNotFound, 0) == NSNotFound,
         "a frame on no monitor belongs to none");
    PASS(URSOutputForFrame(NSMakeRect(100, 100, 600, 444), side, sideTitles, 7, 44) == 0,
         "an output index that no longer exists counts as none");
  END_SET("output of a new frame")

  START_SET("hysteresis across a vertical edge")
    // Frame 600 wide on A, its middle d pixels past the edge at x = 2048
    NSRect f = NSMakeRect(2048 - 300 + 2, 100, 600, 444);
    PASS(URSOutputForFrame(f, side, sideTitles, 0, 44) == 0,
         "2 px past the middle the frame stays on A");
    f = NSMakeRect(2048 - 300 + 10, 100, 600, 444);
    PASS(URSOutputForFrame(f, side, sideTitles, 0, 44) == 1,
         "10 px past the middle the frame moves to B");
    f = NSMakeRect(2048 - 300 - 2, 100, 600, 422);
    PASS(URSOutputForFrame(f, side, sideTitles, 1, 22) == 1,
         "dragged back 2 px past the middle the frame stays on B");
    f = NSMakeRect(2048 - 300 - 10, 100, 600, 422);
    PASS(URSOutputForFrame(f, side, sideTitles, 1, 22) == 0,
         "dragged back 10 px past the middle it returns to A");
    f = NSMakeRect(2500, 100, 600, 444);
    PASS(URSOutputForFrame(f, side, sideTitles, 0, 44) == 1,
         "a frame that left its output entirely moves without margin");
    f = NSMakeRect(5000, 100, 600, 444);
    PASS(URSOutputForFrame(f, side, sideTitles, 0, 44) == NSNotFound,
         "a frame on no monitor belongs to none");
  END_SET("hysteresis across a vertical edge")

  // A on top at 2.0x, B below at 1.0x; the title bar grows downwards
  NSArray *stack = @[ R(0, 0, 2048, 1000), R(0, 1000, 2048, 1000) ];

  START_SET("no oscillation across a horizontal edge")
    // On B with a 22 px title: 220 px on A, 202 on B.  On A's 44 px title
    // the frame would reach 24 px further down, 224 on B: B again.
    NSRect f = NSMakeRect(100, 780, 600, 422);
    PASS(URSOutputForFrame(f, stack, sideTitles, 1, 22) == 1,
         "the frame stays on B while A's taller title bar would hand it back");
    f = NSMakeRect(100, 760, 600, 422);
    PASS(URSOutputForFrame(f, stack, sideTitles, 1, 22) == 0,
         "20 px further up it moves to A");
    f = NSMakeRect(100, 760, 600, 444);
    PASS(URSOutputForFrame(f, stack, sideTitles, 0, 44) == 0,
         "after the switch, with the taller title bar, it stays on A");
  END_SET("no oscillation across a horizontal edge")

  START_SET("frame extents")
    PASS(sameExtents(URSFrameExtentsFor(22, 1.0, YES, 0), 0, 0, 22, 0),
         "with the compositor there is no client border");
    PASS(sameExtents(URSFrameExtentsFor(22, 1.0, NO, 0), 1, 1, 22, 1),
         "without it one pixel at 1.0x");
    PASS(sameExtents(URSFrameExtentsFor(44, 2.0, NO, 0), 2, 2, 44, 2),
         "two pixels at 2.0x");
    PASS(sameExtents(URSFrameExtentsFor(33, 1.5, NO, 0), 1, 1, 33, 1),
         "whole pixels only at 1.5x");
    PASS(sameExtents(URSFrameExtentsFor(22, 2.0, YES, 3), 3, 3, 22, 3),
         "a theme's own border decides the inset");
    PASS(URSClientBorderFor(2.0, NO, 0) == 2, "client border at 2.0x");
  END_SET("frame extents")

  START_SET("utility title bar")
    PASS(URSUtilityTitleHeightFor(1.0) == 16, "16 px at 1.0x");
    PASS(URSUtilityTitleHeightFor(2.0) == 32, "32 px at 2.0x");
    PASS(URSUtilityTitleHeightFor(0.01) == 1, "never below one pixel");
  END_SET("utility title bar")

  [arp release];
  return 0;
}

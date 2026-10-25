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

  // A: 2048x1536 at 2.0x (title bar 44), B: 1920x1080 to its right at 1.0x
  // (title bar 22), no client border (compositor).  The client is
  // 300x200 points.
  NSArray *side = @[ R(0, 0, 2048, 1536), R(2048, 0, 1920, 1080) ];
  CGFloat two[2] = { 2.0, 1.0 };
  URSDecoration onA = { 2.0, 44, 0 }, onB = { 1.0, 22, 0 }, none = { 0, 0, 0 };
  NSSize pts = NSMakeSize(300, 200);

  START_SET("output of a new frame")
    PASS(URSOutputForFrame(NSMakeRect(100, 100, 600, 444), side, two, NSNotFound, none, pts) == 0,
         "a frame on A belongs to A");
    PASS(URSOutputForFrame(NSMakeRect(1900, 100, 600, 422), side, two, NSNotFound, none, pts) == 1,
         "a frame mostly on B belongs to B");
    PASS(URSOutputForFrame(NSMakeRect(5000, 100, 600, 422), side, two, NSNotFound, none, pts) == NSNotFound,
         "a frame on no monitor belongs to none");
    PASS(URSOutputForFrame(NSMakeRect(100, 100, 600, 444), side, two, 7, onA, pts) == 0,
         "an output index that no longer exists counts as none");
  END_SET("output of a new frame")

  START_SET("switching where libs-gui switches")
    // On A the frame is 600x444.  libs-gui would make it 300x244 on B (the
    // content at 1x plus the 44 px extents it knows), top-left kept; B must
    // hold more of that than A holds of the 600x444 frame by 8 * 244.
    PASS(URSOutputForFrame(NSMakeRect(1756, 100, 600, 444), side, two, 0, onA, pts) == 0,
         "at the middle of the 2x frame it stays on A");
    PASS(URSOutputForFrame(NSMakeRect(1944, 100, 600, 444), side, two, 0, onA, pts) == 0,
         "at x 1944 B does not win by the margin yet");
    PASS(URSOutputForFrame(NSMakeRect(1945, 100, 600, 444), side, two, 0, onA, pts) == 1,
         "at x 1945 it moves to B");
    // Back: frame 300x222 on B; on A it would be 600x422, margin 8 * 422.
    // Like libs-gui, which looks only once -screen (the largest part of the
    // frame as it is) has changed, A is a candidate only while it holds
    // most of the 300 px frame, from x 1897 on.
    PASS(URSOutputForFrame(NSMakeRect(1939, 100, 300, 222), side, two, 1, onB, pts) == 1,
         "dragged back to x 1939 it stays on B while B holds most of the frame");
    PASS(URSOutputForFrame(NSMakeRect(1899, 100, 300, 222), side, two, 1, onB, pts) == 1,
         "at x 1899 it still stays on B");
    PASS(URSOutputForFrame(NSMakeRect(1897, 100, 300, 222), side, two, 1, onB, pts) == 0,
         "at x 1897 it returns to A");
    // Just switched to B, the client still 600x400 px (300x200 points at
    // 2x, not followed yet): judged by its points it stays on B.
    PASS(URSOutputForFrame(NSMakeRect(1945, 100, 600, 422), side, two, 1, onB, pts) == 1,
         "a client that has not followed the switch yet does not send it back");
    PASS(URSOutputForFrame(NSMakeRect(2500, 100, 600, 444), side, two, 0, onA, pts) == 1,
         "a frame that left its factor's outputs entirely moves without margin");
    PASS(URSOutputForFrame(NSMakeRect(5000, 100, 600, 444), side, two, 0, onA, pts) == NSNotFound,
         "a frame on no monitor belongs to none");
  END_SET("switching where libs-gui switches")

  START_SET("across a horizontal edge")
    // A on top at 2.0x, B below at 1.0x.  On B the frame is 300x222; on A
    // libs-gui would make it 600x422 from the same top-left corner.
    NSArray *stack = @[ R(0, 0, 2048, 1000), R(0, 1000, 2048, 1000) ];
    PASS(URSOutputForFrame(NSMakeRect(100, 922, 300, 222), stack, two, 1, onB, pts) == 1,
         "with its top at y 922 it stays on B, which holds most of it");
    PASS(URSOutputForFrame(NSMakeRect(100, 890, 300, 222), stack, two, 1, onB, pts) == 1,
         "at y 890 too");
    PASS(URSOutputForFrame(NSMakeRect(100, 888, 300, 222), stack, two, 1, onB, pts) == 0,
         "at y 888 it moves to A");
  END_SET("across a horizontal edge")

  START_SET("outputs of the same factor")
    NSArray *three = @[ R(0, 0, 2048, 1536), R(2048, 0, 2048, 1536), R(4096, 0, 1920, 1080) ];
    CGFloat f3[3] = { 2.0, 2.0, 1.0 };
    PASS(URSOutputForFrame(NSMakeRect(1900, 100, 600, 444), three, f3, 0, onA, pts) == 1,
         "between two monitors of one factor the frame follows the larger part");
  END_SET("outputs of the same factor")

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

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Where windows go when a monitor goes away, whether the pointer is still on
// a monitor, and the usable area of each monitor under the panels' struts.
// Headless.  Run with:  gnustep-tests test-displayrescue

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "URSMonitorGeometry.h"

static NSValue *R(CGFloat x, CGFloat y, CGFloat w, CGFloat h)
{
  return [NSValue valueWithRect:NSMakeRect(x, y, w, h)];
}

static BOOL same(NSRect a, CGFloat x, CGFloat y, CGFloat w, CGFloat h)
{
  return NSEqualRects(a, NSMakeRect(x, y, w, h));
}

static NSDictionary *topStrut(uint32_t top, uint32_t startX, uint32_t endX)
{
  return @{ @"left": @0, @"right": @0, @"top": @(top), @"bottom": @0,
            @"left_start_y": @0, @"left_end_y": @0,
            @"right_start_y": @0, @"right_end_y": @0,
            @"top_start_x": @(startX), @"top_end_x": @(endX),
            @"bottom_start_x": @0, @"bottom_end_x": @0, @"isPartial": @YES };
}

static NSDictionary *bottomStrut(uint32_t bottom, uint32_t startX, uint32_t endX)
{
  return @{ @"left": @0, @"right": @0, @"top": @0, @"bottom": @(bottom),
            @"left_start_y": @0, @"left_end_y": @0,
            @"right_start_y": @0, @"right_end_y": @0,
            @"top_start_x": @0, @"top_end_x": @0,
            @"bottom_start_x": @(startX), @"bottom_end_x": @(endX), @"isPartial": @YES };
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  // A 1920x1080 primary at the left, a 1280x1024 monitor to its right
  NSArray *two = @[ R(0, 0, 1920, 1080), R(1920, 0, 1280, 1024) ];

  START_SET("window rescue")
    NSRect f = URSRescueFrame(NSMakeRect(100, 100, 800, 600), 22, two, 0, YES);
    PASS(same(f, 100, 100, 800, 600), "a window on a monitor stays where it is");

    f = URSRescueFrame(NSMakeRect(2000, 100, 800, 600), 22, two, 0, YES);
    PASS(same(f, 2000, 100, 800, 600), "a window on the second monitor stays too");

    NSArray *one = @[ R(0, 0, 1920, 1080) ];
    f = URSRescueFrame(NSMakeRect(2000, 100, 800, 600), 22, one, 0, YES);
    PASS(same(f, 560, 240, 800, 600),
         "a window on a monitor that went away is centered on the primary, same size");

    f = URSRescueFrame(NSMakeRect(1880, 100, 800, 600), 22, one, 0, YES);
    PASS(same(f, 1120, 100, 800, 600),
         "a window hanging off the edge with too little title bar left is pulled fully on");

    f = URSRescueFrame(NSMakeRect(1500, 100, 800, 600), 22, one, 0, YES);
    PASS(same(f, 1500, 100, 800, 600),
         "a window partly off the edge whose title bar can still be grabbed stays");

    f = URSRescueFrame(NSMakeRect(300, -10, 800, 600), 22, one, 0, YES);
    PASS(same(f, 300, 0, 800, 600), "a title bar above the top edge comes down");

    f = URSRescueFrame(NSMakeRect(300, 1070, 800, 600), 22, one, 0, YES);
    PASS(same(f, 300, 480, 800, 600),
         "a window whose title bar is below the bottom edge is moved up onto the monitor");

    f = URSRescueFrame(NSMakeRect(2100, 50, 2400, 1400), 22, one, 0, YES);
    PASS(same(f, 0, 0, 1920, 1080), "a window larger than the target is shrunk to it");

    f = URSRescueFrame(NSMakeRect(2100, 50, 2400, 1400), 22, one, 0, NO);
    PASS(same(f, 0, 0, 2400, 1400),
         "a fixed-size window larger than the target keeps its size at the top-left corner");

    NSArray *workareas = @[ R(0, 22, 1920, 1058), R(1920, 0, 1280, 1024) ];
    f = URSRescueFrame(NSMakeRect(3500, 100, 800, 600), 22, workareas, 0, YES);
    PASS(same(f, 560, 251, 800, 600), "the menu bar of the primary is respected");

    NSArray *rightPrimary = @[ R(0, 0, 1920, 1080), R(1920, 0, 1280, 1024) ];
    f = URSRescueFrame(NSMakeRect(-900, 100, 800, 600), 22, rightPrimary, 1, YES);
    PASS(same(f, 2160, 212, 800, 600), "it goes onto the primary, wherever that is");
  END_SET("window rescue")

  START_SET("pointer")
    PASS(URSPointIsOnRects(NSMakePoint(1919, 1079), two), "the last pixel of a monitor is on it");
    PASS(URSPointIsOnRects(NSMakePoint(2500, 500), two), "a point on the second monitor is on it");
    PASS(!URSPointIsOnRects(NSMakePoint(2500, 1050), two),
         "below the shorter monitor is on no monitor");
    PASS(!URSPointIsOnRects(NSMakePoint(2500, 500), @[ R(0, 0, 1920, 1080) ]),
         "where an unplugged monitor was is on no monitor");
  END_SET("pointer")

  START_SET("usable area per monitor")
    NSSize screen = NSMakeSize(3200, 1080);
    NSArray *struts = @[ topStrut(22, 0, 1919) ];
    PASS(same(URSUsableRectForMonitor(NSMakeRect(0, 0, 1920, 1080), screen, struts), 0, 22, 1920, 1058),
         "a menu bar on the primary reserves its height there");
    PASS(same(URSUsableRectForMonitor(NSMakeRect(1920, 0, 1280, 1024), screen, struts), 1920, 0, 1280, 1024),
         "outside its range the other monitor keeps its full height");

    // The primary below a second monitor: the menu bar's strut counts from
    // the screen top, past the upper monitor.
    NSSize tall = NSMakeSize(1920, 2160);
    NSArray *stacked = @[ topStrut(1080 + 22, 0, 1919) ];
    PASS(same(URSUsableRectForMonitor(NSMakeRect(0, 1080, 1920, 1080), tall, stacked), 0, 1102, 1920, 1058),
         "a menu bar on a lower monitor reserves only its height on that monitor");
    PASS(same(URSUsableRectForMonitor(NSMakeRect(0, 0, 1920, 1080), tall, stacked), 0, 0, 1920, 1080),
         "and nothing on the monitor above it");

    NSArray *dock = @[ bottomStrut(64, 0, 1919) ];
    PASS(same(URSUsableRectForMonitor(NSMakeRect(0, 0, 1920, 1080), screen, dock), 0, 0, 1920, 1016),
         "a dock at the bottom of the primary reserves its height there");
    NSSize unequal = NSMakeSize(3200, 1080);
    PASS(same(URSUsableRectForMonitor(NSMakeRect(1920, 0, 1280, 1024), unequal,
                                      @[ bottomStrut(56 + 64, 1920, 3199) ]), 1920, 0, 1280, 960),
         "a dock at the bottom of the shorter monitor counts from the screen bottom");

    NSDictionary *full = @{ @"left": @0, @"right": @0, @"top": @30, @"bottom": @0, @"isPartial": @NO };
    PASS(same(URSUsableRectForMonitor(NSMakeRect(1920, 0, 1280, 1024), screen, @[ full ]), 1920, 30, 1280, 994),
         "a strut without ranges covers the whole edge");
  END_SET("usable area per monitor")

  START_SET("_NET_WORKAREA")
    NSArray *monitors = @[ R(0, 0, 1920, 1080), R(1920, 0, 1280, 1024) ];
    PASS(same(URSWorkareaForScreen(NSMakeSize(3200, 1080), monitors, @[ topStrut(22, 0, 1919) ]),
              0, 22, 3200, 1058),
         "a menu bar along the screen top is left out of the workarea");
    NSArray *stackedMonitors = @[ R(0, 0, 1920, 1080), R(0, 1080, 1920, 1080) ];
    PASS(same(URSWorkareaForScreen(NSMakeSize(1920, 2160), stackedMonitors,
                                   @[ topStrut(1080 + 22, 0, 1919) ]),
              0, 0, 1920, 2160),
         "a menu bar on an inner edge does not shrink the workarea of the whole screen");
  END_SET("_NET_WORKAREA")

  START_SET("maximize and fullscreen on stacked monitors")
    // 1280x1024 above, the 1280x480 primary below with a 22 pixel menu bar:
    // the phase 3 setup where maximize spanned both (1280x1504 at 0,0).
    NSArray *mons = @[ R(0, 0, 1280, 1024), R(0, 1024, 1280, 480) ];
    NSArray *use = @[ R(0, 0, 1280, 1024), R(0, 1046, 1280, 458) ];
    NSRect lower = NSMakeRect(100, 1100, 400, 300);
    NSRect upper = NSMakeRect(100, 100, 400, 300);
    PASS(URSMonitorIndexForRect(lower, mons, 1) == 1, "a window on the lower monitor belongs to it");
    PASS(URSMonitorIndexForRect(NSMakeRect(100, 800, 400, 300), mons, 1) == 0,
         "a window straddling both belongs to the one it overlaps most");
    PASS(URSMonitorIndexForRect(NSMakeRect(5000, 5000, 10, 10), mons, 1) == 1,
         "a window on no monitor belongs to the primary");
    PASS(same(URSMaximizedRect(lower, mons, use, 1), 0, 1046, 1280, 458),
         "maximize fills the lower monitor below its menu bar, not both monitors");
    PASS(same(URSMaximizedRect(upper, mons, use, 1), 0, 0, 1280, 1024),
         "maximize on the upper monitor fills only that one");
    PASS(same(URSFullscreenRect(lower, mons, 1), 0, 1024, 1280, 480),
         "fullscreen covers the whole lower monitor, menu bar included");
    PASS(same(URSFullscreenRect(upper, mons, 1), 0, 0, 1280, 1024),
         "fullscreen on the upper monitor covers only that one");
  END_SET("maximize and fullscreen on stacked monitors")

  [arp release];
  return 0;
}

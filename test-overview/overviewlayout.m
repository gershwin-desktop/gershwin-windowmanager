/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Rules the window overview layout must keep.  Headless.
// Run with:  gnustep-tests test-overview

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSOverviewLayout.m"

static NSArray *rects(NSUInteger count, const NSRect *r)
{
  NSMutableArray *a = [NSMutableArray array];
  for (NSUInteger i = 0; i < count; i++) {
    [a addObject: [NSValue valueWithRect: r[i]]];
  }
  return a;
}

static BOOL allInside(NSArray *slots, NSRect area)
{
  for (NSValue *v in slots) {
    NSRect s = [v rectValue];
    if (NSMinX(s) < NSMinX(area) - 0.5 || NSMinY(s) < NSMinY(area) - 0.5
        || NSMaxX(s) > NSMaxX(area) + 0.5 || NSMaxY(s) > NSMaxY(area) + 0.5) {
      return NO;
    }
  }
  return YES;
}

static BOOL noneOverlap(NSArray *slots)
{
  for (NSUInteger i = 0; i < [slots count]; i++) {
    for (NSUInteger j = i + 1; j < [slots count]; j++) {
      NSRect a = NSInsetRect([[slots objectAtIndex: i] rectValue], 0.5, 0.5);
      NSRect b = NSInsetRect([[slots objectAtIndex: j] rectValue], 0.5, 0.5);
      if (NSIntersectsRect(a, b)) return NO;
    }
  }
  return YES;
}

static BOOL shapesKept(NSArray *windows, NSArray *slots)
{
  for (NSUInteger i = 0; i < [windows count]; i++) {
    NSRect w = [[windows objectAtIndex: i] rectValue];
    NSRect s = [[slots objectAtIndex: i] rectValue];
    if (NSWidth(s) > NSWidth(w) + 0.5 || NSHeight(s) > NSHeight(w) + 0.5) return NO;
    double aw = NSWidth(w) / NSHeight(w);
    double as = NSWidth(s) / NSHeight(s);
    if (fabs(aw - as) > aw * 0.02) return NO;
  }
  return YES;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSRect screen = NSMakeRect(0, 22, 1920, 1058);
  NSArray *slots;

  slots = [URSOverviewLayout slotsForWindowRects: [NSArray array]
                                          inArea: screen spacing: 24];
  PASS([slots count] == 0, "no windows give no slots");

  {
    NSRect r[] = { NSMakeRect(700, 400, 400, 300) };
    NSArray *w = rects(1, r);
    slots = [URSOverviewLayout slotsForWindowRects: w inArea: screen spacing: 24];
    NSRect s = [[slots objectAtIndex: 0] rectValue];
    PASS([slots count] == 1, "one slot per window");
    PASS(NSWidth(s) == 400 && NSHeight(s) == 300,
         "a window that fits keeps its size");
  }

  {
    NSRect r[] = { NSMakeRect(1000, 100, 900, 700), NSMakeRect(20, 150, 900, 700) };
    NSArray *w = rects(2, r);
    slots = [URSOverviewLayout slotsForWindowRects: w inArea: screen spacing: 24];
    PASS(NSMinX([[slots objectAtIndex: 1] rectValue])
         < NSMinX([[slots objectAtIndex: 0] rectValue]),
         "a window on the left stays left of one on the right");
    PASS(noneOverlap(slots), "side by side windows do not overlap");
  }

  {
    NSRect tall = NSMakeRect(0, 0, 800, 2000);
    NSRect r[] = { NSMakeRect(0, 1200, 700, 600), NSMakeRect(50, 100, 700, 600) };
    NSArray *w = rects(2, r);
    slots = [URSOverviewLayout slotsForWindowRects: w inArea: tall spacing: 24];
    PASS(NSMinY([[slots objectAtIndex: 1] rectValue])
         < NSMinY([[slots objectAtIndex: 0] rectValue]),
         "a window above stays above one below");
  }

  {
    NSRect r[6];
    for (int i = 0; i < 6; i++) r[i] = NSMakeRect(300, 200, 1200, 800);
    NSArray *w = rects(6, r);
    slots = [URSOverviewLayout slotsForWindowRects: w inArea: screen spacing: 24];
    PASS([slots count] == 6, "every stacked window gets a slot");
    PASS(noneOverlap(slots), "windows stacked on each other are spread apart");
    PASS(allInside(slots, screen), "spread windows stay inside the area");
    PASS(shapesKept(w, slots), "windows are only shrunk, never distorted");
    PASS(NSWidth([[slots objectAtIndex: 0] rectValue]) > 1200 * 0.3,
         "six windows are still big enough to recognize");
  }

  {
    NSRect r[30];
    for (int i = 0; i < 30; i++) {
      r[i] = NSMakeRect((i * 97) % 1400, 30 + (i * 53) % 600,
                        300 + (i * 31) % 500, 200 + (i * 17) % 400);
    }
    NSArray *w = rects(30, r);
    slots = [URSOverviewLayout slotsForWindowRects: w inArea: screen spacing: 24];
    PASS(noneOverlap(slots), "thirty windows do not overlap");
    PASS(allInside(slots, screen), "thirty windows stay inside the area");
    PASS(shapesKept(w, slots), "thirty windows keep their shapes");
  }

  [arp release];
  return 0;
}

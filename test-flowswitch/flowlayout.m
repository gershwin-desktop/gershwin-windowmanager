/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Rules the Alt-Tab flow layout must keep.  Headless.
// Run with:  gnustep-tests test-flowswitch

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSFlowLayout.m"

static NSArray *sizes(NSUInteger count, const NSSize *s)
{
  NSMutableArray *a = [NSMutableArray array];
  for (NSUInteger i = 0; i < count; i++) {
    [a addObject: [NSValue valueWithSize: s[i]]];
  }
  return a;
}

static NSRect slotAt(NSArray *slots, NSUInteger i)
{
  return [[slots objectAtIndex: i] rectValue];
}

static double areaOf(NSRect r)
{
  return NSWidth(r) * NSHeight(r);
}

static BOOL inside(NSRect s, NSRect area)
{
  return NSMinX(s) >= NSMinX(area) - 0.5 && NSMinY(s) >= NSMinY(area) - 0.5
    && NSMaxX(s) <= NSMaxX(area) + 0.5 && NSMaxY(s) <= NSMaxY(area) + 0.5;
}

static double rectDistance(NSRect a, NSRect b)
{
  return MAX(MAX(fabs(NSMinX(a) - NSMinX(b)), fabs(NSMinY(a) - NSMinY(b))),
             MAX(fabs(NSMaxX(a) - NSMaxX(b)), fabs(NSMaxY(a) - NSMaxY(b))));
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSRect screen = NSMakeRect(0, 0, 1920, 1080);
  NSArray *slots;

  /* Mixed sizes, the third one chosen. */
  {
    NSSize s[] = { {800, 600}, {1200, 900}, {640, 480}, {1000, 400},
                   {500, 700}, {900, 900} };
    NSArray *w = sizes(6, s);
    slots = [URSFlowLayout slotsForWindowSizes: w position: 2 inArea: screen];
    PASS([slots count] == 6, "one slot per window");
    NSRect chosen = slotAt(slots, 2);
    PASS(fabs(NSMidX(chosen) - NSMidX(screen)) < 0.5,
         "the chosen window is centred across the screen");
    PASS(inside(chosen, screen), "the chosen window stays on the screen");
    PASS(fabs(NSWidth(chosen) / NSHeight(chosen) - 640.0 / 480.0) < 0.02,
         "the chosen window keeps its shape");
    PASS(NSWidth(chosen) <= 640.5 && NSHeight(chosen) <= 480.5,
         "the chosen window is never enlarged");
    BOOL largest = YES;
    for (NSUInteger i = 0; i < 6; i++) {
      if (i != 2 && areaOf(slotAt(slots, i)) >= areaOf(chosen)) largest = NO;
    }
    PASS(largest, "the chosen window is the largest");
    BOOL ordered = YES;
    for (NSUInteger i = 1; i < 6; i++) {
      if (NSMidX(slotAt(slots, i)) <= NSMidX(slotAt(slots, i - 1))) ordered = NO;
    }
    PASS(ordered, "the windows follow each other left to right in list order");
    BOOL oneRow = YES;
    for (NSUInteger i = 0; i < 6; i++) {
      if (fabs(NSMidY(slotAt(slots, i)) - NSMidY(chosen)) > 0.5) oneRow = NO;
    }
    PASS(oneRow, "all windows sit on one row");
    NSArray *order = [URSFlowLayout paintOrderForCount: 6 position: 2];
    PASS([order count] == 6, "every window is painted");
    PASS([[order lastObject] unsignedIntegerValue] == 2,
         "the chosen window is painted last, in front");
    PASS([[order objectAtIndex: 0] unsignedIntegerValue] == 5,
         "the farthest window is painted first, at the back");
  }

  /* Equal windows recede symmetrically. */
  {
    NSSize s[7];
    for (int i = 0; i < 7; i++) s[i] = NSMakeSize(1000, 700);
    slots = [URSFlowLayout slotsForWindowSizes: sizes(7, s) position: 3 inArea: screen];
    BOOL mirrored = YES;
    BOOL receding = YES;
    for (NSUInteger k = 1; k <= 3; k++) {
      NSRect l = slotAt(slots, 3 - k);
      NSRect r = slotAt(slots, 3 + k);
      if (fabs((NSMidX(screen) - NSMidX(l)) - (NSMidX(r) - NSMidX(screen))) > 0.5
          || fabs(NSWidth(l) - NSWidth(r)) > 0.5 || fabs(NSHeight(l) - NSHeight(r)) > 0.5) {
        mirrored = NO;
      }
      NSRect nearer = slotAt(slots, 3 + k - 1);
      if (areaOf(r) > areaOf(nearer) + 0.5) receding = NO;
    }
    NSRect chosen = slotAt(slots, 3);
    PASS(NSMinX(slotAt(slots, 4)) < NSMaxX(chosen)
         && NSMaxX(slotAt(slots, 4)) > NSMaxX(chosen),
         "the right neighbour tucks under the chosen window yet shows beside it");
    PASS(NSMaxX(slotAt(slots, 2)) > NSMinX(chosen)
         && NSMinX(slotAt(slots, 2)) < NSMinX(chosen),
         "the left neighbour tucks under the chosen window yet shows beside it");
    PASS(NSMinX(slotAt(slots, 5)) < NSMaxX(slotAt(slots, 4))
         && NSMaxX(slotAt(slots, 5)) > NSMaxX(slotAt(slots, 4)),
         "farther windows overlap like a stack of covers");
    PASS(mirrored, "the row is mirrored around the chosen window");
    PASS(receding, "windows get no bigger away from the chosen one");
    PASS(NSHeight(slotAt(slots, 4)) < NSHeight(slotAt(slots, 3)),
         "a neighbour is smaller than the chosen window");
    PASS(NSWidth(slotAt(slots, 4)) / NSHeight(slotAt(slots, 4))
         < NSWidth(slotAt(slots, 3)) / NSHeight(slotAt(slots, 3)),
         "a neighbour is turned away, narrower than its shape");
  }

  /* Sliding between two positions moves smoothly. */
  {
    NSSize s[] = { {800, 600}, {800, 600}, {800, 600}, {800, 600} };
    NSArray *w = sizes(4, s);
    BOOL continuous = YES;
    for (double p = 0.0; p < 3.0; p += 0.01) {
      NSArray *a = [URSFlowLayout slotsForWindowSizes: w position: p inArea: screen];
      NSArray *b = [URSFlowLayout slotsForWindowSizes: w position: p + 0.01 inArea: screen];
      for (NSUInteger i = 0; i < 4; i++) {
        if (rectDistance(slotAt(a, i), slotAt(b, i)) > 15.0) continuous = NO;
      }
    }
    PASS(continuous, "no window jumps while the row slides");
    NSRect mid = [URSFlowLayout slotForWindowSize: s[1] atIndex: 1
                                         position: 1.5 inArea: screen];
    NSRect at1 = [URSFlowLayout slotForWindowSize: s[1] atIndex: 1
                                         position: 1 inArea: screen];
    NSRect at2 = [URSFlowLayout slotForWindowSize: s[1] atIndex: 1
                                         position: 2 inArea: screen];
    PASS(NSMidX(mid) < NSMidX(at1) && NSMidX(mid) > NSMidX(at2),
         "half way through a slide a window is between its two places");
    NSArray *order = [URSFlowLayout paintOrderForCount: 4 position: 1.2];
    PASS([[order lastObject] unsignedIntegerValue] == 1,
         "while sliding the window nearest the middle is in front");
  }

  /* One and two windows. */
  {
    NSSize one[] = { {400, 300} };
    slots = [URSFlowLayout slotsForWindowSizes: sizes(1, one) position: 0 inArea: screen];
    PASS([slots count] == 1 && fabs(NSMidX(slotAt(slots, 0)) - NSMidX(screen)) < 0.5,
         "a single window is centred");
    PASS(NSWidth(slotAt(slots, 0)) == 400 && NSHeight(slotAt(slots, 0)) == 300,
         "a single small window keeps its size");
    NSArray *order = [URSFlowLayout paintOrderForCount: 1 position: 0];
    PASS([order count] == 1 && [[order objectAtIndex: 0] unsignedIntegerValue] == 0,
         "a single window is painted");

    NSSize two[] = { {900, 700}, {900, 700} };
    slots = [URSFlowLayout slotsForWindowSizes: sizes(2, two) position: 1 inArea: screen];
    PASS(NSMidX(slotAt(slots, 0)) < NSMidX(screen)
         && fabs(NSMidX(slotAt(slots, 1)) - NSMidX(screen)) < 0.5,
         "of two windows the chosen second is centred, the first left of it");
    PASS(areaOf(slotAt(slots, 0)) < areaOf(slotAt(slots, 1)),
         "of two windows the other one is smaller");
    order = [URSFlowLayout paintOrderForCount: 2 position: 1];
    PASS([[order lastObject] unsignedIntegerValue] == 1,
         "of two windows the chosen one is in front");
  }

  /* Huge windows are shrunk to fit. */
  {
    NSSize s[] = { {4000, 3000} };
    NSRect r = [URSFlowLayout slotForWindowSize: s[0] atIndex: 0 position: 0 inArea: screen];
    PASS(inside(r, screen), "a window larger than the screen is shrunk into it");
    PASS(NSHeight(r) < NSHeight(screen) * 0.75,
         "the chosen window leaves room for its title below");
  }

  /* Next and previous go round. */
  PASS([URSFlowLayout indexFrom: 4 step: 1 count: 5] == 0, "next after the last is the first");
  PASS([URSFlowLayout indexFrom: 0 step: -1 count: 5] == 4, "previous before the first is the last");
  PASS([URSFlowLayout indexFrom: 1 step: 1 count: 5] == 2, "next moves one on");
  PASS([URSFlowLayout indexFrom: 2 step: -1 count: 5] == 1, "previous moves one back");
  PASS([URSFlowLayout indexFrom: 0 step: 1 count: 1] == 0, "a single window stays chosen");
  PASS([URSFlowLayout indexFrom: 0 step: 1 count: 2] == 1
       && [URSFlowLayout indexFrom: 1 step: 1 count: 2] == 0,
       "two windows alternate");

  /* Paint order among other windows. */
  {
    NSArray *stack = @[ @"a", @"menu", @"b", @"dock", @"c" ];
    NSArray *order = @[ @"c", @"a", @"b" ];
    NSArray *want = @[ @"c", @"menu", @"a", @"dock", @"b" ];
    PASS_EQUAL([URSFlowLayout stack: stack reorderedAs: order], want,
               "shown windows are painted in flow order, the others keep their places");
    NSArray *same = @[ @"a", @"b", @"c" ];
    NSArray *keep = @[ @"a", @"menu", @"b", @"dock", @"c" ];
    PASS_EQUAL([URSFlowLayout stack: stack reorderedAs: same], keep,
               "an order the stack already has changes nothing");
  }

  [arp release];
  return 0;
}

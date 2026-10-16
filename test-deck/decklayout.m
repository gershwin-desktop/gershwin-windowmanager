/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Rules the Alt-Tab deck layout must keep.  Headless.
// Run with:  gnustep-tests test-deck

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSFlowLayout.m"
#include "../WindowManager/URSDeckLayout.m"

static NSRect slot(NSSize w, NSUInteger index, NSUInteger count, double position, NSRect area)
{
  return [URSDeckLayout slotForWindowSize: w atIndex: index count: count
                                 position: position inArea: area];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSRect screen = NSMakeRect(0, 0, 1280, 720);
  NSSize win = NSMakeSize(1600, 900);

  /* The places at rest, as measured in the reference animation. */
  {
    NSRect front = slot(win, 0, 6, 0, screen);
    PASS(fabs(NSWidth(front) - 768) < 1.0, "the front window is 60 percent of the screen wide");
    PASS(fabs(NSMidX(front) - 640) < 0.5, "the front window is centred");
    PASS(fabs(NSMidY(front) - 720 * 0.618034) < 1.0,
         "the front window's middle lies at the golden section of the screen height");
    PASS(fabs(NSWidth(front) / NSHeight(front) - 16.0 / 9.0) < 0.01, "the front window keeps its shape");

    double widths[] = { 768, 576, 384, 230, 77 };
    double tops[] = { 229, 84, 42, 13, 5 };
    BOOL placesRight = YES;
    for (NSUInteger i = 0; i < 5; i++) {
      NSRect r = slot(win, i, 6, 0, screen);
      if (fabs(NSWidth(r) - widths[i]) > 2.0 || fabs(NSMinY(r) - tops[i]) > 1.5
          || fabs(NSMidX(r) - 640) > 0.5) placesRight = NO;
    }
    PASS(placesRight, "each place has the measured width and top, centred");
  }

  /* Deeper is smaller and higher; the places beyond the table are the last. */
  {
    BOOL receding = YES;
    for (NSUInteger i = 1; i < 8; i++) {
      NSRect a = slot(win, i - 1, 8, 0, screen);
      NSRect b = slot(win, i, 8, 0, screen);
      if (NSWidth(b) > NSWidth(a) + 0.01 || NSMinY(b) > NSMinY(a) + 0.01) receding = NO;
    }
    PASS(receding, "a window further back is never larger or lower");
    PASS(NSEqualRects(slot(win, 4, 9, 0, screen), slot(win, 8, 9, 0, screen)),
         "the places beyond the last of the table are the last");
  }

  /* One step with 6 windows: the front falls out, the next comes forward. */
  {
    NSRect front = slot(win, 0, 6, 0, screen);
    NSRect quarter = slot(win, 0, 6, 0.25, screen);
    PASS(NSWidth(quarter) > NSWidth(front), "the passed window grows");
    PASS(NSMinY(quarter) > NSMinY(front), "the passed window moves down");
    NSRect gone = slot(win, 0, 6, 0.49, screen);
    PASS(NSMinY(gone) >= NSMaxY(screen), "half way round it is off the bottom");
    PASS(fabs(NSMidX(gone) - 640) < 0.5, "it falls straight down");

    NSRect next = slot(win, 1, 6, 0.5, screen);
    NSRect from = slot(win, 1, 6, 0, screen);
    PASS(NSEqualRects(slot(win, 1, 6, 1, screen), front), "the next window arrives at the front place");
    PASS(NSWidth(next) > NSWidth(from) && NSWidth(next) < NSWidth(front)
         && NSMinY(next) > NSMinY(from) && NSMinY(next) < NSMinY(front),
         "half way the next window is between its two places");
  }

  /* The deck goes round: from behind again. */
  {
    NSUInteger n = 6;
    NSRect deepest = slot(win, 5, n, 0, screen);
    NSRect afterStep = slot(win, 0, n, 1, screen);
    PASS(fabs(NSMinY(afterStep) - NSMinY(deepest)) < 0.5 && fabs(NSWidth(afterStep) - NSWidth(deepest)) < 0.5,
         "the window that fell out is in the deepest place after the step");
    NSRect early = slot(win, 0, n, 0.55, screen);
    NSRect late = slot(win, 0, n, 0.9, screen);
    PASS(NSWidth(early) < NSWidth(late) && NSWidth(late) < NSWidth(deepest) + 0.5,
         "it comes in from behind, growing from nothing");
    PASS(NSWidth(slot(win, 0, n, 0.49, screen)) > 0 && NSMinY(slot(win, 0, n, 0.49, screen)) > 700,
         "just before it comes in it is below the screen");

    /* After a whole round of steps every window is back where it was. */
    BOOL same = YES;
    for (NSUInteger i = 0; i < n; i++) {
      if (!NSEqualRects(slot(win, i, n, 0, screen), slot(win, i, n, (double)n, screen))
          || !NSEqualRects(slot(win, i, n, 0, screen), slot(win, i, n, 2.0 * n, screen))) same = NO;
    }
    PASS(same, "n steps bring every window back to its place");

    /* Going on past the last item brings the first one to the front. */
    PASS(NSEqualRects(slot(win, 0, n, 6, screen), slot(win, 0, n, 0, screen)),
         "going on past the last window shows the first in front");
    PASS(NSEqualRects(slot(win, 1, n, 7, screen), slot(win, 0, n, 0, screen)),
         "and the second one after it comes where the first was");

    /* Backwards is the same ring. */
    PASS(NSEqualRects(slot(win, 1, n, -1, screen), slot(win, 2, n, 0, screen)),
         "a negative position goes round the other way");

    /* No window jumps, except one that is out of sight or has no size. */
    BOOL smooth = YES;
    for (NSUInteger i = 0; i < n; i++) {
      for (double p = 0; p < 2.0 * n; p += 0.01) {
        NSRect r = slot(win, i, n, p, screen);
        NSRect q = slot(win, i, n, p + 0.01, screen);
        BOOL hidden = (NSMinY(r) >= NSMaxY(screen) && NSMinY(q) >= NSMaxY(screen))
          || NSWidth(r) < 4.0 || NSWidth(q) < 4.0;
        if (!hidden && (fabs(NSMinY(q) - NSMinY(r)) > 12.0 || fabs(NSWidth(q) - NSWidth(r)) > 12.0))
          smooth = NO;
      }
    }
    PASS(smooth, "no window jumps in the position or size while it is in sight");
  }

  /* Two windows go round as well. */
  {
    PASS(NSEqualRects(slot(win, 1, 2, 1, screen), slot(win, 0, 2, 0, screen)),
         "with two windows the other one comes to the front");
    PASS(NSEqualRects(slot(win, 0, 2, 1, screen), slot(win, 1, 2, 0, screen)),
         "and the first one is behind it");
  }

  /* Windows are never enlarged, and keep room under the deck. */
  {
    NSRect small = slot(NSMakeSize(500, 300), 0, 3, 0, screen);
    PASS(NSWidth(small) <= 500.5 && NSHeight(small) <= 300.5, "a small window is shown at its own size at most");
    NSRect wide = slot(win, 0, 3, 0, screen);
    PASS(NSMaxY(wide) > 480 && NSMaxY(wide) < 720 * 0.94 + 0.5 && fabs(NSMidY(wide) - 720 * 0.618034) < 1.0,
         "a window of 16:9 reaches into the lower part of the screen");
    NSRect tall = slot(NSMakeSize(600, 1400), 0, 3, 0, screen);
    PASS(fabs(NSMaxY(tall) - 720 * 0.94) < 0.5 && fabs(NSMidY(tall) - 720 * 0.618034) < 1.0,
         "a tall window is centred on the golden section and ends a little above the bottom");
    PASS(fabs(NSWidth(tall) / NSHeight(tall) - 600.0 / 1400.0) < 0.01, "a tall window keeps its shape");
    BOOL never = YES;
    for (NSUInteger i = 0; i < 4; i++) {
      for (double p = 0; p < 8; p += 1.0) {
        NSRect r = slot(NSMakeSize(900, 600), i, 4, p, screen);
        if (NSWidth(r) > 900.5 || NSHeight(r) > 600.5) never = NO;
      }
    }
    PASS(never, "no window is larger than itself at rest");
    NSRect falling = slot(NSMakeSize(900, 600), 0, 4, 0.3, screen);
    PASS(NSWidth(falling) > NSWidth(slot(NSMakeSize(900, 600), 0, 4, 0, screen)) * 1.1,
         "a falling window is larger than at rest, it comes nearer");
  }

  /* Paint order: the nearest last. */
  {
    NSArray *order = [URSDeckLayout paintOrderForCount: 5 position: 0];
    PASS([order count] == 5, "every window is painted");
    PASS([[order lastObject] unsignedIntegerValue] == 0
         && [[order objectAtIndex: 0] unsignedIntegerValue] == 4,
         "at rest the front is last and the deepest first");
    order = [URSDeckLayout paintOrderForCount: 5 position: 0.3];
    PASS([[order lastObject] unsignedIntegerValue] == 0
         && [[order objectAtIndex: 3] unsignedIntegerValue] == 1,
         "a falling window is painted last, over the front");
    order = [URSDeckLayout paintOrderForCount: 5 position: 0.8];
    PASS([[order objectAtIndex: 0] unsignedIntegerValue] == 0,
         "a window coming in from behind is painted first");
    PASS([[order lastObject] unsignedIntegerValue] == 1,
         "and the one in front is painted last");
  }

  /* The index helper of the flow serves the deck unchanged. */
  PASS([URSDeckLayout indexFrom: 0 step: -1 count: 4] == 3, "the choice goes round at the ends");

  DESTROY(arp);
  return 0;
}

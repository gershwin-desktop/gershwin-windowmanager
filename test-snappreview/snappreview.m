/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The outline the snap preview is shaped to when no compositor runs.
// Headless.  Run with:  gnustep-tests test-snappreview

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "URSSnapPreviewFrame.h"

static uint64_t area(URSSnapPreviewRect *r, int n)
{
  uint64_t a = 0;
  for (int i = 0; i < n; i++) a += (uint64_t)r[i].width * r[i].height;
  return a;
}

int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  URSSnapPreviewRect r[4];

  int n = URSSnapPreviewFrameRects(400, 300, 3, r);
  PASS(n == 4, "a normal preview is four strips");
  PASS(area(r, n) == 400ull * 300 - 394ull * 294,
       "the strips cover exactly the border, with no overlap");
  PASS(r[0].y == 0 && r[1].y == 297 && r[2].x == 0 && r[3].x == 397,
       "strips sit on the four edges");

  n = URSSnapPreviewFrameRects(400, 300, 6, r);
  PASS(area(r, n) == 400ull * 300 - 388ull * 288, "border scales with the factor");

  n = URSSnapPreviewFrameRects(5, 300, 3, r);
  PASS(n == 1 && area(r, n) == 1500, "a window with no interior is covered whole");

  n = URSSnapPreviewFrameRects(400, 300, 0, r);
  PASS(area(r, n) == 400ull * 300 - 398ull * 298, "a zero border is still one pixel");

  [pool release];
  return 0;
}

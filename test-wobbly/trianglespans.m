/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Rules the triangle span rasterizer must keep.  Headless.
// Run with:  gnustep-tests test-wobbly

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSTriangleSpans.m"

#define W 200
#define H 200
static int coverage[H][W];

static void paint(NSPoint a, NSPoint b, NSPoint c)
{
  xcb_rectangle_t spans[1000];
  NSUInteger n = URSTriangleSpans(a, b, c, spans, 1000);
  for (NSUInteger i = 0; i < n; i++) {
    for (int y = spans[i].y; y < spans[i].y + spans[i].height; y++) {
      for (int x = spans[i].x; x < spans[i].x + spans[i].width; x++) {
        if (x >= 0 && y >= 0 && x < W && y < H) coverage[y][x]++;
      }
    }
  }
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  static NSString * const suite = @"triangle spans for bent windows";

  {
    memset(coverage, 0, sizeof(coverage));
    // A bent quad mesh: 3x3 cells with jittered inner points.
    NSPoint p[4][4];
    for (int r = 0; r < 4; r++) {
      for (int c = 0; c < 4; c++) {
        p[r][c] = NSMakePoint(20 + c * 50 + ((r * 7 + c * 13) % 11) - 5.3,
                              20 + r * 50 + ((r * 5 + c * 3) % 9) - 4.1);
      }
    }
    for (int r = 0; r < 3; r++) {
      for (int c = 0; c < 3; c++) {
        paint(p[r][c], p[r][c + 1], p[r + 1][c + 1]);
        paint(p[r][c], p[r + 1][c + 1], p[r + 1][c]);
      }
    }
    BOOL twice = NO;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) if (coverage[y][x] > 1) twice = YES;
    PASS(!twice, "no pixel of a bent mesh is painted twice");

    // Every pixel whose row sample lies well inside the mesh is covered.
    BOOL hole = NO;
    for (int y = 40; y < 150; y++) for (int x = 40; x < 150; x++) if (coverage[y][x] == 0) hole = YES;
    PASS(!hole, "the inside of a bent mesh has no holes");
  }

  {
    xcb_rectangle_t spans[10];
    NSUInteger n = URSTriangleSpans(NSMakePoint(0, 0), NSMakePoint(10, 0),
                                    NSMakePoint(20, 0), spans, 10);
    PASS(n == 0, "a flat triangle covers nothing");
    n = URSTriangleSpans(NSMakePoint(0, 0), NSMakePoint(100, 0),
                         NSMakePoint(0, 100), spans, 3);
    PASS(n == 3, "no more spans are written than there is room for");
  }

  {
    memset(coverage, 0, sizeof(coverage));
    paint(NSMakePoint(10, 10), NSMakePoint(110, 10), NSMakePoint(110, 60));
    paint(NSMakePoint(10, 10), NSMakePoint(110, 60), NSMakePoint(10, 60));
    int covered = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) covered += coverage[y][x];
    PASS(covered == 100 * 50, "an unbent cell covers exactly its own pixels (%d)", covered);
  }

  (void)suite;
  [arp release];
  return 0;
}

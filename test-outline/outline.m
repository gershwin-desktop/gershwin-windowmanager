/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The line the window manager draws along a titlebar when no compositor
// runs, so a window with white content does not melt into a white
// background.  Headless.  Run with:  gnustep-tests test-outline

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <math.h>
#import "Testing.h"
#import "URSWindowOutline.h"

#define W 64
#define H 24

// Which pixels of a W x H titlebar (y up) the rects cover, and how often
static void rasterize(NSArray *rects, int grid[W][H])
{
  int x, y;
  memset(grid, 0, sizeof(int) * W * H);
  for (NSValue *v in rects)
    {
      NSRect r = [v rectValue];
      for (x = (int)NSMinX(r); x < (int)NSMaxX(r); x++)
        for (y = (int)NSMinY(r); y < (int)NSMaxY(r); y++)
          {
            if (x >= 0 && x < W && y >= 0 && y < H)
              grid[x][y]++;
            else
              grid[0][0] = 100;  // outside: makes every check below fail
          }
    }
}

// Whether the window's shape keeps the pixel: the X server fills the top
// corners as circles of the radius around (r, H - r), testing pixel centres.
static BOOL shapeKeeps(int x, int y, int r)
{
  double cx, cy;
  if (x >= r && x < W - r)
    return YES;
  if (y < H - r)
    return YES;
  cx = (x < r) ? r : W - r;
  cy = H - r;
  return hypot(x + 0.5 - cx, y + 0.5 - cy) <= r;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSRect titlebar = NSMakeRect(0, 0, W, H);
  static int g[W][H];
  int x, y;

  START_SET("a square titlebar")
    BOOL edges = YES, inside = YES, once = YES;
    rasterize(URSTitlebarOutlineRects(titlebar, 0, 1), g);
    for (x = 0; x < W; x++)
      for (y = 0; y < H; y++)
        {
          BOOL onEdge = (x == 0 || x == W - 1 || y == H - 1);
          if (onEdge && !g[x][y]) edges = NO;
          if (!onEdge && g[x][y]) inside = NO;
          if (g[x][y] > 1) once = NO;
        }
    PASS(edges, "the left column, the top row and the right column are covered");
    PASS(inside, "nothing inside the titlebar, and not its bottom row: below it the frame's strips carry the line");
    PASS(once, "no pixel is covered twice");
  END_SET("a square titlebar")

  START_SET("the corner cut")
    int r = 6, row;
    BOOL matches = YES, below = YES;
    for (row = 0; row < r; row++)
      {
        int first = 0;
        while (!shapeKeeps(first, H - 1 - row, r)) first++;
        if (URSCornerCut(r, row) != first) matches = NO;
      }
    for (row = r; row < H; row++)
      if (URSCornerCut(r, row) != 0) below = NO;
    PASS(matches, "a corner cuts the pixels whose centres lie outside its circle");
    PASS(below && URSCornerCut(0, 0) == 0, "below the corner, and without a radius, nothing is cut");
    PASS(URSCornerCut(r, 0) > URSCornerCut(r, 1) && URSCornerCut(r, 1) >= URSCornerCut(r, 2),
         "the cut shrinks from the outermost row inwards");
  END_SET("the corner cut")

  START_SET("rounded top corners")
    int r = 6;
    BOOL outermost = YES, kept = YES, rows = YES, cols = YES;
    rasterize(URSTitlebarOutlineRects(titlebar, r, 1), g);
    for (y = 0; y < H; y++)
      {
        int first = -1, line = -1;
        for (x = 0; x < W / 2; x++)
          {
            if (first < 0 && shapeKeeps(x, y, r)) first = x;
            if (line < 0 && g[x][y]) line = x;
          }
        if (y < H - 1 && first != line) rows = NO;
      }
    for (x = 0; x < W; x++)
      {
        int top = -1, line = -1;
        for (y = H - 1; y >= 0; y--)
          {
            if (top < 0 && shapeKeeps(x, y, r)) top = y;
            if (line < 0 && g[x][y]) line = y;
          }
        if (top != line) cols = NO;
      }
    for (x = 0; x < W; x++)
      for (y = 0; y < H; y++)
        if (g[x][y] && !shapeKeeps(x, y, r)) kept = NO;
    PASS(rows, "in every row the line is on the leftmost pixel the window's shape keeps");
    PASS(cols, "in every column the line is on the topmost pixel the window's shape keeps");
    PASS(kept, "no part of the line falls into the corners the shape cuts away");
    outermost = !g[0][H - 1] && !g[W - 1][H - 1];
    PASS(outermost, "the sharp corner pixels themselves stay uncovered");
  END_SET("rounded top corners")

  START_SET("scaled and offset")
    NSRect visible = NSMakeRect(1, 0, W - 2, H);
    BOOL two = YES, outside = YES;
    rasterize(URSTitlebarOutlineRects(visible, 0, 2), g);
    for (y = 0; y < H - 2; y++)
      if (!g[1][y] || !g[2][y] || g[3][y] || !g[W - 2][y] || !g[W - 3][y] || g[W - 4][y])
        two = NO;
    for (y = 0; y < H; y++)
      if (g[0][y] || g[W - 1][y]) outside = NO;
    PASS(two, "a line two pixels wide covers the two outermost visible columns");
    PASS(outside, "nothing is drawn on the parts of the titlebar the frame does not show");
  END_SET("scaled and offset")

  START_SET("a tiny window")
    NSArray *rects = URSTitlebarOutlineRects(NSMakeRect(0, 0, 8, 6), 12, 1);
    BOOL within = YES;
    for (NSValue *v in rects)
      if (!NSContainsRect(NSMakeRect(0, 0, 8, 6), [v rectValue])) within = NO;
    PASS([rects count] > 0 && within,
         "a corner radius larger than the titlebar never draws outside it");
  END_SET("a tiny window")

  START_SET("the colour")
    NSColor *c = [URSWindowOutlineColor()
                   colorUsingColorSpaceName: NSDeviceRGBColorSpace];
    PASS(fabs([c redComponent] - 128.0 / 255.0) < 1e-6
         && [c greenComponent] == [c redComponent]
         && [c blueComponent] == [c redComponent] && [c alphaComponent] == 1,
         "the line is an opaque mid grey");
    PASS(URSWindowOutlinePixel() == 0x808080,
         "the frame's strips get the same grey as an X pixel");
  END_SET("the colour")

  [arp release];
  return 0;
}

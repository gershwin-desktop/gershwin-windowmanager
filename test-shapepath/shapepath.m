/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// A window outline given as a _WM_SHAPE_PATH property: parsed, drawn with
// smooth edges at any window size, and turned into shape rectangles.
// Headless.  Run with:  gnustep-tests test-shapepath

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "URSShapePath.h"

#define FX(v) ((int32_t)lround((v) * 65536.0))

// The whole window, but the bottom edge a curve `depth` pixels higher at
// the sides than in the middle
static NSData *curvedBottom(double depth)
{
  int32_t v[] = {
    1,
    URSShapePathMove,  FX(0), FX(0),          FX(0), FX(0),
    URSShapePathLine,  FX(1), FX(0),          FX(0), FX(0),
    URSShapePathLine,  FX(1), FX(0),          FX(1), FX(-depth),
    URSShapePathCurve, FX(2.0/3), FX(0),      FX(1), FX(depth / 3),
                       FX(1.0/3), FX(0),      FX(1), FX(depth / 3),
                       FX(0), FX(0),          FX(1), FX(-depth),
    URSShapePathClose
  };
  return [NSData dataWithBytes: v length: sizeof(v)];
}

static unsigned at(NSData *coverage, int width, int x, int y)
{
  return ((const uint8_t *)[coverage bytes])[y * width + x];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("reading the property")
    NSData *good = curvedBottom(8);
    PASS([URSShapePath shapePathWithValues: [good bytes]
                                     count: [good length] / 4] != nil,
         "a well-formed path is read");
    int32_t wrongVersion[] = { 2, URSShapePathMove, 0, 0, 0, 0, URSShapePathClose };
    PASS([URSShapePath shapePathWithValues: wrongVersion count: 7] == nil,
         "an unknown version is refused");
    int32_t truncated[] = { 1, URSShapePathMove, 0, 0 };
    PASS([URSShapePath shapePathWithValues: truncated count: 4] == nil,
         "so is a path cut short");
    int32_t badCommand[] = { 1, 9, 0, 0, 0, 0 };
    PASS([URSShapePath shapePathWithValues: badCommand count: 6] == nil,
         "and an unknown command");
    int32_t empty[] = { 1 };
    PASS([URSShapePath shapePathWithValues: empty count: 1] == nil,
         "and a path without any outline");
  END_SET("reading the property")

  START_SET("smooth edges at any size")
    NSData *d = curvedBottom(8);
    URSShapePath *path = [URSShapePath shapePathWithValues: [d bytes]
                                                     count: [d length] / 4];
    NSData *c = [path coverageForWidth: 400 height: 300];
    PASS([c length] == 400 * 300, "one value per pixel");
    PASS(at(c, 400, 0, 0) == 255 && at(c, 400, 399, 0) == 255
         && at(c, 400, 200, 150) == 255, "inside is fully covered");
    PASS(at(c, 400, 200, 299) >= 250, "the bottom reaches down in the middle");
    PASS(at(c, 400, 1, 299) == 0 && at(c, 400, 398, 299) == 0,
         "and curves up towards the sides");
    PASS(at(c, 400, 1, 290) == 255 && at(c, 400, 1, 293) == 0,
         "by the depth of the curve");
    BOOL partial = NO;
    for (int x = 0; x < 400 && !partial; x++) {
      for (int y = 290; y < 300; y++) {
        unsigned v = at(c, 400, x, y);
        if (v > 20 && v < 235) partial = YES;
      }
    }
    PASS(partial, "the edge is antialiased, not stepped");

    NSData *big = [path coverageForWidth: 800 height: 600];
    PASS(at(big, 800, 1, 599) == 0 && at(big, 800, 400, 599) >= 250
         && at(big, 800, 1, 590) == 255,
         "the same path fits a larger window, curve depth kept in pixels");
  END_SET("smooth edges at any size")

  START_SET("shape rectangles")
    NSData *d = curvedBottom(8);
    URSShapePath *path = [URSShapePath shapePathWithValues: [d bytes]
                                                     count: [d length] / 4];
    NSData *c = [path coverageForWidth: 400 height: 300];
    NSData *outer = URSShapeRects(c, 400, 300, 1);
    NSData *inner = URSShapeRects(c, 400, 300, 255);
    const URSShapeRect *o = [outer bytes];
    NSUInteger no = [outer length] / sizeof(URSShapeRect);
    PASS(no > 1 && no < 40, "few rectangles: equal rows are merged (%lu)", (unsigned long)no);
    PASS(o[0].x == 0 && o[0].y == 0 && o[0].width == 400 && o[0].height >= 290,
         "the first covers the whole upper part");
    long area = 0, innerArea = 0;
    for (NSUInteger i = 0; i < no; i++) area += (long)o[i].width * o[i].height;
    const URSShapeRect *in = [inner bytes];
    for (NSUInteger i = 0; i < [inner length] / sizeof(URSShapeRect); i++)
      innerArea += (long)in[i].width * in[i].height;
    PASS(innerArea < area, "fully covered pixels are fewer than touched ones");
    NSData *grown = URSShapeRectsGrown(outer, 2, 400, 300);
    const URSShapeRect *g = [grown bytes];
    const URSShapeRect *last = &o[no - 1];
    const URSShapeRect *lastGrown = &g[no - 1];
    PASS(g[0].x == 0 && g[0].y == 0 && g[0].width == 400,
         "grown rectangles stay within the window");
    PASS(lastGrown->x == last->x - 2 && lastGrown->width == last->width + 4
         && lastGrown->y + lastGrown->height <= 300,
         "and reach two pixels further everywhere else");
  END_SET("shape rectangles")

  [arp release];
  return 0;
}

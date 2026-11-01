/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSLiveMiniatureLayout.h"

@implementation URSLiveMiniatureLayout

+ (NSRect)paintRectForTile:(NSRect)tile
                windowSize:(NSSize)windowSize
                     inset:(CGFloat)inset
{
  NSRect room = NSInsetRect(tile, inset, inset);
  if (NSWidth(room) < 1 || NSHeight(room) < 1
      || windowSize.width <= 0 || windowSize.height <= 0)
    {
      return NSZeroRect;
    }
  CGFloat scale = MIN(NSWidth(room) / windowSize.width,
                      NSHeight(room) / windowSize.height);
  CGFloat w = MAX(1, MIN(NSWidth(room), floor(windowSize.width * scale + 0.5)));
  CGFloat h = MAX(1, MIN(NSHeight(room), floor(windowSize.height * scale + 0.5)));
  CGFloat x = floor(NSMinX(room) + (NSWidth(room) - w) / 2);
  CGFloat y = floor(NSMinY(room) + (NSHeight(room) - h) / 2);
  return NSMakeRect(x, y, w, h);
}

+ (NSTimeInterval)repaintDelaySinceLastPaint:(NSTimeInterval)lastPaint
                                         now:(NSTimeInterval)now
                                 minInterval:(NSTimeInterval)minInterval
{
  NSTimeInterval since = now - lastPaint;
  if (lastPaint <= 0 || since < 0 || since >= minInterval)
    {
      return 0;
    }
  return minInterval - since;
}

@end

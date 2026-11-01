/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSMonitorGeometry.h"

const CGFloat URSRescueMinimumGrip = 64;

typedef enum { EdgeLeft, EdgeRight, EdgeTop, EdgeBottom } Edge;

static CGFloat number(NSDictionary *strut, NSString *key)
{
  return [[strut objectForKey:key] doubleValue];
}

// The screen area one side of a strut reserves, or NSZeroRect.  Ranges are
// inclusive pixel coordinates; a plain _NET_WM_STRUT covers the whole edge.
static NSRect reservedRect(NSDictionary *strut, Edge edge, NSSize screen)
{
  BOOL partial = [[strut objectForKey:@"isPartial"] boolValue];
  CGFloat size, start, end;
  switch (edge) {
    case EdgeLeft:
      size = number(strut, @"left");
      start = partial ? number(strut, @"left_start_y") : 0;
      end = partial ? number(strut, @"left_end_y") : screen.height - 1;
      return size > 0 ? NSMakeRect(0, start, size, end - start + 1) : NSZeroRect;
    case EdgeRight:
      size = number(strut, @"right");
      start = partial ? number(strut, @"right_start_y") : 0;
      end = partial ? number(strut, @"right_end_y") : screen.height - 1;
      return size > 0 ? NSMakeRect(screen.width - size, start, size, end - start + 1) : NSZeroRect;
    case EdgeTop:
      size = number(strut, @"top");
      start = partial ? number(strut, @"top_start_x") : 0;
      end = partial ? number(strut, @"top_end_x") : screen.width - 1;
      return size > 0 ? NSMakeRect(start, 0, end - start + 1, size) : NSZeroRect;
    case EdgeBottom:
      size = number(strut, @"bottom");
      start = partial ? number(strut, @"bottom_start_x") : 0;
      end = partial ? number(strut, @"bottom_end_x") : screen.width - 1;
      return size > 0 ? NSMakeRect(start, screen.height - size, end - start + 1, size) : NSZeroRect;
  }
  return NSZeroRect;
}

// How far into `monitor` a reserved rect reaches from the monitor's edge,
// 0 when the strut does not belong to it: its range must cross the
// monitor, and its inner edge (the side facing the screen center) must lie
// on it.  Measuring from the monitor's own edge is what keeps a strut on an
// inner edge from swallowing the monitor beyond it.
static CGFloat insetOnMonitor(NSRect r, Edge edge, NSRect monitor)
{
  if (NSIsEmptyRect(r)) return 0;
  switch (edge) {
    case EdgeLeft:
    case EdgeRight:
      if (NSMaxY(r) <= NSMinY(monitor) || NSMinY(r) >= NSMaxY(monitor)) return 0;
      break;
    case EdgeTop:
    case EdgeBottom:
      if (NSMaxX(r) <= NSMinX(monitor) || NSMinX(r) >= NSMaxX(monitor)) return 0;
      break;
  }
  switch (edge) {
    case EdgeLeft:
      return (NSMaxX(r) > NSMinX(monitor) && NSMaxX(r) <= NSMaxX(monitor))
        ? NSMaxX(r) - NSMinX(monitor) : 0;
    case EdgeRight:
      return (NSMinX(r) >= NSMinX(monitor) && NSMinX(r) < NSMaxX(monitor))
        ? NSMaxX(monitor) - NSMinX(r) : 0;
    case EdgeTop:
      return (NSMaxY(r) > NSMinY(monitor) && NSMaxY(r) <= NSMaxY(monitor))
        ? NSMaxY(r) - NSMinY(monitor) : 0;
    case EdgeBottom:
      return (NSMinY(r) >= NSMinY(monitor) && NSMinY(r) < NSMaxY(monitor))
        ? NSMaxY(monitor) - NSMinY(r) : 0;
  }
  return 0;
}

// The largest inset of each edge of `monitor` over all struts.
static void insetsForMonitor(NSRect monitor, NSSize screen, NSArray *struts, CGFloat insets[4])
{
  for (int e = 0; e < 4; e++) insets[e] = 0;
  for (NSDictionary *strut in struts) {
    for (int e = 0; e < 4; e++) {
      CGFloat inset = insetOnMonitor(reservedRect(strut, (Edge)e, screen), (Edge)e, monitor);
      if (inset > insets[e]) insets[e] = inset;
    }
  }
}

static NSRect insetRect(NSRect r, const CGFloat insets[4])
{
  r.origin.x += insets[EdgeLeft];
  r.size.width -= insets[EdgeLeft] + insets[EdgeRight];
  r.origin.y += insets[EdgeTop];
  r.size.height -= insets[EdgeTop] + insets[EdgeBottom];
  if (r.size.width < 0) r.size.width = 0;
  if (r.size.height < 0) r.size.height = 0;
  return r;
}

NSRect URSUsableRectForMonitor(NSRect monitor, NSSize screen, NSArray *struts)
{
  CGFloat insets[4];
  insetsForMonitor(monitor, screen, struts, insets);
  return insetRect(monitor, insets);
}

NSRect URSWorkareaForScreen(NSSize screen, NSArray *monitors, NSArray *struts)
{
  CGFloat outer[4] = {0, 0, 0, 0};
  for (NSValue *v in monitors) {
    NSRect m = [v rectValue];
    CGFloat insets[4];
    insetsForMonitor(m, screen, struts, insets);
    // Only a monitor on the screen edge turns its inset into one of the
    // whole screen.
    BOOL touches[4] = { NSMinX(m) <= 0, NSMaxX(m) >= screen.width,
                        NSMinY(m) <= 0, NSMaxY(m) >= screen.height };
    for (int e = 0; e < 4; e++) {
      if (touches[e] && insets[e] > outer[e]) outer[e] = insets[e];
    }
  }
  return insetRect(NSMakeRect(0, 0, screen.width, screen.height), outer);
}

BOOL URSPointIsOnRects(NSPoint point, NSArray *rects)
{
  for (NSValue *v in rects) {
    NSRect r = [v rectValue];
    if (point.x >= NSMinX(r) && point.x < NSMaxX(r)
        && point.y >= NSMinY(r) && point.y < NSMaxY(r)) {
      return YES;
    }
  }
  return NO;
}

static BOOL titlebarReachable(NSRect frame, CGFloat titlebarHeight, NSRect u)
{
  if (NSMinY(frame) < NSMinY(u) || NSMinY(frame) + titlebarHeight > NSMaxY(u)) return NO;
  CGFloat overlap = MIN(NSMaxX(frame), NSMaxX(u)) - MAX(NSMinX(frame), NSMinX(u));
  return overlap >= MIN(URSRescueMinimumGrip, NSWidth(frame));
}

static CGFloat clampOrigin(CGFloat origin, CGFloat size, CGFloat min, CGFloat max)
{
  if (size >= max - min) return min;
  if (origin < min) return min;
  if (origin + size > max) return max - size;
  return origin;
}

NSRect URSRescueFrame(NSRect frame, CGFloat titlebarHeight, NSArray *usable,
                      NSUInteger primary, BOOL resizable)
{
  if ([usable count] == 0) return frame;
  for (NSValue *v in usable) {
    if (titlebarReachable(frame, titlebarHeight, [v rectValue])) return frame;
  }

  NSRect target = NSZeroRect;
  CGFloat bestArea = 0;
  for (NSValue *v in usable) {
    NSRect i = NSIntersectionRect(frame, [v rectValue]);
    CGFloat area = NSWidth(i) * NSHeight(i);
    if (area > bestArea) {
      bestArea = area;
      target = [v rectValue];
    }
  }
  BOOL partlyOn = bestArea > 0;
  if (!partlyOn) {
    target = [[usable objectAtIndex:(primary < [usable count] ? primary : 0)] rectValue];
  }

  NSRect result = frame;
  if (resizable) {
    result.size.width = MIN(NSWidth(frame), NSWidth(target));
    result.size.height = MIN(NSHeight(frame), NSHeight(target));
  }
  if (!partlyOn) {
    // Nothing tells where on the primary it belonged, so the middle.
    result.origin.x = floor(NSMidX(target) - NSWidth(result) / 2);
    result.origin.y = floor(NSMidY(target) - NSHeight(result) / 2);
  }
  result.origin.x = clampOrigin(NSMinX(result), NSWidth(result), NSMinX(target), NSMaxX(target));
  result.origin.y = clampOrigin(NSMinY(result), NSHeight(result), NSMinY(target), NSMaxY(target));
  return result;
}

NSUInteger URSMonitorIndexForRect(NSRect frame, NSArray *monitors, NSUInteger primary)
{
  CGFloat bestArea = 0;
  NSUInteger best = primary < [monitors count] ? primary : 0;
  for (NSUInteger i = 0; i < [monitors count]; i++) {
    NSRect overlap = NSIntersectionRect(frame, [[monitors objectAtIndex:i] rectValue]);
    CGFloat area = NSWidth(overlap) * NSHeight(overlap);
    if (area > bestArea) {
      bestArea = area;
      best = i;
    }
  }
  return best;
}

NSRect URSMaximizedRect(NSRect frame, NSArray *monitors, NSArray *usable, NSUInteger primary)
{
  if ([usable count] == 0) return NSZeroRect;
  return [[usable objectAtIndex:URSMonitorIndexForRect(frame, monitors, primary)] rectValue];
}

NSRect URSFullscreenRect(NSRect frame, NSArray *monitors, NSUInteger primary)
{
  if ([monitors count] == 0) return NSZeroRect;
  return [[monitors objectAtIndex:URSMonitorIndexForRect(frame, monitors, primary)] rectValue];
}

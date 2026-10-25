/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSOutputScale.h"

const long URSOutputBaseDPI = 96;
const CGFloat URSOutputHysteresis = 8.0;

CGFloat URSScaleFactorForDPI(long dpi)
{
    if (dpi <= 0)
        return 0;
    return (CGFloat)dpi / (CGFloat)URSOutputBaseDPI;
}

BOOL URSOutputScalesAreMixed(NSArray *factors)
{
    CGFloat seen = 0;

    for (NSNumber *n in factors) {
        CGFloat f = [n doubleValue];
        if (f <= 0)
            continue;
        if (seen == 0)
            seen = f;
        else if (f != seen)
            return YES;
    }
    return NO;
}

static CGFloat OverlapArea(NSRect a, NSRect b)
{
    NSRect i = NSIntersectionRect(a, b);
    return i.size.width * i.size.height;
}

static NSUInteger LargestOverlap(NSRect frame, NSArray *outputs)
{
    NSUInteger best = NSNotFound;
    CGFloat bestArea = 0;
    NSUInteger i;

    for (i = 0; i < [outputs count]; i++) {
        CGFloat area = OverlapArea(frame, [[outputs objectAtIndex:i] rectValue]);
        if (area > bestArea) {
            bestArea = area;
            best = i;
        }
    }
    return best;
}

NSUInteger URSOutputForFrame(NSRect frame, NSArray *outputs, const CGFloat *factors,
                             NSUInteger current, URSDecoration now, NSSize content)
{
    NSUInteger count = [outputs count];
    NSUInteger home = NSNotFound;
    CGFloat here = 0;
    NSUInteger i;

    if (current >= count || now.factor <= 0)
        return LargestOverlap(frame, outputs);

    for (i = 0; i < count; i++) {
        if (factors[i] != now.factor)
            continue;
        CGFloat area = OverlapArea(frame, [[outputs objectAtIndex:i] rectValue]);
        if (area > here || (area == here && i == current && area > 0)) {
            here = area;
            home = i;
        }
    }
    if (here <= 0)
        return LargestOverlap(frame, outputs);

    /* libs-gui looks at another factor only once -screen, the screen
     * holding the largest part of the frame as it is, has changed; that
     * screen is the one candidate. */
    NSUInteger largest = LargestOverlap(frame, outputs);
    NSUInteger best = home;
    CGFloat bestLead = 0;

    for (i = 0; i < count; i++) {
        if (i != largest || factors[i] <= 0 || factors[i] == now.factor)
            continue;
        /* The frame libs-gui gives the window there: its content at that
         * factor in whole pixels plus the extents it knows now, top-left
         * corner kept. */
        NSRect there = NSMakeRect(NSMinX(frame), NSMinY(frame),
                                  rint(content.width * factors[i]) + 2 * now.border,
                                  rint(content.height * factors[i]) + now.titleHeight + now.border);
        CGFloat candidate = OverlapArea(there, [[outputs objectAtIndex:i] rectValue]);
        CGFloat margin = URSOutputHysteresis * MIN(NSWidth(there), NSHeight(there));
        CGFloat lead = candidate - here;
        if (lead > margin && lead > bestLead) {
            bestLead = lead;
            best = i;
        }
    }
    return best;
}

uint32_t URSClientBorderFor(CGFloat scaleFactor, BOOL compositorActive,
                            CGFloat themeBorder)
{
    if (themeBorder > 0)
        return (uint32_t)themeBorder;
    return compositorActive ? 0 : (uint32_t)scaleFactor;
}

URSFrameExtents URSFrameExtentsFor(uint16_t titleHeight, CGFloat scaleFactor,
                                   BOOL compositorActive, CGFloat themeBorder)
{
    uint32_t cb = URSClientBorderFor(scaleFactor, compositorActive, themeBorder);
    URSFrameExtents e = { cb, cb, titleHeight, cb };
    return e;
}

uint16_t URSUtilityTitleHeightFor(CGFloat scaleFactor)
{
    uint16_t h = (uint16_t)(16 * scaleFactor);
    return h < 1 ? 1 : h;
}

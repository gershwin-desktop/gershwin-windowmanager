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

NSUInteger URSOutputForFrame(NSRect frame, NSArray *outputs,
                             NSArray *titleHeights, NSUInteger current,
                             CGFloat currentTitleHeight)
{
    NSUInteger best = current;
    CGFloat bestLead = 0;
    NSUInteger i;

    if (current >= [outputs count] ||
        OverlapArea(frame, [[outputs objectAtIndex:current] rectValue]) <= 0)
        return LargestOverlap(frame, outputs);

    for (i = 0; i < [outputs count]; i++) {
        if (i == current)
            continue;
        /* Judged on the frame as the candidate would decorate it: a switch
         * that changes the title bar height must still hold afterwards, or
         * the taller or shorter frame hands the window straight back. */
        NSRect there = frame;
        there.size.height += [[titleHeights objectAtIndex:i] doubleValue] - currentTitleHeight;
        if (there.size.height <= 0)
            continue;
        CGFloat lead = OverlapArea(there, [[outputs objectAtIndex:i] rectValue]) -
                       OverlapArea(there, [[outputs objectAtIndex:current] rectValue]);
        CGFloat margin = URSOutputHysteresis * MIN(there.size.width, there.size.height);
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

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSCursorSize.h"
#import "URSOutputScale.h"

const uint32_t URSCursorBaseSize = 24;

uint32_t URSCursorPixelSize(CGFloat factor, BOOL allFactorsOne)
{
    if (allFactorsOne)
        return 0;
    if (factor <= 0)
        factor = 1.0;
    return (uint32_t)lround(URSCursorBaseSize * factor);
}

BOOL URSCursorFactorsAllOne(NSArray *factors, CGFloat globalFactor)
{
    if (URSOutputScalesAreMixed(factors))
        return NO;
    return globalFactor <= 0 || globalFactor == 1.0;
}

CGFloat URSCursorFactorAtPoint(NSPoint point, NSArray *rects, NSArray *factors,
                               CGFloat globalFactor)
{
    if (!URSOutputScalesAreMixed(factors) || [rects count] == 0)
        return globalFactor > 0 ? globalFactor : 1.0;
    /* NSPointInRect on X coordinates: y grows downwards here, the rect test
     * is the same half-open interval either way. */
    NSPoint center = NSMakePoint(point.x + 0.5, point.y + 0.5);
    for (NSUInteger i = 0; i < [rects count] && i < [factors count]; i++) {
        if (NSPointInRect(center, [[rects objectAtIndex:i] rectValue]))
            return [[factors objectAtIndex:i] doubleValue];
    }
    return [[factors firstObject] doubleValue];
}

static NSString *const URSCursorSizeKey = @"Xcursor.size";

/* The resource name of a line "name:\tvalue", nil for a line without one. */
static NSString *ResourceName(NSString *line)
{
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound)
        return nil;
    return [[line substringToIndex:colon.location]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

NSString *URSResourcesWithCursorSize(NSString *resources, uint32_t size)
{
    NSMutableString *out = [NSMutableString string];

    for (NSString *line in [resources ?: @"" componentsSeparatedByString:@"\n"]) {
        if ([line length] == 0 || [ResourceName(line) isEqualToString:URSCursorSizeKey])
            continue;
        [out appendFormat:@"%@\n", line];
    }
    if (size > 0)
        [out appendFormat:@"%@:\t%u\n", URSCursorSizeKey, size];
    return out;
}

NSString *URSResourceValue(NSString *resources, NSString *key)
{
    for (NSString *line in [resources ?: @"" componentsSeparatedByString:@"\n"]) {
        if (![ResourceName(line) isEqualToString:key])
            continue;
        NSRange colon = [line rangeOfString:@":"];
        return [[line substringFromIndex:NSMaxRange(colon)]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return nil;
}

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSheetSlideEffect.h"
#import "URSSheetLayout.h"

@implementation URSSheetSlideEffect
{
    BOOL _appearing;
}

- (instancetype)initAppearing:(BOOL)appearing
{
    self = [super init];
    if (self) {
        _appearing = appearing;
    }
    return self;
}

// A sheet dismissed while still sliding in starts sliding back from
// wherever it is instead of waiting for the slide in to end.
- (BOOL)replacesRunningEffect
{
    return YES;
}

- (NSTimeInterval)duration
{
    return 0.25;
}

- (NSRect)paintRectAtProgress:(double)t forWindowRect:(NSRect)windowRect
{
    double hidden = [URSSheetLayout hiddenFractionAtProgress:t appearing:_appearing];
    return NSOffsetRect(windowRect, 0.0, -hidden * NSHeight(windowRect));
}

// Whatever slides above the attachment line is clipped away, so nothing
// outside the window's own rect is ever seen.
- (NSRect)reachOfWindowRect:(NSRect)windowRect
{
    return windowRect;
}

- (NSRect)clipRectForWindowRect:(NSRect)windowRect
{
    // Wide margins at the sides and below keep the drop shadow; only the
    // top is cut, at the parent's titlebar.
    const double margin = 1024.0;
    return NSMakeRect(NSMinX(windowRect) - margin, NSMinY(windowRect),
                      NSWidth(windowRect) + 2.0 * margin,
                      NSHeight(windowRect) + margin);
}

@end

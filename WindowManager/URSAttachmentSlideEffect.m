/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSAttachmentSlideEffect.h"
#import "URSSheetLayout.h"

// Wide enough that the clip never cuts the drop shadow at the three sides
// away from the attachment line.
static const double URSAttachmentClipMargin = 1024.0;

@implementation URSAttachmentSlideEffect
{
    BOOL _appearing;
    URSAttachmentEdge _outward;
}

- (instancetype)initAppearing:(BOOL)appearing outward:(URSAttachmentEdge)outward
{
    self = [super init];
    if (self) {
        _appearing = appearing;
        _outward = outward;
    }
    return self;
}

// A window dismissed while still sliding in starts sliding back from
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
    switch (_outward) {
    case URSAttachmentEdgeLeft:
        return NSOffsetRect(windowRect, hidden * NSWidth(windowRect), 0.0);
    case URSAttachmentEdgeTop:
        return NSOffsetRect(windowRect, 0.0, hidden * NSHeight(windowRect));
    case URSAttachmentEdgeRight:
        return NSOffsetRect(windowRect, -hidden * NSWidth(windowRect), 0.0);
    case URSAttachmentEdgeBottom:
        return NSOffsetRect(windowRect, 0.0, -hidden * NSHeight(windowRect));
    }
    return windowRect;
}

// Whatever slides past the attachment line is clipped away, so nothing
// outside the window's own rect is ever seen.
- (NSRect)reachOfWindowRect:(NSRect)windowRect
{
    return windowRect;
}

- (NSRect)clipRectForWindowRect:(NSRect)windowRect
{
    const double m = URSAttachmentClipMargin;
    NSRect clip = NSInsetRect(windowRect, -m, -m);
    switch (_outward) {
    case URSAttachmentEdgeLeft:
        clip.size.width = NSMaxX(windowRect) - NSMinX(clip);
        break;
    case URSAttachmentEdgeTop:
        clip.size.height = NSMaxY(windowRect) - NSMinY(clip);
        break;
    case URSAttachmentEdgeRight:
        clip.size.width = NSMaxX(clip) - NSMinX(windowRect);
        clip.origin.x = NSMinX(windowRect);
        break;
    case URSAttachmentEdgeBottom:
        clip.size.height = NSMaxY(clip) - NSMinY(windowRect);
        clip.origin.y = NSMinY(windowRect);
        break;
    }
    return clip;
}

@end

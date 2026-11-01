/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSDrawerLayout.h"

@implementation URSDrawerLayout

+ (BOOL)getAttachment:(URSDrawerAttachment *)attachment
         ofDrawerRect:(NSRect)drawer
          parentFrame:(NSRect)parentFrame
        parentContent:(NSRect)parentContent
{
    // The drawer's middle, not its edge: a client that does not know about
    // the frame's border puts it a pixel or two over the frame.
    double midX = NSMidX(drawer), midY = NSMidY(drawer);
    URSDrawerAttachment a;
    if (midX >= NSMaxX(parentFrame)) {
        a.edge = URSAttachmentEdgeRight;
    } else if (midX <= NSMinX(parentFrame)) {
        a.edge = URSAttachmentEdgeLeft;
    } else if (midY >= NSMaxY(parentFrame)) {
        a.edge = URSAttachmentEdgeBottom;
    } else if (midY <= NSMinY(parentFrame)) {
        a.edge = URSAttachmentEdgeTop;
    } else {
        return NO;
    }
    if (a.edge == URSAttachmentEdgeLeft || a.edge == URSAttachmentEdgeRight) {
        a.leading = NSMinY(drawer) - NSMinY(parentContent);
        a.trailing = NSMaxY(parentContent) - NSMaxY(drawer);
        a.thickness = NSWidth(drawer);
    } else {
        a.leading = NSMinX(drawer) - NSMinX(parentContent);
        a.trailing = NSMaxX(parentContent) - NSMaxX(drawer);
        a.thickness = NSHeight(drawer);
    }
    if (attachment) {
        *attachment = a;
    }
    return YES;
}

+ (NSRect)frameForAttachment:(URSDrawerAttachment)a
                 parentFrame:(NSRect)parentFrame
               parentContent:(NSRect)parentContent
{
    if (a.edge == URSAttachmentEdgeLeft || a.edge == URSAttachmentEdgeRight) {
        double x = a.edge == URSAttachmentEdgeRight ? NSMaxX(parentFrame)
                                                    : NSMinX(parentFrame) - a.thickness;
        double length = MAX(1.0, NSHeight(parentContent) - a.leading - a.trailing);
        return NSMakeRect(x, NSMinY(parentContent) + a.leading, a.thickness, length);
    }
    double y = a.edge == URSAttachmentEdgeBottom ? NSMaxY(parentFrame)
                                                 : NSMinY(parentFrame) - a.thickness;
    double length = MAX(1.0, NSWidth(parentContent) - a.leading - a.trailing);
    return NSMakeRect(NSMinX(parentContent) + a.leading, y, length, a.thickness);
}

@end

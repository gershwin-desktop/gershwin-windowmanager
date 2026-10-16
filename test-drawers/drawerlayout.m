/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Where a drawer hangs from its parent, how it is read off the rect the
// client asked for, and how it follows the parent.  Headless.
// Run with:  gnustep-tests test-drawers

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSDrawerLayout.m"

static BOOL near(double a, double b)
{
  return fabs(a - b) < 1e-9;
}

// A parent with a 22 px titlebar and 1 px side borders, like a framed
// window: the frame is wider than the content and reaches above it.
static const NSRect frame = { { 200, 100 }, { 602, 423 } };
static const NSRect content = { { 201, 122 }, { 600, 400 } };

static URSDrawerAttachment make(URSAttachmentEdge edge, double lead, double trail, double t)
{
  URSDrawerAttachment a = { edge, lead, trail, t };
  return a;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("placement on each edge")
    NSRect r = [URSDrawerLayout frameForAttachment: make(URSAttachmentEdgeRight, 0, 10, 170)
                                       parentFrame: frame parentContent: content];
    PASS(near(NSMinX(r), NSMaxX(frame)), "a right drawer starts where the frame ends");
    PASS(near(NSWidth(r), 170), "and is as thick as it asked");
    PASS(near(NSMinY(r), NSMinY(content)) && near(NSMaxY(r), NSMaxY(content) - 10),
         "and spans the content's height less its offsets (top leading, bottom trailing)");

    NSRect l = [URSDrawerLayout frameForAttachment: make(URSAttachmentEdgeLeft, 5, 10, 170)
                                       parentFrame: frame parentContent: content];
    PASS(near(NSMaxX(l), NSMinX(frame)) && near(NSWidth(l), 170),
         "a left drawer ends where the frame begins");
    PASS(near(NSMinY(l), NSMinY(content) + 5) && near(NSHeight(l), 400 - 15),
         "and keeps its offsets too");

    NSRect b = [URSDrawerLayout frameForAttachment: make(URSAttachmentEdgeBottom, 10, 20, 120)
                                       parentFrame: frame parentContent: content];
    PASS(near(NSMinY(b), NSMaxY(frame)) && near(NSHeight(b), 120),
         "a bottom drawer starts below the frame");
    PASS(near(NSMinX(b), NSMinX(content) + 10) && near(NSMaxX(b), NSMaxX(content) - 20),
         "and spans the content's width less its offsets (left leading, right trailing)");

    NSRect t = [URSDrawerLayout frameForAttachment: make(URSAttachmentEdgeTop, 10, 20, 120)
                                       parentFrame: frame parentContent: content];
    PASS(near(NSMaxY(t), NSMinY(frame)) && near(NSHeight(t), 120),
         "a top drawer ends above the titlebar");
    PASS(near(NSMinX(t), NSMinX(content) + 10) && near(NSWidth(t), 600 - 30),
         "and spans the content's width less its offsets");

    NSRect squeezed = [URSDrawerLayout frameForAttachment: make(URSAttachmentEdgeRight, 300, 300, 170)
                                              parentFrame: frame parentContent: content];
    PASS(NSHeight(squeezed) >= 1.0, "offsets longer than the parent never make it vanish");
  END_SET("placement on each edge")

  START_SET("reading the attachment off the client's rect")
    URSAttachmentEdge edges[4] = { URSAttachmentEdgeLeft, URSAttachmentEdgeTop,
                                   URSAttachmentEdgeRight, URSAttachmentEdgeBottom };
    BOOL roundTrips = YES;
    for (int i = 0; i < 4; i++)
      {
        URSDrawerAttachment want = make(edges[i], 7, 13, 150);
        NSRect rect = [URSDrawerLayout frameForAttachment: want
                                              parentFrame: frame parentContent: content];
        URSDrawerAttachment got;
        BOOL ok = [URSDrawerLayout getAttachment: &got ofDrawerRect: rect
                                     parentFrame: frame parentContent: content];
        roundTrips = roundTrips && ok && got.edge == want.edge && near(got.leading, 7)
          && near(got.trailing, 13) && near(got.thickness, 150);
      }
    PASS(roundTrips, "edge, offsets and thickness are read back for every edge");

    // Where GNUstep puts a right drawer: flush with the client's right
    // side (it does not know about the border), below the titlebar.
    URSDrawerAttachment a;
    BOOL ok = [URSDrawerLayout getAttachment: &a
                                ofDrawerRect: NSMakeRect(NSMaxX(content), NSMinY(content), 170, 390)
                                 parentFrame: frame parentContent: content];
    PASS(ok && a.edge == URSAttachmentEdgeRight, "a rect right of the parent is a right drawer");
    PASS(ok && near(a.leading, 0) && near(a.trailing, 10) && near(a.thickness, 170),
         "its offsets and thickness are its distances and width");

    PASS(![URSDrawerLayout getAttachment: &a
                            ofDrawerRect: NSMakeRect(300, 200, 100, 100)
                             parentFrame: frame parentContent: content],
         "a rect over the parent is no attachment");
  END_SET("reading the attachment off the client's rect")

  START_SET("following the parent")
    URSDrawerAttachment a = make(URSAttachmentEdgeRight, 0, 10, 170);
    NSRect before = [URSDrawerLayout frameForAttachment: a parentFrame: frame
                                          parentContent: content];
    NSRect moved = [URSDrawerLayout frameForAttachment: a
                                           parentFrame: NSOffsetRect(frame, 37, -21)
                                         parentContent: NSOffsetRect(content, 37, -21)];
    PASS(NSEqualRects(moved, NSOffsetRect(before, 37, -21)),
         "a moved parent moves its drawer by the same delta");

    NSRect tallFrame = frame, tallContent = content;
    tallFrame.size.height += 100;
    tallContent.size.height += 100;
    tallFrame.size.width += 50;
    tallContent.size.width += 50;
    NSRect resized = [URSDrawerLayout frameForAttachment: a parentFrame: tallFrame
                                           parentContent: tallContent];
    PASS(near(NSHeight(resized), NSHeight(before) + 100),
         "a drawer on a side tracks the parent's height");
    PASS(near(NSMinY(resized), NSMinY(before)) && near(NSMaxY(tallContent) - NSMaxY(resized), 10),
         "keeping its leading and trailing offsets");
    PASS(near(NSMinX(resized), NSMaxX(tallFrame)) && near(NSWidth(resized), 170),
         "and stays against the edge, as thick as before");

    URSDrawerAttachment bottom = make(URSAttachmentEdgeBottom, 10, 20, 120);
    NSRect wide = [URSDrawerLayout frameForAttachment: bottom parentFrame: tallFrame
                                        parentContent: tallContent];
    PASS(near(NSWidth(wide), NSWidth(tallContent) - 30) && near(NSMinY(wide), NSMaxY(tallFrame)),
         "a bottom drawer tracks the parent's width and bottom");
  END_SET("following the parent")

  [arp release];
  return 0;
}

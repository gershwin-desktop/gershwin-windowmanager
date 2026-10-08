/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "URSAttachmentSlideEffect.h"

// How a drawer hangs from its parent: the parent's edge it comes out of,
// how far it stays from either end of that edge (leading is the top of a
// side edge or the left end of a top or bottom edge, as in AppKit for
// left-to-right text) and how far it sticks out.
typedef struct {
    URSAttachmentEdge edge;
    double leading;
    double trailing;
    double thickness;
} URSDrawerAttachment;

// Where a drawer sits on its parent.  Pure geometry, so that the rules can
// be tested without an X server.  Rects are root window pixels, y down;
// parentFrame is the parent's frame (titlebar and borders included),
// parentContent its client window.
@interface URSDrawerLayout : NSObject

// Reads the attachment off the rect the client put its drawer at next to
// its parent, so that no private property is needed: the edge is the side
// of the parent the drawer lies beyond, the offsets and the thickness are
// its distances and size.  NO when the rect does not lie beyond any edge.
+ (BOOL)getAttachment:(URSDrawerAttachment *)attachment
         ofDrawerRect:(NSRect)drawer
          parentFrame:(NSRect)parentFrame
        parentContent:(NSRect)parentContent;

// The drawer's rect for its attachment: flush against the frame's edge,
// spanning the content's side less the offsets, so it follows the parent's
// moves and tracks its resizes.
+ (NSRect)frameForAttachment:(URSDrawerAttachment)attachment
                 parentFrame:(NSRect)parentFrame
               parentContent:(NSRect)parentContent;

@end

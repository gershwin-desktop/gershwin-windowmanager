/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "URSWindowEffect.h"

// The way a window attached to a parent comes out of it, in screen terms
// (y down): a sheet comes down out of the titlebar, a drawer on the
// parent's right edge comes out to the right.
typedef NS_ENUM(NSUInteger, URSAttachmentEdge) {
    URSAttachmentEdgeLeft = 0,
    URSAttachmentEdgeTop,
    URSAttachmentEdgeRight,
    URSAttachmentEdgeBottom
};

// A window sliding out from under its parent, or back under it.  The
// window stays where it is attached; only its picture moves, and all of it
// that would show on the parent's side of the attachment line (the
// window's inner edge) is clipped away, so it looks as if it came out from
// under the parent's edge.
@interface URSAttachmentSlideEffect : NSObject <URSWindowEffect>

- (instancetype)initAppearing:(BOOL)appearing outward:(URSAttachmentEdge)outward;

@end

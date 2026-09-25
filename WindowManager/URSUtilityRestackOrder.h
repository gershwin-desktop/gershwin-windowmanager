/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Decides the order to send -stackAbove in when several same-application
// utility windows (e.g. Stickies notes, palettes) must be re-raised above
// the dock at once.  Calling -stackAbove on an XCBWindow raises it above
// every one of its current siblings, so the LAST id in the returned order
// is the one that ends up on top - an NSDictionary's -allValues has no
// defined order, so iterating it directly makes that outcome arbitrary.
@interface URSUtilityRestackOrder : NSObject

// currentStackingOrder: the app's utility window ids exactly as the X
// server currently stacks them, bottom-most first (xcb_query_tree order -
// see -[XCBConnection lowestManagedNormalFrameIdExcluding:]).
// requestedWindowId: the window whose own ConfigureRequest asked to be
// raised above its siblings (stack_mode=Above); 0 when this restack was
// not triggered by such a request.
//
// Returns the ids to call -stackAbove on, in order, bottom to top: every
// window keeps its place relative to the others, and the requested window
// (when non-zero) is always last, so it ends up topmost regardless of
// where it already was.
+ (NSArray<NSNumber *> *)raiseOrderForRequestedWindow:(uint32_t)requestedWindowId
                                 currentStackingOrder:(NSArray<NSNumber *> *)currentStackingOrder;

@end

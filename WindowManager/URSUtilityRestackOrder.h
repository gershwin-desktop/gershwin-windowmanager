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

// currentStackingOrder: the app's utility/transient window ids exactly as
// the X server currently stacks them, bottom-most first (xcb_query_tree
// order - see -[XCBConnection lowestManagedNormalFrameIdExcluding:]).
// requestedWindowId: the window whose own ConfigureRequest asked to be
// raised above its siblings (stack_mode=Above); 0 when this restack was
// not triggered by such a request.
// modalWindowIds: ids in currentStackingOrder (or, for a window not
// mapped yet, equal to requestedWindowId) that carry
// _NET_WM_STATE_MODAL.  A modal dialog blocks the rest of its own
// application, so it must end up above every plain utility/transient
// sibling regardless of which of THEM last asked to be raised - pass the
// empty set when the caller has no modal windows to consider.
//
// Returns the ids to call -stackAbove on, in order, bottom to top: plain
// windows first (relative order preserved, the requested one moved last
// among them if it is one of them), then modal windows (same rule,
// applied within that group) - so a modal dialog always lands above every
// plain sibling, and the requested window is always last within its own
// group, ending up topmost there.
+ (NSArray<NSNumber *> *)raiseOrderForRequestedWindow:(uint32_t)requestedWindowId
                                 currentStackingOrder:(NSArray<NSNumber *> *)currentStackingOrder
                                        modalWindowIds:(NSSet<NSNumber *> *)modalWindowIds;

@end

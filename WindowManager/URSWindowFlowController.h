/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "URSWindowPresentation.h"

@class XCBConnection;
@class XCBFrame;
@class URSWindowSwitcher;
@class URSCompositingManager;

// The Alt-Tab flow: while Alt is held the windows fly from where they are
// into one row across a darkened screen, the chosen one big in the middle
// and the others turned away to both sides (URSFlowLayout), and the row
// slides as Tab moves the choice.  Like the window overview it only paints
// the windows elsewhere; the switcher keeps deciding what is chosen and
// what happens on release.
@interface URSWindowFlowController : NSObject <URSWindowPresentation>

@property (weak, nonatomic) URSCompositingManager *compositingManager;

- (instancetype)initWithConnection:(XCBConnection *)connection
                    windowSwitcher:(URSWindowSwitcher *)windowSwitcher;

// Shows those of the frames (in switcher order) that are on the screen,
// choosing the first of them from index on.  Answers the chosen frame, or
// nil when there is no compositing or fewer than two windows to show.
- (XCBFrame *)showFrames:(NSArray *)frames selectedIndex:(NSUInteger)index;

// YES from showing until -close.
- (BOOL)isShown;

// Moves the choice step windows along the row, round at the ends, and
// answers the frame now chosen.
- (XCBFrame *)moveSelectionBy:(NSInteger)step;

// The windows fly back to their places.  A window activated just before
// lands on top.
- (void)close;

@end

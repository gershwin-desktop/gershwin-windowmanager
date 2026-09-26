/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSCompositingManager.h"

// Turning a window over to its back and round again, for whatever triggers
// it (a menu item, a key).  Only the composited picture turns; the window
// itself never moves.
@interface URSCompositingManager (WindowFlip)

// NO without compositing or with the URSWindowFlipEnabled default off.
- (BOOL)canFlipWindows;

// Turns the frame over to its back, or back to its front if it is on or on
// its way to the back.  frameId is the frame's top-level window.
- (void)flipWindow:(xcb_window_t)frameId;

@end

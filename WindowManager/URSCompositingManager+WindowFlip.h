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
// The same; NO when no turn started.  completion runs when this turn ends,
// or when the window goes first, but not when it is turned round midway.
- (BOOL)flipWindow:(xcb_window_t)frameId completion:(dispatch_block_t)completion;

// YES while the frame is on its back or on its way there.
- (BOOL)showsBackOfWindow:(xcb_window_t)frameId;
// YES once the frame has come to rest on its back.
- (BOOL)restsOnBackOfWindow:(xcb_window_t)frameId;

@end

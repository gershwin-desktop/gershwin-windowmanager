/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <xcb/xcb.h>

// Shows windows somewhere other than where they are for as long as it is
// installed in the compositor (the window overview does).  Like an effect it
// changes only where a window's picture is painted, never the window, so the
// windows keep their places and their live content.  Rects are in root
// pixels, y down, borders included.
@protocol URSWindowPresentation <NSObject>

// Where to paint the window now, or NO to paint it where it is.
- (BOOL)getPaintRect:(NSRect *)paintRect
           forWindow:(xcb_window_t)windowId
          windowRect:(NSRect)windowRect;

// How dark (0..1) a veil to lay over what lies below the lowest window the
// presentation shows.
- (double)backdropDimming;

// How opaque (0..1) to paint a window the presentation does not move, its
// shadow included; 1 leaves it as it is, 0 hides it.
- (double)opacityForWindow:(xcb_window_t)windowId;

// While YES the compositor repaints every frame.
- (BOOL)isAnimating;

@end

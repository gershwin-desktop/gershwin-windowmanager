/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Cursors of the Xcursor theme at a given pixel size.  libxcb-cursor loads a
// theme only at the one size it reads from the resources at startup; with
// monitors of different scale factors the window manager needs each cursor
// at several sizes, so it loads the theme files itself (libXcursor) and makes
// the cursors with RENDER.  Every cursor is made once per size and kept for
// the life of the window manager (a handful of names times the factors in
// use); callers never free them.

#import <Foundation/Foundation.h>
#import <xcb/xcb.h>

@interface URSCursorTheme : NSObject

+ (instancetype)sharedThemeWithConnection:(xcb_connection_t *)connection
                                     root:(xcb_window_t)root;

// The theme's cursor `name` at `size` pixels, XCB_NONE when the theme has
// no cursor of that name or `size` is 0.
- (xcb_cursor_t)cursorNamed:(NSString *)name size:(uint32_t)size;

@end

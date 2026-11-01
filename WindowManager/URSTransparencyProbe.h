/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <xcb/xcb.h>

/* Decides whether a depth-32 window has a (almost fully) transparent
 * background by sampling the alpha of its edge strips.
 *
 * The pixels are read through MIT-SHM into one segment the window manager
 * keeps, never with a plain GetImage: on FreeBSD CI the image data of such
 * replies ended up read as X packets (a gray pixel and runs of transparent
 * zeros showed up as events), which threw libxcb's sequence numbers off for
 * good.  With MIT-SHM the reply carries no pixels at all. */
@interface URSTransparencyProbe : NSObject

- (instancetype)initWithConnection:(xcb_connection_t *)connection;

/* 1 transparent background, 0 opaque, -1 undetermined: the window could not
 * be read now, or there is no MIT-SHM to read it with. */
- (int)classifyWindow:(xcb_window_t)window
                width:(uint16_t)width
               height:(uint16_t)height;

/* Detaches and frees the segment; the connection must still be open. */
- (void)invalidate;

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWindowDeformation.h"

// A window made of jelly: a grid of masses, each tied by a spring to its
// place on the window and to its neighbours.  The point the pointer holds
// stays under the pointer; the rest trails behind when the window is moved
// and wobbles back into shape when it stops or is let go.
@interface URSWobblyModel : NSObject <URSWindowDeformation>

// grabPoint is where the pointer holds the window, in root pixels.
- (instancetype)initWithWindowRect:(NSRect)windowRect
                         grabPoint:(NSPoint)grabPoint
                              time:(NSTimeInterval)now;

// The pointer let go: the whole window now springs back into shape.
- (void)releaseGrab;

@property (readonly, nonatomic) BOOL grabbed;
// The window's rect as of the last step: where the mesh points are placed
// from.
@property (readonly, nonatomic) NSRect windowRect;

@end

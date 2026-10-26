/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "URSProjection.h"

// Where the parts of a window's back are when it shows its flip side (a
// terminal in the application's source directory, see URSFlipSideController):
// the front's titlebar stays at the top, so the window still reads as itself
// and its buttons are where the real ones are, and the flip side window
// fills the client area below it.
//
// Face coordinates are the pixels of the frame's own picture (the face the
// back is painted on, see URSWindowProjection): origin at the frame's top
// left, y down.  On the back URSFlipGeometry maps them upright and
// unmirrored, so the titlebar strip and the flip side both read as they
// would on the front.
@interface URSFlipSideGeometry : NSObject

@property (readonly, nonatomic) NSSize frameSize;
// Where the flip side window's top left lies in face coordinates: its root
// position less the frame's.
@property (readonly, nonatomic) NSPoint clientOffset;
@property (readonly, nonatomic) NSSize flipSideSize;

- (instancetype)initWithFrameSize:(NSSize)frameSize
                     clientOffset:(NSPoint)clientOffset
                     flipSideSize:(NSSize)flipSideSize;

// The part of the front painted on the back: the full width of the frame
// down to where the client area begins.  Empty when the flip side does not
// start inside the frame.
- (NSRect)titlebarStrip;
// The flip side window in face coordinates.
- (NSRect)flipSideRect;
// Screen to flip side picture, from screen to face (toFace of the window's
// projection): the flip side's pixel (0, 0) lies at clientOffset on the face.
- (URSProjectiveMatrix)flipSideMatrixForFaceMatrix:(URSProjectiveMatrix)toFace;

@end

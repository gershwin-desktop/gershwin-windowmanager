/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "URSProjection.h"

// A window turned about its vertical centre line and seen in perspective:
// at 0 degrees the front is in view where the window really is, at 180 the
// back, upright and in the same place.  All coordinates are window-local
// (see URSWindowProjection); angles are in degrees.
@interface URSFlipGeometry : NSObject

@property (readonly, nonatomic) NSSize size;
// How far the viewer is from the window, in pixels.
@property (readonly, nonatomic) double viewerDistance;

- (instancetype)initWithSize:(NSSize)size;

- (BOOL)showsBackFaceAtAngle:(double)degrees;
// Face picture to screen; the back face is mirrored so it reads upright.
- (URSProjectiveMatrix)faceToScreenAtAngle:(double)degrees;
// The face's top left, top right, bottom right and bottom left corners.
- (void)getCorners:(NSPoint *)corners atAngle:(double)degrees;
- (double)shadingAtAngle:(double)degrees;
// NO while the window is seen edge-on and there is nothing to paint.
- (BOOL)getProjection:(URSWindowProjection *)projection atAngle:(double)degrees;
// Everything the face covers while turning between the two angles, one
// pixel wider on every side for the filtered edge, in whole pixels.
- (NSRect)sweptRectFromAngle:(double)from toAngle:(double)to;

// The angle a turn from one angle to another has reached at progress t,
// eased in and out like the other window transitions.
+ (double)angleAtProgress:(double)t fromAngle:(double)from toAngle:(double)to;

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// A plane-to-plane projective map in homogeneous coordinates, m[row][column],
// applied to column vectors (x, y, 1).  XRender takes exactly this matrix as
// a picture transform and divides by w itself, so a window turned in depth
// is drawn by the server in one composite.
typedef struct {
    double m[3][3];
} URSProjectiveMatrix;

URSProjectiveMatrix URSProjectiveMatrixIdentity(void);
URSProjectiveMatrix URSProjectiveMatrixTranslation(double tx, double ty);
// a applied after b.
URSProjectiveMatrix URSProjectiveMatrixMultiply(URSProjectiveMatrix a, URSProjectiveMatrix b);
// NO for a singular matrix (a plane seen exactly edge-on).
BOOL URSProjectiveMatrixInvert(URSProjectiveMatrix m, URSProjectiveMatrix *inverse);
NSPoint URSProjectiveMatrixMapPoint(URSProjectiveMatrix m, NSPoint p);
// Bounding box of a rect's image; a projective map keeps lines straight, so
// the four corners bound it as long as the rect stays in front of the viewer.
NSRect URSProjectiveMatrixMapRectBounds(URSProjectiveMatrix m, NSRect r);
// The same map scaled for the 16.16 fixed point entries of an XRender
// transform: a map that only moves and scales is kept exact (w stays 1, so
// the server keeps its fast affine path); a perspective map is scaled up
// until its largest entry is URSProjectiveFixedPointLimit, because its
// perspective row is far below 1 and would otherwise lose most of its bits.
URSProjectiveMatrix URSProjectiveMatrixForFixedPoint(URSProjectiveMatrix m);
extern const double URSProjectiveFixedPointLimit;

// One frame of a window turned in depth.  Coordinates are window-local:
// origin at the window's top left corner where it really is, y down, pixels.
typedef struct URSWindowProjection {
    // Face picture pixel to window-local screen pixel, and back.
    URSProjectiveMatrix toScreen;
    URSProjectiveMatrix toFace;
    // 0 paints the face as it is, 1 black.
    double shading;
    // The back of the window is in view: a plain panel, not the content.
    BOOL backFace;
} URSWindowProjection;

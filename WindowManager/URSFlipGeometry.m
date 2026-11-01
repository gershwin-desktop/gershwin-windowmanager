/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSFlipGeometry.h"
#import "URSPresentationTransition.h"
#import <math.h>

// The viewer sits two window widths away: close enough for the depth to
// read at once, far enough that the near edge grows by at most a third.
// Small windows get a floor so their drop shadow, which reaches further
// out than half of them, never passes behind the viewer.
static const double URSFlipViewerDistancePerWidth = 2.0;
static const double URSFlipMinimumViewerDistance = 200.0;
// Darkest shading, reached edge-on: light, like a face turned from a lamp.
static const double URSFlipMaximumShading = 0.4;
// Narrower than this the face is a sliver not worth a composite.
static const double URSFlipMinimumVisibleWidth = 0.5;

static double URSFlipRadians(double degrees) {
    return degrees * M_PI / 180.0;
}

// sin and cos of the angle, with the rounding noise of sin(pi) removed so a
// window at rest gets an exactly affine map (the server's fast path).
static void URSFlipSinCos(double degrees, double *s, double *c) {
    double r = URSFlipRadians(degrees);
    *s = sin(r);
    *c = cos(r);
    if (fabs(*s) < 1e-12) *s = 0.0;
    if (fabs(*c) < 1e-12) *c = 0.0;
}

@implementation URSFlipGeometry

- (instancetype)initWithSize:(NSSize)size {
    self = [super init];
    if (self) {
        _size = size;
        _viewerDistance = MAX(URSFlipViewerDistancePerWidth * size.width,
                              URSFlipMinimumViewerDistance);
    }
    return self;
}

- (BOOL)showsBackFaceAtAngle:(double)degrees {
    return cos(URSFlipRadians(degrees)) < 0.0;
}

- (URSProjectiveMatrix)faceToScreenAtAngle:(double)degrees {
    double s, c;
    URSFlipSinCos(degrees, &s, &c);
    // The back face is the front seen from behind: mirrored left to right,
    // which this undoes so it reads upright, like the back of a card.
    double side = [self showsBackFaceAtAngle:degrees] ? -1.0 : 1.0;
    // About the centre line, a face point x from the centre turns to
    // x cos in the plane and x sin towards the viewer, who sees it scaled
    // by D / (D - depth): a perspective divide by w = 1 - depth / D.
    URSProjectiveMatrix turn = {{
        { side * c, 0.0, 0.0 },
        { 0.0, 1.0, 0.0 },
        { -side * s / self.viewerDistance, 0.0, 1.0 },
    }};
    double cx = self.size.width * 0.5;
    double cy = self.size.height * 0.5;
    return URSProjectiveMatrixMultiply(URSProjectiveMatrixTranslation(cx, cy),
               URSProjectiveMatrixMultiply(turn, URSProjectiveMatrixTranslation(-cx, -cy)));
}

- (void)getCorners:(NSPoint *)corners atAngle:(double)degrees {
    URSProjectiveMatrix m = [self faceToScreenAtAngle:degrees];
    NSPoint face[4] = {
        { 0.0, 0.0 }, { self.size.width, 0.0 },
        { self.size.width, self.size.height }, { 0.0, self.size.height },
    };
    for (int i = 0; i < 4; i++) {
        corners[i] = URSProjectiveMatrixMapPoint(m, face[i]);
    }
}

- (double)shadingAtAngle:(double)degrees {
    double s, c;
    URSFlipSinCos(degrees, &s, &c);
    return URSFlipMaximumShading * (1.0 - fabs(c));
}

- (BOOL)getProjection:(URSWindowProjection *)projection atAngle:(double)degrees {
    double s, c;
    URSFlipSinCos(degrees, &s, &c);
    if (fabs(c) * self.size.width < URSFlipMinimumVisibleWidth) {
        return NO;
    }
    URSProjectiveMatrix toScreen = [self faceToScreenAtAngle:degrees];
    URSProjectiveMatrix toFace;
    if (!URSProjectiveMatrixInvert(toScreen, &toFace)) {
        return NO;
    }
    projection->toScreen = toScreen;
    projection->toFace = toFace;
    projection->shading = [self shadingAtAngle:degrees];
    projection->backFace = [self showsBackFaceAtAngle:degrees];
    return YES;
}

- (NSRect)sweptRectFromAngle:(double)from toAngle:(double)to {
    double lo = MAX(0.0, MIN(from, to));
    double hi = MIN(180.0, MAX(from, to));
    // Each corner moves monotonically except where the near edge is widest
    // (sin = W / 2D, on either face) and tallest (edge-on), so the ends of
    // the turn and those angles bound every frame.
    double widest = asin(self.size.width * 0.5 / self.viewerDistance) * 180.0 / M_PI;
    double candidates[5] = { lo, hi, widest, 180.0 - widest, 90.0 };
    double x1 = INFINITY, y1 = INFINITY, x2 = -INFINITY, y2 = -INFINITY;
    for (int i = 0; i < 5; i++) {
        if (candidates[i] < lo || candidates[i] > hi) {
            continue;
        }
        NSPoint corners[4];
        [self getCorners:corners atAngle:candidates[i]];
        for (int j = 0; j < 4; j++) {
            x1 = MIN(x1, corners[j].x);
            y1 = MIN(y1, corners[j].y);
            x2 = MAX(x2, corners[j].x);
            y2 = MAX(y2, corners[j].y);
        }
    }
    NSRect bounds = NSMakeRect(x1, y1, x2 - x1, y2 - y1);
    return NSIntegralRect(NSInsetRect(bounds, -1.0, -1.0));
}

+ (double)angleAtProgress:(double)t fromAngle:(double)from toAngle:(double)to {
    double clamped = MIN(1.0, MAX(0.0, t));
    return from + (to - from) * URSPresentationEase(clamped);
}

@end

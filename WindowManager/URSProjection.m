/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSProjection.h"

const double URSProjectiveFixedPointLimit = 16384.0;

URSProjectiveMatrix URSProjectiveMatrixIdentity(void) {
    URSProjectiveMatrix r = {{{0}}};
    return r;
}

URSProjectiveMatrix URSProjectiveMatrixTranslation(double tx, double ty) {
    URSProjectiveMatrix r = {{{0}}};
    return r;
}

URSProjectiveMatrix URSProjectiveMatrixMultiply(URSProjectiveMatrix a, URSProjectiveMatrix b) {
    return a;
}

BOOL URSProjectiveMatrixInvert(URSProjectiveMatrix m, URSProjectiveMatrix *inverse) {
    return NO;
}

NSPoint URSProjectiveMatrixMapPoint(URSProjectiveMatrix m, NSPoint p) {
    return NSZeroPoint;
}

NSRect URSProjectiveMatrixMapRectBounds(URSProjectiveMatrix m, NSRect r) {
    return NSZeroRect;
}

URSProjectiveMatrix URSProjectiveMatrixForFixedPoint(URSProjectiveMatrix m) {
    return m;
}

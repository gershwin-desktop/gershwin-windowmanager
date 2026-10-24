/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "URSResizeGeometry.h"
#include <string.h>

static URSZoneRect zoneRect(int32_t x, int32_t y, int32_t width, int32_t height)
{
    URSZoneRect r = { x, y, width, height };
    return r;
}

URSResizeZoneLayout URSResizeZoneLayoutForFrame(int32_t w,
                                                int32_t h,
                                                int32_t corner,
                                                int32_t edge,
                                                int32_t growBoxSize)
{
    URSResizeZoneLayout l;
    memset(&l, 0, sizeof(l));

    l.nw = zoneRect(0, 0, corner, corner);
    l.ne = zoneRect(w - corner, 0, corner, corner);
    l.sw = zoneRect(0, h - corner, corner, corner);
    l.se = zoneRect(w - corner, h - corner, corner, corner);

    l.n = zoneRect(corner, 0, w - 2 * corner, edge);
    l.s = zoneRect(corner, h - edge, w - 2 * corner, edge);
    l.w = zoneRect(0, corner, edge, h - 2 * corner);
    l.e = zoneRect(w - edge, corner, edge, h - 2 * corner);

    if (growBoxSize > 0)
        l.growBox = zoneRect(w - growBoxSize, h - growBoxSize, growBoxSize, growBoxSize);

    return l;
}

URSResizeGrab URSResizeGrabMake(int32_t pointerX, int32_t pointerY,
                                int32_t frameWidth, int32_t frameHeight)
{
    URSResizeGrab g;
    g.toLeft = pointerX;
    g.toTop = pointerY;
    g.toRight = frameWidth - pointerX;
    g.toBottom = frameHeight - pointerY;
    return g;
}

int32_t URSResizeGrabLeftEdge(URSResizeGrab grab, int32_t rootX)
{
    return rootX - grab.toLeft;
}

int32_t URSResizeGrabTopEdge(URSResizeGrab grab, int32_t rootY)
{
    return rootY - grab.toTop;
}

int32_t URSResizeGrabWidth(URSResizeGrab grab, int32_t pointerX)
{
    return pointerX + grab.toRight;
}

int32_t URSResizeGrabHeight(URSResizeGrab grab, int32_t pointerY)
{
    return pointerY + grab.toBottom;
}

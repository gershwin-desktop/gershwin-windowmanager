/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSnapZone.h"

SnapZone URSSnapZoneForPointer(int32_t x, int32_t y,
                               int32_t areaX, int32_t areaY,
                               uint32_t areaWidth, uint32_t areaHeight,
                               BOOL windowResizable)
{
    if (!windowResizable) {
        return SnapZoneNone;
    }

    int32_t areaRight = areaX + (int32_t)areaWidth;
    int32_t areaBottom = areaY + (int32_t)areaHeight;
    BOOL nearTop = y <= areaY + SNAP_EDGE_THRESHOLD;
    BOOL nearBottom = y >= areaBottom - SNAP_EDGE_THRESHOLD;
    BOOL nearLeft = x <= areaX + SNAP_EDGE_THRESHOLD;
    BOOL nearRight = x >= areaRight - SNAP_EDGE_THRESHOLD;
    BOOL inLeftCornerZone = x <= areaX + SNAP_CORNER_THRESHOLD;
    BOOL inRightCornerZone = x >= areaRight - SNAP_CORNER_THRESHOLD;
    BOOL inTopCornerZone = y <= areaY + SNAP_CORNER_THRESHOLD;
    BOOL inBottomCornerZone = y >= areaBottom - SNAP_CORNER_THRESHOLD;

    // A corner needs the pointer at an edge AND within the corner zone of
    // the edge across, so that a pointer sliding along one edge only turns
    // into a quarter snap close to the corner.
    if ((nearTop || nearLeft) && inTopCornerZone && inLeftCornerZone)
        return SnapZoneTopLeft;
    if ((nearTop || nearRight) && inTopCornerZone && inRightCornerZone)
        return SnapZoneTopRight;
    if ((nearBottom || nearLeft) && inBottomCornerZone && inLeftCornerZone)
        return SnapZoneBottomLeft;
    if ((nearBottom || nearRight) && inBottomCornerZone && inRightCornerZone)
        return SnapZoneBottomRight;
    if (nearTop && !inLeftCornerZone && !inRightCornerZone)
        return SnapZoneTop;
    if (nearLeft && !inTopCornerZone && !inBottomCornerZone)
        return SnapZoneLeft;
    if (nearRight && !inTopCornerZone && !inBottomCornerZone)
        return SnapZoneRight;
    return SnapZoneNone;
}

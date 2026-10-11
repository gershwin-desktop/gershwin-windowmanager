/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <stdint.h>

/*
 * Without a compositor a window cannot be translucent, so the snap preview
 * is cut down to a frame with the X Shape extension: the interior is not
 * part of the window and the windows beneath stay visible. These are the
 * rectangles of that frame, relative to the preview window and in device
 * pixels. Header-only so tests need not link the overlay.
 */
typedef struct {
    int32_t x, y;
    uint32_t width, height;
} URSSnapPreviewRect;

// Fills out[4] (top, bottom, left, right; no overlaps) and returns how many
// are used. A window too small to have an interior is covered whole.
static inline int URSSnapPreviewFrameRects(uint32_t width, uint32_t height,
                                           uint32_t border,
                                           URSSnapPreviewRect out[4])
{
    if (border == 0) {
        border = 1;
    }
    if (width <= 2 * border || height <= 2 * border) {
        out[0] = (URSSnapPreviewRect){0, 0, width, height};
        return 1;
    }
    uint32_t sideHeight = height - 2 * border;
    out[0] = (URSSnapPreviewRect){0, 0, width, border};
    out[1] = (URSSnapPreviewRect){0, (int32_t)(height - border), width, border};
    out[2] = (URSSnapPreviewRect){0, (int32_t)border, border, sideHeight};
    out[3] = (URSSnapPreviewRect){(int32_t)(width - border), (int32_t)border,
                                  border, sideHeight};
    return 4;
}

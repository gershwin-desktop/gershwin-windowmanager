/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSShadowSize.h"

/* X servers keep window sizes in signed 16 bits, so nothing real is larger;
 * anything above is an unknown size seen as unsigned. */
static const int URSLargestWindowSide = 32767;

BOOL URSShadowSizeIsKnown(int width, int height)
{
  return width > 0 && height > 0
    && width <= URSLargestWindowSide && height <= URSLargestWindowSide;
}

size_t URSShadowImageBytes(int width, int height, int gaussianSize)
{
  if (!URSShadowSizeIsKnown(width, height) || gaussianSize < 0)
    {
      return 0;
    }
  return (size_t)(width + gaussianSize) * (size_t)(height + gaussianSize);
}

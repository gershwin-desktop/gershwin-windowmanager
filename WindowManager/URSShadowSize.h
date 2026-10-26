/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Whether a window of this size (border included) may get a shadow.  A size
 * the compositor does not really know - XCBInvalidRect's 0xffff, i.e. -1 as
 * an unsigned 16-bit value, or 0 - must wait for the real one: shadow images
 * are allocated from it. */
BOOL URSShadowSizeIsKnown(int width, int height);

/* The bytes of a shadow image for a window of this size with a blur of
 * gaussianSize, or 0 when no image may be made for it. */
size_t URSShadowImageBytes(int width, int height, int gaussianSize);

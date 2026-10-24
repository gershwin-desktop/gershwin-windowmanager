/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Which window sizes a shadow may be made for.  The WindowManager crashed in
// -makeShadowImage:... for a window it believed to be 65535 x 65535 (the
// unsigned 16-bit form of -1, an unknown size): the buffer size overflowed
// int, a small buffer was allocated and written far past its end.
// Headless.  Run with:  gnustep-tests test-shadowsize

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "URSShadowSize.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("window sizes")
    PASS(URSShadowSizeIsKnown(800, 600), "an ordinary window has a shadow");
    PASS(URSShadowSizeIsKnown(1, 1), "so has a one pixel window");
    PASS(URSShadowSizeIsKnown(32767, 32767), "and the largest window X can have");
    PASS(!URSShadowSizeIsKnown(65535, 65535), "an unknown size (-1 as 16 bits) has none");
    PASS(!URSShadowSizeIsKnown(65535, 600), "nor an unknown width");
    PASS(!URSShadowSizeIsKnown(800, 65535), "nor an unknown height");
    PASS(!URSShadowSizeIsKnown(0, 600), "nor a window without width");
    PASS(!URSShadowSizeIsKnown(800, 0), "nor a window without height");
    PASS(!URSShadowSizeIsKnown(-1, -1), "nor a negative size");
    PASS(!URSShadowSizeIsKnown(32768, 600), "nor one wider than X allows");
  END_SET("window sizes")

  START_SET("shadow image bytes")
    PASS(URSShadowImageBytes(800, 600, 24) == (size_t)824 * 624,
         "the image is the window plus the blur on each axis");
    PASS(URSShadowImageBytes(65535, 65535, 24) == 0,
         "an unknown size gives no image instead of an overflowed one");
    PASS(URSShadowImageBytes(0, 600, 24) == 0, "nor does an empty window");
    PASS(URSShadowImageBytes(800, 600, -1) == 0, "nor a negative blur");
  END_SET("shadow image bytes")

  [arp release];
  return 0;
}

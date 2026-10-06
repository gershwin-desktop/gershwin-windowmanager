/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

//
//  URSBackgroundRender.h
//  uroswm - desktop wallpaper decoding in a short-lived helper process
//
//  Decoding and scaling the wallpaper takes tens of megabytes of heap that the
//  allocator keeps resident, and the window manager runs for the whole
//  session. The work therefore runs in a copy of the executable that exits
//  when it is done, and hands over the finished pixels on its standard output.
//

#import <Foundation/Foundation.h>

/** Command-line flag that selects the helper mode of the executable. */
extern NSString * const URSRenderBackgroundFlag;

/**
 * Helper-mode entry point: decode the image, scale it to width x height and
 * write the pixels to standard output as tightly packed 32-bit ARGB (native
 * endian), width * height * 4 bytes. Returns the process exit status.
 */
int URSRenderBackgroundMain(NSString *imagePath, NSUInteger width, NSUInteger height);

/**
 * Runs the helper and returns the pixel data (width * height * 4 bytes), or
 * nil when it failed.
 */
NSData *URSRenderBackgroundInHelper(NSString *imagePath, NSUInteger width, NSUInteger height);

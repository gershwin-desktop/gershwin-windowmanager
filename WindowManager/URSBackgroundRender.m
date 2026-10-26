/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSBackgroundRender.h"
#import <AppKit/AppKit.h>
#include <unistd.h>

NSString * const URSRenderBackgroundFlag = @"--render-background";

int URSRenderBackgroundMain(NSString *imagePath, NSUInteger width, NSUInteger height)
{
    @autoreleasepool {
        [NSApplication sharedApplication];

        NSImage *image = [[NSImage alloc] initWithContentsOfFile:imagePath];
        if (!image || width < 1 || height < 1) {
            NSLog(@"[Compositor] Desktop background: failed to load image at %@", imagePath);
            return 1;
        }

        NSImage *scaled = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
        [scaled lockFocus];
        [image drawInRect:NSMakeRect(0, 0, width, height)
                 fromRect:NSZeroRect
                operation:NSCompositeCopy
                 fraction:1.0];
        /* Read the pixels back directly: -TIFFRepresentation would encode a
           TIFF that is only decoded again. */
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
            initWithFocusedViewRect:NSMakeRect(0, 0, width, height)];
        [scaled unlockFocus];
        if (!bitmap) {
            NSLog(@"[Compositor] Desktop background: bitmap conversion failed");
            return 1;
        }

        size_t bufSize = (size_t)width * (size_t)height * 4;
        uint32_t *argb = calloc(1, bufSize);
        if (!argb) {
            return 1;
        }

        NSUInteger srcW = [bitmap pixelsWide];
        NSUInteger srcH = [bitmap pixelsHigh];
        for (NSUInteger y = 0; y < height && y < srcH; y++) {
            for (NSUInteger x = 0; x < width && x < srcW; x++) {
                NSUInteger pixel[4];
                [bitmap getPixel:pixel atX:x y:y];
                argb[y * width + x] = ((uint32_t)pixel[3] << 24) | ((uint32_t)pixel[0] << 16)
                                    | ((uint32_t)pixel[1] << 8) | (uint32_t)pixel[2];
            }
        }

        NSData *data = [NSData dataWithBytesNoCopy:argb length:bufSize freeWhenDone:YES];
        NSFileHandle *out = [NSFileHandle fileHandleWithStandardOutput];
        @try {
            [out writeData:data];
        } @catch (NSException *e) {
            NSLog(@"[Compositor] Desktop background: cannot write the pixels: %@", e);
            return 1;
        }
    }
    return 0;
}

NSData *URSRenderBackgroundInHelper(NSString *imagePath, NSUInteger width, NSUInteger height)
{
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    [task setLaunchPath:[[NSBundle mainBundle] executablePath]];
    [task setArguments:@[URSRenderBackgroundFlag, imagePath,
                         [NSString stringWithFormat:@"%lu", (unsigned long)width],
                         [NSString stringWithFormat:@"%lu", (unsigned long)height]]];
    [task setStandardOutput:pipe];

    NSData *data = nil;
    int status = -1;
    @try {
        [task launch];
        // Read to the end before waiting: the pixels do not fit in the pipe.
        data = [[pipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        status = [task terminationStatus];
    } @catch (NSException *e) {
        NSLog(@"[Compositor] Desktop background: could not run helper: %@", e);
        return nil;
    }

    if (status != 0) {
        NSLog(@"[Compositor] Desktop background: helper failed with status %d", status);
        return nil;
    }
    if ([data length] != (size_t)width * height * 4) {
        NSLog(@"[Compositor] Desktop background: helper wrote %lu bytes, expected %lu",
              (unsigned long)[data length], (unsigned long)((size_t)width * height * 4));
        return nil;
    }
    return data;
}

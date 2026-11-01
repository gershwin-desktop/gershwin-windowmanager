/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSTransparencyProbe.h"
#include <xcb/shm.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

// Strip thickness and the inset of the sampled row or column within it.
static const int URSProbeStrip = 4;
static const int URSProbeInset = 2;

// One strip is at most 65535 pixels long and URSProbeStrip thick, 4 bytes
// each, so a single segment of this size serves every window.
static const size_t URSProbeSegmentSize = (size_t)65535 * URSProbeStrip * 4;

// An anonymous shared memory file to hand to the X server with
// xcb_shm_attach_fd: memfd on Linux, SHM_ANON on FreeBSD, and an unlinked
// POSIX shared memory object elsewhere (OpenBSD and the other BSDs).
static int URSCreateSharedMemoryFile(size_t size)
{
    int fd = -1;
#if defined(__linux__)
    fd = memfd_create("WindowManager transparency probe", MFD_CLOEXEC);
#elif defined(SHM_ANON)
    fd = shm_open(SHM_ANON, O_RDWR | O_CREAT, 0600);
#else
    char name[64];
    snprintf(name, sizeof(name), "/WindowManager-probe-%d", (int)getpid());
    fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd >= 0) {
        shm_unlink(name);
    }
#endif
    if (fd < 0) {
        return -1;
    }
    if (ftruncate(fd, (off_t)size) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

@implementation URSTransparencyProbe
{
    xcb_connection_t *_connection;
    xcb_shm_seg_t _segment;
    uint8_t *_pixels;
    // Set up is tried once: without MIT-SHM it would fail the same way on
    // every window.
    BOOL _setUpTried;
}

- (instancetype)initWithConnection:(xcb_connection_t *)connection
{
    self = [super init];
    if (self) {
        _connection = connection;
    }
    return self;
}

- (void)dealloc
{
    [self invalidate];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (BOOL)setUp
{
    if (_setUpTried) {
        return _pixels != NULL;
    }
    _setUpTried = YES;

    const xcb_query_extension_reply_t *ext = xcb_get_extension_data(_connection, &xcb_shm_id);
    xcb_shm_query_version_reply_t *version = NULL;
    if (ext && ext->present) {
        version = xcb_shm_query_version_reply(_connection, xcb_shm_query_version(_connection), NULL);
    }
    // Attaching a file descriptor needs MIT-SHM 1.2.
    BOOL fdCapable = version &&
        (version->major_version > 1 || (version->major_version == 1 && version->minor_version >= 2));
    free(version);
    if (!fdCapable) {
        NSLog(@"[Compositor] No MIT-SHM 1.2 on this X server: transparent window "
              @"backgrounds are not detected, those windows get a shadow");
        return NO;
    }

    int fd = URSCreateSharedMemoryFile(URSProbeSegmentSize);
    if (fd < 0) {
        NSLog(@"[Compositor] Cannot create shared memory for the transparency probe: %s; "
              @"transparent window backgrounds are not detected", strerror(errno));
        return NO;
    }
    void *map = mmap(NULL, URSProbeSegmentSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        NSLog(@"[Compositor] Cannot map shared memory for the transparency probe: %s; "
              @"transparent window backgrounds are not detected", strerror(errno));
        close(fd);
        return NO;
    }

    // libxcb sends the descriptor and closes it.
    _segment = xcb_generate_id(_connection);
    xcb_generic_error_t *error = xcb_request_check(_connection,
        xcb_shm_attach_fd_checked(_connection, _segment, fd, 0));
    if (error) {
        NSLog(@"[Compositor] The X server refused the transparency probe's shared memory "
              @"(error %u); transparent window backgrounds are not detected", error->error_code);
        free(error);
        munmap(map, URSProbeSegmentSize);
        _segment = XCB_NONE;
        return NO;
    }
    _pixels = map;
    return YES;
}

- (void)invalidate
{
    if (_pixels) {
        xcb_shm_detach(_connection, _segment);
        xcb_flush(_connection);
        munmap(_pixels, URSProbeSegmentSize);
        _pixels = NULL;
        _segment = XCB_NONE;
    }
}

- (int)classifyWindow:(xcb_window_t)window
                width:(uint16_t)w
               height:(uint16_t)h
{
    // Deliberately no plain GetImage when MIT-SHM is missing: that request
    // is what broke the connection, so such windows stay undetermined, which
    // the compositor turns into an opaque window with a shadow.
    if (![self setUp]) {
        return -1;
    }

    const int T = URSProbeStrip;
    const int I = URSProbeInset;
    struct { int16_t x, y; uint16_t sw, sh; } strips[4] = {
        { 0,                0,                w, T },   // top
        { 0,                (int16_t)(h - T), w, T },   // bottom
        { 0,                0,                T, h },   // left
        { (int16_t)(w - T), 0,                T, h },   // right
    };

    int opaque = 0, total = 0;
    for (int s = 0; s < 4; s++) {
        xcb_shm_get_image_reply_t *img = xcb_shm_get_image_reply(_connection,
            xcb_shm_get_image(_connection, window, strips[s].x, strips[s].y,
                              strips[s].sw, strips[s].sh, (uint32_t)~0,
                              XCB_IMAGE_FORMAT_Z_PIXMAP, _segment, 0),
            NULL);
        if (!img || img->depth != 32 ||
            img->size < (uint32_t)strips[s].sw * strips[s].sh * 4) {
            free(img);
            return -1;
        }
        free(img);
        const uint32_t *data = (const uint32_t *)_pixels;
        uint32_t stride = strips[s].sw;
        if (s < 2) {
            uint32_t step = strips[s].sw > 64 ? strips[s].sw / 64 : 1;
            for (uint32_t x = 0; x < strips[s].sw; x += step) {
                total++;
                if (((data[I * stride + x] >> 24) & 0xFF) >= 16) opaque++;
            }
        } else {
            uint32_t step = strips[s].sh > 64 ? strips[s].sh / 64 : 1;
            for (uint32_t y = 0; y < strips[s].sh; y += step) {
                total++;
                if (((data[y * stride + I] >> 24) & 0xFF) >= 16) opaque++;
            }
        }
    }

    if (total == 0) {
        return -1;
    }
    // Rounded corners etc. leave a few transparent samples on normal windows,
    // so an overwhelming translucent majority is required to skip the shadow.
    return (opaque * 100 < total * 12) ? 1 : 0;
}

@end

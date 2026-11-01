/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The transparency probe must tell an opaque from a translucent depth-32
// window as before, and must read the pixels through MIT-SHM: no GetImage
// request may go over the socket.
// Needs an X server: DISPLAY=:<n> gnustep-tests test-transparencyprobe

#import <Foundation/Foundation.h>
#import "Testing.h"
#include <dlfcn.h>
#include <xcb/composite.h>

// Counts plain GetImage requests made by the code compiled into this test.
static unsigned getImageRequests;

xcb_get_image_cookie_t xcb_get_image(xcb_connection_t *c, uint8_t format,
                                     xcb_drawable_t drawable, int16_t x, int16_t y,
                                     uint16_t width, uint16_t height, uint32_t planeMask)
{
    static xcb_get_image_cookie_t (*real)(xcb_connection_t *, uint8_t, xcb_drawable_t,
                                          int16_t, int16_t, uint16_t, uint16_t, uint32_t);
    if (!real) real = dlsym(RTLD_NEXT, "xcb_get_image");
    getImageRequests++;
    return real(c, format, drawable, x, y, width, height, planeMask);
}

#include "../WindowManager/URSTransparencyProbe.m"

static xcb_visualid_t argbVisual(xcb_screen_t *s)
{
    xcb_depth_iterator_t d = xcb_screen_allowed_depths_iterator(s);
    for (; d.rem; xcb_depth_next(&d)) {
        if (d.data->depth != 32) continue;
        xcb_visualtype_iterator_t v = xcb_depth_visuals_iterator(d.data);
        if (v.rem) return v.data->visual_id;
    }
    return 0;
}

static xcb_window_t argbWindow(xcb_connection_t *c, xcb_screen_t *s, xcb_colormap_t cmap,
                               uint32_t background)
{
    xcb_window_t w = xcb_generate_id(c);
    uint32_t vals[] = { background, 0, cmap };
    xcb_create_window(c, 32, w, s->root, 10, 10, 200, 120, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
                      argbVisual(s), XCB_CW_BACK_PIXEL | XCB_CW_BORDER_PIXEL | XCB_CW_COLORMAP,
                      vals);
    xcb_map_window(c, w);
    return w;
}

int main(void)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    xcb_connection_t *c = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(c)) {
        NSLog(@"No X server; set DISPLAY to a private Xvfb");
        PASS(0, "an X server is reachable");
        [pool release];
        return 0;
    }
    xcb_screen_t *s = xcb_setup_roots_iterator(xcb_get_setup(c)).data;
    // Redirected like under the compositor, so each window keeps its alpha.
    free(xcb_composite_query_version_reply(c, xcb_composite_query_version(c, 0, 4), NULL));
    xcb_composite_redirect_subwindows(c, s->root, XCB_COMPOSITE_REDIRECT_MANUAL);
    xcb_colormap_t cmap = xcb_generate_id(c);
    xcb_create_colormap(c, XCB_COLORMAP_ALLOC_NONE, cmap, s->root, argbVisual(s));
    xcb_window_t opaque = argbWindow(c, s, cmap, 0xFFC6C8CE);
    xcb_window_t clear = argbWindow(c, s, cmap, 0x00000000);
    free(xcb_get_input_focus_reply(c, xcb_get_input_focus(c), NULL));

    URSTransparencyProbe *probe = [[URSTransparencyProbe alloc] initWithConnection:c];

    START_SET("transparency probe")

    PASS([probe classifyWindow:opaque width:200 height:120] == 0,
         "an opaque depth-32 window is opaque");
    PASS([probe classifyWindow:clear width:200 height:120] == 1,
         "a depth-32 window with a transparent background is transparent");
    PASS([probe classifyWindow:opaque width:200 height:120] == 0,
         "the shared segment is reused for the next window");
    PASS(getImageRequests == 0,
         "no GetImage request went over the socket (%u)", getImageRequests);
    [probe invalidate];
    PASS(!xcb_connection_has_error(c), "the connection survives the teardown");

    END_SET("transparency probe")

    [probe release];
    xcb_disconnect(c);
    [pool release];
    return 0;
}

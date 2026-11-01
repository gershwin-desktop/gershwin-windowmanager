/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSCursorTheme.h"
#import "URSCursorSize.h"
#import "URSImageUpload.h"
#import <xcb/render.h>
#import <X11/Xcursor/Xcursor.h>

@implementation URSCursorTheme
{
    xcb_connection_t *_connection;
    xcb_window_t _root;
    xcb_render_pictformat_t _argbFormat;
    NSMutableDictionary *_cursors;   // "name/size" -> NSNumber xcb_cursor_t
}

+ (instancetype)sharedThemeWithConnection:(xcb_connection_t *)connection
                                     root:(xcb_window_t)root
{
    static URSCursorTheme *shared = nil;
    if (shared == nil) {
        shared = [[URSCursorTheme alloc] init];
        shared->_connection = connection;
        shared->_root = root;
        shared->_cursors = [NSMutableDictionary dictionary];
    }
    return shared;
}

/* The theme the user chose, looked up like libXcursor and libxcb-cursor do:
 * the environment first, then the resources; NULL is the "default" theme. */
- (NSString *)themeName
{
    const char *env = getenv("XCURSOR_THEME");
    if (env != NULL && *env != '\0')
        return [NSString stringWithUTF8String:env];

    NSString *resources = nil;
    xcb_get_property_reply_t *reply = xcb_get_property_reply(_connection,
        xcb_get_property(_connection, 0, _root, XCB_ATOM_RESOURCE_MANAGER,
                         XCB_ATOM_STRING, 0, 65536), NULL);
    if (reply != NULL && xcb_get_property_value_length(reply) > 0)
        resources = [[NSString alloc] initWithBytes:xcb_get_property_value(reply)
                                             length:xcb_get_property_value_length(reply)
                                           encoding:NSUTF8StringEncoding];
    free(reply);
    return URSResourceValue(resources, @"Xcursor.theme");
}

- (xcb_render_pictformat_t)argbFormat
{
    if (_argbFormat != XCB_NONE)
        return _argbFormat;

    xcb_render_query_pict_formats_reply_t *formats = xcb_render_query_pict_formats_reply(
        _connection, xcb_render_query_pict_formats(_connection), NULL);
    if (formats == NULL)
        return XCB_NONE;
    xcb_render_pictforminfo_iterator_t it =
        xcb_render_query_pict_formats_formats_iterator(formats);
    for (; it.rem; xcb_render_pictforminfo_next(&it)) {
        xcb_render_pictforminfo_t *f = it.data;
        if (f->type == XCB_RENDER_PICT_TYPE_DIRECT && f->depth == 32 &&
            f->direct.alpha_shift == 24 && f->direct.alpha_mask == 0xff &&
            f->direct.red_shift == 16 && f->direct.green_shift == 8 &&
            f->direct.blue_shift == 0) {
            _argbFormat = f->id;
            break;
        }
    }
    free(formats);
    return _argbFormat;
}

/* One frame of a cursor: the image becomes a 32 bit picture and RENDER
 * makes the cursor from it (premultiplied ARGB, as Xcursor files hold it). */
- (xcb_cursor_t)cursorFromImage:(XcursorImage *)image
{
    xcb_render_pictformat_t format = [self argbFormat];
    if (format == XCB_NONE)
        return XCB_NONE;

    xcb_pixmap_t pixmap = xcb_generate_id(_connection);
    xcb_create_pixmap(_connection, 32, pixmap, _root, image->width, image->height);
    xcb_gcontext_t gc = xcb_generate_id(_connection);
    xcb_create_gc(_connection, gc, pixmap, 0, NULL);
    URSPutImageBanded(_connection, XCB_IMAGE_FORMAT_Z_PIXMAP, pixmap, gc,
                      image->width, image->height, 0, 0, 0, 32,
                      image->width * 4, (const uint8_t *)image->pixels);
    xcb_render_picture_t picture = xcb_generate_id(_connection);
    xcb_render_create_picture(_connection, picture, pixmap, format, 0, NULL);
    xcb_cursor_t cursor = xcb_generate_id(_connection);
    xcb_render_create_cursor(_connection, cursor, picture, image->xhot, image->yhot);
    xcb_render_free_picture(_connection, picture);
    xcb_free_gc(_connection, gc);
    xcb_free_pixmap(_connection, pixmap);
    return cursor;
}

- (xcb_cursor_t)cursorNamed:(NSString *)name size:(uint32_t)size
{
    if (size == 0)
        return XCB_NONE;

    NSString *key = [NSString stringWithFormat:@"%@/%u", name, size];
    NSNumber *cached = [_cursors objectForKey:key];
    if (cached != nil)
        return [cached unsignedIntValue];

    NSString *theme = [self themeName];
    XcursorImages *images = XcursorLibraryLoadImages([name UTF8String],
                                                     [theme UTF8String], (int)size);
    if (images == NULL || images->nimage == 0) {
        if (images != NULL)
            XcursorImagesDestroy(images);
        return XCB_NONE;
    }

    xcb_cursor_t cursor;
    if (images->nimage == 1) {
        cursor = [self cursorFromImage:images->images[0]];
    } else {
        /* An animated cursor (watch, progress) is one cursor per frame. */
        xcb_render_animcursorelt_t *frames = calloc(images->nimage, sizeof(*frames));
        for (int i = 0; i < images->nimage; i++) {
            frames[i].cursor = [self cursorFromImage:images->images[i]];
            frames[i].delay = images->images[i]->delay;
        }
        cursor = xcb_generate_id(_connection);
        xcb_render_create_anim_cursor(_connection, cursor, images->nimage, frames);
        for (int i = 0; i < images->nimage; i++)
            xcb_free_cursor(_connection, frames[i].cursor);
        free(frames);
    }
    XcursorImagesDestroy(images);

    if (cursor != XCB_NONE)
        [_cursors setObject:[NSNumber numberWithUnsignedInt:cursor] forKey:key];
    return cursor;
}

@end

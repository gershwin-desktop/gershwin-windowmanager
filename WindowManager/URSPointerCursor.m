/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSPointerCursor.h"
#import "URSCursorSize.h"
#import "URSCursorTheme.h"
#import "URSOutputScales.h"
#import "XCBConnection.h"
#import "XCBScreen.h"
#import <xcb/xcb_cursor.h>

@implementation URSPointerCursor
{
    XCBConnection *_connection;
    xcb_window_t _root;
    uint32_t _rootSize;          // UINT32_MAX until the root got a cursor
    xcb_cursor_t _defaultArrow;  // the theme's arrow at its default size
    uint32_t _publishedSize;     // the Xcursor.size this run wrote, 0 = none
}

+ (instancetype)sharedPointerCursor
{
    static URSPointerCursor *shared = nil;
    if (shared == nil)
        shared = [[URSPointerCursor alloc] init];
    return shared;
}

- (void)startWithConnection:(XCBConnection *)connection
{
    xcb_connection_t *conn = [connection connection];
    XCBScreen *screen = [[connection screens] firstObject];

    if (conn == NULL || screen == nil)
        return;
    _connection = connection;
    _root = [screen screen]->root;
    _rootSize = UINT32_MAX;

    /* Our own event mask on the root is replaced as a whole: keep what the
     * window manager selected there and add the pointer. */
    xcb_get_window_attributes_reply_t *attributes = xcb_get_window_attributes_reply(
        conn, xcb_get_window_attributes(conn, _root), NULL);
    if (attributes == NULL)
        return;
    uint32_t mask = attributes->your_event_mask |
                    XCB_EVENT_MASK_POINTER_MOTION | XCB_EVENT_MASK_ENTER_WINDOW;
    free(attributes);
    xcb_change_window_attributes(conn, _root, XCB_CW_EVENT_MASK, &mask);

    [self outputScalesChanged];
}

- (void)outputScalesChanged
{
    xcb_connection_t *conn = [_connection connection];

    if (conn == NULL)
        return;
    xcb_query_pointer_reply_t *pointer = xcb_query_pointer_reply(
        conn, xcb_query_pointer(conn, _root), NULL);
    if (pointer != NULL) {
        _rootSize = UINT32_MAX;
        [self pointerAtRootX:pointer->root_x y:pointer->root_y];
        free(pointer);
    }
    [self publishCursorSize:[[URSOutputScales sharedScales] primaryCursorSize]];
    [_connection flush];
}

- (xcb_cursor_t)defaultArrow
{
    if (_defaultArrow != XCB_NONE)
        return _defaultArrow;

    xcb_cursor_context_t *context = NULL;
    XCBScreen *screen = [[_connection screens] firstObject];
    if (xcb_cursor_context_new([_connection connection], [screen screen], &context) < 0)
        return XCB_NONE;
    _defaultArrow = xcb_cursor_load_cursor(context, "left_ptr");
    xcb_cursor_context_free(context);
    return _defaultArrow;
}

- (void)pointerAtRootX:(int16_t)x y:(int16_t)y
{
    uint32_t size = [[URSOutputScales sharedScales] cursorSizeAtPoint:NSMakePoint(x, y)];

    if (size == _rootSize || _connection == nil)
        return;
    _rootSize = size;

    xcb_cursor_t cursor = size > 0
        ? [[URSCursorTheme sharedThemeWithConnection:[_connection connection] root:_root]
           cursorNamed:@"left_ptr" size:size]
        : [self defaultArrow];
    if (cursor == XCB_NONE)
        return;
    xcb_change_window_attributes([_connection connection], _root, XCB_CW_CURSOR, &cursor);
    [_connection flush];
}

- (void)publishCursorSize:(uint32_t)size
{
    xcb_connection_t *conn = [_connection connection];
    NSString *resources = @"";

    xcb_get_property_reply_t *reply = xcb_get_property_reply(conn,
        xcb_get_property(conn, 0, _root, XCB_ATOM_RESOURCE_MANAGER, XCB_ATOM_STRING, 0, 1 << 20),
        NULL);
    if (reply != NULL && xcb_get_property_value_length(reply) > 0)
        resources = [[NSString alloc] initWithBytes:xcb_get_property_value(reply)
                                             length:xcb_get_property_value_length(reply)
                                           encoding:NSUTF8StringEncoding];
    free(reply);
    if (resources == nil)
        return;
    /* Unscaled setups keep whatever the user has; only a size this window
     * manager published is taken back. */
    if (size == 0 && _publishedSize == 0)
        return;

    NSString *updated = URSResourcesWithCursorSize(resources, size);
    if ([updated isEqualToString:resources]) {
        _publishedSize = size;
        return;
    }
    _publishedSize = size;
    NSData *bytes = [updated dataUsingEncoding:NSUTF8StringEncoding];
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, _root, XCB_ATOM_RESOURCE_MANAGER,
                        XCB_ATOM_STRING, 8, (uint32_t)[bytes length], [bytes bytes]);
}

@end

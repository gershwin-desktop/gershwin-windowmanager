/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSheetController.h"
#import "URSSheetLayout.h"
#import "URSSheetSlideEffect.h"
#import "URSCompositingManager.h"
#import "XCBConnection.h"
#import "XCBWindow.h"
#import "XCBFrame.h"
#import "XCBScreen.h"

NSString * const URSSheetPropertyName = @"_GERSHWIN_SHEET";

@implementation URSSheetController
{
    XCBConnection *_connection;
    xcb_atom_t _sheetAtom;
    // Sheet window id -> the client window it is a sheet of.
    NSMutableDictionary<NSNumber *, NSNumber *> *_parents;
}

- (instancetype)initWithConnection:(XCBConnection *)connection
{
    self = [super init];
    if (self) {
        _connection = connection;
        _parents = [NSMutableDictionary dictionary];
        const char *name = [URSSheetPropertyName UTF8String];
        xcb_connection_t *c = [connection connection];
        xcb_intern_atom_reply_t *reply =
            xcb_intern_atom_reply(c, xcb_intern_atom(c, 0, strlen(name), name), NULL);
        _sheetAtom = reply ? reply->atom : XCB_NONE;
        free(reply);
        if (_sheetAtom == XCB_NONE) {
            NSLog(@"[Sheets] Cannot intern %@; sheets are shown as dialogs", URSSheetPropertyName);
        }
    }
    return self;
}

#pragma mark - Recognising a sheet

// The window it is a sheet of, or XCB_NONE: both the sheet mark and
// WM_TRANSIENT_FOR must be there, since the mark alone does not say whose
// sheet it is and WM_TRANSIENT_FOR alone is any dialog or child window.
- (xcb_window_t)parentOfSheet:(xcb_window_t)window
{
    if (_sheetAtom == XCB_NONE) {
        return XCB_NONE;
    }
    xcb_connection_t *c = [_connection connection];
    xcb_get_property_cookie_t markCookie =
        xcb_get_property(c, 0, window, _sheetAtom, XCB_ATOM_CARDINAL, 0, 1);
    xcb_get_property_cookie_t transientCookie =
        xcb_get_property(c, 0, window, XCB_ATOM_WM_TRANSIENT_FOR, XCB_ATOM_WINDOW, 0, 1);
    xcb_get_property_reply_t *mark = xcb_get_property_reply(c, markCookie, NULL);
    xcb_get_property_reply_t *transient = xcb_get_property_reply(c, transientCookie, NULL);

    xcb_window_t parent = XCB_NONE;
    if (mark && xcb_get_property_value_length(mark) >= 4 &&
        *(uint32_t *)xcb_get_property_value(mark) != 0 &&
        transient && xcb_get_property_value_length(transient) >= 4) {
        parent = *(xcb_window_t *)xcb_get_property_value(transient);
    }
    free(mark);
    free(transient);
    return parent;
}

- (XCBFrame *)frameOfClient:(xcb_window_t)client
{
    XCBWindow *window = [_connection windowForXCBId:client];
    XCBWindow *frame = [window parentWindow];
    return [frame isKindOfClass:[XCBFrame class]] ? (XCBFrame *)frame : nil;
}

#pragma mark - Placement

- (void)placeSheet:(xcb_window_t)sheet
{
    xcb_window_t parent = [_parents[@(sheet)] unsignedIntValue];
    XCBFrame *frame = [self frameOfClient:parent];
    XCBScreen *screen = [[_connection screens] firstObject];
    if (!frame || !screen) {
        return;
    }
    xcb_connection_t *c = [_connection connection];
    xcb_window_t root = [[screen rootWindow] window];

    // The client's own rect, not the frame's: the sheet hangs from where
    // the titlebar ends, whatever height the theme gives it.
    xcb_translate_coordinates_cookie_t originCookie =
        xcb_translate_coordinates(c, parent, root, 0, 0);
    xcb_get_geometry_cookie_t parentCookie = xcb_get_geometry(c, parent);
    xcb_get_geometry_cookie_t sheetCookie = xcb_get_geometry(c, sheet);
    xcb_translate_coordinates_reply_t *origin =
        xcb_translate_coordinates_reply(c, originCookie, NULL);
    xcb_get_geometry_reply_t *parentGeometry = xcb_get_geometry_reply(c, parentCookie, NULL);
    xcb_get_geometry_reply_t *sheetGeometry = xcb_get_geometry_reply(c, sheetCookie, NULL);

    if (origin && parentGeometry && sheetGeometry) {
        NSRect content = NSMakeRect(origin->dst_x, origin->dst_y,
                                    parentGeometry->width, parentGeometry->height);
        NSRect f = [URSSheetLayout frameForSheetSize:NSMakeSize(sheetGeometry->width,
                                                                sheetGeometry->height)
                                   parentContentRect:content
                                          screenRect:NSMakeRect(0, 0, [screen width],
                                                                [screen height])];
        uint32_t values[] = {
            (uint32_t)(int32_t)NSMinX(f), (uint32_t)(int32_t)NSMinY(f), 0,
            [frame window], XCB_STACK_MODE_ABOVE
        };
        xcb_configure_window(c, sheet,
                             XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y |
                             XCB_CONFIG_WINDOW_BORDER_WIDTH |
                             XCB_CONFIG_WINDOW_SIBLING | XCB_CONFIG_WINDOW_STACK_MODE,
                             values);
        [_connection flush];
    }
    free(origin);
    free(parentGeometry);
    free(sheetGeometry);
}

#pragma mark - Events

- (BOOL)handleMapRequest:(xcb_map_request_event_t *)event
{
    xcb_window_t parent = [self parentOfSheet:event->window];
    if (parent == XCB_NONE) {
        return NO;
    }
    if ([self frameOfClient:parent] == nil) {
        // Nothing to hang from (an undecorated or unknown parent).
        return NO;
    }
    XCBWindow *sheet = [_connection windowForXCBId:event->window];
    if ([[sheet parentWindow] isKindOfClass:[XCBFrame class]]) {
        // Still framed from being shown as an ordinary dialog before.
        return NO;
    }
    if (sheet == nil) {
        sheet = [[XCBWindow alloc] initWithXCBWindow:event->window andConnection:_connection];
        [sheet updateAttributes];
        [sheet setParentWindow:[[XCBWindow alloc] initWithXCBWindow:event->parent
                                                      andConnection:_connection]];
        [_connection registerWindow:sheet];
        // Like other undecorated windows: a click on it must give it the
        // focus back after the user clicked elsewhere.
        [sheet grabButton];
    }
    [sheet setDecorated:NO];
    [sheet updatePid];

    _parents[@(event->window)] = @(parent);
    [self placeSheet:event->window];
    [_connection mapWindow:sheet];
    [sheet setNormalState];
    [_connection flush];
    return YES;
}

- (BOOL)handleConfigureRequest:(xcb_configure_request_event_t *)event
{
    if (_parents[@(event->window)] == nil) {
        return NO;
    }
    uint16_t mask = 0;
    uint32_t values[2];
    int n = 0;
    if (event->value_mask & XCB_CONFIG_WINDOW_WIDTH) {
        mask |= XCB_CONFIG_WINDOW_WIDTH;
        values[n++] = event->width;
    }
    if (event->value_mask & XCB_CONFIG_WINDOW_HEIGHT) {
        mask |= XCB_CONFIG_WINDOW_HEIGHT;
        values[n++] = event->height;
    }
    if (mask != 0) {
        xcb_configure_window([_connection connection], event->window, mask, values);
    }
    // A sheet that grows stays centred under the titlebar.
    [self placeSheet:event->window];
    return YES;
}

- (void)windowMapped:(xcb_window_t)window
{
    if (_parents[@(window)] == nil || ![self.compositingManager compositingActive]) {
        return;
    }
    [self.compositingManager setKeepsContentAfterUnmap:YES forWindow:window];
    [self.compositingManager playEffect:[[URSSheetSlideEffect alloc] initAppearing:YES]
                               onWindow:window];
}

- (void)windowWillUnmap:(xcb_window_t)window
{
    if (_parents[@(window)] == nil) {
        return;
    }
    [_parents removeObjectForKey:@(window)];
    if ([self.compositingManager compositingActive]) {
        [self.compositingManager playEffect:[[URSSheetSlideEffect alloc] initAppearing:NO]
                                   onWindow:window];
    }
}

- (void)windowDestroyed:(xcb_window_t)window
{
    [_parents removeObjectForKey:@(window)];
    NSArray *orphans = [_parents allKeysForObject:@(window)];
    [_parents removeObjectsForKeys:orphans];
}

- (void)windowConfigured:(xcb_configure_notify_event_t *)event
{
    NSNumber *parent = _parents[@(event->window)];
    if (parent != nil) {
        // Something restacked the sheet away from its parent.
        XCBFrame *frame = [self frameOfClient:[parent unsignedIntValue]];
        if (frame && event->above_sibling != [frame window]) {
            [self placeSheet:event->window];
        }
        return;
    }
    for (NSNumber *sheet in [_parents allKeys]) {
        xcb_window_t client = [_parents[sheet] unsignedIntValue];
        XCBFrame *frame = [self frameOfClient:client];
        if (client == event->window || (frame && [frame window] == event->window)) {
            [self placeSheet:[sheet unsignedIntValue]];
        }
    }
}

@end

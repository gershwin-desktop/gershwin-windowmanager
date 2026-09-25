/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSScreenWindow.h"
#import "URSWindowSwitcher.h"
#import "URSWindowListFilter.h"
#import "XCBConnection.h"
#import "XCBScreen.h"
#import "XCBFrame.h"
#import "XCBTitleBar.h"

static xcb_atom_t URSScreenWindowAtomNamed(xcb_connection_t *conn, const char *name) {
    xcb_intern_atom_reply_t *reply =
        xcb_intern_atom_reply(conn, xcb_intern_atom(conn, 1, strlen(name), name), NULL);
    xcb_atom_t atom = reply ? reply->atom : XCB_NONE;
    free(reply);
    return atom;
}

@implementation URSScreenWindow

+ (NSArray *)windowsOnScreenOfConnection:(XCBConnection *)connection
                          windowSwitcher:(URSWindowSwitcher *)windowSwitcher {
    xcb_connection_t *conn = [connection connection];
    xcb_window_t root = [[[[connection screens] objectAtIndex:0] rootWindow] window];
    // The tree lists the root's children bottom to top, which is the order
    // their pictures are painted and overlap in.
    xcb_query_tree_reply_t *tree = xcb_query_tree_reply(conn, xcb_query_tree(conn, root), NULL);
    if (!tree) {
        NSLog(@"[ScreenWindow] ERROR: could not read the window tree");
        return @[];
    }
    xcb_window_t *children = xcb_query_tree_children(tree);
    int count = xcb_query_tree_children_length(tree);
    NSMutableArray *windows = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        id window = [connection windowForXCBId:children[i]];
        if (![window isKindOfClass:[XCBFrame class]]) {
            continue;
        }
        XCBFrame *frame = window;
        BOOL hasTitlebar = [[frame childWindowForKey:TitleBar] isKindOfClass:[XCBTitleBar class]];
        BOOL isUtilityPanel = [[frame childWindowForKey:ClientWindow] isUtilityPanel];
        if (![URSWindowListFilter includesFrameNeedingDestroy:frame.needDestroy
                                                   hasTitlebar:hasTitlebar
                                                isUtilityPanel:isUtilityPanel] ||
            [windowSwitcher isWindowMinimized:frame]) {
            continue;
        }
        xcb_get_geometry_reply_t *geometry =
            xcb_get_geometry_reply(conn, xcb_get_geometry(conn, children[i]), NULL);
        if (!geometry) {
            continue;
        }
        URSScreenWindow *screenWindow = [[self alloc] init];
        screenWindow.frame = frame;
        screenWindow.title = [windowSwitcher getTitleForFrame:frame];
        screenWindow.windowRect = NSMakeRect(geometry->x, geometry->y,
                                             geometry->width + 2 * geometry->border_width,
                                             geometry->height + 2 * geometry->border_width);
        free(geometry);
        [windows addObject:screenWindow];
    }
    free(tree);
    return windows;
}

+ (NSSet *)utilityPanelsOfConnection:(XCBConnection *)connection {
    NSMutableSet *panels = [NSMutableSet set];
    for (id window in [[connection windowsMap] allValues]) {
        if (![window isKindOfClass:[XCBFrame class]]) {
            continue;
        }
        XCBFrame *frame = window;
        BOOL hasTitlebar = [[frame childWindowForKey:TitleBar] isKindOfClass:[XCBTitleBar class]];
        BOOL isUtilityPanel = [[frame childWindowForKey:ClientWindow] isUtilityPanel];
        if ([URSWindowListFilter isManagedUtilityPanelNeedingDestroy:frame.needDestroy
                                                          hasTitlebar:hasTitlebar
                                                       isUtilityPanel:isUtilityPanel]) {
            [panels addObject:@([frame window])];
        }
    }
    return panels;
}

// Found by their type rather than by name so any panel of that kind gets
// out of the way.
+ (NSSet *)dockWindowsOfConnection:(XCBConnection *)connection {
    xcb_connection_t *conn = [connection connection];
    xcb_window_t root = [[[[connection screens] objectAtIndex:0] rootWindow] window];
    xcb_atom_t typeAtom = URSScreenWindowAtomNamed(conn, "_NET_WM_WINDOW_TYPE");
    xcb_atom_t dockAtom = URSScreenWindowAtomNamed(conn, "_NET_WM_WINDOW_TYPE_DOCK");
    NSMutableSet *docks = [NSMutableSet set];
    if (typeAtom == XCB_NONE || dockAtom == XCB_NONE) {
        return docks;
    }
    xcb_query_tree_reply_t *tree = xcb_query_tree_reply(conn, xcb_query_tree(conn, root), NULL);
    if (!tree) {
        return docks;
    }
    xcb_window_t *children = xcb_query_tree_children(tree);
    int count = xcb_query_tree_children_length(tree);
    xcb_get_property_cookie_t *cookies = malloc(sizeof(xcb_get_property_cookie_t) * MAX(count, 1));
    for (int i = 0; i < count; i++) {
        cookies[i] = xcb_get_property(conn, 0, children[i], typeAtom, XCB_ATOM_ATOM, 0, 16);
    }
    for (int i = 0; i < count; i++) {
        xcb_get_property_reply_t *reply = xcb_get_property_reply(conn, cookies[i], NULL);
        if (!reply) {
            continue;
        }
        xcb_atom_t *types = xcb_get_property_value(reply);
        int typeCount = xcb_get_property_value_length(reply) / (int)sizeof(xcb_atom_t);
        for (int j = 0; j < typeCount; j++) {
            if (types[j] == dockAtom) {
                [docks addObject:@(children[i])];
                break;
            }
        }
        free(reply);
    }
    free(cookies);
    free(tree);
    return docks;
}

@end

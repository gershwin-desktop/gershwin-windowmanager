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

@end

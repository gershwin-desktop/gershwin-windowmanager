/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSLiveMiniatureController.h"
#import "URSCompositingManager.h"
#import "URSFocusManager.h"
#import "XCBConnection.h"
#import "XCBFrame.h"
#import "XCBWindow.h"
#import "XCBAtomService.h"
#import "EWMHService.h"
#import <xcb/shape.h>

static NSString * const URSLiveMiniatureAtomName = @"_WINDOW_LIVE_MINIATURE";
static NSString * const URSLiveMiniaturesAtomName = @"_WINDOW_LIVE_MINIATURES";

// One window being minimized or shown as a live miniature.
@interface URSLiveMiniature : NSObject
@property (strong, nonatomic) XCBFrame *frame;
@property (assign, nonatomic) xcb_window_t client;
@property (assign, nonatomic) BOOL live;
// The Dock window the tile belongs to (0 until the Dock answers).
@property (assign, nonatomic) xcb_window_t dock;
@end

@implementation URSLiveMiniature
@end

@interface URSLiveMiniatureController ()
@property (weak, nonatomic) XCBConnection *connection;
@property (assign, nonatomic) xcb_atom_t miniatureAtom;
@property (assign, nonatomic) xcb_atom_t miniaturesAtom;
@property (assign, nonatomic) xcb_atom_t iconGeometryAtom;
// In the order they were minimized, which is the order of the root list.
@property (strong, nonatomic) NSMutableArray<URSLiveMiniature *> *miniatures;
@end

@implementation URSLiveMiniatureController

- (instancetype)initWithConnection:(XCBConnection *)connection {
    self = [super init];
    if (self) {
        _connection = connection;
        _miniatures = [NSMutableArray array];
        XCBAtomService *atoms = [XCBAtomService sharedInstanceWithConnection:connection];
        _miniatureAtom = [atoms cacheAtom:URSLiveMiniatureAtomName];
        _miniaturesAtom = [atoms cacheAtom:URSLiveMiniaturesAtomName];
        EWMHService *ewmh = [EWMHService sharedInstanceWithConnection:connection];
        _iconGeometryAtom = [atoms cacheAtom:[ewmh EWMHWMIconGeometry]];
        // A list left behind by an earlier window manager names windows that
        // are no live miniatures any more.
        [self publishList];
    }
    return self;
}

#pragma mark - Bookkeeping

- (URSLiveMiniature *)miniatureForWindow:(xcb_window_t)window {
    for (URSLiveMiniature *m in self.miniatures) {
        if (m.client == window || [m.frame window] == window) {
            return m;
        }
    }
    return nil;
}

- (URSLiveMiniature *)miniatureForFrame:(XCBFrame *)frame {
    return frame ? [self miniatureForWindow:[frame window]] : nil;
}

- (BOOL)isLiveMiniature:(XCBFrame *)frame {
    return [[self miniatureForFrame:frame] live];
}

- (xcb_window_t)rootWindow {
    return [[self.connection rootWindowForScreenNumber:0] window];
}

- (void)publishList {
    xcb_connection_t *conn = [self.connection connection];
    NSUInteger count = [self.miniatures count];
    xcb_window_t ids[count > 0 ? count : 1];
    for (NSUInteger i = 0; i < count; i++) {
        ids[i] = self.miniatures[i].client;
    }
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, [self rootWindow], self.miniaturesAtom,
                        XCB_ATOM_WINDOW, 32, (uint32_t)count, ids);
    [self.connection flush];
}

- (void)forget:(URSLiveMiniature *)m {
    // The Dock's answer must not outlive the request: a later minimize
    // would take it for a tile made for that one.
    xcb_delete_property([self.connection connection], m.client, self.miniatureAtom);
    [self.miniatures removeObject:m];
    [self publishList];
}

- (BOOL)readCardinals:(uint32_t *)values
                count:(uint32_t)count
                 type:(xcb_atom_t)type
             property:(xcb_atom_t)property
               window:(xcb_window_t)window {
    xcb_connection_t *conn = [self.connection connection];
    xcb_get_property_reply_t *reply =
        xcb_get_property_reply(conn, xcb_get_property(conn, 0, window, property, type, 0, count), NULL);
    if (!reply) {
        return NO;
    }
    BOOL ok = reply->type == type && reply->format == 32
        && (uint32_t)xcb_get_property_value_length(reply) >= count * 4;
    if (ok) {
        memcpy(values, xcb_get_property_value(reply), count * 4);
    }
    free(reply);
    return ok;
}

// The Dock window that made a tile for the client, or 0.
- (xcb_window_t)dockAnswerFor:(xcb_window_t)client {
    uint32_t dock = 0;
    if (![self readCardinals:&dock count:1 type:XCB_ATOM_WINDOW
                    property:self.miniatureAtom window:client]) {
        return 0;
    }
    return dock;
}

- (BOOL)tileFor:(xcb_window_t)client rect:(XCBRect *)rect {
    uint32_t v[4];
    if (![self readCardinals:v count:4 type:XCB_ATOM_CARDINAL
                    property:self.iconGeometryAtom window:client]
        || v[2] == 0 || v[3] == 0) {
        return NO;
    }
    *rect = XCBMakeRect(XCBMakePoint((int)v[0], (int)v[1]),
                        XCBMakeSize((uint16_t)v[2], (uint16_t)v[3]));
    return YES;
}

- (void)setInputPassesThrough:(BOOL)passesThrough frame:(XCBFrame *)frame {
    xcb_connection_t *conn = [self.connection connection];
    if (passesThrough) {
        xcb_shape_rectangles(conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_INPUT,
                             XCB_CLIP_ORDERING_UNSORTED, [frame window], 0, 0, 0, NULL);
    } else {
        xcb_shape_mask(conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_INPUT, [frame window], 0, 0, XCB_NONE);
    }
}

#pragma mark - Minimize and restore

- (void)minimizeWillStartForFrame:(XCBFrame *)frame client:(XCBWindow *)client {
    if (!frame || !client || ![self.compositingManager compositingActive]) {
        return;
    }
    URSLiveMiniature *m = [self miniatureForFrame:frame];
    if (m) {
        [self forget:m];
    }
    m = [URSLiveMiniature new];
    m.frame = frame;
    m.client = [client window];
    xcb_delete_property([self.connection connection], m.client, self.miniatureAtom);
    [self.miniatures addObject:m];
    [self publishList];
}

- (BOOL)minimizeDidEndForFrame:(XCBFrame *)frame client:(XCBWindow *)client {
    URSLiveMiniature *m = [self miniatureForFrame:frame];
    if (!m) {
        return NO;
    }
    xcb_window_t dock = [self dockAnswerFor:m.client];
    XCBRect tile;
    if (dock == 0 || ![self tileFor:m.client rect:&tile]
        || ![self.compositingManager compositingActive]) {
        [self forget:m];
        return NO;
    }

    m.live = YES;
    m.dock = dock;
    [frame setIconicState];
    [frame setIsMinimized:YES];
    [client setIconicState];
    [client setIsMinimized:YES];
    [self setInputPassesThrough:YES frame:frame];
    [self.compositingManager showLiveMiniatureOfWindow:[frame window] inTile:tile aboveWindow:dock];
    [self.connection flush];
    // An unmapped window hands focus on through UnmapNotify; this one stays
    // mapped, so it has to be handed on here.
    [self.focusManager ensureFocusAfterWindowRemoval:m.client];
    return YES;
}

- (void)restoreFrame:(XCBFrame *)frame {
    URSLiveMiniature *m = [self miniatureForFrame:frame];
    if (!m) {
        return;
    }
    if (m.live) {
        [self setInputPassesThrough:NO frame:frame];
        [self.compositingManager hideLiveMiniatureOfWindow:[frame window]];
    }
    [self forget:m];
}

// The window keeps being minimized, the ordinary way: its Dock is gone.
- (void)fallBackToUnmapped:(URSLiveMiniature *)m {
    XCBFrame *frame = m.frame;
    [self setInputPassesThrough:NO frame:frame];
    [self.compositingManager hideLiveMiniatureOfWindow:[frame window]];
    XCBWindow *titleBar = [frame childWindowForKey:TitleBar];
    XCBWindow *client = [frame childWindowForKey:ClientWindow];
    [self.connection unmapWindow:frame];
    if (titleBar) {
        [self.connection unmapWindow:titleBar];
    }
    if (client) {
        [self.connection unmapWindow:client];
    }
    [self forget:m];
}

#pragma mark - Events

- (void)propertyChanged:(xcb_atom_t)atom ofWindow:(xcb_window_t)window {
    if (atom != self.miniatureAtom && atom != self.iconGeometryAtom) {
        return;
    }
    URSLiveMiniature *m = [self miniatureForWindow:window];
    if (!m || window != m.client) {
        return;
    }
    xcb_window_t dock = [self dockAnswerFor:m.client];
    XCBRect tile;
    if (dock == 0 || ![self tileFor:m.client rect:&tile]) {
        return;
    }
    if (m.live) {
        m.dock = dock;
        [self.compositingManager showLiveMiniatureOfWindow:[m.frame window] inTile:tile aboveWindow:dock];
    } else {
        // The tile was made while the window flies: it lands there, and
        // the miniature takes over without a fade.
        [self.compositingManager retargetMinimizeOfWindow:[m.frame window] toTile:tile fading:NO];
    }
}

- (void)windowDestroyed:(xcb_window_t)window {
    for (URSLiveMiniature *m in [self.miniatures copy]) {
        if (m.live && m.dock == window) {
            [self fallBackToUnmapped:m];
        }
    }
    [self windowUnmapped:window];
}

// The window is withdrawn or gone; its properties may be gone with it, so
// they are left alone.
- (void)windowUnmapped:(xcb_window_t)window {
    URSLiveMiniature *m = [self miniatureForWindow:window];
    if (m) {
        if (m.live) {
            [self.compositingManager hideLiveMiniatureOfWindow:[m.frame window]];
        }
        [self.miniatures removeObject:m];
        [self publishList];
    }
}

@end

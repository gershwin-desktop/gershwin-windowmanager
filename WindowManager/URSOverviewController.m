/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSOverviewController.h"
#import "URSOverviewLayout.h"
#import "URSOverviewTitleLabel.h"
#import "URSCompositingManager.h"
#import "URSFocusManager.h"
#import "URSWindowSwitcher.h"
#import "XCBConnection.h"
#import "XCBScreen.h"
#import "XCBFrame.h"
#import "XCBTitleBar.h"
#import <X11/Xlib.h>
#import <X11/keysym.h>

NSString * const URSOverviewEnabledKey = @"URSOverviewEnabled";
NSString * const URSOverviewKeyKey = @"URSOverviewKey";
NSString * const URSOverviewHotCornerKey = @"URSOverviewHotCorner";

static const NSTimeInterval URSOverviewTransitionDuration = 0.3;
static const double URSOverviewBackdropDimming = 0.5;
static const NSTimeInterval URSHotCornerPollInterval = 0.1;
// The pointer must leave the corner by this much before it can fire again,
// or resting against it would open and close the overview in turn.
static const int16_t URSHotCornerRearmDistance = 8;

static const uint16_t URSLockMasks[] = {
    0, XCB_MOD_MASK_LOCK, XCB_MOD_MASK_2, XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2
};

// Ease in and out, so windows neither jump off nor slam into place.
static double URSOverviewEase(double t) {
    return t < 0.5 ? 4.0 * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5;
}

static NSRect URSInterpolateRect(NSRect from, NSRect to, double p) {
    return NSMakeRect(NSMinX(from) + (NSMinX(to) - NSMinX(from)) * p,
                      NSMinY(from) + (NSMinY(to) - NSMinY(from)) * p,
                      NSWidth(from) + (NSWidth(to) - NSWidth(from)) * p,
                      NSHeight(from) + (NSHeight(to) - NSHeight(from)) * p);
}

@interface URSOverviewItem : NSObject
@property (strong, nonatomic) XCBFrame *frame;
@property (copy, nonatomic) NSString *title;
@property (assign, nonatomic) NSRect windowRect;
@property (assign, nonatomic) NSRect slot;
@end

@implementation URSOverviewItem
@end

@interface URSOverviewController ()
@property (weak, nonatomic) XCBConnection *connection;
@property (weak, nonatomic) URSFocusManager *focusManager;
@property (weak, nonatomic) URSWindowSwitcher *windowSwitcher;
@property (assign, nonatomic) xcb_window_t root;
@property (assign, nonatomic) xcb_keycode_t toggleKeycode;
@property (strong, nonatomic) NSDictionary *keysymsByKeycode;
@property (strong, nonatomic) NSTimer *hotCornerTimer;
@property (copy, nonatomic) NSString *hotCorner;
@property (assign, nonatomic) BOOL hotCornerArmed;
// Items by frame id while the overview is open or closing, else nil.
@property (strong, nonatomic) NSDictionary *items;
// Menu bar, Dock and other dock-type windows, faded out while it is open.
@property (strong, nonatomic) NSSet *dockWindows;
@property (strong, nonatomic) URSOverviewItem *selectedItem;
@property (assign, nonatomic) BOOL open;
@property (assign, nonatomic) double fromProgress;
@property (assign, nonatomic) double toProgress;
@property (assign, nonatomic) NSTimeInterval transitionStart;
@property (strong, nonatomic) NSTimer *transitionTimer;
@property (strong, nonatomic) URSOverviewTitleLabel *titleLabel;
@end

@implementation URSOverviewController

+ (void)initialize {
    if (self == [URSOverviewController class]) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            URSOverviewEnabledKey: @YES,
            URSOverviewKeyKey: @"F9",
            URSOverviewHotCornerKey: @"none"
        }];
    }
}

- (instancetype)initWithConnection:(XCBConnection *)connection
                      focusManager:(URSFocusManager *)focusManager
                    windowSwitcher:(URSWindowSwitcher *)windowSwitcher {
    self = [super init];
    if (self) {
        _connection = connection;
        _focusManager = focusManager;
        _windowSwitcher = windowSwitcher;
        _root = [[[[connection screens] objectAtIndex:0] rootWindow] window];
        _hotCornerArmed = YES;
    }
    return self;
}

#pragma mark - Setup

- (void)setUp {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Without compositing there is nothing to show the windows with, and a
    // grabbed key would only be taken away from the applications.
    if (![defaults boolForKey:URSOverviewEnabledKey] ||
        ![self.compositingManager compositingActive]) {
        return;
    }
    [self readKeyboardMapping];
    [self grabToggleKey:[defaults stringForKey:URSOverviewKeyKey]];

    self.hotCorner = [defaults stringForKey:URSOverviewHotCornerKey];
    NSArray *corners = @[@"top-left", @"top-right", @"bottom-left", @"bottom-right"];
    if ([corners containsObject:self.hotCorner]) {
        // Polled rather than watched through small windows in the corners:
        // those would have to be kept above every window raised later.
        self.hotCornerTimer = [NSTimer scheduledTimerWithTimeInterval:URSHotCornerPollInterval
                                                               target:self
                                                             selector:@selector(checkHotCorner:)
                                                             userInfo:nil
                                                              repeats:YES];
    } else if (![self.hotCorner isEqualToString:@"none"]) {
        NSLog(@"[Overview] ERROR: %@ is %@, expected none, %@",
              URSOverviewHotCornerKey, self.hotCorner, [corners componentsJoinedByString:@", "]);
    }
}

- (void)tearDown {
    [self.hotCornerTimer invalidate];
    self.hotCornerTimer = nil;
    if (self.toggleKeycode != 0) {
        xcb_connection_t *conn = [self.connection connection];
        for (size_t i = 0; i < sizeof(URSLockMasks) / sizeof(URSLockMasks[0]); i++) {
            xcb_ungrab_key(conn, self.toggleKeycode, self.root, URSLockMasks[i]);
        }
        self.toggleKeycode = 0;
    }
}

- (void)readKeyboardMapping {
    xcb_connection_t *conn = [self.connection connection];
    const xcb_setup_t *setup = xcb_get_setup(conn);
    xcb_get_keyboard_mapping_reply_t *reply = xcb_get_keyboard_mapping_reply(conn,
        xcb_get_keyboard_mapping(conn, setup->min_keycode,
                                 setup->max_keycode - setup->min_keycode + 1), NULL);
    if (!reply) {
        NSLog(@"[Overview] ERROR: could not read the keyboard mapping");
        return;
    }
    xcb_keysym_t *keysyms = xcb_get_keyboard_mapping_keysyms(reply);
    int length = xcb_get_keyboard_mapping_keysyms_length(reply);
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (int i = 0; i < length; i += reply->keysyms_per_keycode) {
        if (keysyms[i] != XCB_NO_SYMBOL) {
            map[@(setup->min_keycode + i / reply->keysyms_per_keycode)] = @(keysyms[i]);
        }
    }
    free(reply);
    self.keysymsByKeycode = map;
}

- (void)grabToggleKey:(NSString *)keyName {
    KeySym keysym = XStringToKeysym([keyName UTF8String]);
    if (keysym == NoSymbol) {
        NSLog(@"[Overview] ERROR: %@ is %@, which is no X key name", URSOverviewKeyKey, keyName);
        return;
    }
    for (NSNumber *keycode in self.keysymsByKeycode) {
        if ([self.keysymsByKeycode[keycode] unsignedLongValue] == keysym) {
            self.toggleKeycode = [keycode unsignedCharValue];
            break;
        }
    }
    if (self.toggleKeycode == 0) {
        NSLog(@"[Overview] ERROR: no key on this keyboard sends %@", keyName);
        return;
    }
    xcb_connection_t *conn = [self.connection connection];
    for (size_t i = 0; i < sizeof(URSLockMasks) / sizeof(URSLockMasks[0]); i++) {
        xcb_grab_key(conn, 0, self.root, URSLockMasks[i], self.toggleKeycode,
                     XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC);
    }
    [self.connection flush];
}

#pragma mark - Hot corner

- (void)checkHotCorner:(NSTimer *)timer {
    xcb_connection_t *conn = [self.connection connection];
    xcb_query_pointer_reply_t *pointer =
        xcb_query_pointer_reply(conn, xcb_query_pointer(conn, self.root), NULL);
    if (!pointer) {
        return;
    }
    XCBScreen *screen = [[self.connection screens] objectAtIndex:0];
    int16_t maxX = [screen width] - 1;
    int16_t maxY = [screen height] - 1;
    int16_t cornerX = [self.hotCorner hasSuffix:@"left"] ? 0 : maxX;
    int16_t cornerY = [self.hotCorner hasPrefix:@"top"] ? 0 : maxY;
    int dx = abs(pointer->root_x - cornerX);
    int dy = abs(pointer->root_y - cornerY);
    // A drag into the corner (a window, a file) is not a request for the
    // overview.
    BOOL buttonDown = (pointer->mask & (XCB_BUTTON_MASK_1 | XCB_BUTTON_MASK_2 | XCB_BUTTON_MASK_3)) != 0;
    free(pointer);

    if (dx == 0 && dy == 0 && self.hotCornerArmed && !buttonDown) {
        self.hotCornerArmed = NO;
        [self toggle];
    } else if (dx > URSHotCornerRearmDistance || dy > URSHotCornerRearmDistance) {
        self.hotCornerArmed = YES;
    }
}

#pragma mark - Opening and closing

- (void)toggle {
    if (self.open) {
        [self closeActivating:nil];
    } else {
        [self openOverview];
    }
}

// The windows the overview shows: the managed ones on the screen.
- (NSArray *)collectItems {
    xcb_connection_t *conn = [self.connection connection];
    NSMutableArray *items = [NSMutableArray array];
    for (id window in [[self.connection windowsMap] allValues]) {
        if (![window isKindOfClass:[XCBFrame class]]) {
            continue;
        }
        XCBFrame *frame = window;
        if (frame.needDestroy ||
            ![[frame childWindowForKey:TitleBar] isKindOfClass:[XCBTitleBar class]] ||
            [self.windowSwitcher isWindowMinimized:frame]) {
            continue;
        }
        xcb_get_geometry_reply_t *geometry =
            xcb_get_geometry_reply(conn, xcb_get_geometry(conn, [frame window]), NULL);
        if (!geometry) {
            continue;
        }
        URSOverviewItem *item = [[URSOverviewItem alloc] init];
        item.frame = frame;
        item.title = [self.windowSwitcher getTitleForFrame:frame];
        item.windowRect = NSMakeRect(geometry->x, geometry->y,
                                     geometry->width + 2 * geometry->border_width,
                                     geometry->height + 2 * geometry->border_width);
        free(geometry);
        [items addObject:item];
    }
    return items;
}

// The Menu bar and the Dock fade out, so the whole screen is free.
- (xcb_atom_t)atomNamed:(const char *)name {
    xcb_connection_t *conn = [self.connection connection];
    xcb_intern_atom_reply_t *reply =
        xcb_intern_atom_reply(conn, xcb_intern_atom(conn, 1, strlen(name), name), NULL);
    xcb_atom_t atom = reply ? reply->atom : XCB_NONE;
    free(reply);
    return atom;
}

// Top-level windows typed _NET_WM_WINDOW_TYPE_DOCK: the Menu bar and the
// Dock both are.  Found by their type rather than by name so any panel of
// that kind gets out of the way.
- (NSSet *)collectDockWindows {
    xcb_connection_t *conn = [self.connection connection];
    xcb_atom_t typeAtom = [self atomNamed:"_NET_WM_WINDOW_TYPE"];
    xcb_atom_t dockAtom = [self atomNamed:"_NET_WM_WINDOW_TYPE_DOCK"];
    NSMutableSet *docks = [NSMutableSet set];
    if (typeAtom == XCB_NONE || dockAtom == XCB_NONE) {
        return docks;
    }
    xcb_query_tree_reply_t *tree = xcb_query_tree_reply(conn, xcb_query_tree(conn, self.root), NULL);
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

- (void)layOutItems:(NSArray *)items {
    XCBScreen *screen = [[self.connection screens] objectAtIndex:0];
    NSRect area = NSMakeRect(0, 0, [screen width], [screen height]);
    // Room around the windows scales with the screen, like the windows do.
    CGFloat shortSide = MIN(NSWidth(area), NSHeight(area));
    CGFloat margin = round(shortSide * 0.04);
    CGFloat spacing = round(shortSide * 0.025);
    NSMutableArray *rects = [NSMutableArray array];
    for (URSOverviewItem *item in items) {
        [rects addObject:[NSValue valueWithRect:item.windowRect]];
    }
    NSArray *slots = [URSOverviewLayout slotsForWindowRects:rects
                                                     inArea:NSInsetRect(area, margin, margin)
                                                    spacing:spacing];
    for (NSUInteger i = 0; i < [items count]; i++) {
        [[items objectAtIndex:i] setSlot:[[slots objectAtIndex:i] rectValue]];
    }
}

- (BOOL)grabInput {
    xcb_connection_t *conn = [self.connection connection];
    xcb_grab_pointer_reply_t *pointer = xcb_grab_pointer_reply(conn,
        xcb_grab_pointer(conn, 0, self.root,
                         XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE |
                         XCB_EVENT_MASK_POINTER_MOTION,
                         XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC,
                         XCB_NONE, XCB_NONE, XCB_CURRENT_TIME), NULL);
    BOOL pointerGrabbed = pointer && pointer->status == XCB_GRAB_STATUS_SUCCESS;
    free(pointer);
    xcb_grab_keyboard_reply_t *keyboard = xcb_grab_keyboard_reply(conn,
        xcb_grab_keyboard(conn, 0, self.root, XCB_CURRENT_TIME,
                          XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC), NULL);
    BOOL keyboardGrabbed = keyboard && keyboard->status == XCB_GRAB_STATUS_SUCCESS;
    free(keyboard);
    if (pointerGrabbed && keyboardGrabbed) {
        return YES;
    }
    // Another client holds a grab (a menu is open, a drag is running); the
    // overview must not open half deaf.
    NSLog(@"[Overview] Not opening: grabbing the pointer %@, the keyboard %@",
          pointerGrabbed ? @"worked" : @"failed", keyboardGrabbed ? @"worked" : @"failed");
    [self releaseInput];
    return NO;
}

- (void)releaseInput {
    xcb_connection_t *conn = [self.connection connection];
    xcb_ungrab_pointer(conn, XCB_CURRENT_TIME);
    xcb_ungrab_keyboard(conn, XCB_CURRENT_TIME);
    [self.connection flush];
}

- (void)openOverview {
    if (![self.compositingManager compositingActive]) {
        NSLog(@"[Overview] Not opening: it needs compositing");
        return;
    }
    // Still closing: turn around from where the windows are.
    if (self.items) {
        if (![self grabInput]) {
            return;
        }
        self.open = YES;
        [self startTransitionTo:1.0];
        return;
    }

    NSArray *items = [self collectItems];
    if ([items count] == 0 || ![self grabInput]) {
        return;
    }
    [self layOutItems:items];
    NSMutableDictionary *byFrame = [NSMutableDictionary dictionary];
    for (URSOverviewItem *item in items) {
        byFrame[@([item.frame window])] = item;
    }
    self.items = byFrame;
    self.dockWindows = [self collectDockWindows];
    self.selectedItem = nil;
    self.open = YES;
    self.fromProgress = 0.0;
    self.toProgress = 0.0;
    [self.compositingManager setPresentation:self];
    [self startTransitionTo:1.0];
}

// frame nil closes without picking a window.
- (void)closeActivating:(XCBFrame *)frame {
    if (!self.open) {
        return;
    }
    self.open = NO;
    [self releaseInput];
    [self.titleLabel hide];
    // The window may have closed while the overview was open.
    if (frame && [self.connection windowForXCBId:[frame window]] != frame) {
        frame = nil;
    }
    if (frame) {
        // Raised before the windows fly back, so the picked one lands on top.
        [self.focusManager activateFrame:frame];
    }
    [self startTransitionTo:0.0];
}

- (double)progress {
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.transitionStart;
    double t = MIN(1.0, MAX(0.0, elapsed / URSOverviewTransitionDuration));
    return self.fromProgress + (self.toProgress - self.fromProgress) * URSOverviewEase(t);
}

- (void)startTransitionTo:(double)target {
    self.fromProgress = [self progress];
    self.toProgress = target;
    self.transitionStart = [NSDate timeIntervalSinceReferenceDate];
    [self.transitionTimer invalidate];
    self.transitionTimer = [NSTimer scheduledTimerWithTimeInterval:URSOverviewTransitionDuration
                                                            target:self
                                                          selector:@selector(transitionEnded:)
                                                          userInfo:nil
                                                           repeats:NO];
    [self.compositingManager presentationChanged];
}

- (void)transitionEnded:(NSTimer *)timer {
    self.transitionTimer = nil;
    if (self.toProgress > 0.0) {
        [self.compositingManager presentationChanged];
        return;
    }
    self.items = nil;
    self.dockWindows = nil;
    self.selectedItem = nil;
    [self.compositingManager setPresentation:nil];
}

#pragma mark - URSWindowPresentation

- (BOOL)getPaintRect:(NSRect *)paintRect
           forWindow:(xcb_window_t)windowId
          windowRect:(NSRect)windowRect {
    URSOverviewItem *item = self.items[@(windowId)];
    if (!item) {
        return NO;
    }
    *paintRect = URSInterpolateRect(windowRect, item.slot, [self progress]);
    return YES;
}

- (double)opacityForWindow:(xcb_window_t)windowId {
    return [self.dockWindows containsObject:@(windowId)] ? 1.0 - [self progress] : 1.0;
}

- (double)backdropDimming {
    return URSOverviewBackdropDimming * [self progress];
}

- (BOOL)isAnimating {
    return [NSDate timeIntervalSinceReferenceDate] - self.transitionStart
           < URSOverviewTransitionDuration;
}

#pragma mark - Selection

- (URSOverviewItem *)itemAtX:(int16_t)x y:(int16_t)y {
    for (URSOverviewItem *item in [self.items allValues]) {
        if (NSPointInRect(NSMakePoint(x, y), item.slot)) {
            return item;
        }
    }
    return nil;
}

- (void)select:(URSOverviewItem *)item {
    if (item == self.selectedItem) {
        return;
    }
    self.selectedItem = item;
    if (!item) {
        [self.titleLabel hide];
        return;
    }
    if (!self.titleLabel) {
        self.titleLabel = [[URSOverviewTitleLabel alloc] init];
    }
    [self.titleLabel showTitle:item.title centeredOnBottomOfSlot:item.slot];
}

// The nearest window in the arrow's direction; sideways distance counts
// double so the move stays in its row or column.
- (URSOverviewItem *)itemFrom:(URSOverviewItem *)from inDirection:(xcb_keysym_t)arrow {
    NSPoint origin = NSMakePoint(NSMidX(from.slot), NSMidY(from.slot));
    URSOverviewItem *best = nil;
    double bestScore = INFINITY;
    for (URSOverviewItem *item in [self.items allValues]) {
        double dx = NSMidX(item.slot) - origin.x;
        double dy = NSMidY(item.slot) - origin.y;
        double ahead, aside;
        switch (arrow) {
            case XK_Left:  ahead = -dx; aside = dy; break;
            case XK_Right: ahead = dx;  aside = dy; break;
            case XK_Up:    ahead = -dy; aside = dx; break;
            default:       ahead = dy;  aside = dx; break;
        }
        if (ahead <= 0) {
            continue;
        }
        double score = ahead + 2.0 * fabs(aside);
        if (score < bestScore) {
            bestScore = score;
            best = item;
        }
    }
    return best;
}

- (void)moveSelection:(xcb_keysym_t)arrow {
    if (!self.selectedItem) {
        // Start from the window in front, where the eye was.
        URSOverviewItem *front = self.items[@(self.focusManager.lastFocusedWindowId)];
        if (!front) {
            for (URSOverviewItem *item in [self.items allValues]) {
                if ([[item.frame childWindowForKey:ClientWindow] window]
                    == self.focusManager.lastFocusedWindowId) {
                    front = item;
                    break;
                }
            }
        }
        [self select:front ?: [[self.items allValues] firstObject]];
        return;
    }
    URSOverviewItem *next = [self itemFrom:self.selectedItem inDirection:arrow];
    if (next) {
        [self select:next];
    }
}

#pragma mark - Input

- (BOOL)handleKeyPress:(xcb_key_press_event_t *)event {
    if (event->detail == self.toggleKeycode && self.toggleKeycode != 0) {
        [self toggle];
        return YES;
    }
    if (!self.open) {
        return NO;
    }
    xcb_keysym_t keysym = [self.keysymsByKeycode[@(event->detail)] unsignedIntValue];
    switch (keysym) {
        case XK_Escape:
            [self closeActivating:nil];
            break;
        case XK_Return:
        case XK_KP_Enter:
        case XK_space:
            [self closeActivating:self.selectedItem.frame];
            break;
        case XK_Left:
        case XK_Right:
        case XK_Up:
        case XK_Down:
            [self moveSelection:keysym];
            break;
        default:
            break;
    }
    return YES;
}

- (BOOL)handleKeyRelease:(xcb_key_release_event_t *)event {
    return self.open || event->detail == self.toggleKeycode;
}

- (BOOL)handleButtonPress:(xcb_button_press_event_t *)event {
    return self.open;
}

- (BOOL)handleButtonRelease:(xcb_button_release_event_t *)event {
    if (!self.open) {
        return NO;
    }
    if (event->detail == XCB_BUTTON_INDEX_1) {
        // A click beside every window closes the overview and changes nothing.
        [self closeActivating:[self itemAtX:event->root_x y:event->root_y].frame];
    }
    return YES;
}

- (BOOL)handleMotion:(xcb_motion_notify_event_t *)event {
    if (!self.open) {
        return NO;
    }
    [self select:[self itemAtX:event->root_x y:event->root_y]];
    return YES;
}

@end

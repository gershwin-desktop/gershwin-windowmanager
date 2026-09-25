/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSOverviewController.h"
#import "URSOverviewLayout.h"
#import "URSOverviewTitleLabel.h"
#import "URSGlobalKey.h"
#import "URSHotCorner.h"
#import "URSPresentationTransition.h"
#import "URSScreenWindow.h"
#import "URSCompositingManager.h"
#import "URSFocusManager.h"
#import "URSWindowSwitcher.h"
#import "XCBConnection.h"
#import "XCBScreen.h"
#import "XCBFrame.h"
#import <X11/keysym.h>

NSString * const URSOverviewEnabledKey = @"URSOverviewEnabled";
NSString * const URSOverviewKeyKey = @"URSOverviewKey";
NSString * const URSOverviewHotCornerKey = @"URSOverviewHotCorner";

static const NSTimeInterval URSOverviewTransitionDuration = 0.3;
static const double URSOverviewBackdropDimming = 0.5;

@interface URSOverviewItem : URSScreenWindow
@property (assign, nonatomic) NSRect slot;
@end

@implementation URSOverviewItem
@end

@interface URSOverviewController ()
@property (weak, nonatomic) XCBConnection *connection;
@property (weak, nonatomic) URSFocusManager *focusManager;
@property (weak, nonatomic) URSWindowSwitcher *windowSwitcher;
@property (assign, nonatomic) xcb_window_t root;
@property (strong, nonatomic) URSGlobalKey *toggleKey;
@property (strong, nonatomic) URSHotCorner *hotCorner;
// Items by frame id while the overview is open or closing, else nil.
@property (strong, nonatomic) NSDictionary *items;
// Menu bar, Dock and other dock-type windows, faded out while it is open.
@property (strong, nonatomic) NSSet *dockWindows;
// Utility panels (palettes) excluded from the grid, faded out the same way
// as the dock windows so they do not clutter the overview; restored the
// instant it closes, since they are never part of self.items and so never
// get relaid out or moved.
@property (strong, nonatomic) NSSet *utilityPanelWindows;
@property (strong, nonatomic) URSOverviewItem *selectedItem;
@property (assign, nonatomic) BOOL open;
@property (strong, nonatomic) URSPresentationTransition *transition;
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
        _transition = [[URSPresentationTransition alloc] initWithDuration:URSOverviewTransitionDuration
                                                                    target:self
                                                              closedAction:@selector(transitionClosed:)];
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
    self.transition.compositingManager = self.compositingManager;
    self.toggleKey = [[URSGlobalKey alloc] initWithConnection:self.connection];
    [self.toggleKey grabKeyNamed:[defaults stringForKey:URSOverviewKeyKey]
                         setting:URSOverviewKeyKey];
    self.hotCorner = [[URSHotCorner alloc] initWithConnection:self.connection
                                                   cornerName:[defaults stringForKey:URSOverviewHotCornerKey]
                                                      setting:URSOverviewHotCornerKey
                                                       target:self
                                                       action:@selector(hotCornerHit:)];
    [self.hotCorner start];
}

- (void)tearDown {
    [self.hotCorner stop];
    self.hotCorner = nil;
    [self.toggleKey ungrab];
    self.toggleKey = nil;
}

- (void)hotCornerHit:(URSHotCorner *)hotCorner {
    [self toggle];
}

#pragma mark - Opening and closing

- (void)toggle {
    if (self.open) {
        [self closeActivating:nil];
    } else {
        [self openOverview];
    }
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
        [self.transition runTo:1.0];
        return;
    }

    NSArray *items = [URSOverviewItem windowsOnScreenOfConnection:self.connection
                                                   windowSwitcher:self.windowSwitcher];
    if ([items count] == 0 || ![self grabInput]) {
        return;
    }
    [self layOutItems:items];
    NSMutableDictionary *byFrame = [NSMutableDictionary dictionary];
    for (URSOverviewItem *item in items) {
        byFrame[@([item.frame window])] = item;
    }
    self.items = byFrame;
    self.dockWindows = [URSScreenWindow dockWindowsOfConnection:self.connection];
    self.utilityPanelWindows = [URSScreenWindow utilityPanelsOfConnection:self.connection];
    self.selectedItem = nil;
    self.open = YES;
    [self.compositingManager setPresentation:self];
    [self.transition runTo:1.0];
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
    [self.transition runTo:0.0];
}

- (void)transitionClosed:(URSPresentationTransition *)transition {
    self.items = nil;
    self.dockWindows = nil;
    self.utilityPanelWindows = nil;
    self.selectedItem = nil;
    [self.compositingManager removePresentation:self];
}

#pragma mark - URSWindowPresentation

- (BOOL)getPaintRect:(NSRect *)paintRect
           forWindow:(xcb_window_t)windowId
          windowRect:(NSRect)windowRect {
    URSOverviewItem *item = self.items[@(windowId)];
    if (!item) {
        return NO;
    }
    *paintRect = URSInterpolateRect(windowRect, item.slot, [self.transition progress]);
    return YES;
}

- (double)opacityForWindow:(xcb_window_t)windowId {
    // Palettes fade with the Menu bar and Dock: hidden from the overview's
    // own scene without ever being unmapped, so they reappear exactly as
    // they were - including mid-fade, if a document is picked before the
    // fade-out finishes - the instant progress heads back to 0.
    BOOL fadesOut = [self.dockWindows containsObject:@(windowId)] ||
                    [self.utilityPanelWindows containsObject:@(windowId)];
    return fadesOut ? 1.0 - [self.transition progress] : 1.0;
}

- (double)backdropDimming {
    return URSOverviewBackdropDimming * [self.transition progress];
}

- (BOOL)isAnimating {
    return [self.transition isAnimating];
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
    if (self.toggleKey.keycode != 0 && event->detail == self.toggleKey.keycode) {
        [self toggle];
        return YES;
    }
    if (!self.open) {
        return NO;
    }
    xcb_keysym_t keysym = [self.toggleKey keysymForKeycode:event->detail];
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
    return self.open || (self.toggleKey.keycode != 0 && event->detail == self.toggleKey.keycode);
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

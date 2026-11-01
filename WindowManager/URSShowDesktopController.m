/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSShowDesktopController.h"
#import "URSShowDesktopLayout.h"
#import "URSGlobalKey.h"
#import "URSHotCorner.h"
#import "URSPresentationTransition.h"
#import "URSScreenWindow.h"
#import "URSCompositingManager.h"
#import "URSFocusManager.h"
#import "URSWindowSwitcher.h"
#import "URSWorkareaManager.h"
#import "XCBConnection.h"
#import "XCBScreen.h"
#import "XCBFrame.h"
#import "XCBTitleBar.h"
#import <xcb/shape.h>

NSString * const URSShowDesktopEnabledKey = @"URSShowDesktopEnabled";
NSString * const URSShowDesktopKeyKey = @"URSShowDesktopKey";
NSString * const URSShowDesktopHotCornerKey = @"URSShowDesktopHotCorner";

static const NSTimeInterval URSShowDesktopTransitionDuration = 0.3;
// How much of each window stays on the screen, as a share of the shorter
// screen side, so it is as easy to hit on every screen size.
static const CGFloat URSShowDesktopSliverShare = 0.015;

@interface URSShowDesktopItem : URSScreenWindow
@property (assign, nonatomic) NSPoint offset;
@property (assign, nonatomic) NSRect sliverRect;
// The InputOnly window that catches clicks on the sliver, XCB_NONE while
// the desktop is not shown.
@property (assign, nonatomic) xcb_window_t sliverWindow;
@end

@implementation URSShowDesktopItem
@end

@interface URSShowDesktopController ()
@property (weak, nonatomic) XCBConnection *connection;
@property (weak, nonatomic) URSFocusManager *focusManager;
@property (weak, nonatomic) URSWindowSwitcher *windowSwitcher;
@property (weak, nonatomic) URSWorkareaManager *workareaManager;
@property (assign, nonatomic) xcb_window_t root;
@property (strong, nonatomic) URSGlobalKey *toggleKey;
@property (strong, nonatomic) URSHotCorner *hotCorner;
@property (strong, nonatomic) URSPresentationTransition *transition;
// Bottom to top while the desktop is shown or the windows are coming back,
// else nil.
@property (strong, nonatomic) NSArray *items;
// Frame ids of the palettes, faded out rather than slid away: they belong
// to their document, not to a place on the screen.
@property (strong, nonatomic) NSSet *palettes;
// The document window that was in front, given focus again when the key
// brings the windows back.
@property (strong, nonatomic) XCBFrame *frontFrame;
@property (assign, nonatomic) BOOL shown;
@property (assign, nonatomic) xcb_window_t pressedSliver;
@end

@implementation URSShowDesktopController

+ (void)initialize {
    if (self == [URSShowDesktopController class]) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            URSShowDesktopEnabledKey: @YES,
            URSShowDesktopKeyKey: @"F11",
            URSShowDesktopHotCornerKey: @"none"
        }];
    }
}

- (instancetype)initWithConnection:(XCBConnection *)connection
                      focusManager:(URSFocusManager *)focusManager
                    windowSwitcher:(URSWindowSwitcher *)windowSwitcher
                   workareaManager:(URSWorkareaManager *)workareaManager {
    self = [super init];
    if (self) {
        _connection = connection;
        _focusManager = focusManager;
        _windowSwitcher = windowSwitcher;
        _workareaManager = workareaManager;
        _root = [[[[connection screens] objectAtIndex:0] rootWindow] window];
        _transition = [[URSPresentationTransition alloc] initWithDuration:URSShowDesktopTransitionDuration
                                                                    target:self
                                                              closedAction:@selector(transitionClosed:)];
    }
    return self;
}

#pragma mark - Setup

- (void)setUp {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Without compositing the windows cannot be shown elsewhere, and a
    // grabbed key would only be taken away from the applications.
    if (![defaults boolForKey:URSShowDesktopEnabledKey] ||
        ![self.compositingManager compositingActive]) {
        return;
    }
    self.transition.compositingManager = self.compositingManager;
    self.toggleKey = [[URSGlobalKey alloc] initWithConnection:self.connection];
    [self.toggleKey grabKeyNamed:[defaults stringForKey:URSShowDesktopKeyKey]
                         setting:URSShowDesktopKeyKey];
    self.hotCorner = [[URSHotCorner alloc] initWithConnection:self.connection
                                                   cornerName:[defaults stringForKey:URSShowDesktopHotCornerKey]
                                                      setting:URSShowDesktopHotCornerKey
                                                       target:self
                                                       action:@selector(hotCornerHit:)];
    [self.hotCorner start];
}

- (void)tearDown {
    [self.hotCorner stop];
    self.hotCorner = nil;
    [self.toggleKey ungrab];
    self.toggleKey = nil;
    // The windows must not stay deaf to the pointer after the WM is gone.
    if (self.shown) {
        [self letWindowsBack];
    }
}

- (void)hotCornerHit:(URSHotCorner *)hotCorner {
    [self toggle];
}

#pragma mark - Showing and hiding the desktop

- (void)toggle {
    if (self.shown) {
        [self bringWindowsBackActivating:self.frontFrame];
    } else {
        [self showDesktop];
    }
}

- (void)showDesktop {
    if (![self.compositingManager compositingActive]) {
        NSLog(@"[ShowDesktop] Not showing the desktop: it needs compositing");
        return;
    }
    // The overview owns the screen while it is open.
    id<URSWindowPresentation> installed = [self.compositingManager presentation];
    if (installed && installed != self) {
        return;
    }
    // Still coming back: turn around from where the windows are.
    if (self.items) {
        [self sendWindowsAway];
        [self.transition runTo:1.0];
        return;
    }

    NSArray *windows = [URSShowDesktopItem windowsOnScreenOfConnection:self.connection
                                                        windowSwitcher:self.windowSwitcher];
    NSRect area = [self.workareaManager currentWorkarea];
    NSMutableArray *rects = [NSMutableArray array];
    for (URSShowDesktopItem *item in windows) {
        [rects addObject:[NSValue valueWithRect:item.windowRect]];
    }
    CGFloat sliver = MAX(1.0, round(MIN(NSWidth(area), NSHeight(area)) * URSShowDesktopSliverShare));
    NSArray *offsets = [URSShowDesktopLayout offsetsForWindowRects:rects inArea:area sliver:sliver];
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger i = 0; i < [windows count]; i++) {
        URSShowDesktopItem *item = [windows objectAtIndex:i];
        item.offset = [[offsets objectAtIndex:i] pointValue];
        // Already out of the way: nothing to move, nothing to let through.
        if (!NSEqualPoints(item.offset, NSZeroPoint)) {
            [items addObject:item];
        }
    }
    if ([items count] == 0) {
        return;
    }
    self.items = items;
    self.palettes = [URSScreenWindow utilityPanelsOfConnection:self.connection];
    // Focus may sit on a palette, which its application hides as soon as
    // the desktop takes focus; the document in front is what comes back.
    URSShowDesktopItem *focused = [self itemForWindow:self.focusManager.lastFocusedWindowId];
    URSShowDesktopItem *front = focused ?: [items lastObject];
    self.frontFrame = front.frame;
    [self.compositingManager setPresentation:self];
    [self sendWindowsAway];
    [self focusDesktop];
    [self.transition runTo:1.0];
}

// frame nil brings the windows back without changing which one is active.
- (void)bringWindowsBackActivating:(XCBFrame *)frame {
    if (!self.shown) {
        return;
    }
    [self letWindowsBack];
    // The window may have closed while the desktop was shown.
    if (frame && [self.connection windowForXCBId:[frame window]] == frame) {
        // Raised before the windows slide in, so it lands in front.
        [self.focusManager activateFrame:frame];
    }
    [self.transition runTo:0.0];
}

- (void)transitionClosed:(URSPresentationTransition *)transition {
    self.items = nil;
    self.palettes = nil;
    self.frontFrame = nil;
    [self.compositingManager removePresentation:self];
}

// The windows are still where they were, only painted elsewhere, so they
// would take every click meant for the desktop; an empty input shape lets
// the pointer through them.  Clicks on the slivers are caught by InputOnly
// windows there instead.
- (void)sendWindowsAway {
    xcb_connection_t *conn = [self.connection connection];
    NSRect area = [self.workareaManager currentWorkarea];
    // A faded palette would still catch the clicks meant for the desktop.
    for (NSNumber *palette in self.palettes) {
        [self setInputPassesThrough:YES frame:[palette unsignedIntValue]];
    }
    for (URSShowDesktopItem *item in self.items) {
        [self setInputPassesThrough:YES frame:[item.frame window]];
        NSRect sliver = NSIntersectionRect(NSOffsetRect(item.windowRect, item.offset.x, item.offset.y),
                                           area);
        item.sliverRect = sliver;
        item.sliverWindow = xcb_generate_id(conn);
        uint32_t values[] = { 1, XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE };
        xcb_create_window(conn, XCB_COPY_FROM_PARENT, item.sliverWindow, self.root,
                          (int16_t)NSMinX(sliver), (int16_t)NSMinY(sliver),
                          (uint16_t)NSWidth(sliver), (uint16_t)NSHeight(sliver), 0,
                          XCB_WINDOW_CLASS_INPUT_ONLY, XCB_COPY_FROM_PARENT,
                          XCB_CW_OVERRIDE_REDIRECT | XCB_CW_EVENT_MASK, values);
        // Mapped bottom to top, so where slivers overlap the one painted in
        // front takes the click.
        xcb_map_window(conn, item.sliverWindow);
    }
    [self.connection flush];
    self.shown = YES;
}

- (void)setInputPassesThrough:(BOOL)passesThrough frame:(xcb_window_t)frameId {
    xcb_connection_t *conn = [self.connection connection];
    if (passesThrough) {
        xcb_shape_rectangles(conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_INPUT,
                             XCB_CLIP_ORDERING_UNSORTED, frameId, 0, 0, 0, NULL);
    } else {
        xcb_shape_mask(conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_INPUT, frameId, 0, 0, XCB_NONE);
    }
}

- (void)letWindowsBack {
    for (NSNumber *palette in self.palettes) {
        [self setInputPassesThrough:NO frame:[palette unsignedIntValue]];
    }
    for (URSShowDesktopItem *item in self.items) {
        [self letWindowBack:item restoreInput:YES];
    }
    [self.connection flush];
    self.shown = NO;
    self.pressedSliver = XCB_NONE;
}

- (void)letWindowBack:(URSShowDesktopItem *)item restoreInput:(BOOL)restoreInput {
    if (restoreInput) {
        [self setInputPassesThrough:NO frame:[item.frame window]];
    }
    if (item.sliverWindow != XCB_NONE) {
        xcb_destroy_window([self.connection connection], item.sliverWindow);
        item.sliverWindow = XCB_NONE;
    }
}

// Keys typed while the desktop is shown must not go to a window that
// cannot be seen.
- (void)focusDesktop {
    xcb_window_t desktop = [self.focusManager desktopWindowCandidateExcluding:XCB_NONE];
    xcb_set_input_focus([self.connection connection], XCB_INPUT_FOCUS_POINTER_ROOT,
                        desktop != XCB_NONE ? desktop : XCB_INPUT_FOCUS_POINTER_ROOT,
                        XCB_CURRENT_TIME);
    [self.connection flush];
}

#pragma mark - Windows

// The decorated frame a window id belongs to, the frame itself or its
// client, else nil.
- (XCBFrame *)frameOfWindow:(xcb_window_t)windowId {
    if (windowId == XCB_NONE) {
        return nil;
    }
    XCBWindow *window = [self.connection windowForXCBId:windowId];
    if (![window isKindOfClass:[XCBFrame class]]) {
        window = [[self.focusManager windowForClientWindowId:windowId] parentWindow];
    }
    if (![window isKindOfClass:[XCBFrame class]]) {
        return nil;
    }
    XCBFrame *frame = (XCBFrame *)window;
    if (![[frame childWindowForKey:TitleBar] isKindOfClass:[XCBTitleBar class]]) {
        return nil;
    }
    return frame;
}

- (URSShowDesktopItem *)itemForWindow:(xcb_window_t)windowId {
    for (URSShowDesktopItem *item in self.items) {
        if ([item.frame window] == windowId ||
            [[item.frame childWindowForKey:ClientWindow] window] == windowId) {
            return item;
        }
    }
    return nil;
}

// A window that becomes active - picked in the Dock or with Alt-Tab, or
// opened from the desktop - ends Show Desktop, as the user now works in it.
- (void)windowGotFocus:(xcb_window_t)windowId {
    if (self.shown && [self frameOfWindow:windowId]) {
        [self bringWindowsBackActivating:nil];
    }
}

- (void)windowMapped:(xcb_window_t)windowId {
    if (!self.shown || [self itemForWindow:windowId]) {
        return;
    }
    if ([self frameOfWindow:windowId]) {
        [self bringWindowsBackActivating:nil];
    }
}

- (void)windowUnmapped:(xcb_window_t)windowId {
    // A minimized window must take clicks again when it comes back.
    [self forgetWindow:windowId restoreInput:YES];
}

- (void)windowDestroyed:(xcb_window_t)windowId {
    [self forgetWindow:windowId restoreInput:NO];
}

- (void)forgetWindow:(xcb_window_t)windowId restoreInput:(BOOL)restoreInput {
    if ([self.palettes containsObject:@(windowId)]) {
        if (restoreInput && self.shown) {
            [self setInputPassesThrough:NO frame:windowId];
            [self.connection flush];
        }
        NSMutableSet *palettes = [self.palettes mutableCopy];
        [palettes removeObject:@(windowId)];
        self.palettes = palettes;
        return;
    }
    URSShowDesktopItem *item = [self itemForWindow:windowId];
    if (!item) {
        return;
    }
    [self letWindowBack:item restoreInput:restoreInput];
    [self.connection flush];
    NSMutableArray *items = [self.items mutableCopy];
    [items removeObject:item];
    self.items = items;
    if (self.shown && [items count] == 0) {
        [self bringWindowsBackActivating:nil];
    }
}

#pragma mark - URSWindowPresentation

- (BOOL)getPaintRect:(NSRect *)paintRect
           forWindow:(xcb_window_t)windowId
          windowRect:(NSRect)windowRect {
    for (URSShowDesktopItem *item in self.items) {
        if ([item.frame window] == windowId) {
            // An offset rather than a target rect, so a window resized by its
            // application while away keeps its size.
            double p = [self.transition progress];
            *paintRect = NSOffsetRect(windowRect, item.offset.x * p, item.offset.y * p);
            return YES;
        }
    }
    return NO;
}

- (double)backdropDimming {
    return 0.0;
}

- (double)opacityForWindow:(xcb_window_t)windowId {
    return [self.palettes containsObject:@(windowId)] ? 1.0 - [self.transition progress] : 1.0;
}

- (BOOL)isAnimating {
    return [self.transition isAnimating];
}

- (void)presentationWasReplaced {
    // The overview opened over the shown desktop: it shows every window
    // from where it really is, so there is nothing to bring back.
    [self.transition cancel];
    if (self.shown) {
        [self letWindowsBack];
    }
    self.items = nil;
    self.palettes = nil;
    self.frontFrame = nil;
}

#pragma mark - Input

- (BOOL)isToggleKey:(xcb_keycode_t)keycode {
    return self.toggleKey.keycode != 0 && keycode == self.toggleKey.keycode;
}

- (BOOL)handleKeyPress:(xcb_key_press_event_t *)event {
    if (![self isToggleKey:event->detail]) {
        return NO;
    }
    [self toggle];
    return YES;
}

- (BOOL)handleKeyRelease:(xcb_key_release_event_t *)event {
    return [self isToggleKey:event->detail];
}

- (URSShowDesktopItem *)itemForSliver:(xcb_window_t)windowId {
    if (windowId == XCB_NONE) {
        return nil;
    }
    for (URSShowDesktopItem *item in self.items) {
        if (item.sliverWindow == windowId) {
            return item;
        }
    }
    return nil;
}

- (BOOL)handleButtonPress:(xcb_button_press_event_t *)event {
    if (!self.shown || ![self itemForSliver:event->event]) {
        return NO;
    }
    self.pressedSliver = event->detail == XCB_BUTTON_INDEX_1 ? event->event : XCB_NONE;
    return YES;
}

- (BOOL)handleButtonRelease:(xcb_button_release_event_t *)event {
    URSShowDesktopItem *item = [self itemForSliver:event->event];
    if (!self.shown || !item) {
        return NO;
    }
    // Only a click that also ends on the sliver it began on picks it, as
    // with a button.
    BOOL inside = NSPointInRect(NSMakePoint(event->event_x, event->event_y),
                                NSMakeRect(0, 0, NSWidth(item.sliverRect), NSHeight(item.sliverRect)));
    if (event->detail == XCB_BUTTON_INDEX_1 && self.pressedSliver == event->event && inside) {
        [self bringWindowsBackActivating:item.frame];
    }
    self.pressedSliver = XCB_NONE;
    return YES;
}

@end

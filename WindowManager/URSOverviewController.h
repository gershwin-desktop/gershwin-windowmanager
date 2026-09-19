/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <xcb/xcb.h>
#import "URSWindowPresentation.h"

@class XCBConnection;
@class URSFocusManager;
@class URSWorkareaManager;
@class URSWindowSwitcher;
@class URSCompositingManager;

// Defaults keys.
// BOOL, default YES: the window overview can be opened.
extern NSString * const URSOverviewEnabledKey;
// String, default "F9": the key (an X keysym name) that opens and closes it.
extern NSString * const URSOverviewKeyKey;
// String, default "none": the screen corner that opens it when the pointer
// goes there - "top-left", "top-right", "bottom-left" or "bottom-right".
extern NSString * const URSOverviewHotCornerKey;

// The window overview: every window on the screen, shrunk and spread out
// side by side over a darkened desktop, so the one wanted is found at a
// glance and picked with a click.  The windows stay where they are; the
// compositor only paints them elsewhere while the overview is shown.
@interface URSOverviewController : NSObject <URSWindowPresentation>

@property (weak, nonatomic) URSCompositingManager *compositingManager;

- (instancetype)initWithConnection:(XCBConnection *)connection
                      focusManager:(URSFocusManager *)focusManager
                   workareaManager:(URSWorkareaManager *)workareaManager
                    windowSwitcher:(URSWindowSwitcher *)windowSwitcher;

// Grabs the key and starts watching the hot corner, as the defaults say.
- (void)setUp;
- (void)tearDown;

// Input from the event loop.  YES means the overview consumed the event:
// all input while it is open, and its key at any time.
- (BOOL)handleKeyPress:(xcb_key_press_event_t *)event;
- (BOOL)handleKeyRelease:(xcb_key_release_event_t *)event;
- (BOOL)handleButtonPress:(xcb_button_press_event_t *)event;
- (BOOL)handleButtonRelease:(xcb_button_release_event_t *)event;
- (BOOL)handleMotion:(xcb_motion_notify_event_t *)event;

@end

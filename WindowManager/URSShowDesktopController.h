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
@class URSWindowSwitcher;
@class URSWorkareaManager;
@class URSCompositingManager;

// Defaults keys.
// BOOL, default YES: Show Desktop can be used.
extern NSString * const URSShowDesktopEnabledKey;
// String, default "F11": the key (an X keysym name) that shows the desktop
// and brings the windows back.
extern NSString * const URSShowDesktopKeyKey;
// String, default "none": the screen corner that does the same when the
// pointer goes there - "top-left", "top-right", "bottom-left" or
// "bottom-right".
extern NSString * const URSShowDesktopHotCornerKey;

// Show Desktop: every window slides out over the nearest screen edge until
// only a sliver of it is left, so the desktop can be used - icons opened,
// files dragged - while the Menu bar and Dock stay and palettes fade out
// with their documents gone.  The same key or a click on a sliver brings
// the windows back; so does any window becoming active.
// The windows stay where they are: the compositor only paints them elsewhere,
// and while they are away they let the pointer through to the desktop.
@interface URSShowDesktopController : NSObject <URSWindowPresentation>

@property (weak, nonatomic) URSCompositingManager *compositingManager;

- (instancetype)initWithConnection:(XCBConnection *)connection
                      focusManager:(URSFocusManager *)focusManager
                    windowSwitcher:(URSWindowSwitcher *)windowSwitcher
                   workareaManager:(URSWorkareaManager *)workareaManager;

// Grabs the key and starts watching the hot corner, as the defaults say.
- (void)setUp;
- (void)tearDown;

// Input from the event loop.  YES means Show Desktop consumed the event:
// its key, and clicks on the slivers.
- (BOOL)handleKeyPress:(xcb_key_press_event_t *)event;
- (BOOL)handleKeyRelease:(xcb_key_release_event_t *)event;
- (BOOL)handleButtonPress:(xcb_button_press_event_t *)event;
- (BOOL)handleButtonRelease:(xcb_button_release_event_t *)event;

// What happens to windows while the desktop is shown.
- (void)windowGotFocus:(xcb_window_t)windowId;
- (void)windowMapped:(xcb_window_t)windowId;
- (void)windowUnmapped:(xcb_window_t)windowId;
- (void)windowDestroyed:(xcb_window_t)windowId;

@end

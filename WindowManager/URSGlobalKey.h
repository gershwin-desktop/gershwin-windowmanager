/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <xcb/xcb.h>

@class XCBConnection;

// A key grabbed on the root window, so it reaches the window manager
// whichever window has focus and whatever lock keys are on.
@interface URSGlobalKey : NSObject

// 0 until a grab succeeded.
@property (readonly, nonatomic) xcb_keycode_t keycode;

- (instancetype)initWithConnection:(XCBConnection *)connection;

// keyName is an X keysym name such as "F9"; settingName is the defaults key
// it came from, named when it is wrong.
- (BOOL)grabKeyNamed:(NSString *)keyName setting:(NSString *)settingName;
- (void)ungrab;

// The unshifted keysym the key sends, XCB_NO_SYMBOL for none.
- (xcb_keysym_t)keysymForKeycode:(xcb_keycode_t)keycode;

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSGlobalKey.h"
#import "XCBConnection.h"
#import "XCBScreen.h"
#import <X11/Xlib.h>

// NumLock and CapsLock must not stop the key from working.
static const uint16_t URSLockMasks[] = {
    0, XCB_MOD_MASK_LOCK, XCB_MOD_MASK_2, XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2
};

@interface URSGlobalKey ()
@property (weak, nonatomic) XCBConnection *connection;
@property (assign, nonatomic) xcb_window_t root;
@property (readwrite, assign, nonatomic) xcb_keycode_t keycode;
@property (strong, nonatomic) NSDictionary *keysymsByKeycode;
@end

@implementation URSGlobalKey

- (instancetype)initWithConnection:(XCBConnection *)connection {
    self = [super init];
    if (self) {
        _connection = connection;
        _root = [[[[connection screens] objectAtIndex:0] rootWindow] window];
        [self readKeyboardMapping];
    }
    return self;
}

- (void)readKeyboardMapping {
    xcb_connection_t *conn = [self.connection connection];
    const xcb_setup_t *setup = xcb_get_setup(conn);
    xcb_get_keyboard_mapping_reply_t *reply = xcb_get_keyboard_mapping_reply(conn,
        xcb_get_keyboard_mapping(conn, setup->min_keycode,
                                 setup->max_keycode - setup->min_keycode + 1), NULL);
    if (!reply) {
        NSLog(@"[GlobalKey] ERROR: could not read the keyboard mapping");
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

- (xcb_keysym_t)keysymForKeycode:(xcb_keycode_t)keycode {
    return [self.keysymsByKeycode[@(keycode)] unsignedIntValue];
}

- (BOOL)grabKeyNamed:(NSString *)keyName setting:(NSString *)settingName {
    KeySym keysym = XStringToKeysym([keyName UTF8String]);
    if (keysym == NoSymbol) {
        NSLog(@"[GlobalKey] ERROR: %@ is %@, which is no X key name", settingName, keyName);
        return NO;
    }
    xcb_keycode_t keycode = 0;
    for (NSNumber *code in self.keysymsByKeycode) {
        if ([self.keysymsByKeycode[code] unsignedLongValue] == keysym) {
            keycode = [code unsignedCharValue];
            break;
        }
    }
    if (keycode == 0) {
        NSLog(@"[GlobalKey] ERROR: %@ is %@, but no key on this keyboard sends it",
              settingName, keyName);
        return NO;
    }
    xcb_connection_t *conn = [self.connection connection];
    for (size_t i = 0; i < sizeof(URSLockMasks) / sizeof(URSLockMasks[0]); i++) {
        xcb_grab_key(conn, 0, self.root, URSLockMasks[i], keycode,
                     XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC);
    }
    [self.connection flush];
    self.keycode = keycode;
    return YES;
}

- (void)ungrab {
    if (self.keycode == 0) {
        return;
    }
    xcb_connection_t *conn = [self.connection connection];
    for (size_t i = 0; i < sizeof(URSLockMasks) / sizeof(URSLockMasks[0]); i++) {
        xcb_ungrab_key(conn, self.keycode, self.root, URSLockMasks[i]);
    }
    self.keycode = 0;
}

@end

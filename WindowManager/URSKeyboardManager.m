//
//  URSKeyboardManager.m
//  uroswm - Keyboard Grab Management for Alt-Tab
//
//  Handles keyboard grabbing, key press/release events for Alt-Tab window
//  switching, alt-keycode caching, and robust alt-release polling.
//

#import "URSKeyboardManager.h"
#import "XCBScreen.h"
#import <xcb/xcb.h>
#import <X11/keysym.h>

@interface URSKeyboardManager ()
@property (strong, nonatomic) NSMutableArray *altKeycodes;
@property (strong, nonatomic) NSTimer *altReleasePollTimer;
@property (assign, nonatomic) xcb_keycode_t tabKeycode;
@end

@implementation URSKeyboardManager

- (instancetype)initWithConnection:(XCBConnection *)aConnection
                    windowSwitcher:(URSWindowSwitcher *)aWindowSwitcher
{
    self = [super init];
    if (!self) return nil;

    _connection = aConnection;
    _windowSwitcher = aWindowSwitcher;
    _altKeyPressed = NO;
    _shiftKeyPressed = NO;
    _altKeycodes = [[NSMutableArray alloc] init];
    _altReleasePollTimer = nil;
    _tabKeycode = 23; /* fallback; overwritten by setupKeyboardGrabbing */

    return self;
}

#pragma mark - Keyboard Grab Setup/Teardown

- (void)setupKeyboardGrabbing
{
    NSLog(@"[Alt-Tab] Setting up keyboard grabbing");

    @try {
        XCBScreen *screen = [[self.connection screens] objectAtIndex:0];
        xcb_window_t root = [[screen rootWindow] window];
        xcb_connection_t *conn = [self.connection connection];

        const xcb_setup_t *setup = xcb_get_setup(conn);
        xcb_get_keyboard_mapping_cookie_t cookie = xcb_get_keyboard_mapping(
            conn,
            setup->min_keycode,
            setup->max_keycode - setup->min_keycode + 1
        );

        xcb_get_keyboard_mapping_reply_t *reply =
            xcb_get_keyboard_mapping_reply(conn, cookie, NULL);
        if (!reply) {
            NSLog(@"[Alt-Tab] ERROR: Failed to get keyboard mapping");
            return;
        }

        xcb_keysym_t *keysyms = xcb_get_keyboard_mapping_keysyms(reply);
        int keysyms_len = xcb_get_keyboard_mapping_keysyms_length(reply);

        NSLog(@"[Alt-Tab] Found %d keysyms in keyboard mapping", keysyms_len);

        BOOL tabFound = NO;
        for (int i = 0; i < keysyms_len; i++) {
            // Cache Alt/Meta keycodes for query_keymap polling
            if (keysyms[i] == XK_Alt_L || keysyms[i] == XK_Alt_R ||
                keysyms[i] == XK_Meta_L || keysyms[i] == XK_Meta_R ||
                keysyms[i] == XK_Super_L || keysyms[i] == XK_Super_R) {
                xcb_keycode_t altcode =
                    setup->min_keycode + (i / reply->keysyms_per_keycode);

                if (![self.altKeycodes containsObject:@(altcode)]) {
                    NSLog(@"[Alt-Tab] Caching potential modifier key: %d (sym=0x%x)",
                          altcode, (unsigned int)keysyms[i]);
                    [self.altKeycodes addObject:@(altcode)];
                }
            }

            if (keysyms[i] == XK_Tab) {
                xcb_keycode_t keycode =
                    setup->min_keycode + (i / reply->keysyms_per_keycode);

                NSLog(@"[Alt-Tab] Found Tab key at keycode %d", keycode);

                self.tabKeycode = keycode;

                // Grab Alt+Tab and Shift+Alt+Tab with all lock modifier combinations
                uint16_t lockMasks[] = {
                    0, XCB_MOD_MASK_LOCK, XCB_MOD_MASK_2,
                    XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2
                };
                for (int j = 0; j < 4; j++) {
                    xcb_grab_key(conn, 0, root,
                                 XCB_MOD_MASK_1 | lockMasks[j],
                                 keycode,
                                 XCB_GRAB_MODE_ASYNC,
                                 XCB_GRAB_MODE_ASYNC);

                    xcb_grab_key(conn, 0, root,
                                 XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT | lockMasks[j],
                                 keycode,
                                 XCB_GRAB_MODE_ASYNC,
                                 XCB_GRAB_MODE_ASYNC);
                }

                tabFound = YES;
            }
        }

        // Query modifier mapping to find all keycodes assigned to Mod1
        xcb_get_modifier_mapping_cookie_t modCookie =
            xcb_get_modifier_mapping(conn);
        xcb_get_modifier_mapping_reply_t *modReply =
            xcb_get_modifier_mapping_reply(conn, modCookie, NULL);
        if (modReply) {
            int keycodesPerMod = modReply->keycodes_per_modifier;
            xcb_keycode_t *modKeycodes =
                xcb_get_modifier_mapping_keycodes(modReply);

            NSLog(@"[Alt-Tab] Querying Mod1 (Alt) modifier mapping (%d keycodes per modifier)",
                  keycodesPerMod);
            for (int i = 0; i < keycodesPerMod; i++) {
                xcb_keycode_t kc = modKeycodes[3 * keycodesPerMod + i];
                if (kc != 0 && ![self.altKeycodes containsObject:@(kc)]) {
                    NSLog(@"[Alt-Tab] Adding Mod1 keycode from mapping: %d", kc);
                    [self.altKeycodes addObject:@(kc)];
                }
            }
            free(modReply);
        }

        if (!tabFound) {
            NSLog(@"[Alt-Tab] Warning: Tab key not found, using keycode 23 as fallback");
            uint16_t fbLockMasks[] = {
                0, XCB_MOD_MASK_LOCK, XCB_MOD_MASK_2,
                XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2
            };
            for (int j = 0; j < 4; j++) {
                xcb_grab_key(conn, 0, root,
                             XCB_MOD_MASK_1 | fbLockMasks[j], 23,
                             XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC);
                xcb_grab_key(conn, 0, root,
                             XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT | fbLockMasks[j], 23,
                             XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC);
            }
        }

        free(reply);
        [self.connection flush];
        NSLog(@"[Alt-Tab] Successfully grabbed Alt+Tab and Shift+Alt+Tab");

    } @catch (NSException *exception) {
        NSLog(@"[Alt-Tab] Exception in setupKeyboardGrabbing: %@", exception.reason);
    }
}

- (void)cleanupKeyboardGrabbing
{
    NSLog(@"[Alt-Tab] Cleaning up keyboard grabbing");

    @try {
        XCBScreen *screen = [[self.connection screens] objectAtIndex:0];
        xcb_window_t root = [[screen rootWindow] window];
        xcb_connection_t *conn = [self.connection connection];

        xcb_get_keyboard_mapping_cookie_t cookie = xcb_get_keyboard_mapping(
            conn, 8, 248);

        xcb_get_keyboard_mapping_reply_t *reply =
            xcb_get_keyboard_mapping_reply(conn, cookie, NULL);
        if (!reply) {
            NSLog(@"[Alt-Tab] Warning: Failed to get keyboard mapping during cleanup");
            uint16_t fbLockMasks[] = {
                0, XCB_MOD_MASK_LOCK, XCB_MOD_MASK_2,
                XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2
            };
            for (int j = 0; j < 4; j++) {
                xcb_ungrab_key(conn, 23, root, XCB_MOD_MASK_1 | fbLockMasks[j]);
                xcb_ungrab_key(conn, 23, root,
                               XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT | fbLockMasks[j]);
            }
            [self.connection flush];
            return;
        }

        xcb_keysym_t *keysyms = xcb_get_keyboard_mapping_keysyms(reply);
        int keysyms_len = xcb_get_keyboard_mapping_keysyms_length(reply);

        BOOL tabFound = NO;
        for (int i = 0; i < keysyms_len; i++) {
            if (keysyms[i] == XK_Tab) {
                xcb_keycode_t keycode = 8 + (i / reply->keysyms_per_keycode);

                NSLog(@"[Alt-Tab] Ungrabbing Tab key at keycode %d", keycode);

                uint16_t lockMasks[] = {
                    0, XCB_MOD_MASK_LOCK, XCB_MOD_MASK_2,
                    XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2
                };
                for (int j = 0; j < 4; j++) {
                    xcb_ungrab_key(conn, keycode, root,
                                   XCB_MOD_MASK_1 | lockMasks[j]);
                    xcb_ungrab_key(conn, keycode, root,
                                   XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT | lockMasks[j]);
                }

                tabFound = YES;
                break;
            }
        }

        if (!tabFound) {
            NSLog(@"[Alt-Tab] Using fallback keycode 23 for ungrab");
            uint16_t fbLockMasks2[] = {
                0, XCB_MOD_MASK_LOCK, XCB_MOD_MASK_2,
                XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2
            };
            for (int j = 0; j < 4; j++) {
                xcb_ungrab_key(conn, 23, root, XCB_MOD_MASK_1 | fbLockMasks2[j]);
                xcb_ungrab_key(conn, 23, root,
                               XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT | fbLockMasks2[j]);
            }
        }

        free(reply);
        [self.connection flush];
        NSLog(@"[Alt-Tab] Successfully ungrabbed keyboard");

        [self stopAltReleasePoll];

    } @catch (NSException *exception) {
        NSLog(@"[Alt-Tab] Exception in cleanupKeyboardGrabbing: %@", exception.reason);
    }
}

#pragma mark - Key Event Handling

- (void)handleKeyPress:(xcb_key_press_event_t *)event
{
    @try {
        BOOL altPressed = (event->state & XCB_MOD_MASK_1) != 0;
        BOOL shiftPressed = (event->state & XCB_MOD_MASK_SHIFT) != 0;

        NSLog(@"[Alt-Tab] Key press: keycode=%d, state=0x%x, alt=%d, shift=%d",
              event->detail, event->state, altPressed, shiftPressed);

        if ([self.altKeycodes containsObject:@(event->detail)]) {
            self.altKeyPressed = YES;
            NSLog(@"[Alt-Tab] Alt-class key pressed: keycode=%d", event->detail);
        }

        if (event->detail == 50 || event->detail == 62) {
            self.shiftKeyPressed = YES;
        }

        // Handle Tab key with Alt modifier
        if (event->detail == self.tabKeycode && altPressed) {
            NSLog(@"[Alt-Tab] Tab pressed with Alt (shift=%d)", shiftPressed);

            if (!self.windowSwitcher.isSwitching) {
                XCBScreen *screen = [[self.connection screens] objectAtIndex:0];
                xcb_window_t root = [[screen rootWindow] window];
                xcb_connection_t *conn = [self.connection connection];

                xcb_grab_keyboard_cookie_t cookie = xcb_grab_keyboard(
                    conn, 0, root, XCB_CURRENT_TIME,
                    XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC);
                xcb_grab_keyboard_reply_t *reply =
                    xcb_grab_keyboard_reply(conn, cookie, NULL);

                if (reply) {
                    if (reply->status == XCB_GRAB_STATUS_SUCCESS) {
                        NSLog(@"[Alt-Tab] Successfully grabbed keyboard");
                    } else {
                        NSLog(@"[Alt-Tab] Warning: Keyboard grab failed with status %d",
                              reply->status);
                    }
                    free(reply);
                }
                [self.connection flush];
            }

            if (shiftPressed) {
                NSLog(@"[Alt-Tab] Cycling backward");
                [self.windowSwitcher cycleBackward];
            } else {
                NSLog(@"[Alt-Tab] Cycling forward");
                [self.windowSwitcher cycleForward];
            }

            [self startAltReleasePoll];
        }

    } @catch (NSException *exception) {
        NSLog(@"[Alt-Tab] Exception in handleKeyPress: %@", exception.reason);
    }
}

- (void)handleKeyRelease:(xcb_key_release_event_t *)event
{
    @try {
        if ([self.altKeycodes containsObject:@(event->detail)]) {
            self.altKeyPressed = NO;
            NSLog(@"[Alt-Tab] Alt-class key release: keycode=%d", event->detail);
        }

        if (self.windowSwitcher.isSwitching) {
            if (![self altModifierCurrentlyDown]) {
                NSLog(@"[Alt-Tab] Alt release confirmed via keymap query - completing switch");

                xcb_connection_t *conn = [self.connection connection];
                xcb_ungrab_keyboard(conn, XCB_CURRENT_TIME);
                [self.connection flush];

                [self.windowSwitcher completeSwitching];
                [self stopAltReleasePoll];
            } else {
                if ([self.altKeycodes containsObject:@(event->detail)]) {
                    NSLog(@"[Alt-Tab] One Alt key released, but another Alt/Meta key is still held.");
                } else if (event->detail == self.tabKeycode) {
                    NSLog(@"[Alt-Tab] Tab released, keeping switcher open as Alt is still held.");
                }
            }
        }

        if (event->detail == 50 || event->detail == 62) {
            self.shiftKeyPressed = NO;
        }

    } @catch (NSException *exception) {
        NSLog(@"[Alt-Tab] Exception in handleKeyRelease: %@", exception.reason);
    }
}

#pragma mark - Alt Release Polling

- (BOOL)altModifierCurrentlyDown
{
    xcb_connection_t *conn = [self.connection connection];
    xcb_query_keymap_cookie_t cookie = xcb_query_keymap(conn);
    xcb_query_keymap_reply_t *reply = xcb_query_keymap_reply(conn, cookie, NULL);
    if (!reply) return NO;

    const uint8_t *keys = reply->keys;
    BOOL down = NO;

    for (NSNumber *num in self.altKeycodes) {
        xcb_keycode_t keycode = (xcb_keycode_t)[num unsignedCharValue];
        if (keycode < 8) continue;
        uint8_t byte = keys[keycode >> 3];
        uint8_t mask = (1 << (keycode & 7));
        if (byte & mask) {
            down = YES;
            break;
        }
    }

    free(reply);
    return down;
}

- (void)startAltReleasePoll
{
    if (self.altReleasePollTimer) return;
    NSLog(@"[Alt-Tab] Starting Alt release poll timer");
    self.altReleasePollTimer =
        [NSTimer scheduledTimerWithTimeInterval:0.05
                                         target:self
                                       selector:@selector(checkAltReleaseTimerFired:)
                                       userInfo:nil
                                        repeats:YES];
}

- (void)stopAltReleasePoll
{
    if (!self.altReleasePollTimer) return;
    NSLog(@"[Alt-Tab] Stopping Alt release poll timer");
    [self.altReleasePollTimer invalidate];
    self.altReleasePollTimer = nil;
}

- (void)checkAltReleaseTimerFired:(NSTimer *)timer
{
    if (!self.windowSwitcher.isSwitching) {
        [self stopAltReleasePoll];
        return;
    }

    if (![self altModifierCurrentlyDown]) {
        NSLog(@"[Alt-Tab] Alt release detected via poll - completing switch");
        xcb_connection_t *conn = [self.connection connection];
        xcb_ungrab_keyboard(conn, XCB_CURRENT_TIME);
        [self.connection flush];

        [self.windowSwitcher completeSwitching];
        [self stopAltReleasePoll];
    }
}

@end

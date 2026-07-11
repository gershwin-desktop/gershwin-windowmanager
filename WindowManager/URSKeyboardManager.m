//
//  URSKeyboardManager.m
//  uroswm - Keyboard Grab Management for Alt-Tab
//
//  Handles keyboard grabbing, key press/release events for Alt-Tab window
//  switching, alt-keycode caching, and robust alt-release polling.
//

#import "URSKeyboardManager.h"
#import "URSFocusManager.h"
#import "XCBWindow.h"
#import "XCBFrame.h"
#import "XCBScreen.h"
#import "EWMHService.h"
#import <xcb/xcb.h>
#import <X11/keysym.h>

@interface URSKeyboardManager ()
@property (strong, nonatomic) NSMutableArray *altKeycodes;
@property (strong, nonatomic) NSTimer *altReleasePollTimer;
@property (assign, nonatomic) xcb_keycode_t tabKeycode;
@property (assign, nonatomic) xcb_keycode_t escapeKeycode;
@property (assign, nonatomic) xcb_keycode_t wKeycode;
@property (assign, nonatomic) xcb_keycode_t returnKeycode;
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
    _tabKeycode = 23;
    _escapeKeycode = 0;
    _wKeycode = 0;
    _returnKeycode = 0;

    return self;
}

#pragma mark - Keyboard Grab Setup/Teardown

- (void)setupKeyboardGrabbing
{
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

        BOOL tabFound = NO;
        for (int i = 0; i < keysyms_len; i++) {
            if (keysyms[i] == XK_Alt_L || keysyms[i] == XK_Alt_R ||
                keysyms[i] == XK_Meta_L || keysyms[i] == XK_Meta_R ||
                keysyms[i] == XK_Super_L || keysyms[i] == XK_Super_R) {
                xcb_keycode_t altcode =
                    setup->min_keycode + (i / reply->keysyms_per_keycode);

                if (![self.altKeycodes containsObject:@(altcode)]) {
                    [self.altKeycodes addObject:@(altcode)];
                }
            }

            if (keysyms[i] == XK_Tab) {
                xcb_keycode_t keycode =
                    setup->min_keycode + (i / reply->keysyms_per_keycode);

                self.tabKeycode = keycode;

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
            
            if (keysyms[i] == XK_Escape) {
                xcb_keycode_t keycode =
                    setup->min_keycode + (i / reply->keysyms_per_keycode);

                self.escapeKeycode = keycode;
            }

            if (keysyms[i] == XK_w || keysyms[i] == XK_W) {
                xcb_keycode_t keycode =
                    setup->min_keycode + (i / reply->keysyms_per_keycode);

                if (self.wKeycode == 0) {
                    self.wKeycode = keycode;
                }

                // Alt+W is left ungrabbed — apps with their own Alt+W
                // binding (e.g. close tab in a browser) receive it first.
                // The WM close shortcut is Shift+Alt+W instead, which
                // apps almost never register for themselves.
                uint16_t lockMasks[] = {
                    0, XCB_MOD_MASK_LOCK, XCB_MOD_MASK_2,
                    XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2
                };
                for (int j = 0; j < 4; j++) {
                    xcb_grab_key(conn, 0, root,
                                 XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT | lockMasks[j],
                                 keycode,
                                 XCB_GRAB_MODE_ASYNC,
                                 XCB_GRAB_MODE_ASYNC);
                }
            }

            if (keysyms[i] == XK_Return || keysyms[i] == XK_KP_Enter) {
                xcb_keycode_t keycode =
                    setup->min_keycode + (i / reply->keysyms_per_keycode);

                if (self.returnKeycode == 0) {
                    self.returnKeycode = keycode;
                }

                // Alt+Return — toggle fullscreen on the focused window
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
                }
            }
        }

        xcb_get_modifier_mapping_cookie_t modCookie =
            xcb_get_modifier_mapping(conn);
        xcb_get_modifier_mapping_reply_t *modReply =
            xcb_get_modifier_mapping_reply(conn, modCookie, NULL);
        if (modReply) {
            int keycodesPerMod = modReply->keycodes_per_modifier;
            xcb_keycode_t *modKeycodes =
                xcb_get_modifier_mapping_keycodes(modReply);

            for (int i = 0; i < keycodesPerMod; i++) {
                xcb_keycode_t kc = modKeycodes[3 * keycodesPerMod + i];
                if (kc != 0 && ![self.altKeycodes containsObject:@(kc)]) {
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

    } @catch (NSException *exception) {
        NSLog(@"[Alt-Tab] Exception in setupKeyboardGrabbing: %@", exception.reason);
    }
}

- (void)cleanupKeyboardGrabbing
{
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

        if (self.wKeycode != 0) {
            uint16_t lockMasks[] = {
                0, XCB_MOD_MASK_LOCK, XCB_MOD_MASK_2,
                XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2
            };
            for (int j = 0; j < 4; j++) {
                xcb_ungrab_key(conn, self.wKeycode, root,
                               XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT | lockMasks[j]);
            }
        }

        if (self.returnKeycode != 0) {
            uint16_t lockMasks[] = {
                0, XCB_MOD_MASK_LOCK, XCB_MOD_MASK_2,
                XCB_MOD_MASK_LOCK | XCB_MOD_MASK_2
            };
            for (int j = 0; j < 4; j++) {
                xcb_ungrab_key(conn, self.returnKeycode, root,
                               XCB_MOD_MASK_1 | lockMasks[j]);
            }
        }

        free(reply);
        [self.connection flush];

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

        if ([self.altKeycodes containsObject:@(event->detail)]) {
            self.altKeyPressed = YES;
        }

        if (event->detail == 50 || event->detail == 62) {
            self.shiftKeyPressed = YES;
        }

        if (event->detail == self.tabKeycode && altPressed) {
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
                    if (reply->status != XCB_GRAB_STATUS_SUCCESS) {
                        NSLog(@"[Alt-Tab] Warning: Keyboard grab failed with status %d",
                              reply->status);
                    }
                    free(reply);
                }
                [self.connection flush];
            }

            if (shiftPressed) {
                [self.windowSwitcher cycleBackward];
            } else {
                [self.windowSwitcher cycleForward];
            }

            [self startAltReleasePoll];
        }

        if (event->detail == self.escapeKeycode && self.windowSwitcher.isSwitching) {
            xcb_connection_t *conn = [self.connection connection];
            xcb_ungrab_keyboard(conn, XCB_CURRENT_TIME);
            [self.connection flush];

            [self.windowSwitcher cancelSwitching];
            [self stopAltReleasePoll];
        }

        // Shift+Alt+W — close focused window.
        // Alt+W (without Shift) is left ungrabbed on purpose so that apps
        // with their own Alt+W binding (e.g. close-tab in a browser) can
        // handle it first.
        if (event->detail == self.wKeycode && altPressed && shiftPressed
            && !self.windowSwitcher.isSwitching) {
            xcb_connection_t *conn = [self.connection connection];
            xcb_get_input_focus_cookie_t focCookie = xcb_get_input_focus(conn);
            xcb_get_input_focus_reply_t *focReply =
                xcb_get_input_focus_reply(conn, focCookie, NULL);
            xcb_window_t targetId = XCB_NONE;
            if (focReply) {
                targetId = focReply->focus;
                free(focReply);
            }

            XCBWindow *clientWindow = nil;
            if (targetId != XCB_NONE && targetId != XCB_WINDOW_NONE) {
                clientWindow = [self.connection windowForXCBId:targetId];
                if (!clientWindow) {
                    XCBWindow *resolved = [self.focusManager windowForClientWindowId:targetId];
                    if (resolved) {
                        clientWindow = resolved;
                    }
                }
                if ([clientWindow isKindOfClass:[XCBFrame class]]) {
                    XCBFrame *frame = (XCBFrame *)clientWindow;
                    XCBWindow *frameClient = [frame childWindowForKey:ClientWindow];
                    if (frameClient) {
                        clientWindow = frameClient;
                    }
                }
            }
            if (clientWindow && [clientWindow canClose]) {
                [clientWindow close];
            }
        }

        // Alt+Return — toggle fullscreen on the focused window.
        if (event->detail == self.returnKeycode && altPressed
            && !self.windowSwitcher.isSwitching) {
            xcb_connection_t *conn = [self.connection connection];
            xcb_get_input_focus_cookie_t focCookie = xcb_get_input_focus(conn);
            xcb_get_input_focus_reply_t *focReply =
                xcb_get_input_focus_reply(conn, focCookie, NULL);
            xcb_window_t targetId = XCB_NONE;
            if (focReply) {
                targetId = focReply->focus;
                free(focReply);
            }

            XCBWindow *clientWindow = nil;
            if (targetId != XCB_NONE && targetId != XCB_WINDOW_NONE) {
                clientWindow = [self.connection windowForXCBId:targetId];
                if (!clientWindow) {
                    XCBWindow *resolved = [self.focusManager windowForClientWindowId:targetId];
                    if (resolved)
                        clientWindow = resolved;
                }
                if ([clientWindow isKindOfClass:[XCBFrame class]]) {
                    XCBFrame *frame = (XCBFrame *)clientWindow;
                    XCBWindow *frameClient = [frame childWindowForKey:ClientWindow];
                    if (frameClient)
                        clientWindow = frameClient;
                }
            }
            if (clientWindow && [clientWindow canFullscreen]) {
                EWMHService *ewmh = [EWMHService sharedInstanceWithConnection:self.connection];
                [ewmh toggleFullscreenForWindow:clientWindow];
            }
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
        }

        if (self.windowSwitcher.isSwitching) {
            if (![self altModifierCurrentlyDown]) {
                xcb_connection_t *conn = [self.connection connection];
                xcb_ungrab_keyboard(conn, XCB_CURRENT_TIME);
                [self.connection flush];

                [self.windowSwitcher completeSwitching];
                [self stopAltReleasePoll];
            } else {
                if ([self.altKeycodes containsObject:@(event->detail)]) {
                } else if (event->detail == self.tabKeycode) {
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
        xcb_connection_t *conn = [self.connection connection];
        xcb_ungrab_keyboard(conn, XCB_CURRENT_TIME);
        [self.connection flush];

        [self.windowSwitcher completeSwitching];
        [self stopAltReleasePoll];
    }
}

@end

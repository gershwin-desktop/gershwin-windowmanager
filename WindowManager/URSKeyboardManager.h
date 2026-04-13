//
//  URSKeyboardManager.h
//  uroswm - Keyboard Grab Management for Alt-Tab
//
//  Handles keyboard grabbing, key press/release events for Alt-Tab window
//  switching, alt-keycode caching, and robust alt-release polling.
//

#import <Foundation/Foundation.h>
#import "XCBConnection.h"
#import "URSWindowSwitcher.h"

@interface URSKeyboardManager : NSObject

@property (weak, nonatomic) XCBConnection *connection;
@property (weak, nonatomic) URSWindowSwitcher *windowSwitcher;
@property (assign, nonatomic) BOOL altKeyPressed;
@property (assign, nonatomic) BOOL shiftKeyPressed;

- (instancetype)initWithConnection:(XCBConnection *)connection
                    windowSwitcher:(URSWindowSwitcher *)windowSwitcher;

- (void)setupKeyboardGrabbing;
- (void)cleanupKeyboardGrabbing;
- (void)handleKeyPress:(xcb_key_press_event_t *)event;
- (void)handleKeyRelease:(xcb_key_release_event_t *)event;

@end

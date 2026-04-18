//
//  URSFocusManager.h
//  uroswm - Focus Tracking and Window Resolution
//
//  Manages which window has focus, resolves window/frame/titlebar/client
//  relationships, checks focusability, and reassigns focus after window removal.
//

#import <Foundation/Foundation.h>
#import "XCBConnection.h"
#import "XCBWindow.h"
#import "XCBFrame.h"
#import "XCBTitleBar.h"

@interface URSFocusManager : NSObject

@property (weak, nonatomic) XCBConnection *connection;
@property (weak, nonatomic) XCBWindow *selectionManagerWindow;
@property (assign, nonatomic) xcb_window_t lastFocusedWindowId;
@property (assign, nonatomic) xcb_window_t previousFocusedWindowId;

- (instancetype)initWithConnection:(XCBConnection *)connection
                   selectionWindow:(XCBWindow *)selectionWindow;

// Focus tracking
- (void)trackFocusGain:(xcb_window_t)clientWindowId;
- (void)ensureFocusAfterWindowRemoval:(xcb_window_t)removedClientId;
- (void)focusWindowDelayed:(XCBWindow *)clientWindow;
- (void)focusWindowAfterThemeApplied:(XCBWindow *)clientWindow;
- (void)focusNewlyMappedWindow:(XCBWindow *)clientWindow;
- (void)removeWindowFromRecentlyFocused:(NSNumber *)windowIdNum;

// Focusability queries
- (BOOL)isWindowFocusable:(XCBWindow *)window allowDesktop:(BOOL)allowDesktop;
- (xcb_window_t)anyFocusableWindowExcluding:(xcb_window_t)excludedId;
- (xcb_window_t)desktopWindowCandidateExcluding:(xcb_window_t)excludedId;
- (xcb_window_t)focusableWindowWithSamePidAs:(xcb_window_t)clientWindowId
                                  excluding:(xcb_window_t)excludedId;

// Window resolution utilities (frame/titlebar/client lookups)
- (XCBWindow *)clientWindowForWindow:(XCBWindow *)window
                       fallbackFrame:(XCBFrame *)frame;
- (xcb_window_t)clientWindowIdForWindowId:(xcb_window_t)windowId;
- (XCBWindow *)windowForClientWindowId:(xcb_window_t)clientId;

@end

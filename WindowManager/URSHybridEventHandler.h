//
//  URSHybridEventHandler.h
//  uroswm - Event Coordinator
//
//  Created by Alessandro Sangiuliano on 22/06/20.
//  Copyright (c) 2020 Alessandro Sangiuliano. All rights reserved.
//
//  Coordinator: owns the XCB event loop and dispatches to single-responsibility
//  managers (focus, keyboard, workarea, titlebar, snapping menu).
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "XCBConnection.h"
#import "XCBWindow.h"
#import "XCBTitleBar.h"
#import "URSThemeIntegration.h"
#import "URSWindowSwitcher.h"
#import "URSWindowSwitcherOverlay.h"
#import "URSCompositingManager.h"
#import "URSFocusManager.h"
#import "URSKeyboardManager.h"
#import "URSWorkareaManager.h"
#import "URSTitlebarController.h"
#import "URSSnappingMenuController.h"

@interface URSHybridEventHandler : NSObject <NSApplicationDelegate, RunLoopEvents>

// XCB Integration
@property (strong, nonatomic) XCBConnection *connection;
@property (strong, nonatomic) XCBWindow *selectionManagerWindow;

// Event loop bookkeeping
@property (assign, nonatomic) BOOL xcbEventsIntegrated;
@property (assign, nonatomic) BOOL nsRunLoopActive;
@property (assign, nonatomic) NSUInteger eventCount;

// Window Switcher (Alt-Tab)
@property (strong, nonatomic) URSWindowSwitcher *windowSwitcher;

// Compositing Manager
@property (strong, nonatomic) URSCompositingManager *compositingManager;
@property (assign, nonatomic) BOOL compositingRequested;

// --- Single-responsibility managers ---
@property (strong, nonatomic) URSFocusManager *focusManager;
@property (strong, nonatomic) URSKeyboardManager *keyboardManager;
@property (strong, nonatomic) URSWorkareaManager *workareaManager;
@property (strong, nonatomic) URSTitlebarController *titlebarController;
@property (strong, nonatomic) URSSnappingMenuController *snappingMenuController;

// Window manager lifecycle
- (BOOL)registerAsWindowManager;
- (void)decorateExistingWindowsOnStartup;

// NSRunLoop integration
- (void)setupXCBEventIntegration;
- (void)processXCBEvent:(xcb_generic_event_t *)event;

// GSTheme integration
- (void)handleWindowCreated:(XCBTitleBar *)titlebar;
- (void)handleWindowFocusChanged:(XCBTitleBar *)titlebar isActive:(BOOL)active;
- (void)refreshAllManagedWindows;

// Cleanup
- (void)cleanupBeforeExit;

// ICCCM Manager Selection Protocol
- (void)handleSelectionClear:(xcb_selection_clear_event_t *)event;

@end
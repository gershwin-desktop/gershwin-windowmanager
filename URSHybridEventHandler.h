//
//  URSHybridEventHandler.h
//  uroswm - Phase 1: NSApplication + NSRunLoop Integration
//
//  Created by Alessandro Sangiuliano on 22/06/20.
//  Copyright (c) 2020 Alessandro Sangiuliano. All rights reserved.
//
//  Phase 1 Enhancement: NSApplication delegate that integrates XCB event handling
//  with NSRunLoop using file descriptor monitoring (following libs-back pattern).
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <XCBKit/XCBConnection.h>
#import <XCBKit/XCBWindow.h>
#import <XCBKit/XCBTitleBar.h>
#import "URSThemeIntegration.h"
#import "URSWindowSwitcher.h"

// Use GNUstep's existing RunLoopEventType and RunLoopEvents protocol
// (already defined in Foundation/NSRunLoop.h)

@interface URSHybridEventHandler : NSObject <NSApplicationDelegate, RunLoopEvents>

// XCB Integration Properties (same as original URSEventHandler)
@property (strong, nonatomic) XCBConnection* connection;
@property (strong, nonatomic) XCBWindow* selectionManagerWindow;

// Phase 1 Validation Properties
@property (assign, nonatomic) BOOL xcbEventsIntegrated;
@property (assign, nonatomic) BOOL nsRunLoopActive;
@property (assign, nonatomic) NSUInteger eventCount;

// Window Switcher (Alt-Tab)
@property (strong, nonatomic) URSWindowSwitcher* windowSwitcher;
@property (assign, nonatomic) BOOL altKeyPressed;
@property (assign, nonatomic) BOOL shiftKeyPressed;

// Original URSEventHandler methods (preserved for compatibility)
- (BOOL)registerAsWindowManager;
- (void)decorateExistingWindowsOnStartup;

// New NSRunLoop Integration methods
- (void)setupXCBEventIntegration;
- (void)processXCBEvent:(xcb_generic_event_t*)event;

// NEW: GSTheme Integration methods
- (void)handleWindowCreated:(XCBTitleBar*)titlebar;
- (void)handleWindowFocusChanged:(XCBTitleBar*)titlebar isActive:(BOOL)active;
- (void)refreshAllManagedWindows;

// Cleanup methods
- (void)cleanupBeforeExit;

// ICCCM Manager Selection Protocol - Being Replaced
- (void)handleSelectionClear:(xcb_selection_clear_event_t*)event;

// Keyboard event handling for Alt-Tab
- (void)setupKeyboardGrabbing;
- (void)handleKeyPressEvent:(xcb_key_press_event_t*)event;
- (void)handleKeyReleaseEvent:(xcb_key_release_event_t*)event;

@end
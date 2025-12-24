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

// Original URSEventHandler methods (preserved for compatibility)
- (void)registerAsWindowManager;

// New NSRunLoop Integration methods
- (void)setupXCBEventIntegration;
- (void)processXCBEvent:(xcb_generic_event_t*)event;

// NEW: GSTheme Integration methods
- (void)handleWindowCreated:(XCBTitleBar*)titlebar;
- (void)handleWindowFocusChanged:(XCBTitleBar*)titlebar isActive:(BOOL)active;
- (void)refreshAllManagedWindows;


@end
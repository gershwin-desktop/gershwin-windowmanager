//
//  main.m
//  uroswm - Phase 1: NSApplication + NSRunLoop Integration
//
//  Created by Alessandro Sangiuliano on 22/06/20.
//  Copyright (c) 2020 Alessandro Sangiuliano. All rights reserved.
//
//  Phase 1 Enhancement: Convert from Foundation-only blocking event loop
//  to NSApplication-based hybrid window manager with NSRunLoop integration.
//

#import <AppKit/AppKit.h>
#import "URSHybridEventHandler.h"
#import "UROSWMApplication.h"
#import "URSThemeIntegration.h"
#import <XCBKit/utils/XCBShape.h>
#import <XCBKit/services/TitleBarSettingsService.h>
#import <signal.h>
#import <string.h>

// Global reference to the event handler for signal handlers
static URSHybridEventHandler *globalEventHandler = nil;

// Signal handler for clean shutdown
static void signalHandler(int sig)
{
    const char *signame;
    switch (sig) {
        case SIGTERM: signame = "SIGTERM"; break;
        case SIGINT: signame = "SIGINT"; break;
        case SIGHUP: signame = "SIGHUP"; break;
        default: signame = "UNKNOWN"; break;
    }
    
    NSLog(@"[WindowManager] Received signal %d (%s), initiating clean shutdown...", sig, signame);
    
    if (globalEventHandler) {
        [globalEventHandler cleanupBeforeExit];
    }
    
    // Terminate the application
    [NSApp terminate:nil];
}

// Setup signal handlers for clean termination
static void setupSignalHandlers(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signalHandler;
    sigemptyset(&sa.sa_mask);
#ifdef SA_RESTART
    sa.sa_flags = SA_RESTART;
#else
    sa.sa_flags = 0;
#endif
    
    // Handle common termination signals
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    
    NSLog(@"[WindowManager] Signal handlers installed for clean shutdown");
}

int main(int argc, const char * argv[])
{
    @autoreleasepool {

        // Initialize TitleBar settings (same as before)
        TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
        [settings setHeight:25];
        XCBPoint closePosition = XCBMakePoint(3.5, 3.8);
        XCBPoint minimizePosition = XCBMakePoint(3, 8);
        XCBPoint maximizePosition = XCBMakePoint(3, 3);
        [settings setClosePosition:closePosition];
        [settings setMinimizePosition:minimizePosition];
        [settings setMaximizePosition:maximizePosition];

        // Initialize GSTheme for titlebar decorations
        NSLog(@"Initializing GSTheme titlebar integration...");
        [URSThemeIntegration initializeGSTheme];
        [URSThemeIntegration enableGSThemeTitleBars];

        // Create custom NSApplication and hybrid event handler
        UROSWMApplication *app = [UROSWMApplication sharedApplication];
        URSHybridEventHandler *hybridHandler = [[URSHybridEventHandler alloc] init];
        [app setDelegate:hybridHandler];
        
        // Store global reference for signal handlers
        globalEventHandler = hybridHandler;
        
        // Setup signal handlers for clean shutdown
        setupSignalHandlers();

        // Start NSApplication main loop (replaces blocking XCB event loop)
        [app run];
    }
    return 0;
}

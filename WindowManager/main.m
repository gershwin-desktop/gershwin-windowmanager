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
//  Wayland Mode: When --wayland is passed, uses GWLRiverWindowManager
//  to connect to River compositor instead of X11/XCB.
//

#import <AppKit/AppKit.h>
#import "URSHybridEventHandler.h"
#import "UROSWMApplication.h"
#import "URSThemeIntegration.h"
#ifdef WAYLAND_SUPPORT
#import "GWLRiverWindowManager.h"
#endif
#import <XCBKit/utils/XCBShape.h>
#import <XCBKit/services/TitleBarSettingsService.h>
#import <signal.h>
#import <string.h>

// Global reference to the event handler for signal handlers (X11 mode)
static URSHybridEventHandler *globalEventHandler = nil;
#ifdef WAYLAND_SUPPORT
// Global reference to Wayland mode handler for signal handlers
static GWLRiverWindowManager *globalWaylandManager = nil;
#endif

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
#ifdef WAYLAND_SUPPORT
    if (globalWaylandManager) {
        [globalWaylandManager cleanupBeforeExit];
    }
#endif
    
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
        
        // Parse command-line arguments
        BOOL enableCompositing = NO;
#ifdef WAYLAND_SUPPORT
        BOOL waylandMode = NO;
#endif
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "-c") == 0 || strcmp(argv[i], "--compositing") == 0) {
                enableCompositing = YES;
                NSLog(@"[WindowManager] Compositing mode enabled via command-line flag");
            } else if (strcmp(argv[i], "-w") == 0 || strcmp(argv[i], "--wayland") == 0) {
#ifdef WAYLAND_SUPPORT
                waylandMode = YES;
                NSLog(@"[WindowManager] Wayland mode enabled via command-line flag");
#else
                fprintf(stderr, "Wayland support not compiled in. Build with WAYLAND=1.\n");
                return 1;
#endif
            } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
                printf("WindowManager - Objective-C Window Manager\n");
                printf("Usage: %s [options]\n\n", argv[0]);
                printf("Options:\n");
                printf("  -c, --compositing    Enable XRender compositing (X11 mode, experimental)\n");
#ifdef WAYLAND_SUPPORT
                printf("  -w, --wayland        Run in Wayland mode (River compositor)\n");
#endif
                printf("  -h, --help          Show this help message\n\n");
                printf("Without compositing, windows render directly (traditional mode).\n");
                printf("With compositing, windows use XRender for transparency effects.\n");
                return 0;
            }
        }

#ifdef WAYLAND_SUPPORT
        if (waylandMode) {
            // ===== WAYLAND MODE =====
            NSLog(@"[WindowManager] Starting in Wayland mode (River compositor)");

            // Initialize GSTheme for titlebar decorations (shared with X11 mode)
            NSLog(@"Initializing GSTheme titlebar integration...");
            [URSThemeIntegration initializeGSTheme];
            [URSThemeIntegration enableGSThemeTitleBars];

            UROSWMApplication *app = [UROSWMApplication sharedApplication];
            GWLRiverWindowManager *waylandManager = [[GWLRiverWindowManager alloc] init];
            [app setDelegate:waylandManager];

            globalWaylandManager = waylandManager;
            setupSignalHandlers();

            [app run];
        } else
#endif
        {
            // ===== X11 MODE (original) =====

            // Store compositing preference in user defaults for access by event handler
            [[NSUserDefaults standardUserDefaults] setBool:enableCompositing 
                                                     forKey:@"URSCompositingEnabled"];

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
    }
    return 0;
}

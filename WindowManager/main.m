//
//  main.m
//  Originally based on uroswm by Alessandro Sangiuliano.
//  Copyright (c) 2020 Alessandro Sangiuliano. All rights reserved.
//

#import <AppKit/AppKit.h>
#import "URSHybridEventHandler.h"
#import "UROSWMApplication.h"
#import "URSThemeIntegration.h"
#import "XCBTypes.h"
#import "TitleBarSettingsService.h"
#import "URSProfiler.h"
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
        
        // Parse command-line arguments for compositing mode
        BOOL enableCompositing = YES;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "-dc") == 0 || strcmp(argv[i], "--disable-compositing") == 0) {
                enableCompositing = NO;
                NSLog(@"[WindowManager] Compositing mode disabled via command-line flag");
                break;
            } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
                printf("WindowManager - Objective-C Window Manager\n");
                printf("Usage: %s [options]\n\n", argv[0]);
                printf("Options:\n");
                printf("  -dc, --disable-compositing  Disable XRender compositing\n");
                printf("  -h, --help          Show this help message\n\n");
                printf("By default, windows use XRender compositing for transparency effects.\n");
                printf("Use -dc to force traditional direct rendering mode.\n");
                return 0;
            }
        }
        
        // Store compositing preference directly on the event handler
        UROSWMApplication *app = [UROSWMApplication sharedApplication];
        URSHybridEventHandler *hybridHandler = [[URSHybridEventHandler alloc] init];
        hybridHandler.compositingRequested = enableCompositing;

        // Initialize TitleBar settings - height will be queried from GSTheme below (source: AppearanceMetrics.h)
        TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
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

        // Set titlebar height from theme (authoritative source: AppearanceMetrics.h in Eau theme)
        {
            GSTheme *theme = [GSTheme theme];
            uint16_t themeHeight = [theme respondsToSelector:@selector(titlebarHeight)]
                ? (uint16_t)[theme titlebarHeight]
                : 22;
            [settings setHeight:themeHeight];
        }

        [app setDelegate:hybridHandler];
        
        // Store global reference for signal handlers
        globalEventHandler = hybridHandler;
        
        // Setup signal handlers for clean shutdown
        setupSignalHandlers();

        // Install profiling signal handler (SIGUSR1 dumps stats)
        ursProfileInstallSignalHandler();

        // Start NSApplication main loop (replaces blocking XCB event loop)
        [app run];
    }
    return 0;
}

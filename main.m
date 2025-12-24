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

        // Start NSApplication main loop (replaces blocking XCB event loop)
        [app run];
    }
    return 0;
}

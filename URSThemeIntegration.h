//
//  URSThemeIntegration.h
//  uroswm - GSTheme Window Decoration for Titlebars
//
//  Renders actual GSTheme window decorations for X11 titlebars to match AppKit appearance.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#import <XCBKit/XCBTitleBar.h>
#import <XCBKit/XCBFrame.h>
#import <XCBKit/enums/ETitleBarColor.h>

@interface URSThemeIntegration : NSObject

// Singleton access
+ (instancetype)sharedInstance;

// GSTheme initialization and management
+ (void)initializeGSTheme;
+ (GSTheme*)currentTheme;

// Enable GSThemeTitleBar replacement for all XCBTitleBar instances
+ (void)enableGSThemeTitleBars;

// Main titlebar rendering with GSTheme decorations
+ (BOOL)renderGSThemeTitlebar:(XCBTitleBar*)titlebar
                        title:(NSString*)title
                       active:(BOOL)isActive;

// Standalone GSTheme titlebar rendering (bypasses XCBTitleBar entirely)
+ (BOOL)renderGSThemeToWindow:(XCBWindow*)window
                        frame:(XCBFrame*)frame
                        title:(NSString*)title
                       active:(BOOL)isActive;

// Disable XCBTitleBar drawing by overriding its draw methods
+ (void)disableXCBTitleBarDrawing:(XCBTitleBar*)titlebar;

// Refresh all titlebars with current theme
+ (void)refreshAllTitlebars;

// Event handlers
- (void)handleWindowCreated:(XCBTitleBar*)titlebar;
- (void)handleWindowFocusChanged:(XCBTitleBar*)titlebar isActive:(BOOL)active;

// Configuration
@property (assign, nonatomic) BOOL enabled;
@property (strong, nonatomic) NSMutableArray *managedTitlebars;

@end
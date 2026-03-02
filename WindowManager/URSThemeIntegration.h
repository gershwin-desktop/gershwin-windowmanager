//
//  URSThemeIntegration.h
//  uroswm - GSTheme Window Decoration for Titlebars
//
//  Renders actual GSTheme window decorations for X11 titlebars to match AppKit appearance.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#import <xcb/xcb.h>
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

// Fixed-size window tracking (for hiding buttons except close)
+ (void)registerFixedSizeWindow:(xcb_window_t)windowId;
+ (void)unregisterFixedSizeWindow:(xcb_window_t)windowId;
+ (BOOL)isFixedSizeWindow:(xcb_window_t)windowId;

// Hover state tracking for titlebar buttons
+ (xcb_window_t)hoveredTitlebarWindow;
+ (NSInteger)hoveredButtonIndex;
+ (void)setHoveredTitlebar:(xcb_window_t)titlebarId buttonIndex:(NSInteger)buttonIdx;
+ (void)clearHoverState;

// Determine which button (if any) is at a given coordinate
// Returns: 0=close, 1=mini, 2=zoom, -1=none
// Side-by-side layout: Close (X) on left | title | Minimize (-) | Maximize (+) on right
+ (NSInteger)buttonIndexAtX:(CGFloat)x forWidth:(CGFloat)width hasMaximize:(BOOL)hasMax;
+ (NSInteger)buttonIndexAtX:(CGFloat)x y:(CGFloat)y forWidth:(CGFloat)width height:(CGFloat)height hasMaximize:(BOOL)hasMax;

// Orb button style detection (reads EauTitleBarButtonStyle preference)
+ (BOOL)isOrbButtonStyle;

@end
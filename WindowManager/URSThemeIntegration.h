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
#import "XCBTitleBar.h"
#import "XCBFrame.h"
#import "ETitleBarColor.h"

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

// Refresh all titlebars with current theme, using the given focused client window
// to determine which titlebar should appear active.
+ (void)refreshAllTitlebarsWithFocusedWindow:(xcb_window_t)focusedClientId;

// Reset the cached GSScaleFactor used for titlebar drawing constants, so the
// next render picks up a live scale-factor change.
+ (void)invalidateScaleFactorCache;

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

// Buttons a frame's titlebar shows, as an NSWindow style mask
+ (NSUInteger)buttonStyleMaskForFrame:(XCBFrame *)frame;

// Determine which button (if any) is at a point in titlebar coordinates
// (X11, origin top left). Returns: 0=close, 1=mini, 2=zoom, -1=none
+ (NSInteger)buttonIndexAtPoint:(NSPoint)point
                   titlebarSize:(NSSize)size
                      styleMask:(NSUInteger)styleMask;
// Same, for the titlebar of frame (which may be nil)
+ (NSInteger)buttonIndexAtPoint:(NSPoint)point
                   titlebarSize:(NSSize)size
                          frame:(XCBFrame *)frame;

// YES when the theme draws the titlebar buttons itself, so the window manager
// must not overlay its edge buttons
+ (BOOL)themeDrawsTitlebarButtons;

// Width of the window border the theme draws around the client, 0 for none
+ (CGFloat)frameBorderWidth;
// Paint that border on the frame window, and repaint it with the state last
// painted (after the frame was cleared, e.g. on expose or resize)
+ (void)paintFrameBorder:(XCBFrame *)frame active:(BOOL)active;
+ (void)repaintFrameBorder:(XCBFrame *)frame;
// Let go of what was kept for a frame's border once the frame is gone
+ (void)forgetFrameBorder:(XCBWindow *)window;

// Slot of a theme-drawn button in theme drawing coordinates (origin bottom
// left); NSZeroRect when styleMask has no such button
+ (NSRect)themeButtonRect:(NSInteger)buttonIndex
             titlebarSize:(NSSize)size
                styleMask:(NSUInteger)styleMask;

@end
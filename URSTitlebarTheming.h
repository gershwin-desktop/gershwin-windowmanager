//
//  URSTitlebarTheming.h
//  uroswm - Simple Titlebar Color Integration
//
//  Provides NSColor-based theming for XCBTitleBar without complex GSTheme integration.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <XCBKit/XCBTitleBar.h>

@interface URSTitlebarTheming : NSObject

// Simple color extraction from system
+ (NSColor*)systemTitlebarBackgroundColor;
+ (NSColor*)systemTitlebarTextColor;
+ (NSColor*)systemTitlebarActiveColor;
+ (NSColor*)systemTitlebarInactiveColor;

// Convert NSColor to XCBColor for XCBTitleBar
+ (XCBColor)xcbColorFromNSColor:(NSColor*)nsColor;

// Apply system colors to XCBTitleBar
+ (void)applySystemColorsToTitlebar:(XCBTitleBar*)titlebar active:(BOOL)isActive;

// Update all titlebars when system appearance changes
+ (void)refreshAllTitlebarsWithSystemColors;

@end
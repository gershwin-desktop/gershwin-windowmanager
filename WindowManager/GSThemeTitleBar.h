//
//  GSThemeTitleBar.h
//  uroswm - GSTheme-based TitleBar Replacement
//
//  A complete replacement for XCBTitleBar that uses GSTheme for all rendering
//  instead of Cairo graphics. Provides authentic AppKit window decorations.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#import "XCBTitleBar.h"

// Button types for hit detection
typedef NS_ENUM(NSInteger, GSThemeTitleBarButton) {
    GSThemeTitleBarButtonNone = 0,
    GSThemeTitleBarButtonMiniaturize,
    GSThemeTitleBarButtonClose,
    GSThemeTitleBarButtonZoom
};

@interface GSThemeTitleBar : XCBTitleBar

// Override XCBTitleBar drawing methods to use GSTheme
- (void)drawTitleBarForColor:(TitleBarColor)aColor;
- (void)drawArcsForColor:(TitleBarColor)aColor;
- (void)drawTitleBarComponents;
- (void)drawTitleBarComponentsPixmaps;

// GSTheme-specific rendering methods
- (void)renderWithGSTheme:(BOOL)isActive;
- (NSImage*)createGSThemeImage:(NSSize)size title:(NSString*)title active:(BOOL)isActive;
- (void)transferGSThemeImageToPixmap:(NSImage*)image;

// Helper methods
- (GSTheme*)currentTheme;
- (NSUInteger)windowStyleMask;
- (GSThemeControlState)themeStateForActive:(BOOL)isActive;

// Button hit detection - returns which button was clicked at the given coordinates
- (GSThemeTitleBarButton)buttonAtPoint:(NSPoint)point;

@end
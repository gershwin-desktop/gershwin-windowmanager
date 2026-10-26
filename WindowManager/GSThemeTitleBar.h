//
//  GSThemeTitleBar.h
//  uroswm - GSTheme-based TitleBar Replacement
//
//  A complete replacement for XCBTitleBar that uses GSTheme for all rendering
//  using AppKit/GNUstep drawing. Provides authentic window decorations.
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

// Maps URSThemeIntegration button indices (0=close, 1=mini, 2=zoom, -1=none)
static inline GSThemeTitleBarButton GSThemeTitleBarButtonForIndex(NSInteger index)
{
    switch (index) {
        case 0: return GSThemeTitleBarButtonClose;
        case 1: return GSThemeTitleBarButtonMiniaturize;
        case 2: return GSThemeTitleBarButtonZoom;
        default: return GSThemeTitleBarButtonNone;
    }
}

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
- (int)titleBarInputStateForActive:(BOOL)isActive;

// Button hit detection - returns which button was clicked at the given coordinates
- (GSThemeTitleBarButton)buttonAtPoint:(NSPoint)point;

@end
//
//  URSSnapPreviewOverlay.h
//  uroswm - Window Snap Preview Overlay
//
//  Shows a semi-transparent preview of where a window will snap
//  when dragged to screen edges (top = maximize, left/right = half)
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@interface URSSnapPreviewOverlay : NSWindow

// Singleton access
+ (instancetype)sharedOverlay;

// Display management
- (void)showPreviewForRect:(NSValue *)rectValue;
- (void)hide;

@end

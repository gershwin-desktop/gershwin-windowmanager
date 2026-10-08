//
//  URSSnappingMenuController.h
//  uroswm - Titlebar Right-Click Snapping Context Menu
//
//  Manages the right-click context menu on titlebars for snapping operations
//  (center, maximize vertically/horizontally, snap to corners/sides).
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "XCBConnection.h"
#import "XCBFrame.h"

@class URSFlipSideController;

@interface URSSnappingMenuController : NSObject

@property (weak, nonatomic) XCBConnection *connection;
// "Flip Window" turns the window through it, so the back can show its flip
// side.
@property (weak, nonatomic) URSFlipSideController *flipSideController;
@property (strong, nonatomic) NSMenu *activeMenu;

- (instancetype)initWithConnection:(XCBConnection *)connection;

// Returns YES if a menu was dismissed (caller should skip further processing)
- (BOOL)dismissIfActive;

// Show the snapping context menu (called with deferred perform)
- (void)showSnappingContextMenuForFrame:(XCBFrame *)frame
                            atX11Point:(NSPoint)x11Point;

@end

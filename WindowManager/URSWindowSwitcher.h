//
//  URSWindowSwitcher.h
//  uroswm - Alt-Tab Window Switching
//
//  Created for implementing Alt-Tab and Shift-Alt-Tab functionality
//
//  Manages window cycling and focus switching for keyboard navigation
//  Includes support for minimized windows and visual overlay
//

#import <Foundation/Foundation.h>
#import "XCBConnection.h"
#import "XCBWindow.h"
#import "XCBFrame.h"
#import "URSWindowSwitcherOverlay.h"

// Window entry to track original minimized state
@interface URSWindowEntry : NSObject
@property (strong, nonatomic) XCBFrame *frame;
@property (assign, nonatomic) BOOL wasMinimized;        // Was minimized when Alt-Tab started
@property (assign, nonatomic) BOOL temporarilyShown;    // Currently shown during cycling
@property (strong, nonatomic) NSString *title;
@property (strong, nonatomic) NSImage *icon;
@end

@interface URSWindowSwitcher : NSObject

@property (strong, nonatomic) XCBConnection *connection;
@property (strong, nonatomic) NSMutableArray *windowEntries;   // Array of URSWindowEntry
@property (assign, nonatomic) NSInteger currentIndex;          // Current position during switching
@property (assign, nonatomic) BOOL isSwitching;               // Whether we're in the middle of switching
@property (strong, nonatomic) URSWindowSwitcherOverlay *overlay;  // Visual overlay

// Singleton access
+ (instancetype)sharedSwitcherWithConnection:(XCBConnection *)connection;

// Window stack management
- (void)updateWindowStack;
- (void)addWindowToStack:(XCBFrame *)frame;
- (void)removeWindowFromStack:(XCBFrame *)frame;

// Window state checking and manipulation
- (BOOL)isWindowMinimized:(XCBFrame *)frame;
- (void)minimizeWindow:(XCBFrame *)frame;
- (void)unminimizeWindow:(XCBFrame *)frame;
- (NSString *)getTitleForFrame:(XCBFrame *)frame;
- (NSImage *)getIconForFrame:(XCBFrame *)frame;
- (NSImage *)convertNetWmIconData:(uint32_t *)iconData width:(int)width height:(int)height;

// Switching operations
- (void)startSwitching;
- (void)cycleForward;
- (void)cycleBackward;
- (void)completeSwitching;
- (void)cancelSwitching;

@end

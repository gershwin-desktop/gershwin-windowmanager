//
//  URSTitlebarController.h
//  uroswm - Titlebar Interaction Controller
//
//  Handles titlebar button hit-testing, hover state, button press actions
//  (close/minimize/maximize), and resize-during-motion rendering updates.
//

#import <Foundation/Foundation.h>
#import "XCBConnection.h"
#import "XCBFrame.h"
#import "XCBTitleBar.h"
#import "GSThemeTitleBar.h"
#import "URSWorkareaManager.h"

@class URSCompositingManager;

@interface URSTitlebarController : NSObject

@property (weak, nonatomic) XCBConnection *connection;
@property (weak, nonatomic) URSCompositingManager *compositingManager;
@property (weak, nonatomic) URSWorkareaManager *workareaManager;

- (instancetype)initWithConnection:(XCBConnection *)connection;

// Button press handling (returns YES if the event was consumed)
- (BOOL)handleTitlebarButtonPress:(xcb_button_press_event_t *)pressEvent;

// Button hit detection
- (GSThemeTitleBarButton)buttonAtPoint:(NSPoint)point
                          forTitlebar:(XCBTitleBar *)titlebar;

// Hover handling during motion
- (void)handleHoverDuringMotion:(xcb_motion_notify_event_t *)motionEvent;
- (void)handleTitlebarLeave:(xcb_leave_notify_event_t *)leaveEvent;

// Resize rendering
- (void)handleResizeDuringMotion:(xcb_motion_notify_event_t *)motionEvent;
- (void)handleResizeComplete:(xcb_button_release_event_t *)releaseEvent;

// Focus-change rendering
- (void)rerenderTitlebarForFrame:(XCBFrame *)frame active:(BOOL)isActive;

@end

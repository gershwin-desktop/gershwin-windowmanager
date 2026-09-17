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
@class URSFocusManager;

@interface URSTitlebarController : NSObject

@property (weak, nonatomic) XCBConnection *connection;
@property (weak, nonatomic) URSCompositingManager *compositingManager;
@property (weak, nonatomic) URSFocusManager *focusManager;
@property (weak, nonatomic) URSWorkareaManager *workareaManager;

// Double-click detection on the empty titlebar area (WindowShade toggle).
// Uses wall-clock time: X server timestamps are unreliable for this
// (XTEST/synthetic input may repeat identical stamps).
// Distance is checked in ROOT coordinates: titlebar-relative coordinates are
// identical whenever the cursor grabs the same spot, which made two quick
// consecutive window drags look like a double-click.
@property (assign, nonatomic) NSTimeInterval lastTitleClickWallTime;
@property (assign, nonatomic) xcb_timestamp_t lastTitleClickXTime;
@property (assign, nonatomic) int16_t lastTitleClickRootX;
@property (assign, nonatomic) int16_t lastTitleClickRootY;
@property (strong, nonatomic) XCBFrame *lastTitleClickFrame;

// Content-activity spinner engine: 10 fps tick that drives the titlebar
// spinners of frames whose client content changed within the last 2 s.
// Started on demand (first activity notification), stops when idle.
@property (strong, nonatomic) NSTimer *spinnerTimer;

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

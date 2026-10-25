//
//  URSWorkareaManager.h
//  uroswm - ICCCM/EWMH Strut and Workarea Management
//
//  Tracks _NET_WM_STRUT and _NET_WM_STRUT_PARTIAL properties from dock windows,
//  calculates the usable workarea, and updates _NET_WORKAREA on the root window.
//

#import <Foundation/Foundation.h>
#import "XCBConnection.h"

@interface URSWorkareaManager : NSObject <XCBMonitorAreas>

@property (weak, nonatomic) XCBConnection *connection;

- (instancetype)initWithConnection:(XCBConnection *)connection;

- (void)handleStrutPropertyChange:(xcb_property_notify_event_t *)event;
- (BOOL)readAndRegisterStrutForWindow:(xcb_window_t)windowId;
- (BOOL)removeStrutForWindow:(xcb_window_t)windowId;
- (void)recalculateWorkarea;
- (void)pushExistingWindowsBelowWorkarea;
// The _NET_WORKAREA rectangle: the screen minus the struts on its edges.
- (NSRect)currentWorkarea;

// The lit monitors (NSValue rects, screen coordinates) and which of them is
// the RandR primary; set after every display change.  Without them the
// whole screen counts as one monitor.
@property (copy, nonatomic) NSArray *monitors;
@property (assign, nonatomic) NSUInteger primaryMonitorIndex;
// The monitors, or the whole screen when none are known.
- (NSArray *)effectiveMonitors;
// Each monitor minus the struts that belong to it, in -effectiveMonitors order.
- (NSArray *)usableMonitorRects;
// The usable rect of the monitor `rect` overlaps most, else of the primary.
- (NSRect)usableRectForRect:(NSRect)rect;
- (NSRect)usableRectOfPrimaryMonitor;
// The whole monitor `rect` overlaps most, else the primary.
- (NSRect)monitorRectForRect:(NSRect)rect;
// A normal framed window the WM may move: not fullscreen, not a dock, menu,
// desktop or other special type.
- (BOOL)isRelocatableFrame:(XCBWindow *)window;

@end

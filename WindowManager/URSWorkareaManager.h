//
//  URSWorkareaManager.h
//  uroswm - ICCCM/EWMH Strut and Workarea Management
//
//  Tracks _NET_WM_STRUT and _NET_WM_STRUT_PARTIAL properties from dock windows,
//  calculates the usable workarea, and updates _NET_WORKAREA on the root window.
//

#import <Foundation/Foundation.h>
#import "XCBConnection.h"

@interface URSWorkareaManager : NSObject

@property (weak, nonatomic) XCBConnection *connection;

- (instancetype)initWithConnection:(XCBConnection *)connection;

- (void)handleStrutPropertyChange:(xcb_property_notify_event_t *)event;
- (BOOL)readAndRegisterStrutForWindow:(xcb_window_t)windowId;
- (BOOL)removeStrutForWindow:(xcb_window_t)windowId;
- (void)recalculateWorkarea;
- (NSRect)currentWorkarea;

@end

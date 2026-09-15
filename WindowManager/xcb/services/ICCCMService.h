//
//  Pova.h
//  XCBKit
//
//  Created by Alessandro Sangiuliano on 12/04/20.
//  Copyright (c) 2020 alex. All rights reserved.
//

#import "EWMHService.h"
#include <xcb/xcb_icccm.h>

@interface ICCCMService : EWMHService

@property (strong, nonatomic) NSArray* atomsArray;
@property (strong, nonatomic) NSString* WMDeleteWindow;
@property (strong, nonatomic) NSString* WMTakeFocus;
@property (strong, nonatomic) NSString* WMProtocols;
@property (strong, nonatomic) NSString* WMName;
@property (strong, nonatomic) NSString* WMNormalHints;
@property (strong, nonatomic) NSString* WMSizeHints;
@property (strong, nonatomic) NSString* WMState;
@property (strong, nonatomic) NSString* WMHints;
@property (strong, nonatomic) NSString* WMChangeState;
@property (strong, nonatomic) NSString* WMClass;

+ (id) sharedInstanceWithConnection:(XCBConnection*)aConnection;

- (id) initWithConnection:(XCBConnection*) aConnection;
- (BOOL)hasProtocol:(NSString*)protocol forWindow:(XCBWindow*)window;
- (xcb_size_hints_t*) wmNormalHintsForWindow:(XCBWindow*)aWindow;
/* YES when the application set the window's screen coordinates itself
   (WM_NORMAL_HINTS USPosition, or PPosition with a non-origin position).
   Such windows must be mapped at their requested location — the window
   manager must not apply cascade/centering placement on top of them.
   Placement-policy exception handled at the call sites: a position that
   would put the window's bottom-left corner into the screen's bottom-left
   corner ((0,0) in the app's bottom-left-origin coordinates) is the
   "no real position" default and is cascaded instead. */
- (BOOL)windowSpecifiesPosition:(XCBWindow*)aWindow;
- (void)updateWMNormalHints:(xcb_size_hints_t*)sizeHints forWindow:(XCBWindow*)aWindow;
- (NSString*) getWmNameForWindow:(XCBWindow*)aWindow;
- (xcb_icccm_wm_hints_t) wmHintsFromWindow:(XCBWindow*)aWindow;
- (void) setWMStateForWindow:(XCBWindow*)aWindow state:(WindowState)state;
- (WindowState) wmStateFromWindow:(XCBWindow*)aWindow;
- (void) wmClassForWindow:(XCBWindow*)aWindow;


@end

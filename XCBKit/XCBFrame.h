//
//  XCBFrame.h
//  XCBKit
//
//  Created by Alessandro Sangiuliano on 05/08/19.
//  Copyright (c) 2019 alex. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "XCBWindow.h"
#import "XCBConnection.h"
#import "enums/EMousePosition.h"
#import "enums/EResizeDirection.h"


#define WM_MIN_WINDOW_HEIGHT 431
#define WM_MIN_WINDOW_WIDTH 496

typedef NS_ENUM(NSInteger, childrenMask)
{
    TitleBar = 0,
    ClientWindow = 1,
    ResizeHandle = 2,    // Legacy (keep for backwards compatibility)
    ResizeZoneNW = 10,
    ResizeZoneN = 11,
    ResizeZoneNE = 12,
    ResizeZoneE = 13,
    ResizeZoneSE = 14,
    ResizeZoneS = 15,
    ResizeZoneSW = 16,
    ResizeZoneW = 17,
    ResizeZoneGrowBox = 18  // Theme-defined grow box overlay
};

@interface XCBFrame : XCBWindow
{
    NSMutableDictionary *children;
}

@property (nonatomic, assign) int minHeightHint;
@property (nonatomic, assign) int minWidthHint;
@property (nonatomic, assign) uint16_t titleHeight;
@property (strong, nonatomic) XCBConnection *connection;
@property (nonatomic, assign) BOOL rightBorderClicked;
@property (nonatomic, assign) BOOL bottomBorderClicked;
@property (nonatomic, assign) BOOL leftBorderClicked;
@property (nonatomic, assign) BOOL topBorderClicked;
@property (nonatomic, assign) XCBPoint offset;

- (id) initWithClientWindow:(XCBWindow*) aClientWindow withConnection:(XCBConnection*) aConnection;
- (id) initWithClientWindow:(XCBWindow*) aClientWindow
             withConnection:(XCBConnection*) aConnection
              withXcbWindow:(xcb_window_t) xcbWindow
                   withRect:(XCBRect)aRect;

- (void) addChildWindow:(XCBWindow*) aChild withKey:(childrenMask) keyMask;
- (XCBWindow*) childWindowForKey:(childrenMask) key;
- (void) removeChild:(childrenMask) frameChild;
- (void) resize:(xcb_motion_notify_event_t *)anEvent xcbConnection:(xcb_connection_t*)aXcbConnection;
- (void) moveTo:(XCBPoint)coordinates;
- (void) configureClient;
- (void) configureClientWithFramePosition:(XCBPoint)framePos clientSize:(XCBSize)clientSize;
- (MousePosition) mouseIsOnWindowBorderForEvent:(xcb_motion_notify_event_t *)anEvent;
- (void) restoreDimensionAndPosition;
- (void) createResizeHandle;
- (void) updateResizeHandlePosition;
- (void) raiseResizeHandle;
- (void) applyRoundedCornersShapeMask;
- (void) programmaticResizeToRect:(XCBRect)targetRect;

// Theme-driven resize zones
- (void) createResizeZonesFromTheme;
- (void) updateAllResizeZonePositions;
- (void) destroyResizeZones;


 /********************************
 *                               *
 *            ACCESSORS          *
 *                               *
 ********************************/

- (void) setChildren:(NSMutableDictionary*) aChildrenSet;
- (NSMutableDictionary*) getChildren;
- (void) decorateClientWindow;

@end

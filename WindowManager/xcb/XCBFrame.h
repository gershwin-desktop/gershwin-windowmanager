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
#import "EMousePosition.h"
#import "EResizeDirection.h"


#define WM_MIN_WINDOW_HEIGHT 431
#define WM_MIN_WINDOW_WIDTH 496

// Absolute minimum client area — prevents windows from collapsing to just the titlebar.
// These are enforced even when the client doesn't set WM_NORMAL_HINTS.
#define WM_MIN_CLIENT_HEIGHT 100
#define WM_MIN_CLIENT_WIDTH  100

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

// Posted (rarely - only on the stale-to-active transition) when a frame's
// client content started changing after being idle; wakes the spinner engine.
extern NSString *URSWindowTitleContentChangedNotification;

@interface XCBFrame : XCBWindow
{
    NSMutableDictionary *children;
}

@property (nonatomic, assign) int minHeightHint;
@property (nonatomic, assign) int minWidthHint;
@property (nonatomic, assign) uint16_t titleHeight;
@property (strong, nonatomic) XCBConnection *connection;
// clientBorder: pixels inset around the client area (1 = thin border, 0 = flush in compositor mode)
@property (nonatomic, assign) int clientBorder;
@property (nonatomic, assign) BOOL rightBorderClicked;
@property (nonatomic, assign) BOOL bottomBorderClicked;
@property (nonatomic, assign) BOOL leftBorderClicked;
@property (nonatomic, assign) BOOL topBorderClicked;
/* Set while a close animation is in flight; handleUnMapNotify: skips the
 * frame teardown until the animation completes (so the compositor can render
 * the shrink/fade over the still-mapped window). */
@property (nonatomic, assign) BOOL closeAnimating;
/* Close-animation parameters carried from the Workspace close message until
 * the client's UnmapNotify starts the animation.  The message only prepares
 * (captures a snapshot while the client is still mapped); the unmap event is
 * what triggers the shrink/fade, mirroring how KDE fades windows on unmap. */
@property (nonatomic, assign) int32_t closeAnimationType;
@property (nonatomic, assign) XCBRect closeAnimationTargetRect;
@property (nonatomic, assign) BOOL closeAnimationPrepared;
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
- (void) clearShapeMasks;
- (void) programmaticResizeToRect:(XCBRect)targetRect;

// WindowShade: roll the window up into its titlebar (double-click or
// _NET_WM_STATE_SHADED).  The client stays mapped and untouched - it is only
// clipped by the smaller parent frame.
- (void) shade;
- (void) unshade;
- (void) toggleShade;
@property (nonatomic, assign) BOOL shadeAnimationInProgress;

// Timestamp of the most recent damage on this frame's CLIENT content.
// The client stays mapped and rendering while shaded, so this keeps
// advancing even when the content is hidden - it drives the titlebar
// activity spinner.  0 = never damaged since map.
@property (nonatomic, assign) NSTimeInterval lastContentChange;
- (void) noteContentChanged;

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

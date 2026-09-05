//
//  URSCompositingManager.h
//  uroswm - XRender Compositing Manager
//
//  Provides optional XRender-based compositing for window transparency and effects.
//  Uses defensive coding with fallback to non-compositing mode on any errors.
//  Enabled by default; can be disabled with --disable-compositing.
//

#import <Foundation/Foundation.h>
#import "XCBConnection.h"
#import "XCBTypes.h"
#import <xcb/randr.h>

// Replaces <dispatch/dispatch.h> dispatch_block_t without linking libdispatch
typedef void (^dispatch_block_t)(void);

@interface URSCompositingManager : NSObject

// Singleton access
+ (instancetype)sharedManager;

// Compositing state
@property (readonly, nonatomic) BOOL compositingEnabled;
@property (readonly, nonatomic) BOOL compositingActive;

// Initialize compositing (must be called before activation)
- (BOOL)initializeWithConnection:(XCBConnection *)connection;

// Activate/deactivate compositing
// Returns YES on success, NO on failure (falls back to non-compositing)
- (BOOL)activateCompositing;
- (void)deactivateCompositing;

// Window management for compositing
- (void)registerWindow:(xcb_window_t)window;
- (void)unregisterWindow:(xcb_window_t)window;
- (void)updateWindow:(xcb_window_t)window;

// Window state changes
- (void)mapWindow:(xcb_window_t)window;
- (void)unmapWindow:(xcb_window_t)window;
- (void)moveWindow:(xcb_window_t)windowId x:(int16_t)x y:(int16_t)y;
- (void)resizeWindow:(xcb_window_t)windowId x:(int16_t)x y:(int16_t)y 
               width:(uint16_t)width height:(uint16_t)height;
// Drain a window's pending damage and schedule a repaint of its extents.
// The window picture is a live view of the drawable, so there is no cached
// pixmap to re-acquire; this only flushes stale damage state and makes sure
// the area is composited on the next paint pass.
- (void)invalidateWindowPixmap:(xcb_window_t)windowId;

// OPTIMIZATION: Notify compositor that stacking order changed (window raised/lowered)
- (void)markStackingOrderDirty;

// Per-window variant: a raise/lower in place only changes pixels inside the
// restacked window's own extents, so only those are damaged instead of the
// whole screen.  Falls back to the debounced full-screen pass when the
// window is unknown, unviewable or unredirected.
- (void)markStackingOrderDirtyForWindow:(xcb_window_t)windowId;

// Window animations (compositing-only)
- (void)animateWindowMinimize:(xcb_window_t)windowId
                                         fromRect:(XCBRect)startRect
                                             toRect:(XCBRect)endRect;
- (void)animateWindowMinimize:(xcb_window_t)windowId
                                         fromRect:(XCBRect)startRect
                                             toRect:(XCBRect)endRect
                                         completion:(void (^)(void))completion;
- (void)animateWindowRestore:(xcb_window_t)windowId
                                        fromRect:(XCBRect)startRect
                                            toRect:(XCBRect)endRect;
- (void)animateWindowTransition:(xcb_window_t)windowId
                                                fromRect:(XCBRect)startRect
                                                    toRect:(XCBRect)endRect
                                                duration:(NSTimeInterval)duration
                                                        fade:(BOOL)fade;
- (void)animateWindowTransition:(xcb_window_t)windowId
                                                fromRect:(XCBRect)startRect
                                                    toRect:(XCBRect)endRect
                                                duration:(NSTimeInterval)duration
                                                        fade:(BOOL)fade
                                                 completion:(void (^)(void))completion;
- (void)animateWindowShrink:(xcb_window_t)windowId
                   fromRect:(XCBRect)startRect
                     toRect:(XCBRect)endRect
                   duration:(NSTimeInterval)duration;
- (void)animateWindowShrink:(xcb_window_t)windowId
                   fromRect:(XCBRect)startRect
                     toRect:(XCBRect)endRect
                   duration:(NSTimeInterval)duration
                 completion:(void (^)(void))completion;

// Non-compositing zoom rect animation (outline-based, fast)
+ (void)animateZoomRectsFromRect:(XCBRect)startRect
                          toRect:(XCBRect)endRect
                      connection:(XCBConnection *)connection
                          screen:(xcb_screen_t *)screen
                        duration:(NSTimeInterval)duration;

// Force immediate repair without deferring to next runloop (use during interactive drag)
- (void)performRepairNow;

// True while a window (birth/close/minimize/restore/shrink) animation is in
// flight for the given frame.  Used by the spinner to ignore the WM's own
// repaints during an animation.
- (BOOL)windowIsAnimating:(xcb_window_t)windowId;

// Render the composite screen
- (void)compositeScreen;

// Schedule a throttled composite (preferred for event-driven updates)
- (void)scheduleComposite;

// Perform repair immediately without deferring (for critical updates like cursor blinking)
- (void)performRepairNow;

// Re-acquire and repaint one window's content right now.  Used by direct
// X-drawing animations (titlebar spinner) that bypass the damage pipeline.
- (void)repairRegionForWindow:(xcb_window_t)windowId;

// Mark a window to skip shadow rendering (e.g. snap preview overlay)
- (void)setSkipShadowForWindow:(xcb_window_t)windowId;
- (void)clearSkipShadowForWindow:(xcb_window_t)windowId;

// Fast check used by the event loop to avoid redundant performRepairNow calls
- (BOOL)hasPendingDamage;

// Damage the entire screen region (used after resize/expose to force full redraw)
- (void)damageScreen;

// Handle damage events
- (void)handleDamageNotify:(xcb_window_t)window
                                     area:(xcb_rectangle_t)area;

// Handle RANDR screen-change events
- (void)handleScreenChange:(xcb_randr_screen_change_notify_event_t *)event;
- (void)handleScreenSizeChange:(uint16_t)newW height:(uint16_t)newH;

// Handle expose events - forces pixmap recreation for exposed windows
- (void)handleExposeEvent:(xcb_window_t)window;

// Extension event base access (for event routing)
- (uint8_t)damageEventBase;
- (uint8_t)presentEventBase;
- (uint8_t)randrEventBase;

// X Present extension events (vblank sync)
- (void)handlePresentComplete:(void *)event;
- (void)handlePresentIdle;

// Redirect a window individually — needed for windows created after the
// initial redirect_subwindows(root) call which only captures existing
// root children.  Must be called BEFORE the window is mapped so the
// backing pixmap captures all initial rendering.
- (void)redirectWindow:(xcb_window_t)windowId;

// Cleanup
- (void)cleanup;

@end

/*
 * GWLRiverWindowManager.h
 * Gershwin Window Manager - Wayland Mode (River compositor)
 *
 * Main window manager class that connects to River via
 * river-window-management-v1 protocol and manages windows.
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <wayland-client.h>
#include "wayland/generated/river-window-management-v1-client.h"
#include "wayland/generated/river-xkb-bindings-v1-client.h"
#include "wayland/generated/river-layer-shell-v1-client.h"

@class GWLWindowState;
@class GWLOutputState;
@class GWLSeatState;

/*
 * Sequence state for the manage/render loop.
 */
typedef NS_ENUM(NSInteger, GWLSequencePhase) {
    GWLSequencePhaseIdle = 0,
    GWLSequencePhaseManage,
    GWLSequencePhaseRender,
};

/*
 * GWLRiverWindowManager
 *
 * Wayland-mode equivalent of URSHybridEventHandler.
 * Connects to River compositor, manages windows via River protocols,
 * integrates with NSRunLoop for the GNUstep event loop.
 */
@interface GWLRiverWindowManager : NSObject <NSApplicationDelegate, RunLoopEvents>

/* Wayland connection state */
@property (assign, nonatomic) struct wl_display *wlDisplay;
@property (assign, nonatomic) struct wl_registry *wlRegistry;
@property (assign, nonatomic) struct wl_compositor *wlCompositor;
@property (assign, nonatomic) struct wl_shm *wlShm;
@property (assign, nonatomic) struct river_window_manager_v1 *riverWM;
@property (assign, nonatomic) struct river_xkb_bindings_v1 *riverXkbBindings;
@property (assign, nonatomic) struct river_layer_shell_v1 *riverLayerShell;

/* Protocol state */
@property (assign, nonatomic) GWLSequencePhase currentPhase;
@property (assign, nonatomic) BOOL sessionLocked;
@property (assign, nonatomic) BOOL unavailable;

/* Managed objects */
@property (strong, nonatomic) NSMutableDictionary<NSValue *, GWLWindowState *> *windows;
@property (strong, nonatomic) NSMutableArray<GWLWindowState *> *windowStackingOrder;
@property (strong, nonatomic) NSMutableDictionary<NSValue *, GWLOutputState *> *outputs;
@property (strong, nonatomic) NSMutableDictionary<NSValue *, GWLSeatState *> *seats;

/* Focus tracking */
@property (weak, nonatomic) GWLWindowState *focusedWindow;
@property (weak, nonatomic) GWLWindowState *previousFocusedWindow;

/* Titlebar height (matches X11 mode: 25px) */
@property (assign, nonatomic) int titleBarHeight;

/* Connection and lifecycle */
- (BOOL)connectToCompositor;
- (void)disconnect;
- (void)setupWaylandEventIntegration;

/* RunLoopEvents protocol */
- (void)receivedEvent:(void *)data type:(RunLoopEventType)type
                extra:(void *)extra forMode:(NSString *)mode;

/* Manage/render sequence handlers */
- (void)handleManageStart;
- (void)handleRenderStart;

/* Window management */
- (void)handleNewWindow:(struct river_window_v1 *)window;
- (void)handleWindowClosed:(GWLWindowState *)windowState;
- (void)placeNewWindow:(GWLWindowState *)windowState;
- (void)focusWindow:(GWLWindowState *)windowState;
- (void)restoreFocusAfterClose;

/* Output management */
- (void)handleNewOutput:(struct river_output_v1 *)output;
- (void)handleOutputRemoved:(GWLOutputState *)outputState;
- (NSRect)primaryOutputRect;

/* Seat management */
- (void)handleNewSeat:(struct river_seat_v1 *)seat;

/* Cleanup */
- (void)cleanupBeforeExit;

@end

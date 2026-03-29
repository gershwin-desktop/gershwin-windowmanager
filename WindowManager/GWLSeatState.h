/*
 * GWLSeatState.h
 * Gershwin Window Manager - Wayland Mode
 *
 * Per-seat input state tracking.
 */

#import <Foundation/Foundation.h>
#include <wayland-client.h>
#include "wayland/generated/river-window-management-v1-client.h"
#include "wayland/generated/river-xkb-bindings-v1-client.h"
#import "GWLDecorationRenderer.h"

@class GWLRiverWindowManager;
@class GWLWindowState;

@interface GWLSeatState : NSObject

@property (assign, nonatomic) struct river_seat_v1 *riverSeat;
@property (weak, nonatomic) GWLRiverWindowManager *manager;

/* wl_seat global name */
@property (assign, nonatomic) uint32_t wlSeatName;

/* wl_seat and wl_pointer (bound when seat is received) */
@property (assign, nonatomic) struct wl_seat *wlSeat;
@property (assign, nonatomic) struct wl_pointer *wlPointer;

/* Pointer state */
@property (assign, nonatomic) int32_t pointerX;
@property (assign, nonatomic) int32_t pointerY;
@property (weak, nonatomic) GWLWindowState *pointerEnteredWindow;

/* Decoration surface under the pointer (for titlebar hit-testing) */
@property (assign, nonatomic) struct wl_surface *decorFocusSurface;
@property (weak, nonatomic) GWLWindowState *decorFocusWindow;
@property (assign, nonatomic) int32_t decorPtrX;
@property (assign, nonatomic) int32_t decorPtrY;

/* Pending actions queued from wl_pointer events; executed in next manage_start */
@property (assign, nonatomic) BOOL pendingOpStartPointer;
@property (assign, nonatomic) GWLTitlebarButton pendingTitlebarButton;
@property (weak, nonatomic) GWLWindowState *pendingButtonWindow;

/* Interactive operation state */
@property (assign, nonatomic) BOOL operationActive;
@property (assign, nonatomic) int32_t opDeltaX;
@property (assign, nonatomic) int32_t opDeltaY;
@property (assign, nonatomic) BOOL opReleased;

/* Window being interacted with (for move/resize tracking) */
@property (weak, nonatomic) GWLWindowState *interactingWindow;
@property (assign, nonatomic) int32_t opStartX;
@property (assign, nonatomic) int32_t opStartY;

/* Key bindings */
@property (assign, nonatomic) struct river_xkb_binding_v1 *altTabBinding;
@property (assign, nonatomic) struct river_xkb_binding_v1 *shiftAltTabBinding;
@property (assign, nonatomic) struct river_xkb_bindings_seat_v1 *xkbSeat;

/* Pointer bindings (for titlebar drag / resize) */
@property (assign, nonatomic) struct river_pointer_binding_v1 *altLeftClickBinding;

@property (assign, nonatomic) BOOL removed;

@end

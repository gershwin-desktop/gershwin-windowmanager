/*
 * GWLOutputState.h
 * Gershwin Window Manager - Wayland Mode
 *
 * Per-output state tracking.
 */

#import <Foundation/Foundation.h>
#include <wayland-client.h>
#include "wayland/generated/river-window-management-v1-client.h"
#include "wayland/generated/river-layer-shell-v1-client.h"

@class GWLRiverWindowManager;

@interface GWLOutputState : NSObject

@property (assign, nonatomic) struct river_output_v1 *riverOutput;
@property (assign, nonatomic) struct river_layer_shell_output_v1 *layerShellOutput;
@property (weak, nonatomic) GWLRiverWindowManager *manager;

/* Output geometry (from River events) */
@property (assign, nonatomic) int32_t x;
@property (assign, nonatomic) int32_t y;
@property (assign, nonatomic) int32_t width;
@property (assign, nonatomic) int32_t height;

/* wl_output global name */
@property (assign, nonatomic) uint32_t wlOutputName;

/* Workarea (non-exclusive area after layer-shell exclusive zones) */
@property (assign, nonatomic) NSRect workarea;
@property (assign, nonatomic) BOOL hasWorkarea;

@property (assign, nonatomic) BOOL removed;

- (NSRect)fullRect;

@end

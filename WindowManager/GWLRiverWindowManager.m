/*
 * GWLRiverWindowManager.m
 * Gershwin Window Manager - Wayland Mode (River compositor)
 *
 * This is the Wayland-mode equivalent of URSHybridEventHandler.
 * It connects to the River compositor via river-window-management-v1,
 * manages windows, provides decorations, handles focus, and integrates
 * with NSRunLoop.
 */

#import "GWLRiverWindowManager.h"
#import "GWLWindowState.h"
#import "GWLOutputState.h"
#import "GWLSeatState.h"
#import "GWLDecorationRenderer.h"

#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include <linux/input-event-codes.h>
#include <sys/mman.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <time.h>

/* Golden ratio for window placement (matching X11 mode) */
static const double kGoldenRatio = 0.618;
/* Default window size as fraction of workarea */
static const double kDefaultSizeFraction = 0.70;
/* Default titlebar height (matching X11 mode) */
static const int kDefaultTitleBarHeight = 25;
/* Border width for window decoration borders */
static const int kBorderWidth = 1;

#pragma mark - Forward declarations of C callbacks

/* Registry */
static void registry_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface, uint32_t version);
static void registry_global_remove(void *data, struct wl_registry *registry,
                                   uint32_t name);

/* Window Manager */
static void wm_unavailable(void *data, struct river_window_manager_v1 *wm);
static void wm_finished(void *data, struct river_window_manager_v1 *wm);
static void wm_manage_start(void *data, struct river_window_manager_v1 *wm);
static void wm_render_start(void *data, struct river_window_manager_v1 *wm);
static void wm_session_locked(void *data, struct river_window_manager_v1 *wm);
static void wm_session_unlocked(void *data, struct river_window_manager_v1 *wm);
static void wm_window(void *data, struct river_window_manager_v1 *wm,
                       struct river_window_v1 *window);
static void wm_output(void *data, struct river_window_manager_v1 *wm,
                       struct river_output_v1 *output);
static void wm_seat(void *data, struct river_window_manager_v1 *wm,
                     struct river_seat_v1 *seat);

/* Window */
static void window_closed(void *data, struct river_window_v1 *window);
static void window_dimensions_hint(void *data, struct river_window_v1 *window,
                                   int32_t min_w, int32_t min_h,
                                   int32_t max_w, int32_t max_h);
static void window_dimensions(void *data, struct river_window_v1 *window,
                              int32_t width, int32_t height);
static void window_app_id(void *data, struct river_window_v1 *window,
                          const char *app_id);
static void window_title(void *data, struct river_window_v1 *window,
                         const char *title);
static void window_parent(void *data, struct river_window_v1 *window,
                          struct river_window_v1 *parent);
static void window_decoration_hint(void *data, struct river_window_v1 *window,
                                   uint32_t hint);
static void window_pointer_move_requested(void *data, struct river_window_v1 *window,
                                          struct river_seat_v1 *seat);
static void window_pointer_resize_requested(void *data, struct river_window_v1 *window,
                                            struct river_seat_v1 *seat, uint32_t edges);
static void window_show_window_menu_requested(void *data, struct river_window_v1 *window,
                                              int32_t x, int32_t y);
static void window_maximize_requested(void *data, struct river_window_v1 *window);
static void window_unmaximize_requested(void *data, struct river_window_v1 *window);
static void window_fullscreen_requested(void *data, struct river_window_v1 *window,
                                        struct river_output_v1 *output);
static void window_exit_fullscreen_requested(void *data, struct river_window_v1 *window);
static void window_minimize_requested(void *data, struct river_window_v1 *window);
static void window_unreliable_pid(void *data, struct river_window_v1 *window,
                                  int32_t pid);
static void window_presentation_hint(void *data, struct river_window_v1 *window,
                                     uint32_t hint);
static void window_identifier(void *data, struct river_window_v1 *window,
                              const char *id);

/* Output */
static void output_removed(void *data, struct river_output_v1 *output);
static void output_wl_output(void *data, struct river_output_v1 *output,
                             uint32_t name);
static void output_position(void *data, struct river_output_v1 *output,
                            int32_t x, int32_t y);
static void output_dimensions(void *data, struct river_output_v1 *output,
                              int32_t width, int32_t height);

/* Seat */
static void seat_removed(void *data, struct river_seat_v1 *seat);
static void seat_wl_seat(void *data, struct river_seat_v1 *seat, uint32_t name);
static void seat_pointer_enter(void *data, struct river_seat_v1 *seat,
                               struct river_window_v1 *window);
static void seat_pointer_leave(void *data, struct river_seat_v1 *seat);
static void seat_window_interaction(void *data, struct river_seat_v1 *seat,
                                    struct river_window_v1 *window);
static void seat_shell_surface_interaction(void *data, struct river_seat_v1 *seat,
                                           struct river_shell_surface_v1 *shell_surface);
static void seat_op_delta(void *data, struct river_seat_v1 *seat,
                          int32_t dx, int32_t dy);
static void seat_op_release(void *data, struct river_seat_v1 *seat);
static void seat_pointer_position(void *data, struct river_seat_v1 *seat,
                                  int32_t x, int32_t y);

/* Layer shell output */
static void layer_shell_output_non_exclusive_area(void *data,
    struct river_layer_shell_output_v1 *lso,
    int32_t x, int32_t y, int32_t width, int32_t height);

/* XKB binding */
static void xkb_binding_pressed(void *data, struct river_xkb_binding_v1 *binding);
static void xkb_binding_released(void *data, struct river_xkb_binding_v1 *binding);
static void xkb_binding_stop_repeat(void *data, struct river_xkb_binding_v1 *binding);

/* wl_pointer (for decoration surface hit-testing) */
static void pointer_enter(void *data, struct wl_pointer *pointer, uint32_t serial,
                          struct wl_surface *surface,
                          wl_fixed_t sx, wl_fixed_t sy);
static void pointer_leave(void *data, struct wl_pointer *pointer, uint32_t serial,
                          struct wl_surface *surface);
static void pointer_motion(void *data, struct wl_pointer *pointer, uint32_t time,
                           wl_fixed_t sx, wl_fixed_t sy);
static void pointer_button(void *data, struct wl_pointer *pointer, uint32_t serial,
                           uint32_t time, uint32_t button, uint32_t state);
static void pointer_axis(void *data, struct wl_pointer *pointer, uint32_t time,
                         uint32_t axis, wl_fixed_t value);
static void pointer_frame(void *data, struct wl_pointer *pointer);
static void pointer_axis_source(void *data, struct wl_pointer *pointer, uint32_t axis_source);
static void pointer_axis_stop(void *data, struct wl_pointer *pointer, uint32_t time, uint32_t axis);
static void pointer_axis_discrete(void *data, struct wl_pointer *pointer, uint32_t axis, int32_t discrete);

#pragma mark - Listener structs

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static const struct river_window_manager_v1_listener wm_listener = {
    .unavailable = wm_unavailable,
    .finished = wm_finished,
    .manage_start = wm_manage_start,
    .render_start = wm_render_start,
    .session_locked = wm_session_locked,
    .session_unlocked = wm_session_unlocked,
    .window = wm_window,
    .output = wm_output,
    .seat = wm_seat,
};

static const struct river_window_v1_listener window_listener = {
    .closed = window_closed,
    .dimensions_hint = window_dimensions_hint,
    .dimensions = window_dimensions,
    .app_id = window_app_id,
    .title = window_title,
    .parent = window_parent,
    .decoration_hint = window_decoration_hint,
    .pointer_move_requested = window_pointer_move_requested,
    .pointer_resize_requested = window_pointer_resize_requested,
    .show_window_menu_requested = window_show_window_menu_requested,
    .maximize_requested = window_maximize_requested,
    .unmaximize_requested = window_unmaximize_requested,
    .fullscreen_requested = window_fullscreen_requested,
    .exit_fullscreen_requested = window_exit_fullscreen_requested,
    .minimize_requested = window_minimize_requested,
    .unreliable_pid = window_unreliable_pid,
    .presentation_hint = window_presentation_hint,
    .identifier = window_identifier,
};

static const struct river_output_v1_listener output_listener = {
    .removed = output_removed,
    .wl_output = output_wl_output,
    .position = output_position,
    .dimensions = output_dimensions,
};

static const struct river_seat_v1_listener seat_listener = {
    .removed = seat_removed,
    .wl_seat = seat_wl_seat,
    .pointer_enter = seat_pointer_enter,
    .pointer_leave = seat_pointer_leave,
    .window_interaction = seat_window_interaction,
    .shell_surface_interaction = seat_shell_surface_interaction,
    .op_delta = seat_op_delta,
    .op_release = seat_op_release,
    .pointer_position = seat_pointer_position,
};

static const struct river_xkb_binding_v1_listener xkb_binding_listener = {
    .pressed = xkb_binding_pressed,
    .released = xkb_binding_released,
    .stop_repeat = xkb_binding_stop_repeat,
};

static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
    .frame = pointer_frame,
    .axis_source = pointer_axis_source,
    .axis_stop = pointer_axis_stop,
    .axis_discrete = pointer_axis_discrete,
};

#pragma mark - Helper: Look up objects from protocol pointers

static GWLWindowState *windowStateForRiverWindow(GWLRiverWindowManager *mgr,
                                                  struct river_window_v1 *rw)
{
    NSValue *key = [NSValue valueWithPointer:rw];
    return mgr.windows[key];
}

static GWLOutputState *outputStateForRiverOutput(GWLRiverWindowManager *mgr,
                                                  struct river_output_v1 *ro)
{
    NSValue *key = [NSValue valueWithPointer:ro];
    return mgr.outputs[key];
}

static GWLSeatState *seatStateForRiverSeat(GWLRiverWindowManager *mgr,
                                            struct river_seat_v1 *rs)
{
    NSValue *key = [NSValue valueWithPointer:rs];
    return mgr.seats[key];
}

static GWLSeatState *seatStateForWlPointer(GWLRiverWindowManager *mgr,
                                            struct wl_pointer *ptr)
{
    for (GWLSeatState *ss in mgr.seats.allValues) {
        if (ss.wlPointer == ptr) return ss;
    }
    return nil;
}

#pragma mark - Implementation

@implementation GWLRiverWindowManager

@synthesize wlDisplay, wlRegistry, wlCompositor, wlShm;
@synthesize riverWM, riverXkbBindings, riverLayerShell;
@synthesize currentPhase, sessionLocked, unavailable;
@synthesize windows, windowStackingOrder, outputs, seats;
@synthesize focusedWindow, previousFocusedWindow;
@synthesize titleBarHeight;

#pragma mark - Initialization

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.windows = [[NSMutableDictionary alloc] init];
        self.windowStackingOrder = [[NSMutableArray alloc] init];
        self.outputs = [[NSMutableDictionary alloc] init];
        self.seats = [[NSMutableDictionary alloc] init];
        self.currentPhase = GWLSequencePhaseIdle;
        self.titleBarHeight = kDefaultTitleBarHeight;
    }
    return self;
}

#pragma mark - NSApplicationDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSLog(@"[WaylandWM] Application did finish launching");

    if (![self connectToCompositor]) {
        NSLog(@"[WaylandWM] FATAL: Failed to connect to River compositor");
        [NSApp terminate:nil];
        return;
    }

    [self setupWaylandEventIntegration];
    NSLog(@"[WaylandWM] Wayland mode initialized successfully");
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self cleanupBeforeExit];
}

#pragma mark - Wayland Connection

- (BOOL)connectToCompositor
{
    // Retry connection with exponential backoff
    // River's compositor may still be initializing when socket file is created
    int maxRetries = 30;
    int retryDelay = 50; // milliseconds
    
    for (int attempt = 0; attempt < maxRetries; attempt++) {
        self.wlDisplay = wl_display_connect(NULL);
        
        if (self.wlDisplay) {
            if (attempt > 0) {
                NSLog(@"[WaylandWM] Connected to Wayland display (attempt %d/%d)",
                      attempt + 1, maxRetries);
            } else {
                NSLog(@"[WaylandWM] Connected to Wayland display");
            }
            break;
        }
        
        if (attempt < maxRetries - 1) {
            // Sleep for retryDelay milliseconds
            struct timespec ts;
            ts.tv_sec = retryDelay / 1000;
            ts.tv_nsec = (retryDelay % 1000) * 1000000;
            nanosleep(&ts, NULL);
            retryDelay = (retryDelay * 3) / 2; // 1.5x exponential backoff
        }
    }
    
    if (!self.wlDisplay) {
        NSLog(@"[WaylandWM] Failed to connect to Wayland display after %d attempts "
              "(WAYLAND_DISPLAY=%s)", 
              maxRetries, getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "not set");
        return NO;
    }

    self.wlRegistry = wl_display_get_registry(self.wlDisplay);
    wl_registry_add_listener(self.wlRegistry, &registry_listener,
                             (__bridge void *)self);

    /* Roundtrip to get globals */
    wl_display_roundtrip(self.wlDisplay);

    if (!self.riverWM) {
        NSLog(@"[WaylandWM] river_window_manager_v1 not available. "
              "Is River compositor running?");
        return NO;
    }

    /* Add WM listener */
    river_window_manager_v1_add_listener(self.riverWM, &wm_listener,
                                         (__bridge void *)self);

    /* Second roundtrip to receive initial state */
    wl_display_roundtrip(self.wlDisplay);

    if (self.unavailable) {
        NSLog(@"[WaylandWM] Another window manager is already running");
        return NO;
    }

    NSLog(@"[WaylandWM] River window manager protocol bound successfully");
    return YES;
}

- (void)disconnect
{
    if (self.riverWM) {
        river_window_manager_v1_stop(self.riverWM);
    }
    if (self.wlDisplay) {
        wl_display_disconnect(self.wlDisplay);
        self.wlDisplay = NULL;
    }
}

#pragma mark - NSRunLoop Integration

- (void)setupWaylandEventIntegration
{
    int fd = wl_display_get_fd(self.wlDisplay);
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];

    /* Monitor the Wayland fd for readability, just like the X11 mode
     * monitors the XCB fd via RunLoopEvents protocol */
    [runLoop addEvent:(void *)(intptr_t)fd
                 type:ET_RDESC
              watcher:self
              forMode:NSDefaultRunLoopMode];

    NSLog(@"[WaylandWM] Wayland fd %d integrated with NSRunLoop", fd);
}

- (void)receivedEvent:(void *)data type:(RunLoopEventType)type
                extra:(void *)extra forMode:(NSString *)mode
{
    if (type != ET_RDESC)
        return;

    /* Flush pending writes */
    while (wl_display_prepare_read(self.wlDisplay) != 0) {
        wl_display_dispatch_pending(self.wlDisplay);
    }

    /* Read events from the fd */
    if (wl_display_read_events(self.wlDisplay) < 0) {
        if (errno != EAGAIN && errno != EINTR) {
            NSLog(@"[WaylandWM] Wayland display read error: %s",
                  strerror(errno));
            [NSApp terminate:nil];
            return;
        }
    }

    /* Dispatch received events (calls our listeners) */
    wl_display_dispatch_pending(self.wlDisplay);

    /* Flush outgoing requests */
    wl_display_flush(self.wlDisplay);
}

#pragma mark - Manage/Render Sequence Handlers

- (void)handleManageStart
{
    self.currentPhase = GWLSequencePhaseManage;

    /* Process all pending manage-sequence work:
     * - Propose dimensions for new windows
     * - Set focus
     * - Set up key bindings
     * - Handle maximize/minimize/fullscreen requests
     */

    /* For each new window without dimensions, propose initial size */
    for (GWLWindowState *ws in self.windows.allValues) {
        if (ws.closed)
            continue;

        if (!ws.dimensionsReceived && ws.width == 0 && ws.height == 0) {
            [self placeNewWindow:ws];
        }
    }

    /* Ensure focus is set */
    if (!self.focusedWindow) {
        [self restoreFocusAfterClose];
    }

    /* Apply focus */
    GWLSeatState *primarySeat = self.seats.allValues.firstObject;
    if (primarySeat && self.focusedWindow && !self.focusedWindow.closed) {
        river_seat_v1_focus_window(primarySeat.riverSeat,
                                   self.focusedWindow.riverWindow);
    }

    /* Tell all windows their capabilities and apply decoration mode.
     * use_ssd / use_csd must be called during the manage sequence. */
    for (GWLWindowState *ws in self.windows.allValues) {
        if (ws.closed)
            continue;
        river_window_v1_set_capabilities(ws.riverWindow,
            RIVER_WINDOW_V1_CAPABILITIES_WINDOW_MENU |
            RIVER_WINDOW_V1_CAPABILITIES_MAXIMIZE |
            RIVER_WINDOW_V1_CAPABILITIES_FULLSCREEN |
            RIVER_WINDOW_V1_CAPABILITIES_MINIMIZE);

        /* Tell clients that support SSD to use it (no duplicate titlebar).
         * For CSD-only clients, this has no effect per the protocol.
         * Either way, the WM always renders its own decoration surface. */
        if (ws.decorationHint != GWLDecorationHintOnlyCSD) {
            river_window_v1_use_ssd(ws.riverWindow);
        }
        /* Always enable WM-side decoration rendering via decoration surfaces */
        ws.usingSSD = YES;
    }

    /* Handle pending decoration surface button actions.
     * wl_pointer.button events cannot call op_start_pointer directly;
     * they set flags and request a manage sequence via manage_dirty. */
    for (GWLSeatState *ss in self.seats.allValues) {
        if (ss.pendingOpStartPointer && ss.interactingWindow) {
            [self startInteractiveMove:ss.interactingWindow seat:ss];
            ss.pendingOpStartPointer = NO;
        }
        if (ss.pendingTitlebarButton != GWLTitlebarButtonNone &&
            ss.pendingButtonWindow) {
            [self handleTitlebarButton:ss.pendingTitlebarButton
                             forWindow:ss.pendingButtonWindow];
            ss.pendingTitlebarButton = GWLTitlebarButtonNone;
            ss.pendingButtonWindow = nil;
        }
    }

    /* Finish manage sequence */
    river_window_manager_v1_manage_finish(self.riverWM);
    self.currentPhase = GWLSequencePhaseIdle;

    wl_display_flush(self.wlDisplay);
}

- (void)handleRenderStart
{
    self.currentPhase = GWLSequencePhaseRender;

    /* Apply rendering state for all windows:
     * - Set positions
     * - Set z-order
     * - Show/hide
     * - Set borders
     */

    for (GWLWindowState *ws in self.windows.allValues) {
        if (ws.closed)
            continue;

        /* Ensure node exists */
        if (!ws.node && ws.dimensionsReceived) {
            ws.node = river_window_v1_get_node(ws.riverWindow);
        }

        if (!ws.node)
            continue;

        /* Set position */
        river_node_v1_set_position(ws.node, ws.x, ws.y);

        /* Show or hide */
        if (ws.isMinimized) {
            river_window_v1_hide(ws.riverWindow);
        } else {
            river_window_v1_show(ws.riverWindow);
        }

        /* Set borders (light gray, 1px, matching the X11 frame border) */
        if (!ws.isFullscreen) {
            /* Top border only where titlebar isn't covering */
            uint32_t edges = RIVER_WINDOW_V1_EDGES_LEFT |
                             RIVER_WINDOW_V1_EDGES_RIGHT |
                             RIVER_WINDOW_V1_EDGES_BOTTOM;

            river_window_v1_set_borders(ws.riverWindow, edges,
                                        kBorderWidth,
                                        0xCC, 0xCC, 0xCC, 0xFF);
        } else {
            /* No borders in fullscreen */
            river_window_v1_set_borders(ws.riverWindow,
                                        RIVER_WINDOW_V1_EDGES_NONE,
                                        0, 0, 0, 0, 0);
        }
    }

    /* --- Decoration surface rendering --- */
    GWLDecorationRenderer *decoRenderer = [GWLDecorationRenderer sharedInstance];
    for (GWLWindowState *ws in self.windows.allValues) {
        if (ws.closed || !ws.usingSSD || ws.isFullscreen || !ws.dimensionsReceived)
            continue;

        /* Create decoration surface if needed */
        if (!ws.titlebarSurface) {
            [decoRenderer createDecorationSurfaceForWindow:ws
                                                compositor:self.wlCompositor];
        }

        /* Re-render if needed (title/focus/size change) */
        BOOL needsRender = ws.needsDecorationUpdate ||
                           !ws.titlebarBuffer ||
                           ws.lastRenderedWidth != ws.width;
        if (needsRender && ws.titlebarSurface) {
            [decoRenderer renderTitlebarForWindow:ws
                                           active:ws.isFocused
                                              shm:self.wlShm];
        }

        /* Sync decoration and commit surface during render sequence */
        if (ws.titlebarSurface && ws.titlebarBuffer && ws.decorationAbove) {
            /* Position titlebar above window content */
            river_decoration_v1_set_offset(ws.decorationAbove,
                                           0, -self.titleBarHeight);
            river_decoration_v1_sync_next_commit(ws.decorationAbove);

            wl_surface_attach(ws.titlebarSurface, ws.titlebarBuffer, 0, 0);
            wl_surface_damage_buffer(ws.titlebarSurface, 0, 0,
                                     ws.width, self.titleBarHeight);
            wl_surface_commit(ws.titlebarSurface);
        }
    }

    /* Set stacking order: focused window on top, then reverse order */
    GWLWindowState *prev = nil;
    for (GWLWindowState *ws in self.windowStackingOrder) {
        if (ws.closed || !ws.node)
            continue;
        if (!prev) {
            river_node_v1_place_top(ws.node);
        } else {
            river_node_v1_place_below(ws.node, prev.node);
        }
        prev = ws;
    }

    /* Bring focused window to top */
    if (self.focusedWindow && self.focusedWindow.node &&
        !self.focusedWindow.closed) {
        river_node_v1_place_top(self.focusedWindow.node);

        /* Place dialog children above their parent */
        for (GWLWindowState *ws in self.focusedWindow.children) {
            if (!ws.closed && ws.node) {
                river_node_v1_place_above(ws.node,
                                          self.focusedWindow.node);
            }
        }
    }

    /* Finish render sequence */
    river_window_manager_v1_render_finish(self.riverWM);
    self.currentPhase = GWLSequencePhaseIdle;

    wl_display_flush(self.wlDisplay);
}

#pragma mark - Window Management

- (void)handleNewWindow:(struct river_window_v1 *)window
{
    GWLWindowState *ws = [[GWLWindowState alloc] init];
    ws.riverWindow = window;
    ws.manager = self;

    NSValue *key = [NSValue valueWithPointer:window];
    self.windows[key] = ws;

    /* Add listener for window events */
    river_window_v1_add_listener(window, &window_listener,
                                 (__bridge void *)self);

    /* Add to stacking order (on top) */
    [self.windowStackingOrder insertObject:ws atIndex:0];

    NSLog(@"[WaylandWM] New window tracked (total: %lu)",
          (unsigned long)self.windows.count);
}

- (void)handleWindowClosed:(GWLWindowState *)ws
{
    ws.closed = YES;

    /* Clean up decoration surfaces */
    [[GWLDecorationRenderer sharedInstance] destroyDecorationForWindow:ws];

    /* Remove from stacking order */
    [self.windowStackingOrder removeObject:ws];

    /* Remove from parent's children */
    if (ws.parent) {
        [ws.parent.children removeObject:ws];
    }

    /* Clear focus if this was focused */
    if (self.focusedWindow == ws) {
        self.previousFocusedWindow = nil;
        self.focusedWindow = nil;
    } else if (self.previousFocusedWindow == ws) {
        self.previousFocusedWindow = nil;
    }

    /* Destroy River object */
    river_window_v1_destroy(ws.riverWindow);

    /* Remove from tracking */
    NSValue *key = [NSValue valueWithPointer:ws.riverWindow];
    [self.windows removeObjectForKey:key];

    NSLog(@"[WaylandWM] Window closed (remaining: %lu)",
          (unsigned long)self.windows.count);
}

- (void)placeNewWindow:(GWLWindowState *)ws
{
    NSRect outputRect = [self primaryOutputRect];
    if (outputRect.size.width == 0 || outputRect.size.height == 0)
        return;

    int32_t workWidth = (int32_t)outputRect.size.width;
    int32_t workHeight = (int32_t)outputRect.size.height;
    int32_t workX = (int32_t)outputRect.origin.x;
    int32_t workY = (int32_t)outputRect.origin.y;

    /* Default size: 70% of workarea (matching X11 mode) */
    int32_t winW = (int32_t)(workWidth * kDefaultSizeFraction);
    int32_t winH = (int32_t)(workHeight * kDefaultSizeFraction);

    /* Respect size hints */
    if (ws.minWidth > 0 && winW < ws.minWidth) winW = ws.minWidth;
    if (ws.minHeight > 0 && winH < ws.minHeight) winH = ws.minHeight;
    if (ws.maxWidth > 0 && winW > ws.maxWidth) winW = ws.maxWidth;
    if (ws.maxHeight > 0 && winH > ws.maxHeight) winH = ws.maxHeight;

    /* Position at golden ratio (matching X11 mode) */
    ws.x = workX + (int32_t)((workWidth - winW) * (1.0 - kGoldenRatio));
    ws.y = workY + (int32_t)((workHeight - winH) * (1.0 - kGoldenRatio));

    /* For dialogs, center over parent */
    if (ws.parent && !ws.parent.closed) {
        ws.x = ws.parent.x + (ws.parent.width - winW) / 2;
        ws.y = ws.parent.y + (ws.parent.height - winH) / 2;
    }

    /* Propose dimensions to River */
    river_window_v1_propose_dimensions(ws.riverWindow, winW, winH);

    /* Auto-focus new windows */
    [self focusWindow:ws];

    NSLog(@"[WaylandWM] Placing new window at (%d, %d) size %dx%d",
          ws.x, ws.y, winW, winH);
}

- (void)focusWindow:(GWLWindowState *)ws
{
    if (!ws || ws.closed)
        return;

    if (self.focusedWindow != ws) {
        self.previousFocusedWindow = self.focusedWindow;
        if (self.focusedWindow) {
            self.focusedWindow.isFocused = NO;
            self.focusedWindow.needsDecorationUpdate = YES;
        }
    }

    self.focusedWindow = ws;
    ws.isFocused = YES;
    ws.needsDecorationUpdate = YES;

    /* Move to top of stacking order */
    [self.windowStackingOrder removeObject:ws];
    [self.windowStackingOrder insertObject:ws atIndex:0];
}

- (void)restoreFocusAfterClose
{
    /* Try previous focused window first */
    if (self.previousFocusedWindow &&
        !self.previousFocusedWindow.closed &&
        !self.previousFocusedWindow.isMinimized) {
        [self focusWindow:self.previousFocusedWindow];
        return;
    }

    /* Otherwise, focus top of stacking order */
    for (GWLWindowState *ws in self.windowStackingOrder) {
        if (!ws.closed && !ws.isMinimized) {
            [self focusWindow:ws];
            return;
        }
    }

    /* No windows to focus */
    self.focusedWindow = nil;
    GWLSeatState *seat = self.seats.allValues.firstObject;
    if (seat) {
        river_seat_v1_clear_focus(seat.riverSeat);
    }
}

#pragma mark - Maximize / Fullscreen / Minimize

- (void)maximizeWindow:(GWLWindowState *)ws
{
    if (ws.isMaximized)
        return;

    /* Save current geometry for restore */
    ws.savedGeometry = NSMakeRect(ws.x, ws.y, ws.width, ws.height);
    ws.hasSavedGeometry = YES;
    ws.isMaximized = YES;

    NSRect outRect = [self primaryOutputRect];
    int32_t w = (int32_t)outRect.size.width;
    int32_t h = (int32_t)outRect.size.height;

    ws.x = (int32_t)outRect.origin.x;
    ws.y = (int32_t)outRect.origin.y;

    river_window_v1_propose_dimensions(ws.riverWindow, w, h);
    river_window_v1_inform_maximized(ws.riverWindow);
    river_window_v1_set_tiled(ws.riverWindow,
        RIVER_WINDOW_V1_EDGES_TOP | RIVER_WINDOW_V1_EDGES_BOTTOM |
        RIVER_WINDOW_V1_EDGES_LEFT | RIVER_WINDOW_V1_EDGES_RIGHT);

    NSLog(@"[WaylandWM] Maximized window to %dx%d", w, h);
}

- (void)unmaximizeWindow:(GWLWindowState *)ws
{
    if (!ws.isMaximized)
        return;

    ws.isMaximized = NO;

    if (ws.hasSavedGeometry) {
        ws.x = (int32_t)ws.savedGeometry.origin.x;
        ws.y = (int32_t)ws.savedGeometry.origin.y;
        river_window_v1_propose_dimensions(ws.riverWindow,
            (int32_t)ws.savedGeometry.size.width,
            (int32_t)ws.savedGeometry.size.height);
        ws.hasSavedGeometry = NO;
    }

    river_window_v1_inform_unmaximized(ws.riverWindow);
    river_window_v1_set_tiled(ws.riverWindow, RIVER_WINDOW_V1_EDGES_NONE);
}

- (void)fullscreenWindow:(GWLWindowState *)ws onOutput:(GWLOutputState *)output
{
    if (ws.isFullscreen)
        return;

    ws.savedGeometry = NSMakeRect(ws.x, ws.y, ws.width, ws.height);
    ws.hasSavedGeometry = YES;
    ws.isFullscreen = YES;

    struct river_output_v1 *ro = output ? output.riverOutput :
        self.outputs.allValues.firstObject.riverOutput;
    ws.fullscreenOutput = output ?: self.outputs.allValues.firstObject;

    river_window_v1_fullscreen(ws.riverWindow, ro);
    river_window_v1_inform_fullscreen(ws.riverWindow);
}

- (void)exitFullscreenWindow:(GWLWindowState *)ws
{
    if (!ws.isFullscreen)
        return;

    ws.isFullscreen = NO;
    ws.fullscreenOutput = nil;

    river_window_v1_exit_fullscreen(ws.riverWindow);
    river_window_v1_inform_not_fullscreen(ws.riverWindow);

    if (ws.hasSavedGeometry) {
        ws.x = (int32_t)ws.savedGeometry.origin.x;
        ws.y = (int32_t)ws.savedGeometry.origin.y;
        river_window_v1_propose_dimensions(ws.riverWindow,
            (int32_t)ws.savedGeometry.size.width,
            (int32_t)ws.savedGeometry.size.height);
        ws.hasSavedGeometry = NO;
    }
}

- (void)minimizeWindow:(GWLWindowState *)ws
{
    ws.isMinimized = YES;

    if (self.focusedWindow == ws) {
        self.focusedWindow = nil;
        [self restoreFocusAfterClose];
    }
}

- (void)restoreWindow:(GWLWindowState *)ws
{
    ws.isMinimized = NO;
    [self focusWindow:ws];
}

#pragma mark - Snap

- (void)snapWindow:(GWLWindowState *)ws direction:(GWLSnapDirection)direction
{
    NSRect outRect = [self primaryOutputRect];
    int32_t outW = (int32_t)outRect.size.width;
    int32_t outH = (int32_t)outRect.size.height;
    int32_t outX = (int32_t)outRect.origin.x;
    int32_t outY = (int32_t)outRect.origin.y;

    if (!ws.hasSavedGeometry && !ws.isMaximized &&
        ws.snapDirection == GWLSnapNone) {
        ws.savedGeometry = NSMakeRect(ws.x, ws.y, ws.width, ws.height);
        ws.hasSavedGeometry = YES;
    }

    ws.snapDirection = direction;

    switch (direction) {
    case GWLSnapLeft:
        ws.x = outX;
        ws.y = outY;
        river_window_v1_propose_dimensions(ws.riverWindow, outW / 2, outH);
        river_window_v1_set_tiled(ws.riverWindow,
            RIVER_WINDOW_V1_EDGES_TOP | RIVER_WINDOW_V1_EDGES_BOTTOM |
            RIVER_WINDOW_V1_EDGES_LEFT);
        break;
    case GWLSnapRight:
        ws.x = outX + outW / 2;
        ws.y = outY;
        river_window_v1_propose_dimensions(ws.riverWindow, outW / 2, outH);
        river_window_v1_set_tiled(ws.riverWindow,
            RIVER_WINDOW_V1_EDGES_TOP | RIVER_WINDOW_V1_EDGES_BOTTOM |
            RIVER_WINDOW_V1_EDGES_RIGHT);
        break;
    case GWLSnapMaximize:
        [self maximizeWindow:ws];
        break;
    case GWLSnapNone:
        if (ws.hasSavedGeometry) {
            ws.x = (int32_t)ws.savedGeometry.origin.x;
            ws.y = (int32_t)ws.savedGeometry.origin.y;
            river_window_v1_propose_dimensions(ws.riverWindow,
                (int32_t)ws.savedGeometry.size.width,
                (int32_t)ws.savedGeometry.size.height);
            ws.hasSavedGeometry = NO;
        }
        river_window_v1_set_tiled(ws.riverWindow, RIVER_WINDOW_V1_EDGES_NONE);
        break;
    }
}

#pragma mark - Output Management

- (void)handleNewOutput:(struct river_output_v1 *)output
{
    GWLOutputState *os = [[GWLOutputState alloc] init];
    os.riverOutput = output;
    os.manager = self;

    NSValue *key = [NSValue valueWithPointer:output];
    self.outputs[key] = os;

    river_output_v1_add_listener(output, &output_listener,
                                 (__bridge void *)self);

    /* If layer shell is available, get output state */
    if (self.riverLayerShell) {
        os.layerShellOutput = river_layer_shell_v1_get_output(
            self.riverLayerShell, output);

        /* Hook up layer shell output listener for workarea tracking */
        static const struct river_layer_shell_output_v1_listener lso_listener = {
            .non_exclusive_area = layer_shell_output_non_exclusive_area,
        };
        river_layer_shell_output_v1_add_listener(os.layerShellOutput,
            &lso_listener, (__bridge void *)self);
    }

    NSLog(@"[WaylandWM] New output tracked (total: %lu)",
          (unsigned long)self.outputs.count);
}

- (void)handleOutputRemoved:(GWLOutputState *)os
{
    os.removed = YES;
    river_output_v1_destroy(os.riverOutput);
    NSValue *key = [NSValue valueWithPointer:os.riverOutput];
    [self.outputs removeObjectForKey:key];
}

- (NSRect)primaryOutputRect
{
    /* Use workarea if available from layer-shell, otherwise full output */
    for (GWLOutputState *os in self.outputs.allValues) {
        if (os.removed)
            continue;
        if (os.hasWorkarea) {
            return os.workarea;
        }
        return [os fullRect];
    }
    /* Fallback: 1920x1080 */
    return NSMakeRect(0, 0, 1920, 1080);
}

#pragma mark - Seat Management

- (void)handleNewSeat:(struct river_seat_v1 *)seat
{
    GWLSeatState *ss = [[GWLSeatState alloc] init];
    ss.riverSeat = seat;
    ss.manager = self;

    NSValue *key = [NSValue valueWithPointer:seat];
    self.seats[key] = ss;

    river_seat_v1_add_listener(seat, &seat_listener,
                               (__bridge void *)self);

    /* Set up xkb key bindings for Alt-Tab, Shift-Alt-Tab */
    if (self.riverXkbBindings) {
        /* Alt + Tab */
        ss.altTabBinding = river_xkb_bindings_v1_get_xkb_binding(
            self.riverXkbBindings,
            seat,
            XKB_KEY_Tab,
            RIVER_SEAT_V1_MODIFIERS_MOD1);  /* mod1 = Alt */

        river_xkb_binding_v1_add_listener(ss.altTabBinding,
                                           &xkb_binding_listener,
                                           (__bridge void *)self);

        /* Shift + Alt + Tab */
        ss.shiftAltTabBinding = river_xkb_bindings_v1_get_xkb_binding(
            self.riverXkbBindings,
            seat,
            XKB_KEY_Tab,
            RIVER_SEAT_V1_MODIFIERS_MOD1 | RIVER_SEAT_V1_MODIFIERS_SHIFT);

        river_xkb_binding_v1_add_listener(ss.shiftAltTabBinding,
                                           &xkb_binding_listener,
                                           (__bridge void *)self);

        /* XKB bindings seat (v2) for chorded bindings */
        ss.xkbSeat = river_xkb_bindings_v1_get_seat(
            self.riverXkbBindings, seat);

        NSLog(@"[WaylandWM] Alt-Tab and Shift-Alt-Tab bindings configured");
    }

    /* Set up pointer binding for Alt+Left Click (move window) */
    ss.altLeftClickBinding = river_seat_v1_get_pointer_binding(
        seat, BTN_LEFT, RIVER_SEAT_V1_MODIFIERS_MOD1);

    NSLog(@"[WaylandWM] New seat tracked (total: %lu)",
          (unsigned long)self.seats.count);
}

#pragma mark - Interactive Move/Resize

- (void)startInteractiveMove:(GWLWindowState *)ws seat:(GWLSeatState *)ss
{
    if (ss.operationActive)
        return;

    ss.operationActive = YES;
    ss.interactingWindow = ws;
    ss.opStartX = ws.x;
    ss.opStartY = ws.y;
    ss.opDeltaX = 0;
    ss.opDeltaY = 0;
    ss.opReleased = NO;

    river_seat_v1_op_start_pointer(ss.riverSeat);
    [self focusWindow:ws];

    NSLog(@"[WaylandWM] Starting interactive move for window '%@'", ws.title);
}

- (void)handleOpDelta:(GWLSeatState *)ss dx:(int32_t)dx dy:(int32_t)dy
{
    if (!ss.operationActive || !ss.interactingWindow)
        return;

    GWLWindowState *ws = ss.interactingWindow;
    ss.opDeltaX = dx;
    ss.opDeltaY = dy;

    /* Update window position */
    ws.x = ss.opStartX + dx;
    ws.y = ss.opStartY + dy;
}

- (void)handleOpRelease:(GWLSeatState *)ss
{
    if (!ss.operationActive)
        return;

    ss.opReleased = YES;

    /* Check snap zones */
    GWLWindowState *ws = ss.interactingWindow;
    if (ws) {
        NSRect outRect = [self primaryOutputRect];
        int32_t outX = (int32_t)outRect.origin.x;
        int32_t outY = (int32_t)outRect.origin.y;
        int32_t outW = (int32_t)outRect.size.width;

        int32_t ptrX = ss.pointerX;
        int32_t ptrY = ss.pointerY;
        int32_t snapMargin = 8;

        if (ptrY <= outY + snapMargin) {
            /* Top edge: maximize */
            [self snapWindow:ws direction:GWLSnapMaximize];
        } else if (ptrX <= outX + snapMargin) {
            /* Left edge: snap left */
            [self snapWindow:ws direction:GWLSnapLeft];
        } else if (ptrX >= outX + outW - snapMargin) {
            /* Right edge: snap right */
            [self snapWindow:ws direction:GWLSnapRight];
        }
    }

    /* End operation */
    river_seat_v1_op_end(ss.riverSeat);
    ss.operationActive = NO;
    ss.interactingWindow = nil;
}

#pragma mark - Window Switching (Alt-Tab)

- (void)handleAltTabPressed:(BOOL)reverse
{
    /* Build list of switchable windows */
    NSMutableArray<GWLWindowState *> *switchable = [[NSMutableArray alloc] init];
    for (GWLWindowState *ws in self.windowStackingOrder) {
        if (!ws.closed) {
            [switchable addObject:ws];
        }
    }

    if (switchable.count < 2)
        return;

    /* Find current index */
    NSUInteger currentIdx = 0;
    if (self.focusedWindow) {
        NSUInteger idx = [switchable indexOfObject:self.focusedWindow];
        if (idx != NSNotFound)
            currentIdx = idx;
    }

    /* Cycle */
    NSUInteger nextIdx;
    if (reverse) {
        nextIdx = (currentIdx == 0) ? switchable.count - 1 : currentIdx - 1;
    } else {
        nextIdx = (currentIdx + 1) % switchable.count;
    }

    GWLWindowState *target = switchable[nextIdx];

    /* If minimized, restore it */
    if (target.isMinimized) {
        [self restoreWindow:target];
    }

    [self focusWindow:target];

    NSLog(@"[WaylandWM] Alt-Tab: switching to '%@' (%s)",
          target.title, reverse ? "backward" : "forward");
}

#pragma mark - Decoration Surface Pointer Helpers

- (GWLWindowState *)windowForTitlebarSurface:(struct wl_surface *)surface
{
    for (GWLWindowState *ws in self.windows.allValues) {
        if (!ws.closed && ws.titlebarSurface == surface) {
            return ws;
        }
    }
    return nil;
}

- (void)handleTitlebarButton:(GWLTitlebarButton)button forWindow:(GWLWindowState *)ws
{
    if (!ws || ws.closed)
        return;

    switch (button) {
        case GWLTitlebarButtonClose:
            river_window_v1_close(ws.riverWindow);
            NSLog(@"[WaylandWM] Close button: closing '%@'", ws.title);
            break;
        case GWLTitlebarButtonMiniaturize:
            [self minimizeWindow:ws];
            NSLog(@"[WaylandWM] Minimize button: minimizing '%@'", ws.title);
            break;
        case GWLTitlebarButtonZoom:
            if (ws.isMaximized)
                [self unmaximizeWindow:ws];
            else
                [self maximizeWindow:ws];
            NSLog(@"[WaylandWM] Zoom button: toggling maximize for '%@'", ws.title);
            break;
        case GWLTitlebarButtonNone:
            break;
    }
}

#pragma mark - Cleanup

- (void)cleanupBeforeExit
{
    NSLog(@"[WaylandWM] Cleaning up before exit...");

    /* Note: key bindings need to be enabled during a manage sequence.
     * For cleanup we just disconnect. */

    [self disconnect];

    NSLog(@"[WaylandWM] Cleanup complete");
}

@end

#pragma mark - Wayland Registry Callbacks

static void registry_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface,
                            uint32_t version)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;

    if (strcmp(interface, river_window_manager_v1_interface.name) == 0) {
        uint32_t bind_ver = version < 4 ? version : 4;
        mgr.riverWM = wl_registry_bind(registry, name,
            &river_window_manager_v1_interface, bind_ver);
        NSLog(@"[WaylandWM] Bound river_window_manager_v1 v%u", bind_ver);
    }
    else if (strcmp(interface, "wl_compositor") == 0) {
        mgr.wlCompositor = wl_registry_bind(registry, name,
            &wl_compositor_interface, 4);
    }
    else if (strcmp(interface, "wl_shm") == 0) {
        mgr.wlShm = wl_registry_bind(registry, name,
            &wl_shm_interface, 1);
    }
    else if (strcmp(interface, river_xkb_bindings_v1_interface.name) == 0) {
        uint32_t bind_ver = version < 2 ? version : 2;
        mgr.riverXkbBindings = wl_registry_bind(registry, name,
            &river_xkb_bindings_v1_interface, bind_ver);
        NSLog(@"[WaylandWM] Bound river_xkb_bindings_v1 v%u", bind_ver);
    }
    else if (strcmp(interface, river_layer_shell_v1_interface.name) == 0) {
        mgr.riverLayerShell = wl_registry_bind(registry, name,
            &river_layer_shell_v1_interface, 1);
        NSLog(@"[WaylandWM] Bound river_layer_shell_v1");
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry,
                                   uint32_t name)
{
    /* Outputs/seats are handled via their own removed events */
}

#pragma mark - Window Manager Callbacks

static void wm_unavailable(void *data, struct river_window_manager_v1 *wm)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    mgr.unavailable = YES;
    NSLog(@"[WaylandWM] Window management unavailable (another WM running)");
}

static void wm_finished(void *data, struct river_window_manager_v1 *wm)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    NSLog(@"[WaylandWM] Server finished, shutting down");
    [mgr cleanupBeforeExit];
    [NSApp terminate:nil];
}

static void wm_manage_start(void *data, struct river_window_manager_v1 *wm)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    [mgr handleManageStart];
}

static void wm_render_start(void *data, struct river_window_manager_v1 *wm)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    [mgr handleRenderStart];
}

static void wm_session_locked(void *data, struct river_window_manager_v1 *wm)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    mgr.sessionLocked = YES;
    NSLog(@"[WaylandWM] Session locked");
}

static void wm_session_unlocked(void *data, struct river_window_manager_v1 *wm)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    mgr.sessionLocked = NO;
    NSLog(@"[WaylandWM] Session unlocked");
}

static void wm_window(void *data, struct river_window_manager_v1 *wm,
                       struct river_window_v1 *window)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    [mgr handleNewWindow:window];
}

static void wm_output(void *data, struct river_window_manager_v1 *wm,
                       struct river_output_v1 *output)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    [mgr handleNewOutput:output];
}

static void wm_seat(void *data, struct river_window_manager_v1 *wm,
                     struct river_seat_v1 *seat)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    [mgr handleNewSeat:seat];
}

#pragma mark - Window Callbacks

static void window_closed(void *data, struct river_window_v1 *window)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        [mgr handleWindowClosed:ws];
    }
}

static void window_dimensions_hint(void *data, struct river_window_v1 *window,
                                   int32_t min_w, int32_t min_h,
                                   int32_t max_w, int32_t max_h)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        ws.minWidth = min_w;
        ws.minHeight = min_h;
        ws.maxWidth = max_w;
        ws.maxHeight = max_h;
    }
}

static void window_dimensions(void *data, struct river_window_v1 *window,
                              int32_t width, int32_t height)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        if (ws.width != width)
            ws.needsDecorationUpdate = YES;
        ws.width = width;
        ws.height = height;
        ws.dimensionsReceived = YES;
    }
}

static void window_app_id(void *data, struct river_window_v1 *window,
                          const char *app_id)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        ws.appId = app_id ? [NSString stringWithUTF8String:app_id] : nil;
        NSLog(@"[WaylandWM] Window app_id: %@", ws.appId);
    }
}

static void window_title(void *data, struct river_window_v1 *window,
                         const char *title)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        ws.title = title ? [NSString stringWithUTF8String:title] : nil;
        ws.needsDecorationUpdate = YES;
    }
}

static void window_parent(void *data, struct river_window_v1 *window,
                          struct river_window_v1 *parent)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        /* Remove from old parent */
        if (ws.parent) {
            [ws.parent.children removeObject:ws];
        }

        if (parent) {
            GWLWindowState *parentWs = windowStateForRiverWindow(mgr, parent);
            ws.parent = parentWs;
            if (parentWs) {
                [parentWs.children addObject:ws];
            }
        } else {
            ws.parent = nil;
        }
    }
}

static void window_decoration_hint(void *data, struct river_window_v1 *window,
                                   uint32_t hint)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        ws.decorationHint = (GWLDecorationHint)hint;
        NSLog(@"[WaylandWM] Window decoration_hint=%u for '%@'", hint, ws.title ?: ws.appId);

        /* Just record the preference; use_ssd must be called during
         * the manage sequence that follows this event.
         * The WM always renders decorations regardless of hint. */
        ws.usingSSD = YES;
    }
}

static void window_pointer_move_requested(void *data,
                                          struct river_window_v1 *window,
                                          struct river_seat_v1 *seat)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    GWLSeatState *ss = seatStateForRiverSeat(mgr, seat);
    if (ws && ss) {
        [mgr startInteractiveMove:ws seat:ss];
    }
}

static void window_pointer_resize_requested(void *data,
                                            struct river_window_v1 *window,
                                            struct river_seat_v1 *seat,
                                            uint32_t edges)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    GWLSeatState *ss = seatStateForRiverSeat(mgr, seat);
    if (ws && ss) {
        /* For resize, also start pointer op; the WM adjusts dimensions
         * based on delta in handleOpDelta. Resize is more complex than move -
         * for now delegate to op_start_pointer. */
        ss.operationActive = YES;
        ss.interactingWindow = ws;
        ss.opStartX = ws.x;
        ss.opStartY = ws.y;
        ss.opDeltaX = 0;
        ss.opDeltaY = 0;
        ss.opReleased = NO;
        river_seat_v1_op_start_pointer(ss.riverSeat);
        river_window_v1_inform_resize_start(ws.riverWindow);
        [mgr focusWindow:ws];
    }
}

static void window_show_window_menu_requested(void *data,
                                              struct river_window_v1 *window,
                                              int32_t x, int32_t y)
{
    /* TODO: Show window context menu */
    NSLog(@"[WaylandWM] Window menu requested at (%d, %d)", x, y);
}

static void window_maximize_requested(void *data, struct river_window_v1 *window)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        [mgr maximizeWindow:ws];
    }
}

static void window_unmaximize_requested(void *data,
                                        struct river_window_v1 *window)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        [mgr unmaximizeWindow:ws];
    }
}

static void window_fullscreen_requested(void *data,
                                        struct river_window_v1 *window,
                                        struct river_output_v1 *output)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    GWLOutputState *os = output ? outputStateForRiverOutput(mgr, output) : nil;
    if (ws) {
        [mgr fullscreenWindow:ws onOutput:os];
    }
}

static void window_exit_fullscreen_requested(void *data,
                                             struct river_window_v1 *window)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        [mgr exitFullscreenWindow:ws];
    }
}

static void window_minimize_requested(void *data, struct river_window_v1 *window)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        [mgr minimizeWindow:ws];
    }
}

static void window_unreliable_pid(void *data, struct river_window_v1 *window,
                                  int32_t pid)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        ws.pid = pid;
    }
}

static void window_presentation_hint(void *data, struct river_window_v1 *window,
                                     uint32_t hint)
{
    /* Informational; we don't use this currently */
}

static void window_identifier(void *data, struct river_window_v1 *window,
                              const char *id)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        ws.identifier = id ? [NSString stringWithUTF8String:id] : nil;
    }
}

#pragma mark - Output Callbacks

static void output_removed(void *data, struct river_output_v1 *output)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLOutputState *os = outputStateForRiverOutput(mgr, output);
    if (os) {
        [mgr handleOutputRemoved:os];
    }
}

static void output_wl_output(void *data, struct river_output_v1 *output,
                             uint32_t name)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLOutputState *os = outputStateForRiverOutput(mgr, output);
    if (os) {
        os.wlOutputName = name;
    }
}

static void output_position(void *data, struct river_output_v1 *output,
                            int32_t x, int32_t y)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLOutputState *os = outputStateForRiverOutput(mgr, output);
    if (os) {
        os.x = x;
        os.y = y;
    }
}

static void output_dimensions(void *data, struct river_output_v1 *output,
                              int32_t width, int32_t height)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLOutputState *os = outputStateForRiverOutput(mgr, output);
    if (os) {
        os.width = width;
        os.height = height;
        NSLog(@"[WaylandWM] Output dimensions: %dx%d", width, height);
    }
}

#pragma mark - Seat Callbacks

static void seat_removed(void *data, struct river_seat_v1 *seat)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLSeatState *ss = seatStateForRiverSeat(mgr, seat);
    if (ss) {
        ss.removed = YES;
        river_seat_v1_destroy(seat);
        NSValue *key = [NSValue valueWithPointer:seat];
        [mgr.seats removeObjectForKey:key];
    }
}

static void seat_wl_seat(void *data, struct river_seat_v1 *seat,
                         uint32_t name)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLSeatState *ss = seatStateForRiverSeat(mgr, seat);
    if (ss) {
        ss.wlSeatName = name;

        /* Bind the underlying wl_seat so we can get wl_pointer events
         * on our decoration surfaces. */
        ss.wlSeat = wl_registry_bind(mgr.wlRegistry, name,
                                     &wl_seat_interface, 1);
        if (ss.wlSeat) {
            ss.wlPointer = wl_seat_get_pointer(ss.wlSeat);
            if (ss.wlPointer) {
                wl_pointer_add_listener(ss.wlPointer, &pointer_listener,
                                        (__bridge void *)mgr);
                NSLog(@"[WaylandWM] wl_pointer listener registered for seat %u", name);
            }
        }
    }
}

static void seat_pointer_enter(void *data, struct river_seat_v1 *seat,
                               struct river_window_v1 *window)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLSeatState *ss = seatStateForRiverSeat(mgr, seat);
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ss) {
        ss.pointerEnteredWindow = ws;
    }
}

static void seat_pointer_leave(void *data, struct river_seat_v1 *seat)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLSeatState *ss = seatStateForRiverSeat(mgr, seat);
    if (ss) {
        ss.pointerEnteredWindow = nil;
    }
}

static void seat_window_interaction(void *data, struct river_seat_v1 *seat,
                                    struct river_window_v1 *window)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLWindowState *ws = windowStateForRiverWindow(mgr, window);
    if (ws) {
        /* Focus-follows-click: focus the interacted window */
        [mgr focusWindow:ws];
    }
}

static void seat_shell_surface_interaction(void *data,
                                           struct river_seat_v1 *seat,
                                           struct river_shell_surface_v1 *shell_surface)
{
    /* Interaction with our shell surfaces (panels, overlays) */
}

static void seat_op_delta(void *data, struct river_seat_v1 *seat,
                          int32_t dx, int32_t dy)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLSeatState *ss = seatStateForRiverSeat(mgr, seat);
    if (ss) {
        [mgr handleOpDelta:ss dx:dx dy:dy];
    }
}

static void seat_op_release(void *data, struct river_seat_v1 *seat)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLSeatState *ss = seatStateForRiverSeat(mgr, seat);
    if (ss) {
        [mgr handleOpRelease:ss];
    }
}

static void seat_pointer_position(void *data, struct river_seat_v1 *seat,
                                  int32_t x, int32_t y)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLSeatState *ss = seatStateForRiverSeat(mgr, seat);
    if (ss) {
        ss.pointerX = x;
        ss.pointerY = y;
    }
}

#pragma mark - Layer Shell Output Callbacks

static void layer_shell_output_non_exclusive_area(
    void *data __attribute__((unused)),
    struct river_layer_shell_output_v1 *lso __attribute__((unused)),
    int32_t x, int32_t y, int32_t width, int32_t height)
{
    /* Find which output this belongs to and update workarea */
    /* TODO: implement once layer_shell_output listeners are hooked up */
    NSLog(@"[WaylandWM] Non-exclusive area: (%d, %d) %dx%d", x, y, width, height);
}

#pragma mark - XKB Binding Callbacks

static void xkb_binding_pressed(void *data,
                                struct river_xkb_binding_v1 *binding)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;

    /* Determine which binding was pressed */
    for (GWLSeatState *ss in mgr.seats.allValues) {
        if (ss.altTabBinding == binding) {
            [mgr handleAltTabPressed:NO];
            return;
        }
        if (ss.shiftAltTabBinding == binding) {
            [mgr handleAltTabPressed:YES];
            return;
        }
    }
}

static void xkb_binding_released(void *data,
                                 struct river_xkb_binding_v1 *binding)
{
    /* Alt-Tab released: finalize the switch (already done on press
     * since we don't have an overlay yet that requires hold behavior) */
}

static void xkb_binding_stop_repeat(void *data,
                                    struct river_xkb_binding_v1 *binding)
{
    /* Repeating stopped */
}

#pragma mark - wl_pointer Callbacks (decoration surface hit-testing)

static void pointer_enter(void *data, struct wl_pointer *pointer,
                          uint32_t serial __attribute__((unused)),
                          struct wl_surface *surface,
                          wl_fixed_t sx, wl_fixed_t sy)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLSeatState *ss = seatStateForWlPointer(mgr, pointer);
    if (!ss) return;

    GWLWindowState *ws = [mgr windowForTitlebarSurface:surface];
    ss.decorFocusSurface = ws ? surface : NULL;
    ss.decorFocusWindow = ws;
    ss.decorPtrX = wl_fixed_to_int(sx);
    ss.decorPtrY = wl_fixed_to_int(sy);
}

static void pointer_leave(void *data, struct wl_pointer *pointer,
                          uint32_t serial __attribute__((unused)),
                          struct wl_surface *surface)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLSeatState *ss = seatStateForWlPointer(mgr, pointer);
    if (!ss) return;

    if (ss.decorFocusSurface == surface) {
        ss.decorFocusSurface = NULL;
        ss.decorFocusWindow = nil;
    }
}

static void pointer_motion(void *data, struct wl_pointer *pointer,
                           uint32_t time __attribute__((unused)),
                           wl_fixed_t sx, wl_fixed_t sy)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLSeatState *ss = seatStateForWlPointer(mgr, pointer);
    if (!ss || !ss.decorFocusSurface) return;

    ss.decorPtrX = wl_fixed_to_int(sx);
    ss.decorPtrY = wl_fixed_to_int(sy);
}

static void pointer_button(void *data, struct wl_pointer *pointer,
                           uint32_t serial __attribute__((unused)),
                           uint32_t time __attribute__((unused)),
                           uint32_t button, uint32_t state)
{
    GWLRiverWindowManager *mgr = (__bridge GWLRiverWindowManager *)data;
    GWLSeatState *ss = seatStateForWlPointer(mgr, pointer);
    if (!ss) return;

    /* Only handle left-button press on decoration surfaces */
    if (state != WL_POINTER_BUTTON_STATE_PRESSED) return;
    if (button != BTN_LEFT) return;
    if (!ss.decorFocusWindow || !ss.decorFocusSurface) return;

    GWLWindowState *ws = ss.decorFocusWindow;
    GWLTitlebarButton btn = [[GWLDecorationRenderer sharedInstance]
        hitTestButtonAtX:ss.decorPtrX y:ss.decorPtrY forWindow:ws];

    if (btn == GWLTitlebarButtonNone) {
        /* Drag area: queue interactive move for next manage sequence */
        ss.pendingOpStartPointer = YES;
        ss.interactingWindow = ws;
    } else {
        /* Button click: queue button action for next manage sequence */
        ss.pendingTitlebarButton = btn;
        ss.pendingButtonWindow = ws;
    }

    /* Request a manage sequence to execute the queued action */
    river_window_manager_v1_manage_dirty(mgr.riverWM);
    wl_display_flush(mgr.wlDisplay);
}

static void pointer_axis(void *data __attribute__((unused)),
                         struct wl_pointer *pointer __attribute__((unused)),
                         uint32_t time __attribute__((unused)),
                         uint32_t axis __attribute__((unused)),
                         wl_fixed_t value __attribute__((unused))) {}

static void pointer_frame(void *data __attribute__((unused)),
                          struct wl_pointer *pointer __attribute__((unused))) {}

static void pointer_axis_source(void *data __attribute__((unused)),
                                struct wl_pointer *pointer __attribute__((unused)),
                                uint32_t axis_source __attribute__((unused))) {}

static void pointer_axis_stop(void *data __attribute__((unused)),
                              struct wl_pointer *pointer __attribute__((unused)),
                              uint32_t time __attribute__((unused)),
                              uint32_t axis __attribute__((unused))) {}

static void pointer_axis_discrete(void *data __attribute__((unused)),
                                  struct wl_pointer *pointer __attribute__((unused)),
                                  uint32_t axis __attribute__((unused)),
                                  int32_t discrete __attribute__((unused))) {}

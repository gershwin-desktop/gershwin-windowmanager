/*
 * GWLWindowState.h
 * Gershwin Window Manager - Wayland Mode
 *
 * Per-window state tracking. Equivalent to XCBFrame + XCBWindow + XCBTitleBar
 * in the X11 mode, but for River-managed Wayland windows.
 */

#import <Foundation/Foundation.h>
#include <wayland-client.h>
#include "wayland/generated/river-window-management-v1-client.h"

@class GWLRiverWindowManager;
@class GWLOutputState;

typedef NS_ENUM(NSInteger, GWLDecorationHint) {
    GWLDecorationHintOnlyCSD = 0,
    GWLDecorationHintPrefersCSD = 1,
    GWLDecorationHintPrefersSSD = 2,
    GWLDecorationHintNoPreference = 3,
};

@interface GWLWindowState : NSObject

/* River protocol objects */
@property (assign, nonatomic) struct river_window_v1 *riverWindow;
@property (assign, nonatomic) struct river_node_v1 *node;
@property (assign, nonatomic) struct river_decoration_v1 *decorationAbove;

/* Wayland surfaces for decorating */
@property (assign, nonatomic) struct wl_surface *titlebarSurface;
@property (assign, nonatomic) struct wl_buffer *titlebarBuffer;

/* mmap'd buffer data for the titlebar (kept alive while buffer is in use) */
@property (assign, nonatomic) void *titlebarData;
@property (assign, nonatomic) size_t titlebarDataSize;
@property (assign, nonatomic) int32_t lastRenderedWidth;

/* Back-reference to owning WM */
@property (weak, nonatomic) GWLRiverWindowManager *manager;

/* Window properties (from River events) */
@property (copy, nonatomic) NSString *appId;
@property (copy, nonatomic) NSString *title;
@property (copy, nonatomic) NSString *identifier;
@property (assign, nonatomic) int32_t pid;
@property (assign, nonatomic) GWLDecorationHint decorationHint;

/* Parent/child relationship */
@property (weak, nonatomic) GWLWindowState *parent;
@property (strong, nonatomic) NSMutableArray<GWLWindowState *> *children;

/* Dimensions */
@property (assign, nonatomic) int32_t width;
@property (assign, nonatomic) int32_t height;
@property (assign, nonatomic) int32_t x;
@property (assign, nonatomic) int32_t y;

/* Dimension hints (from window) */
@property (assign, nonatomic) int32_t minWidth;
@property (assign, nonatomic) int32_t minHeight;
@property (assign, nonatomic) int32_t maxWidth;
@property (assign, nonatomic) int32_t maxHeight;

/* Saved geometry for restore (unmaximize, unsnap) */
@property (assign, nonatomic) NSRect savedGeometry;
@property (assign, nonatomic) BOOL hasSavedGeometry;

/* Window state flags */
@property (assign, nonatomic) BOOL isMaximized;
@property (assign, nonatomic) BOOL isFullscreen;
@property (assign, nonatomic) BOOL isMinimized;
@property (assign, nonatomic) BOOL isFocused;
@property (assign, nonatomic) BOOL dimensionsReceived;
@property (assign, nonatomic) BOOL closed;

/* Fullscreen output */
@property (weak, nonatomic) GWLOutputState *fullscreenOutput;

/* Decoration state */
@property (assign, nonatomic) BOOL usingSSD;
@property (assign, nonatomic) BOOL needsDecorationUpdate;

/* Snap state */
typedef NS_ENUM(NSInteger, GWLSnapDirection) {
    GWLSnapNone = 0,
    GWLSnapLeft,
    GWLSnapRight,
    GWLSnapMaximize,
};
@property (assign, nonatomic) GWLSnapDirection snapDirection;

/* Whether this is a fixed-size window (min==max) */
- (BOOL)isFixedSize;

/* Returns YES if this window is a dialog (has a parent) */
- (BOOL)isDialog;

@end

/*
 * GWLDecorationRenderer.h
 * Gershwin Window Manager - Wayland Mode
 *
 * Renders GSTheme-based window decorations (titlebars) to Wayland
 * shared-memory buffers for use as River decoration surfaces.
 *
 * Wayland equivalent of URSThemeIntegration.
 */

#import <Foundation/Foundation.h>
#include <wayland-client.h>

@class GWLWindowState;

/* Button identifiers for hit testing on the decoration surface */
typedef NS_ENUM(NSInteger, GWLTitlebarButton) {
    GWLTitlebarButtonNone = 0,
    GWLTitlebarButtonMiniaturize,
    GWLTitlebarButtonClose,
    GWLTitlebarButtonZoom,
};

@interface GWLDecorationRenderer : NSObject

+ (instancetype)sharedInstance;

/*
 * Create the wl_surface and river_decoration_v1 for a window's titlebar.
 * Must be called before renderTitlebar:. Does nothing if already created.
 */
- (void)createDecorationSurfaceForWindow:(GWLWindowState *)ws
                              compositor:(struct wl_compositor *)compositor;

/*
 * Render the GSTheme titlebar into a wl_shm buffer and store it on the
 * window state. Call this when:
 *   - Window first gets SSD + dimensions
 *   - Title changes
 *   - Focus changes (active/inactive)
 *   - Window width changes
 *
 * Returns YES on success.
 */
- (BOOL)renderTitlebarForWindow:(GWLWindowState *)ws
                         active:(BOOL)isActive
                            shm:(struct wl_shm *)shm;

/*
 * Destroy the decoration surface and buffers for a window.
 * Called when a window is closed.
 */
- (void)destroyDecorationForWindow:(GWLWindowState *)ws;

/*
 * Hit-test a point on the titlebar to determine which button (if any)
 * was clicked. Coordinates are relative to the decoration surface (0,0)
 * at top-left of the titlebar.
 */
- (GWLTitlebarButton)hitTestButtonAtX:(int32_t)x y:(int32_t)y
                            forWindow:(GWLWindowState *)ws;

@end

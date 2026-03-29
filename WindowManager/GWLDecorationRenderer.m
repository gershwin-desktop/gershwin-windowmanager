/*
 * GWLDecorationRenderer.m
 * Gershwin Window Manager - Wayland Mode
 *
 * Renders GSTheme-based window decorations to Wayland shm buffers.
 * This is the Wayland equivalent of URSThemeIntegration.
 *
 * Pipeline:
 *   1. Create NSImage at titlebar size
 *   2. lockFocus → draw GSTheme + Eau buttons
 *   3. Extract NSBitmapImageRep, convert RGBA→BGRA
 *   4. Copy pixels into mmap'd wl_shm buffer
 *   5. Attach buffer to wl_surface, commit during render sequence
 */

#define _GNU_SOURCE  /* for memfd_create */

#import "GWLDecorationRenderer.h"
#import "GWLWindowState.h"

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#include <wayland-client.h>
#include "wayland/generated/river-window-management-v1-client.h"

#include <sys/mman.h>
#include <unistd.h>
#include <errno.h>

/* Titlebar layout constants (matching Eau theme / X11 mode) */
static const int kTitleBarHeight = 25;
static const float kButtonSize = 13.0f;
static const float kButtonSpacing = 17.0f;
static const float kButtonTopMargin = 6.0f;
static const float kButtonLeftMargin = 2.0f;

@implementation GWLDecorationRenderer

static GWLDecorationRenderer *sharedInstance = nil;

+ (instancetype)sharedInstance
{
    if (!sharedInstance) {
        sharedInstance = [[self alloc] init];
    }
    return sharedInstance;
}

#pragma mark - Decoration Surface Lifecycle

- (void)createDecorationSurfaceForWindow:(GWLWindowState *)ws
                              compositor:(struct wl_compositor *)compositor
{
    if (ws.titlebarSurface || ws.decorationAbove)
        return;

    if (!compositor || !ws.riverWindow)
        return;

    /* Create a fresh wl_surface (must have no role or buffer yet) */
    struct wl_surface *surface = wl_compositor_create_surface(compositor);
    if (!surface) {
        NSLog(@"[DecoRenderer] Failed to create wl_surface for titlebar");
        return;
    }

    /* Assign decoration-above role via River protocol */
    struct river_decoration_v1 *deco =
        river_window_v1_get_decoration_above(ws.riverWindow, surface);
    if (!deco) {
        NSLog(@"[DecoRenderer] Failed to get decoration_above");
        wl_surface_destroy(surface);
        return;
    }

    ws.titlebarSurface = surface;
    ws.decorationAbove = deco;

    NSLog(@"[DecoRenderer] Created decoration surface for '%@'", ws.title);
}

- (void)destroyDecorationForWindow:(GWLWindowState *)ws
{
    /* Clean up mmap'd buffer data */
    if (ws.titlebarData && ws.titlebarDataSize > 0) {
        munmap(ws.titlebarData, ws.titlebarDataSize);
        ws.titlebarData = NULL;
        ws.titlebarDataSize = 0;
    }

    /* Destroy wl_buffer */
    if (ws.titlebarBuffer) {
        wl_buffer_destroy(ws.titlebarBuffer);
        ws.titlebarBuffer = NULL;
    }

    /* Destroy decoration and surface */
    if (ws.decorationAbove) {
        river_decoration_v1_destroy(ws.decorationAbove);
        ws.decorationAbove = NULL;
    }

    if (ws.titlebarSurface) {
        wl_surface_destroy(ws.titlebarSurface);
        ws.titlebarSurface = NULL;
    }
}

#pragma mark - Titlebar Rendering

- (BOOL)renderTitlebarForWindow:(GWLWindowState *)ws
                         active:(BOOL)isActive
                            shm:(struct wl_shm *)shm
{
    if (!ws.titlebarSurface || !shm)
        return NO;

    int32_t width = ws.width;
    if (width <= 0)
        width = 200;  /* fallback minimum */

    int32_t height = kTitleBarHeight;
    int32_t stride = width * 4;  /* ARGB8888 = 4 bytes/pixel */
    int32_t bufSize = stride * height;

    /* --- Step 1: Create shared memory buffer --- */

    /* Clean up previous buffer */
    if (ws.titlebarData && ws.titlebarDataSize > 0) {
        munmap(ws.titlebarData, ws.titlebarDataSize);
        ws.titlebarData = NULL;
        ws.titlebarDataSize = 0;
    }
    if (ws.titlebarBuffer) {
        wl_buffer_destroy(ws.titlebarBuffer);
        ws.titlebarBuffer = NULL;
    }

    /* Create anonymous shared memory */
    int fd = memfd_create("gershwin-titlebar", MFD_CLOEXEC);
    if (fd < 0) {
        NSLog(@"[DecoRenderer] memfd_create failed: %s", strerror(errno));
        return NO;
    }

    if (ftruncate(fd, bufSize) < 0) {
        NSLog(@"[DecoRenderer] ftruncate failed: %s", strerror(errno));
        close(fd);
        return NO;
    }

    void *data = mmap(NULL, bufSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        NSLog(@"[DecoRenderer] mmap failed: %s", strerror(errno));
        close(fd);
        return NO;
    }

    /* Create wayland shm pool and buffer */
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, bufSize);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool, 0, width, height, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);

    if (!buffer) {
        NSLog(@"[DecoRenderer] Failed to create wl_buffer");
        munmap(data, bufSize);
        return NO;
    }

    /* --- Step 2: Render GSTheme titlebar into NSImage --- */

    NSSize titlebarSize = NSMakeSize(width, height);
    NSImage *titlebarImage = [[NSImage alloc] initWithSize:titlebarSize];

    [titlebarImage lockFocus];

    /* Clear with light gray background (matches X11 mode) */
    [[NSColor lightGrayColor] set];
    NSRectFill(NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height));

    NSRect titlebarRect = NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height);

    /* Build style mask based on window capabilities */
    NSUInteger styleMask = NSTitledWindowMask;
    if (![ws isFixedSize]) {
        styleMask |= NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask;
    } else if (![ws isDialog]) {
        /* Fixed-size but not dialog: close + miniaturize, no resize */
        styleMask |= NSClosableWindowMask | NSMiniaturizableWindowMask;
    }
    /* Dialogs with no parent get all buttons; dialogs may get fewer */

    GSThemeControlState state = isActive ? GSThemeNormalState : GSThemeSelectedState;

    /* Draw titlebar background + title text via GSTheme */
    GSTheme *theme = [GSTheme theme];
    [theme drawWindowBorder:titlebarRect
                  withFrame:titlebarRect
               forStyleMask:styleMask
                      state:state
                   andTitle:ws.title ?: @""];

    /* Draw Eau-style button balls */
    if (styleMask & NSMiniaturizableWindowMask) {
        NSButton *miniButton = [theme standardWindowButton:NSWindowMiniaturizeButton
                                              forStyleMask:styleMask];
        if (miniButton) {
            NSImage *img = [miniButton image];
            if (img) {
                [img drawInRect:NSMakeRect(kButtonLeftMargin,
                                           kButtonTopMargin,
                                           kButtonSize, kButtonSize)
                       fromRect:NSZeroRect
                      operation:NSCompositeSourceOver
                       fraction:1.0];
            }
        }
    }

    if (styleMask & NSClosableWindowMask) {
        NSButton *closeButton = [theme standardWindowButton:NSWindowCloseButton
                                               forStyleMask:styleMask];
        if (closeButton) {
            NSImage *img = [closeButton image];
            if (img) {
                [img drawInRect:NSMakeRect(kButtonLeftMargin + kButtonSpacing,
                                           kButtonTopMargin,
                                           kButtonSize, kButtonSize)
                       fromRect:NSZeroRect
                      operation:NSCompositeSourceOver
                       fraction:1.0];
            }
        }
    }

    if (styleMask & NSResizableWindowMask) {
        NSButton *zoomButton = [theme standardWindowButton:NSWindowZoomButton
                                              forStyleMask:styleMask];
        if (zoomButton) {
            NSImage *img = [zoomButton image];
            if (img) {
                [img drawInRect:NSMakeRect(kButtonLeftMargin + 2 * kButtonSpacing,
                                           kButtonTopMargin,
                                           kButtonSize, kButtonSize)
                       fromRect:NSZeroRect
                      operation:NSCompositeSourceOver
                       fraction:1.0];
            }
        }
    }

    [titlebarImage unlockFocus];

    /* For inactive state, apply desaturation overlay */
    if (!isActive) {
        titlebarImage = [self createDimmedImage:titlebarImage];
    }

    /* --- Step 3: Extract bitmap and convert RGBA → BGRA --- */

    NSBitmapImageRep *bitmap = nil;
    for (NSImageRep *rep in [titlebarImage representations]) {
        if ([rep isKindOfClass:[NSBitmapImageRep class]]) {
            bitmap = (NSBitmapImageRep *)rep;
            break;
        }
    }
    if (!bitmap) {
        NSData *tiff = [titlebarImage TIFFRepresentation];
        bitmap = [NSBitmapImageRep imageRepWithData:tiff];
    }
    if (!bitmap) {
        NSLog(@"[DecoRenderer] Failed to get bitmap from titlebar image");
        wl_buffer_destroy(buffer);
        munmap(data, bufSize);
        return NO;
    }

    unsigned char *srcPixels = [bitmap bitmapData];
    int bmpWidth = (int)[bitmap pixelsWide];
    int bmpHeight = (int)[bitmap pixelsHigh];
    int srcBytesPerRow = (int)[bitmap bytesPerRow];

    /* Convert RGBA → BGRA (WL_SHM_FORMAT_ARGB8888 is BGRA on LE) and
     * copy into the mmap'd buffer */
    uint32_t *dst = (uint32_t *)data;

    for (int y = 0; y < bmpHeight && y < height; y++) {
        uint32_t *srcRow = (uint32_t *)(srcPixels + y * srcBytesPerRow);
        uint32_t *dstRow = dst + y * (stride / 4);

        for (int x = 0; x < bmpWidth && x < width; x++) {
            uint32_t pixel = srcRow[x];
            /* RGBA LE memory: R G B A → need BGRA LE: B G R A */
            uint32_t r = (pixel >> 0)  & 0xFF;
            uint32_t g = (pixel >> 8)  & 0xFF;
            uint32_t b = (pixel >> 16) & 0xFF;
            uint32_t a = (pixel >> 24) & 0xFF;
            dstRow[x] = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }

    /* --- Step 4: Store on window state --- */
    ws.titlebarBuffer = buffer;
    ws.titlebarData = data;
    ws.titlebarDataSize = bufSize;
    ws.lastRenderedWidth = width;
    ws.needsDecorationUpdate = NO;

    NSLog(@"[DecoRenderer] Rendered %s titlebar %dx%d for '%@'",
          isActive ? "active" : "inactive", width, height, ws.title);

    return YES;
}

#pragma mark - Inactive Dimming

- (NSImage *)createDimmedImage:(NSImage *)image
{
    if (!image)
        return nil;

    NSSize size = [image size];
    NSImage *dimmed = [[NSImage alloc] initWithSize:size];

    [dimmed lockFocus];

    [image drawInRect:NSMakeRect(0, 0, size.width, size.height)
             fromRect:NSZeroRect
            operation:NSCompositeSourceOver
             fraction:1.0];

    /* Semi-transparent gray overlay for desaturation (matching X11 mode) */
    [[NSColor colorWithCalibratedWhite:0.5 alpha:0.35] set];
    NSRectFillUsingOperation(NSMakeRect(0, 0, size.width, size.height),
                             NSCompositeSourceAtop);

    [dimmed unlockFocus];

    return dimmed;
}

#pragma mark - Button Hit Testing

- (GWLTitlebarButton)hitTestButtonAtX:(int32_t)x y:(int32_t)y
                            forWindow:(GWLWindowState *)ws
{
    /* Check Y bounds */
    if (y < (int32_t)kButtonTopMargin ||
        y > (int32_t)(kButtonTopMargin + kButtonSize))
        return GWLTitlebarButtonNone;

    /* Miniaturize button: leftMargin .. leftMargin + buttonSize */
    if (x >= (int32_t)kButtonLeftMargin &&
        x <= (int32_t)(kButtonLeftMargin + kButtonSize))
        return GWLTitlebarButtonMiniaturize;

    /* Close button: leftMargin + spacing .. leftMargin + spacing + buttonSize */
    float closeX = kButtonLeftMargin + kButtonSpacing;
    if (x >= (int32_t)closeX &&
        x <= (int32_t)(closeX + kButtonSize))
        return GWLTitlebarButtonClose;

    /* Zoom button: leftMargin + 2*spacing .. leftMargin + 2*spacing + buttonSize */
    if (![ws isFixedSize]) {
        float zoomX = kButtonLeftMargin + 2 * kButtonSpacing;
        if (x >= (int32_t)zoomX &&
            x <= (int32_t)(zoomX + kButtonSize))
            return GWLTitlebarButtonZoom;
    }

    return GWLTitlebarButtonNone;
}

@end

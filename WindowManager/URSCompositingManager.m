//
//  URSCompositingManager.m
//  uroswm - XRender Compositing Manager
//
//  - Proper damage tracking and subtraction
//  - Window pixmap recreation on resize
//  - Double-buffered rendering
//  - Region-based partial repaints
//  - Proper resource cleanup
//

#define _DEFAULT_SOURCE  // For usleep
#import "URSCompositingManager.h"
#import <XCBKit/XCBScreen.h>
#import <xcb/xcb.h>
#import <xcb/composite.h>
#import <xcb/xfixes.h>
#import <xcb/render.h>
#import <xcb/damage.h>
#import <xcb/shm.h>
#import <sys/shm.h>
#import <unistd.h>  // for usleep
#import <sys/ipc.h>
#import <math.h>

// Shadow configuration
#define SHADOW_RADIUS 12
#define SHADOW_OFFSET_X -18
#define SHADOW_OFFSET_Y -10
#define SHADOW_OPACITY 0.40

// Per-window compositing data
@interface URSCompositeWindow : NSObject
@property (assign, nonatomic) xcb_window_t windowId;
@property (assign, nonatomic) xcb_window_t parentWindowId;
@property (assign, nonatomic) xcb_damage_damage_t damage;
@property (assign, nonatomic) xcb_pixmap_t nameWindowPixmap;
@property (assign, nonatomic) xcb_render_picture_t picture;
@property (assign, nonatomic) xcb_xfixes_region_t borderSize;
@property (assign, nonatomic) xcb_xfixes_region_t extents;
@property (assign, nonatomic) BOOL damaged;
@property (assign, nonatomic) BOOL viewable;
@property (assign, nonatomic) BOOL redirected;
@property (assign, nonatomic) BOOL overrideRedirect;
// OPTIMIZATION: Lazy picture creation - defer until first paint
@property (assign, nonatomic) BOOL pictureValid;
@property (assign, nonatomic) BOOL needsPictureCreation;
// Cached geometry
@property (assign, nonatomic) int16_t x;
@property (assign, nonatomic) int16_t y;
@property (assign, nonatomic) uint16_t width;
@property (assign, nonatomic) uint16_t height;
@property (assign, nonatomic) uint16_t borderWidth;
@property (assign, nonatomic) uint8_t depth;
@property (assign, nonatomic) xcb_visualid_t visual;
// Shadow properties
@property (assign, nonatomic) xcb_render_picture_t shadowPicture;
@property (assign, nonatomic) xcb_pixmap_t shadowPixmap;
@property (assign, nonatomic) int16_t shadowOffsetX;
@property (assign, nonatomic) int16_t shadowOffsetY;
@property (assign, nonatomic) uint16_t shadowWidth;
@property (assign, nonatomic) uint16_t shadowHeight;
// Animation state
@property (assign, nonatomic) BOOL animating;
@property (assign, nonatomic) BOOL animatingMinimize;
@property (assign, nonatomic) BOOL animatingFade;
@property (assign, nonatomic) NSTimeInterval animationStart;
@property (assign, nonatomic) NSTimeInterval animationDuration;
@property (assign, nonatomic) XCBRect animationStartRect;
@property (assign, nonatomic) XCBRect animationEndRect;
@end

@implementation URSCompositeWindow
- (instancetype)init {
    self = [super init];
    if (self) {
        _windowId = XCB_NONE;
        _parentWindowId = XCB_NONE;
        _damage = XCB_NONE;
        _nameWindowPixmap = XCB_NONE;
        _picture = XCB_NONE;
        _borderSize = XCB_NONE;
        _extents = XCB_NONE;
        _damaged = NO;
        _viewable = NO;
        _redirected = YES;
        _overrideRedirect = NO;
        // OPTIMIZATION: Lazy picture creation
        _pictureValid = NO;
        _needsPictureCreation = YES;
        _shadowPicture = XCB_NONE;
        _shadowPixmap = XCB_NONE;
        _shadowOffsetX = 0;
        _shadowOffsetY = 0;
        _shadowWidth = 0;
        _shadowHeight = 0;
        _animating = NO;
        _animatingMinimize = NO;
        _animatingFade = NO;
        _animationStart = 0;
        _animationDuration = 0;
        _animationStartRect = XCBInvalidRect;
        _animationEndRect = XCBInvalidRect;
    }
    return self;
}
@end

@interface URSCompositingManager ()

@property (strong, nonatomic) XCBConnection *connection;
@property (assign, nonatomic) xcb_window_t overlayWindow;
@property (assign, nonatomic) xcb_window_t outputWindow;         // Child of overlay for actual rendering
@property (assign, nonatomic) xcb_render_picture_t rootPicture;
@property (assign, nonatomic) xcb_render_picture_t rootBuffer;   // Double buffer
@property (assign, nonatomic) xcb_render_picture_t blackPicture; // Solid black for shadows
@property (assign, nonatomic) xcb_pixmap_t rootPixmap;           // Backing pixmap for buffer
@property (strong, nonatomic) NSMutableDictionary<NSNumber *, URSCompositeWindow *> *cwindows;

@property (assign, nonatomic) BOOL compositingEnabled;
@property (assign, nonatomic) BOOL compositingActive;
@property (assign, nonatomic) BOOL extensionsAvailable;

// Accumulated damage region
@property (assign, nonatomic) xcb_xfixes_region_t allDamage;
@property (assign, nonatomic) xcb_xfixes_region_t screenRegion;

// Gaussian shadow data (pre-computed once)
@property (assign, nonatomic) int gaussianSize;
@property (assign, nonatomic) double *gaussianMap;  // Gaussian convolution kernel
@property (assign, nonatomic) uint8_t *shadowCorner; // Pre-computed shadow corners
@property (assign, nonatomic) uint8_t *shadowTop;    // Pre-computed shadow top/bottom

// Extension version tracking
@property (assign, nonatomic) uint8_t compositeOpcode;
@property (assign, nonatomic) uint8_t renderOpcode;
@property (assign, nonatomic) uint8_t damageEventBase;
@property (assign, nonatomic) uint8_t fixesOpcode;

// Throttling to prevent excessive recomposites
@property (assign, nonatomic) BOOL repairScheduled;
@property (assign, nonatomic) NSTimeInterval lastRepairTime;
@property (assign, nonatomic) NSUInteger repairFrameCounter; // Frame counter for throttling during drag

// Cached screen info
@property (assign, nonatomic) uint16_t screenWidth;
@property (assign, nonatomic) uint16_t screenHeight;
@property (assign, nonatomic) xcb_window_t rootWindow;
@property (assign, nonatomic) xcb_render_pictformat_t rootFormat;
@property (assign, nonatomic) xcb_render_pictformat_t argbFormat;

// OPTIMIZATION: Cached visual-to-format mappings (avoids repeated xcb_render_query_pict_formats)
@property (strong, nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *visualFormatCache;
@property (strong, nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *depthFormatCache;

// OPTIMIZATION: Cached window stacking order (avoids xcb_query_tree on every paint)
@property (strong, nonatomic) NSMutableArray<NSNumber *> *windowStackingOrder;
@property (assign, nonatomic) BOOL stackingOrderDirty;

// OPTIMIZATION: MIT-SHM shared memory support for zero-copy transfers
@property (assign, nonatomic) BOOL shmAvailable;
@property (assign, nonatomic) xcb_shm_seg_t shmSeg;
@property (assign, nonatomic) int shmId;
@property (assign, nonatomic) void *shmAddr;
@property (assign, nonatomic) size_t shmSize;

// Animation timer
@property (strong, nonatomic) NSTimer *animationTimer;
@property (assign, nonatomic) NSUInteger activeAnimations;

@end

@implementation URSCompositingManager

- (void)updateAbsolutePositionForWindow:(URSCompositeWindow *)cw {
    if (!cw || cw.windowId == XCB_NONE || self.rootWindow == XCB_NONE) {
        return;
    }

    xcb_connection_t *conn = [self.connection connection];
    xcb_translate_coordinates_cookie_t cookie = xcb_translate_coordinates(conn,
                                                                          cw.windowId,
                                                                          self.rootWindow,
                                                                          0, 0);
    xcb_translate_coordinates_reply_t *reply = xcb_translate_coordinates_reply(conn, cookie, NULL);
    if (!reply) {
        return;
    }

    cw.x = reply->dst_x;
    cw.y = reply->dst_y;
    free(reply);
}

+ (instancetype)sharedManager {
    static URSCompositingManager *sharedManager = nil;
    @synchronized(self) {
        if (!sharedManager) {
            sharedManager = [[URSCompositingManager alloc] init];
        }
    }
    return sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _compositingEnabled = NO;
        _compositingActive = NO;
        _extensionsAvailable = NO;
        _overlayWindow = XCB_NONE;
        _outputWindow = XCB_NONE;
        _rootPicture = XCB_NONE;
        _rootBuffer = XCB_NONE;
        _rootPixmap = XCB_NONE;
        _allDamage = XCB_NONE;
        _screenRegion = XCB_NONE;
        _repairScheduled = NO;
        _lastRepairTime = 0;
        _repairFrameCounter = 0;
        _cwindows = [[NSMutableDictionary alloc] init];
        
        // OPTIMIZATION: Initialize format caches
        _visualFormatCache = [[NSMutableDictionary alloc] init];
        _depthFormatCache = [[NSMutableDictionary alloc] init];
        
        // OPTIMIZATION: Initialize stacking order cache
        _windowStackingOrder = [[NSMutableArray alloc] init];
        _stackingOrderDirty = YES;
        
        // OPTIMIZATION: Initialize MIT-SHM (will be checked during extension query)
        _shmAvailable = NO;
        _shmSeg = XCB_NONE;
        _shmId = -1;
        _shmAddr = NULL;
        _shmSize = 0;

        _animationTimer = nil;
        _activeAnimations = 0;
        
        // Initialize Gaussian shadow data
        _gaussianMap = make_gaussian_map((double)SHADOW_RADIUS, &_gaussianSize);
        if (_gaussianMap) {
            [self presumGaussianMap];
            NSLog(@"[CompositingManager] Initialized Gaussian shadow map (size=%d)", _gaussianSize);
        } else {
            NSLog(@"[CompositingManager] WARNING: Failed to create Gaussian map");
        }
    }
    return self;
}

#pragma mark - Initialization

- (BOOL)initializeWithConnection:(XCBConnection *)connection {
    if (!connection) {
        NSLog(@"[CompositingManager] ERROR: No connection provided");
        return NO;
    }
    
    self.connection = connection;
    NSLog(@"[CompositingManager] Checking for required X extensions...");
    
    if (![self checkExtensions]) {
        NSLog(@"[CompositingManager] Required extensions not available");
        NSLog(@"[CompositingManager] Falling back to non-compositing mode");
        return NO;
    }
    
    // Cache screen info
    XCBScreen *screen = [[self.connection screens] firstObject];
    if (!screen) {
        NSLog(@"[CompositingManager] No screen available");
        return NO;
    }
    
    self.screenWidth = [screen screen]->width_in_pixels;
    self.screenHeight = [screen screen]->height_in_pixels;
    self.rootWindow = [screen screen]->root;
    
    // Find render formats
    if (![self findRenderFormats]) {
        NSLog(@"[CompositingManager] Failed to find render formats");
        return NO;
    }
    
    self.extensionsAvailable = YES;
    self.compositingEnabled = YES;
    NSLog(@"[CompositingManager] Initialization successful - compositing available");
    return YES;
}

- (BOOL)checkExtensions {
    @try {
        xcb_connection_t *conn = [self.connection connection];
        BOOL allExtensionsOK = YES;
        
        // Check COMPOSITE extension
        const xcb_query_extension_reply_t *composite_ext = 
            xcb_get_extension_data(conn, &xcb_composite_id);
        
        if (!composite_ext || !composite_ext->present) {
            NSLog(@"[CompositingManager] COMPOSITE extension not available");
            allExtensionsOK = NO;
        } else {
            self.compositeOpcode = composite_ext->major_opcode;
            
            xcb_composite_query_version_cookie_t version_cookie = 
                xcb_composite_query_version(conn, 
                                           XCB_COMPOSITE_MAJOR_VERSION, 
                                           XCB_COMPOSITE_MINOR_VERSION);
            xcb_composite_query_version_reply_t *version_reply = 
                xcb_composite_query_version_reply(conn, version_cookie, NULL);
            
            if (version_reply) {
                NSLog(@"[CompositingManager] COMPOSITE v%d.%d available", 
                      version_reply->major_version, version_reply->minor_version);
                // Need at least 0.2 for NameWindowPixmap
                if (version_reply->major_version == 0 && version_reply->minor_version < 2) {
                    NSLog(@"[CompositingManager] COMPOSITE version too old (need >= 0.2)");
                    allExtensionsOK = NO;
                }
                free(version_reply);
            }
        }
        
        // Check RENDER extension
        const xcb_query_extension_reply_t *render_ext = 
            xcb_get_extension_data(conn, &xcb_render_id);
        
        if (!render_ext || !render_ext->present) {
            NSLog(@"[CompositingManager] RENDER extension not available");
            allExtensionsOK = NO;
        } else {
            self.renderOpcode = render_ext->major_opcode;
            NSLog(@"[CompositingManager] RENDER extension available");
        }
        
        // Check DAMAGE extension
        const xcb_query_extension_reply_t *damage_ext = 
            xcb_get_extension_data(conn, &xcb_damage_id);
        
        if (!damage_ext || !damage_ext->present) {
            NSLog(@"[CompositingManager] DAMAGE extension not available");
            allExtensionsOK = NO;
        } else {
            self.damageEventBase = damage_ext->first_event;
            
            // Query DAMAGE version
            xcb_damage_query_version_cookie_t damage_version_cookie = 
                xcb_damage_query_version(conn, 
                                        XCB_DAMAGE_MAJOR_VERSION,
                                        XCB_DAMAGE_MINOR_VERSION);
            xcb_damage_query_version_reply_t *damage_version_reply =
                xcb_damage_query_version_reply(conn, damage_version_cookie, NULL);
            if (damage_version_reply) {
                NSLog(@"[CompositingManager] DAMAGE v%d.%d available (event base: %u)", 
                      damage_version_reply->major_version,
                      damage_version_reply->minor_version,
                      self.damageEventBase);
                free(damage_version_reply);
            }
        }
        
        // Check XFIXES extension
        const xcb_query_extension_reply_t *fixes_ext = 
            xcb_get_extension_data(conn, &xcb_xfixes_id);
        
        if (!fixes_ext || !fixes_ext->present) {
            NSLog(@"[CompositingManager] XFIXES extension not available");
            allExtensionsOK = NO;
        } else {
            self.fixesOpcode = fixes_ext->major_opcode;
            
            xcb_xfixes_query_version_cookie_t xfixes_cookie =
                xcb_xfixes_query_version(conn, 
                                        XCB_XFIXES_MAJOR_VERSION,
                                        XCB_XFIXES_MINOR_VERSION);
            xcb_xfixes_query_version_reply_t *xfixes_reply =
                xcb_xfixes_query_version_reply(conn, xfixes_cookie, NULL);
            if (xfixes_reply) {
                NSLog(@"[CompositingManager] XFIXES v%d.%d available", 
                      xfixes_reply->major_version, xfixes_reply->minor_version);
                free(xfixes_reply);
            }
        }
        
        // OPTIMIZATION: Check MIT-SHM extension (optional, for zero-copy transfers)
        const xcb_query_extension_reply_t *shm_ext = 
            xcb_get_extension_data(conn, &xcb_shm_id);
        
        if (shm_ext && shm_ext->present) {
            xcb_shm_query_version_cookie_t shm_cookie = xcb_shm_query_version(conn);
            xcb_shm_query_version_reply_t *shm_reply = 
                xcb_shm_query_version_reply(conn, shm_cookie, NULL);
            if (shm_reply) {
                self.shmAvailable = YES;
                NSLog(@"[CompositingManager] MIT-SHM v%d.%d available (shared pixmaps: %s)", 
                      shm_reply->major_version, shm_reply->minor_version,
                      shm_reply->shared_pixmaps ? "yes" : "no");
                free(shm_reply);
            }
        } else {
            NSLog(@"[CompositingManager] MIT-SHM not available (using standard transfers)");
        }
        
        return allExtensionsOK;
        
    } @catch (NSException *exception) {
        NSLog(@"[CompositingManager] EXCEPTION checking extensions: %@", exception.reason);
        return NO;
    }
}

- (BOOL)findRenderFormats {
    xcb_connection_t *conn = [self.connection connection];
    
    xcb_render_query_pict_formats_cookie_t formats_cookie = 
        xcb_render_query_pict_formats(conn);
    xcb_render_query_pict_formats_reply_t *formats_reply = 
        xcb_render_query_pict_formats_reply(conn, formats_cookie, NULL);
    
    if (!formats_reply) {
        NSLog(@"[CompositingManager] Failed to query render formats");
        return NO;
    }
    
    // Find format for root window (typically 24-bit RGB)
    self.rootFormat = XCB_NONE;
    self.argbFormat = XCB_NONE;
    
    // OPTIMIZATION: Build depth-to-format cache while iterating
    xcb_render_pictforminfo_iterator_t iter = 
        xcb_render_query_pict_formats_formats_iterator(formats_reply);
    
    for (; iter.rem; xcb_render_pictforminfo_next(&iter)) {
        xcb_render_pictforminfo_t *fmt = iter.data;
        
        // Cache first format found for each depth
        NSNumber *depthKey = @(fmt->depth);
        if (!self.depthFormatCache[depthKey]) {
            self.depthFormatCache[depthKey] = @(fmt->id);
        }
        
        // Look for 24-bit format (RGB without alpha)
        if (fmt->depth == 24 && fmt->type == XCB_RENDER_PICT_TYPE_DIRECT) {
            if (self.rootFormat == XCB_NONE) {
                self.rootFormat = fmt->id;
            }
        }
        
        // Look for 32-bit ARGB format with 8-bit channels
        if (fmt->depth == 32 && fmt->type == XCB_RENDER_PICT_TYPE_DIRECT) {
            // Check if it has alpha AND 8-bit channels (mask = 0xFF)
            if (fmt->direct.alpha_mask == 0xFF &&
                fmt->direct.red_mask == 0xFF &&
                fmt->direct.green_mask == 0xFF &&
                fmt->direct.blue_mask == 0xFF) {
                // Prefer BGRA layout (alpha_shift=24, red_shift=16) which is standard X11 format
                // But accept any 8-bit ARGB format if we don't have one yet
                if (self.argbFormat == XCB_NONE || fmt->direct.alpha_shift == 24) {
                    self.argbFormat = fmt->id;
                    NSLog(@"[Render] Selected ARGB32 format: id=%u, shifts: R=%d G=%d B=%d A=%d, masks: R=0x%x G=0x%x B=0x%x A=0x%x",
                          fmt->id, fmt->direct.red_shift, fmt->direct.green_shift, 
                          fmt->direct.blue_shift, fmt->direct.alpha_shift,
                          fmt->direct.red_mask, fmt->direct.green_mask,
                          fmt->direct.blue_mask, fmt->direct.alpha_mask);
                }
            } else {
                NSLog(@"[Render] Skipping non-8bit ARGB32 format: id=%u, alpha_mask=0x%x",
                      fmt->id, fmt->direct.alpha_mask);
            }
        }
    }
    
    // OPTIMIZATION: Build visual-to-format cache from screens data
    xcb_render_pictscreen_iterator_t screen_iter = 
        xcb_render_query_pict_formats_screens_iterator(formats_reply);
    
    for (; screen_iter.rem; xcb_render_pictscreen_next(&screen_iter)) {
        xcb_render_pictdepth_iterator_t depth_iter = 
            xcb_render_pictscreen_depths_iterator(screen_iter.data);
        
        for (; depth_iter.rem; xcb_render_pictdepth_next(&depth_iter)) {
            xcb_render_pictvisual_iterator_t visual_iter = 
                xcb_render_pictdepth_visuals_iterator(depth_iter.data);
            
            for (; visual_iter.rem; xcb_render_pictvisual_next(&visual_iter)) {
                NSNumber *visualKey = @(visual_iter.data->visual);
                self.visualFormatCache[visualKey] = @(visual_iter.data->format);
            }
        }
    }
    
    NSLog(@"[CompositingManager] Cached %lu visual formats, %lu depth formats", 
          (unsigned long)[self.visualFormatCache count],
          (unsigned long)[self.depthFormatCache count]);
    
    free(formats_reply);
    
    if (self.rootFormat == XCB_NONE) {
        NSLog(@"[CompositingManager] Could not find 24-bit render format");
        return NO;
    }
    
    NSLog(@"[CompositingManager] Found render formats - root: %u, argb: %u", 
          self.rootFormat, self.argbFormat);
    return YES;
}

// Create a solid color picture (for shadow rendering)
- (xcb_render_picture_t)createSolidPicture:(double)r g:(double)g b:(double)b a:(double)a {
    xcb_connection_t *conn = [self.connection connection];
    
    // Create a 1x1 pixmap
    xcb_pixmap_t pixmap = xcb_generate_id(conn);
    xcb_create_pixmap(conn, 32, pixmap, self.rootWindow, 1, 1);
    
    // Create Picture with repeat
    xcb_render_picture_t picture = xcb_generate_id(conn);
    uint32_t values[] = { 1 };  // CPRepeat = 1
    xcb_render_create_picture(conn, picture, pixmap, self.argbFormat, 
                             XCB_RENDER_CP_REPEAT, values);
    
    // Fill with solid color
    xcb_render_color_t color;
    color.red = (uint16_t)(r * 0xFFFF);
    color.green = (uint16_t)(g * 0xFFFF);
    color.blue = (uint16_t)(b * 0xFFFF);
    color.alpha = (uint16_t)(a * 0xFFFF);
    
    xcb_rectangle_t rect = {0, 0, 1, 1};
    xcb_render_fill_rectangles(conn, XCB_RENDER_PICT_OP_SRC, picture, color, 1, &rect);
    
    // Free pixmap (Picture holds reference)
    xcb_free_pixmap(conn, pixmap);
    
    return picture;
}

// Helper to find picture format by depth
// Helper to find picture format by depth and type
- (xcb_render_pictformat_t)findPictFormat:(uint8_t)depth {
    xcb_connection_t *conn = [self.connection connection];
    
    xcb_render_query_pict_formats_cookie_t formats_cookie = 
        xcb_render_query_pict_formats(conn);
    xcb_render_query_pict_formats_reply_t *formats_reply = 
        xcb_render_query_pict_formats_reply(conn, formats_cookie, NULL);
    
    if (!formats_reply) {
        NSLog(@"[Shadow] Failed to query formats");
        return XCB_NONE;
    }
    
    xcb_render_pictformat_t result = XCB_NONE;
    xcb_render_pictforminfo_iterator_t iter = 
        xcb_render_query_pict_formats_formats_iterator(formats_reply);
    
    // For depth 8, we need A8 format (Direct with only alpha channel)
    for (; iter.rem; xcb_render_pictforminfo_next(&iter)) {
        xcb_render_pictforminfo_t *fmt = iter.data;
        if (fmt->depth == depth && fmt->type == XCB_RENDER_PICT_TYPE_DIRECT) {
            // For A8, check that it has alpha channel
            if (depth == 8) {
                xcb_render_directformat_t *direct = &fmt->direct;
                // A8 should have alpha_shift=0, alpha_mask=0xFF, and no RGB
                if (direct->alpha_mask == 0xFF && direct->red_mask == 0 && 
                    direct->green_mask == 0 && direct->blue_mask == 0) {
                    result = fmt->id;
                    NSLog(@"[Shadow] Found A8 format: id=%u alpha_shift=%d alpha_mask=0x%x", 
                          fmt->id, direct->alpha_shift, direct->alpha_mask);
                    break;
                }
            } else {
                result = fmt->id;
                NSLog(@"[Shadow] Found format for depth %d: id=%u type=%d", depth, fmt->id, fmt->type);
                break;
            }
        }
    }
    
    if (result == XCB_NONE) {
        NSLog(@"[Shadow] WARNING: No suitable format found for depth %d", depth);
    }
    
    free(formats_reply);
    return result;
}

#pragma mark - Activation

- (BOOL)activateCompositing {
    if (!self.compositingEnabled) {
        NSLog(@"[CompositingManager] Cannot activate - not initialized properly");
        return NO;
    }
    
    if (self.compositingActive) {
        NSLog(@"[CompositingManager] Compositing already active");
        return YES;
    }
    
    @try {
        NSLog(@"[CompositingManager] Activating compositing...");
        
        // Redirect all windows for compositing
        if (![self redirectWindows]) {
            NSLog(@"[CompositingManager] Failed to redirect windows");
            return NO;
        }
        
        // Create overlay window
        if (![self createOverlayWindow]) {
            NSLog(@"[CompositingManager] Failed to create overlay window");
            [self cleanup];
            return NO;
        }
        
        // Create root picture and buffer
        if (![self createRootBuffer]) {
            NSLog(@"[CompositingManager] Failed to create root buffer");
            [self cleanup];
            return NO;
        }
        
        // Add all existing windows
        [self addAllWindows];
        
        self.compositingActive = YES;
        NSLog(@"[CompositingManager] Compositing activated successfully");
        
        // Damage entire screen to trigger initial paint
        [self damageScreen];
        
        return YES;
        
    } @catch (NSException *exception) {
        NSLog(@"[CompositingManager] EXCEPTION activating compositing: %@", exception.reason);
        [self cleanup];
        return NO;
    }
}

- (BOOL)redirectWindows {
    @try {
        xcb_connection_t *conn = [self.connection connection];
        
        xcb_generic_error_t *error = NULL;
        xcb_void_cookie_t cookie = xcb_composite_redirect_subwindows_checked(
            conn, self.rootWindow, XCB_COMPOSITE_REDIRECT_MANUAL);
        error = xcb_request_check(conn, cookie);
        
        if (error) {
            NSLog(@"[CompositingManager] Error redirecting windows: %d", error->error_code);
            free(error);
            return NO;
        }
        
        [self.connection flush];
        NSLog(@"[CompositingManager] Windows redirected to offscreen buffers");
        return YES;
        
    } @catch (NSException *exception) {
        NSLog(@"[CompositingManager] EXCEPTION redirecting windows: %@", exception.reason);
        return NO;
    }
}

- (BOOL)createOverlayWindow {
    @try {
        xcb_connection_t *conn = [self.connection connection];
        XCBScreen *screen = [[self.connection screens] firstObject];
        
        xcb_composite_get_overlay_window_cookie_t overlay_cookie = 
            xcb_composite_get_overlay_window(conn, self.rootWindow);
        xcb_composite_get_overlay_window_reply_t *overlay_reply = 
            xcb_composite_get_overlay_window_reply(conn, overlay_cookie, NULL);
        
        if (!overlay_reply) {
            NSLog(@"[CompositingManager] Failed to get overlay window");
            return NO;
        }
        
        self.overlayWindow = overlay_reply->overlay_win;
        free(overlay_reply);
        
        NSLog(@"[CompositingManager] Got overlay window: %u", self.overlayWindow);
        
        // Map the overlay window first
        xcb_map_window(conn, self.overlayWindow);
        
        // Make overlay window transparent to input using XFixes
        // ShapeBounding = 0 means use default (full window visible)
        // ShapeInput = empty region means no input captured
        xcb_xfixes_region_t region = xcb_generate_id(conn);
        xcb_xfixes_create_region(conn, region, 0, NULL);
        
        // Setting to 0 resets to default bounding shape (full rectangle)
        xcb_xfixes_set_window_shape_region(conn, self.overlayWindow,
                                           XCB_SHAPE_SK_BOUNDING, 0, 0, XCB_NONE);

        // Empty region = no input captured, all input passes through
        xcb_xfixes_set_window_shape_region(conn, self.overlayWindow,
                                           XCB_SHAPE_SK_INPUT, 0, 0, region);
        xcb_xfixes_destroy_region(conn, region);
        
        // Create a child window inside overlay for actual rendering
        self.outputWindow = xcb_generate_id(conn);
        xcb_create_window(conn,
                         [screen screen]->root_depth,
                         self.outputWindow,
                         self.overlayWindow,  // Parent is the overlay
                         0, 0,
                         self.screenWidth, self.screenHeight,
                         0,  // border_width
                         XCB_WINDOW_CLASS_INPUT_OUTPUT,
                         [screen screen]->root_visual,
                         0, NULL);
        
        xcb_map_window(conn, self.outputWindow);
        [self.connection flush];
        
        NSLog(@"[CompositingManager] Overlay window created with output child: overlay=%u, output=%u", 
              self.overlayWindow, self.outputWindow);
        return YES;
        
    } @catch (NSException *exception) {
        NSLog(@"[CompositingManager] EXCEPTION creating overlay: %@", exception.reason);
        return NO;
    }
}

- (BOOL)createRootBuffer {
    @try {
        xcb_connection_t *conn = [self.connection connection];
        XCBScreen *screen = [[self.connection screens] firstObject];
        
        // Create picture for output window
        // Use IncludeInferiors
        self.rootPicture = xcb_generate_id(conn);
        uint32_t pa_mask = XCB_RENDER_CP_SUBWINDOW_MODE;
        uint32_t pa_values[] = { XCB_SUBWINDOW_MODE_INCLUDE_INFERIORS };
        xcb_render_create_picture(conn, self.rootPicture, 
                                 self.outputWindow, self.rootFormat, pa_mask, pa_values);
        
        // Create backing pixmap for double buffering
        self.rootPixmap = xcb_generate_id(conn);
        xcb_create_pixmap(conn, [screen screen]->root_depth, self.rootPixmap,
                         self.rootWindow, self.screenWidth, self.screenHeight);
        
        // Create picture for the buffer
        self.rootBuffer = xcb_generate_id(conn);
        xcb_render_create_picture(conn, self.rootBuffer,
                                 self.rootPixmap, self.rootFormat, 0, NULL);
        
        // Create solid black picture for shadow rendering
        self.blackPicture = [self createSolidPicture:0.0 g:0.0 b:0.0 a:1.0];
        if (self.blackPicture == XCB_NONE) {
            NSLog(@"[CompositingManager] WARNING: Failed to create black picture for shadows");
        } else {
            NSLog(@"[CompositingManager] Created black picture 0x%x for shadows", self.blackPicture);
        }
        
        [self.connection flush];
        NSLog(@"[CompositingManager] Root buffer created (%dx%d)", 
              self.screenWidth, self.screenHeight);
        return YES;
        
    } @catch (NSException *exception) {
        NSLog(@"[CompositingManager] EXCEPTION creating root buffer: %@", exception.reason);
        return NO;
    }
}

- (void)addAllWindows {
    xcb_connection_t *conn = [self.connection connection];
    
    xcb_query_tree_cookie_t tree_cookie = xcb_query_tree(conn, self.rootWindow);
    xcb_query_tree_reply_t *tree_reply = xcb_query_tree_reply(conn, tree_cookie, NULL);
    
    if (!tree_reply) {
        NSLog(@"[CompositingManager] Failed to query window tree");
        return;
    }
    
    xcb_window_t *children = xcb_query_tree_children(tree_reply);
    int num_children = xcb_query_tree_children_length(tree_reply);
    
    for (int i = 0; i < num_children; i++) {
        [self addWindow:children[i]];
    }
    
    free(tree_reply);
    // NSLog(@"[CompositingManager] Added %d existing windows", num_children);
}

#pragma mark - Window Management

- (URSCompositeWindow *)findCWindow:(xcb_window_t)windowId {
    return self.cwindows[@(windowId)];
}

- (void)addWindow:(xcb_window_t)windowId {
    if (!self.compositingActive) {
        return;
    }
    
    // Skip our own compositor windows
    if (windowId == self.overlayWindow || windowId == self.rootWindow || 
        windowId == self.outputWindow) {
        return;
    }
    
    if ([self findCWindow:windowId]) {
        return; // Already added
    }
    
    xcb_connection_t *conn = [self.connection connection];
    
    // Get window attributes
    xcb_get_window_attributes_cookie_t attr_cookie = xcb_get_window_attributes(conn, windowId);
    xcb_get_window_attributes_reply_t *attr = xcb_get_window_attributes_reply(conn, attr_cookie, NULL);
    
    if (!attr) {
        return;
    }
    
    // Skip InputOnly windows
    if (attr->_class == XCB_WINDOW_CLASS_INPUT_ONLY) {
        free(attr);
        return;
    }
    
    // Get geometry
    xcb_get_geometry_cookie_t geom_cookie = xcb_get_geometry(conn, windowId);
    xcb_get_geometry_reply_t *geom = xcb_get_geometry_reply(conn, geom_cookie, NULL);
    
    if (!geom) {
        free(attr);
        return;
    }
    
    URSCompositeWindow *cw = [[URSCompositeWindow alloc] init];
    cw.windowId = windowId;
    cw.x = geom->x;
    cw.y = geom->y;
    cw.width = geom->width;
    cw.height = geom->height;
    cw.borderWidth = geom->border_width;
    cw.depth = geom->depth;
    cw.visual = attr->visual;
    cw.viewable = (attr->map_state == XCB_MAP_STATE_VIEWABLE);
    cw.redirected = YES;
    cw.overrideRedirect = attr->override_redirect;

    // Track parent and compute absolute position in root coordinates
    xcb_query_tree_cookie_t tree_cookie = xcb_query_tree(conn, windowId);
    xcb_query_tree_reply_t *tree_reply = xcb_query_tree_reply(conn, tree_cookie, NULL);
    if (tree_reply) {
        cw.parentWindowId = tree_reply->parent;
        free(tree_reply);
    } else {
        cw.parentWindowId = XCB_NONE;
    }
    [self updateAbsolutePositionForWindow:cw];
    
    // Create damage object for the window
    cw.damage = xcb_generate_id(conn);
    xcb_damage_create(conn, cw.damage, windowId, XCB_DAMAGE_REPORT_LEVEL_NON_EMPTY);
    
    self.cwindows[@(windowId)] = cw;
    
    // OPTIMIZATION: Mark stacking order dirty (will be rebuilt on next paint)
    self.stackingOrderDirty = YES;

    NSLog(@"[CompositingManager] Added window %u (parent: %u) pos={%d,%d} size={%hu,%hu} viewable=%d", windowId, cw.parentWindowId, cw.x, cw.y, cw.width, cw.height, (int)cw.viewable);
    
    free(attr);
    free(geom);
    
    [self.connection flush];
}

- (void)registerWindow:(xcb_window_t)window {
    [self addWindow:window];
}

- (void)unregisterWindow:(xcb_window_t)window {
    [self removeWindow:window];
}

- (void)removeWindow:(xcb_window_t)windowId {
    if (!self.compositingActive) {
        return;
    }
    
    URSCompositeWindow *cw = [self findCWindow:windowId];
    if (!cw) {
        return;
    }
    
    // Damage the area where the window was
    if (cw.viewable) {
        [self damageWindowArea:cw];
    }
    
    [self freeWindowData:cw delete:YES];
    [self.cwindows removeObjectForKey:@(windowId)];
    
    // OPTIMIZATION: Mark stacking order dirty
    self.stackingOrderDirty = YES;
}

- (void)freeWindowData:(URSCompositeWindow *)cw delete:(BOOL)shouldDelete {
    xcb_connection_t *conn = [self.connection connection];
    
    if (cw.nameWindowPixmap != XCB_NONE) {
        xcb_free_pixmap(conn, cw.nameWindowPixmap);
        cw.nameWindowPixmap = XCB_NONE;
    }
    
    if (cw.picture != XCB_NONE) {
        xcb_render_free_picture(conn, cw.picture);
        cw.picture = XCB_NONE;
    }
    
    if (cw.borderSize != XCB_NONE) {
        xcb_xfixes_destroy_region(conn, cw.borderSize);
        cw.borderSize = XCB_NONE;
    }
    
    if (cw.extents != XCB_NONE) {
        xcb_xfixes_destroy_region(conn, cw.extents);
        cw.extents = XCB_NONE;
    }
    
    if (cw.shadowPicture != XCB_NONE) {
        xcb_render_free_picture(conn, cw.shadowPicture);
        cw.shadowPicture = XCB_NONE;
    }
    
    if (cw.shadowPixmap != XCB_NONE) {
        xcb_free_pixmap(conn, cw.shadowPixmap);
        cw.shadowPixmap = XCB_NONE;
    }
    
    if (shouldDelete && cw.damage != XCB_NONE) {
        xcb_damage_destroy(conn, cw.damage);
        cw.damage = XCB_NONE;
    }
    
    cw.damaged = NO;
    // OPTIMIZATION: Reset lazy picture flags
    cw.pictureValid = NO;
    cw.needsPictureCreation = YES;
}

- (void)updateWindow:(xcb_window_t)window {
    if (!self.compositingActive) {
        return;
    }
    
    URSCompositeWindow *cw = [self findCWindow:window];
        
    // If the window isn't directly tracked, it might be a child window (like a titlebar).
    // Find its parent frame window.
    if (!cw) {
        xcb_window_t parentFrame = [self findParentFrameWindow:window];
        if (parentFrame != XCB_NONE) {
            cw = [self findCWindow:parentFrame];
        }
    }
    
    if (!cw) {
        return;
    }
    
    // Damage the window's area
    [self damageWindowArea:cw];
}

- (void)moveWindow:(xcb_window_t)windowId x:(int16_t)x y:(int16_t)y {
    if (!self.compositingActive) {
        return;
    }
    
    URSCompositeWindow *cw = [self findCWindow:windowId];
    if (!cw) {
        return;
    }
    
    xcb_connection_t *conn = [self.connection connection];

    // Translate to root coordinates for child windows
    int16_t newX = x;
    int16_t newY = y;
    if (cw.parentWindowId != XCB_NONE && cw.parentWindowId != self.rootWindow) {
        xcb_translate_coordinates_cookie_t cookie = xcb_translate_coordinates(conn,
                                                                              cw.windowId,
                                                                              self.rootWindow,
                                                                              0, 0);
        xcb_translate_coordinates_reply_t *reply = xcb_translate_coordinates_reply(conn, cookie, NULL);
        if (reply) {
            newX = reply->dst_x;
            newY = reply->dst_y;
            free(reply);
        }
    }
    
    // PERFORMANCE FIX: During drag, only damage once with combined old+new area
    // Instead of damaging old area, updating position, then damaging new area
    if (cw.viewable) {
        // Create a region that covers both old and new positions
        xcb_rectangle_t rects[2];
        
        // Old position (including shadow if present)
        rects[0].x = cw.x;
        rects[0].y = cw.y;
        rects[0].width = cw.width + 2 * cw.borderWidth;
        rects[0].height = cw.height + 2 * cw.borderWidth;
        
        // Expand to include shadow if present
        if (cw.shadowPicture != XCB_NONE) {
            // Shadow offsets are typically negative, so we need to expand the rectangle
            // to encompass both the window and its shadow
            int16_t shadow_x = cw.x + cw.shadowOffsetX;
            int16_t shadow_y = cw.y + cw.shadowOffsetY;
            int16_t window_right = cw.x + cw.width + 2 * cw.borderWidth;
            int16_t window_bottom = cw.y + cw.height + 2 * cw.borderWidth;
            int16_t shadow_right = shadow_x + cw.shadowWidth;
            int16_t shadow_bottom = shadow_y + cw.shadowHeight;
            
            // Calculate bounding box that includes both window and shadow
            rects[0].x = (shadow_x < cw.x) ? shadow_x : cw.x;
            rects[0].y = (shadow_y < cw.y) ? shadow_y : cw.y;
            int16_t right = (shadow_right > window_right) ? shadow_right : window_right;
            int16_t bottom = (shadow_bottom > window_bottom) ? shadow_bottom : window_bottom;
            rects[0].width = right - rects[0].x;
            rects[0].height = bottom - rects[0].y;
        }
        
        // New position (including shadow if present)
        rects[1].x = newX;
        rects[1].y = newY;
        rects[1].width = cw.width + 2 * cw.borderWidth;
        rects[1].height = cw.height + 2 * cw.borderWidth;
        
        // Expand to include shadow if present
        if (cw.shadowPicture != XCB_NONE) {
            // Shadow offsets are typically negative, so we need to expand the rectangle
            // to encompass both the window and its shadow
            int16_t shadow_x = newX + cw.shadowOffsetX;
            int16_t shadow_y = newY + cw.shadowOffsetY;
            int16_t window_right = newX + cw.width + 2 * cw.borderWidth;
            int16_t window_bottom = newY + cw.height + 2 * cw.borderWidth;
            int16_t shadow_right = shadow_x + cw.shadowWidth;
            int16_t shadow_bottom = shadow_y + cw.shadowHeight;
            
            // Calculate bounding box that includes both window and shadow
            rects[1].x = (shadow_x < newX) ? shadow_x : newX;
            rects[1].y = (shadow_y < newY) ? shadow_y : newY;
            int16_t right = (shadow_right > window_right) ? shadow_right : window_right;
            int16_t bottom = (shadow_bottom > window_bottom) ? shadow_bottom : window_bottom;
            rects[1].width = right - rects[1].x;
            rects[1].height = bottom - rects[1].y;
        }
        
        // Create a single region covering both areas
        xcb_xfixes_region_t combined = xcb_generate_id(conn);
        xcb_xfixes_create_region(conn, combined, 2, rects);
        [self addDamage:combined];
    }
    
    // Update position
    cw.x = newX;
    cw.y = newY;
    
    // Invalidate regions since position changed
    if (cw.borderSize != XCB_NONE) {
        xcb_xfixes_destroy_region(conn, cw.borderSize);
        cw.borderSize = XCB_NONE;
    }
    if (cw.extents != XCB_NONE) {
        xcb_xfixes_destroy_region(conn, cw.extents);
        cw.extents = XCB_NONE;
    }

    // Mark stacking order dirty (window moved)
    self.stackingOrderDirty = YES;
}

- (void)invalidateWindowPixmap:(xcb_window_t)windowId {
    if (!self.compositingActive) {
        return;
    }

    URSCompositeWindow *cw = [self findCWindow:windowId];

    // If the window isn't directly tracked, it might be a child window.
    if (!cw) {
        xcb_window_t parentFrame = [self findParentFrameWindow:windowId];
        if (parentFrame != XCB_NONE) {
            cw = [self findCWindow:parentFrame];
        }
    }

    if (!cw) {
        return;
    }

    xcb_connection_t *conn = [self.connection connection];

    if (cw.nameWindowPixmap != XCB_NONE) {
        xcb_free_pixmap(conn, cw.nameWindowPixmap);
        cw.nameWindowPixmap = XCB_NONE;
    }
    if (cw.picture != XCB_NONE) {
        xcb_render_free_picture(conn, cw.picture);
        cw.picture = XCB_NONE;
    }
    cw.pictureValid = NO;
    cw.needsPictureCreation = YES;

    // Ensure updated content is repainted
    [self damageWindowArea:cw];
    [self scheduleRepair];
}

- (void)resizeWindow:(xcb_window_t)windowId x:(int16_t)x y:(int16_t)y 
               width:(uint16_t)width height:(uint16_t)height {
    if (!self.compositingActive) {
        return;
    }
    
    URSCompositeWindow *cw = [self findCWindow:windowId];
    if (!cw) {
        return;
    }
    
    xcb_connection_t *conn = [self.connection connection];

    // Translate to root coordinates for child windows
    int16_t newX = x;
    int16_t newY = y;
    if (cw.parentWindowId != XCB_NONE && cw.parentWindowId != self.rootWindow) {
        xcb_translate_coordinates_cookie_t cookie = xcb_translate_coordinates(conn,
                                                                              cw.windowId,
                                                                              self.rootWindow,
                                                                              0, 0);
        xcb_translate_coordinates_reply_t *reply = xcb_translate_coordinates_reply(conn, cookie, NULL);
        if (reply) {
            newX = reply->dst_x;
            newY = reply->dst_y;
            free(reply);
        }
    }
    
    // If visible, damage the old area
    if (cw.viewable) {
        [self damageWindowArea:cw];
    }
    
    // If size changed, we need to recreate the pixmap and picture
    if (cw.width != width || cw.height != height) {
        if (cw.nameWindowPixmap != XCB_NONE) {
            xcb_free_pixmap(conn, cw.nameWindowPixmap);
            cw.nameWindowPixmap = XCB_NONE;
        }
        if (cw.picture != XCB_NONE) {
            xcb_render_free_picture(conn, cw.picture);
            cw.picture = XCB_NONE;
        }
        // Recreate shadow with new size
        if (cw.shadowPicture != XCB_NONE) {
            xcb_render_free_picture(conn, cw.shadowPicture);
            cw.shadowPicture = XCB_NONE;
        }
        if (cw.shadowPixmap != XCB_NONE) {
            xcb_free_pixmap(conn, cw.shadowPixmap);
            cw.shadowPixmap = XCB_NONE;
        }
        // OPTIMIZATION: Reset lazy picture flags so picture is recreated
        cw.pictureValid = NO;
        cw.needsPictureCreation = YES;
    }
    
    // If position or size changed, invalidate regions
    if (cw.width != width || cw.height != height || cw.x != newX || cw.y != newY) {
        if (cw.borderSize != XCB_NONE) {
            xcb_xfixes_destroy_region(conn, cw.borderSize);
            cw.borderSize = XCB_NONE;
        }
        if (cw.extents != XCB_NONE) {
            xcb_xfixes_destroy_region(conn, cw.extents);
            cw.extents = XCB_NONE;
        }
    }
    
    // Update cached geometry
    cw.x = newX;
    cw.y = newY;
    cw.width = width;
    cw.height = height;
    
    // Damage the new area
    if (cw.viewable) {
        [self damageWindowArea:cw];
    }
}

- (void)mapWindow:(xcb_window_t)windowId {
    URSCompositeWindow *cw = [self findCWindow:windowId];
    if (!cw) {
        [self addWindow:windowId];
        cw = [self findCWindow:windowId];
    }
    
    if (cw) {
        cw.viewable = YES;
        cw.damaged = NO;
        // OPTIMIZATION: Force picture recreation on remap (window may have new content)
        cw.pictureValid = NO;
        cw.needsPictureCreation = YES;
        // Create shadow for newly mapped window
        if (cw.shadowPicture == XCB_NONE && self.argbFormat != XCB_NONE) {
            [self createShadowForWindow:cw];
        }
        [self damageWindowArea:cw];
        // OPTIMIZATION: Window mapping can change stacking order
        self.stackingOrderDirty = YES;
    }
}

- (void)unmapWindow:(xcb_window_t)windowId {
    URSCompositeWindow *cw = [self findCWindow:windowId];
    if (!cw) {
        return;
    }
    
    if (cw.viewable) {
        [self damageWindowArea:cw];
    }
    
    cw.viewable = NO;
    cw.damaged = NO;

    if (cw.animating) {
        // Keep resources alive until animation completes
        return;
    }
    
    // Free window data but keep the damage object
    [self freeWindowData:cw delete:NO];
    // OPTIMIZATION: Window unmapping can change stacking order
    self.stackingOrderDirty = YES;
}

#pragma mark - Damage Handling

- (void)handleDamageNotify:(xcb_window_t)windowId {
    if (!self.compositingActive) {
        return;
    }

    URSCompositeWindow *cw = [self findCWindow:windowId];

    // If the damaged window is not directly tracked, it might be a child window
    // (like a titlebar). Find its parent frame window.
    if (!cw) {
        xcb_window_t parentFrame = [self findParentFrameWindow:windowId];
        if (parentFrame != XCB_NONE) {
            cw = [self findCWindow:parentFrame];
        }
    }

    if (!cw || !cw.damage) {
        // Unknown window damaged; force full screen repaint to avoid artifacts
        [self damageScreen];
        return;
    }

    // Keep root-relative coordinates current for damage calculations
    [self updateAbsolutePositionForWindow:cw];

    [self repairWindow:cw];
}

- (void)handleExposeEvent:(xcb_window_t)windowId {
    if (!self.compositingActive) {
        return;
    }

    URSCompositeWindow *cw = [self findCWindow:windowId];

    // If the exposed window is not directly tracked, it might be a child window
    // (like a titlebar or client). Find its parent frame window.
    if (!cw) {
        xcb_window_t parentFrame = [self findParentFrameWindow:windowId];
        if (parentFrame != XCB_NONE) {
            cw = [self findCWindow:parentFrame];
        }
    }

    if (!cw) {
        return;
    }

    // BUGFIX: When a window is exposed (becomes visible after being obscured),
    // the NameWindowPixmap may be stale because fixed-size windows don't redraw
    // themselves - they expect the X server to preserve their contents.
    // With compositing, we must force recreation of the pixmap to get fresh content.
    xcb_connection_t *conn = [self.connection connection];

    if (cw.nameWindowPixmap != XCB_NONE) {
        xcb_free_pixmap(conn, cw.nameWindowPixmap);
        cw.nameWindowPixmap = XCB_NONE;
    }
    if (cw.picture != XCB_NONE) {
        xcb_render_free_picture(conn, cw.picture);
        cw.picture = XCB_NONE;
    }
    cw.pictureValid = NO;
    cw.needsPictureCreation = YES;

    // Damage the exposed area to trigger repaint
    [self damageWindowArea:cw];
    [self scheduleRepair];
}

// Find the parent window that we're tracking (frame window)
- (xcb_window_t)findParentFrameWindow:(xcb_window_t)childWindow {
    xcb_connection_t *conn = [self.connection connection];
    xcb_window_t current = childWindow;
    
    // Walk up the window tree to find a tracked parent
    for (int depth = 0; depth < 10; depth++) { // Limit depth to prevent infinite loops
        xcb_query_tree_cookie_t tree_cookie = xcb_query_tree(conn, current);
        xcb_query_tree_reply_t *tree_reply = xcb_query_tree_reply(conn, tree_cookie, NULL);
        
        if (!tree_reply) {
            return XCB_NONE;
        }
        
        xcb_window_t parent = tree_reply->parent;
        free(tree_reply);
        
        if (parent == self.rootWindow || parent == XCB_NONE) {
            return XCB_NONE; // Reached root without finding tracked window
        }
        
        // Check if this parent is tracked
        if ([self findCWindow:parent]) {
            return parent;
        }
        
        current = parent;
    }
    
    return XCB_NONE;
}

- (void)repairWindow:(URSCompositeWindow *)cw {
    xcb_connection_t *conn = [self.connection connection];
    xcb_xfixes_region_t parts;
    
    // NOTE: We do NOT free the picture on damage - the underlying NameWindowPixmap
    // is automatically updated by the X server, and Pictures created from it
    // will reflect the updated content.
    // (Picture is only freed when window size changes or window is removed)
    
    if (cw.damaged) {
        // Window was already damaged before, get the damaged parts
        parts = xcb_generate_id(conn);
        xcb_xfixes_create_region(conn, parts, 0, NULL);
        
        // Subtract damage from window, copying to parts region
        xcb_damage_subtract(conn, cw.damage, XCB_NONE, parts);
        
        // Translate to screen coordinates
        xcb_xfixes_translate_region(conn, parts, 
                                    cw.x + cw.borderWidth,
                                    cw.y + cw.borderWidth);
    } else {
        // First damage on this window - use full extents
        parts = [self windowExtents:cw];
        
        // Clear all damage
        xcb_damage_subtract(conn, cw.damage, XCB_NONE, XCB_NONE);
    }
    
    if (parts != XCB_NONE) {
        [self addDamage:parts];
        cw.damaged = YES;
    }
    
    // Flush to ensure damage events are processed
    [self.connection flush];
}

- (void)damageScreen {
    xcb_xfixes_region_t region = [self getScreenRegion];
    [self addDamage:region];
}

- (void)damageWindowArea:(URSCompositeWindow *)cw {
    xcb_xfixes_region_t extents = [self windowExtents:cw];
    if (extents != XCB_NONE) {
        [self addDamage:extents];
    }
}

- (void)addDamage:(xcb_xfixes_region_t)damage {
    if (damage == XCB_NONE) {
        return;
    }
    
    xcb_connection_t *conn = [self.connection connection];
    
    // Clip to screen region
    if (self.screenRegion == XCB_NONE) {
        self.screenRegion = [self getScreenRegion];
    }
    xcb_xfixes_intersect_region(conn, damage, damage, self.screenRegion);
    
    if (self.allDamage != XCB_NONE) {
        // Union with existing damage
        xcb_xfixes_union_region(conn, self.allDamage, self.allDamage, damage);
        xcb_xfixes_destroy_region(conn, damage);
    } else {
        self.allDamage = damage;
    }
    
    [self scheduleRepair];
}

- (xcb_xfixes_region_t)windowExtents:(URSCompositeWindow *)cw {
    xcb_connection_t *conn = [self.connection connection];
    
    xcb_rectangle_t r;
    r.x = cw.x;
    r.y = cw.y;
    r.width = cw.width + 2 * cw.borderWidth;
    r.height = cw.height + 2 * cw.borderWidth;
    
    // Expand to include shadow if present
    if (cw.shadowPicture != XCB_NONE) {
        r.x += cw.shadowOffsetX;
        r.y += cw.shadowOffsetY;
        r.width = cw.shadowWidth;
        r.height = cw.shadowHeight;
    }
    
    xcb_xfixes_region_t region = xcb_generate_id(conn);
    xcb_xfixes_create_region(conn, region, 1, &r);
    return region;
}

- (xcb_xfixes_region_t)getScreenRegion {
    xcb_connection_t *conn = [self.connection connection];
    
    xcb_rectangle_t r;
    r.x = 0;
    r.y = 0;
    r.width = self.screenWidth;
    r.height = self.screenHeight;
    
    xcb_xfixes_region_t region = xcb_generate_id(conn);
    xcb_xfixes_create_region(conn, region, 1, &r);
    return region;
}

#pragma mark - Compositing

- (void)scheduleRepair {
    // If repair is already scheduled, don't reschedule (damage accumulates)
    if (self.repairScheduled) {
        return;
    }
    
    // Mark repair as scheduled
    self.repairScheduled = YES;
    
    // Schedule repair on next run loop iteration (immediate)
    // This ensures damage is painted as soon as possible while still
    // allowing multiple damage events to accumulate
    [self performSelector:@selector(performRepair) withObject:nil afterDelay:0.0];
}

- (void)performRepair {
    if (!self.compositingActive) {
        self.repairScheduled = NO;
        return;
    }
    
    // Check if there's damage to paint
    if (self.allDamage == XCB_NONE) {
        self.repairScheduled = NO;
        return;
    }
    
    xcb_xfixes_region_t damage = self.allDamage;
    self.allDamage = XCB_NONE;
    self.repairScheduled = NO;
    
    [self paintAll:damage];
    
    xcb_xfixes_destroy_region([self.connection connection], damage);
}

- (void)performRepairNow {
    if (!self.compositingActive) {
        return;
    }

    // PERFORMANCE FIX: Time-based throttling during drag (target ~60fps = 16.67ms)
    // Unlike frame-skipping, this ensures we always paint when enough time has passed,
    // preventing ghost artifacts while still maintaining good performance.
    if ([self.connection dragState]) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval elapsed = now - self.lastRepairTime;

        // Throttle to ~60fps during drag (allow paint if >= 16ms since last paint)
        // This prevents ghost artifacts that occurred with frame-skipping
        if (elapsed < 0.016 && self.lastRepairTime > 0) {
            // Too soon - schedule a deferred repair to ensure we don't miss this damage
            if (!self.repairScheduled) {
                self.repairScheduled = YES;
                [self performSelector:@selector(performRepair)
                           withObject:nil
                           afterDelay:0.016 - elapsed];
            }
            return;
        }
        self.lastRepairTime = now;
    }

    // Cancel any scheduled repair
    if (self.repairScheduled) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(performRepair)
                                                   object:nil];
        self.repairScheduled = NO;
    }

    // Check if there's damage to paint
    if (self.allDamage == XCB_NONE) {
        return;
    }

    xcb_xfixes_region_t damage = self.allDamage;
    self.allDamage = XCB_NONE;

    [self paintAll:damage];

    xcb_xfixes_destroy_region([self.connection connection], damage);
}

- (void)scheduleComposite {
    // If no damage is pending, damage the entire screen to ensure redraw
    // This handles cases where external drawing (like GSTheme) needs compositing
    if (self.allDamage == XCB_NONE) {
        [self damageScreen];
    } else {
        [self scheduleRepair];
    }
}

static inline double URSClampDouble(double value, double min, double max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

static inline double URSEaseSmooth(double t) {
    return t * t * (3.0 - (2.0 * t));
}

static inline xcb_render_transform_t URSIdentityTransform(void) {
    xcb_render_transform_t transform;
    transform.matrix11 = 1 << 16;
    transform.matrix12 = 0;
    transform.matrix13 = 0;
    transform.matrix21 = 0;
    transform.matrix22 = 1 << 16;
    transform.matrix23 = 0;
    transform.matrix31 = 0;
    transform.matrix32 = 0;
    transform.matrix33 = 1 << 16;
    return transform;
}

- (void)startAnimationTimerIfNeeded {
    if (self.animationTimer || self.activeAnimations == 0) {
        return;
    }
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:0.016
                                                           target:self
                                                         selector:@selector(animationTimerFired:)
                                                         userInfo:nil
                                                          repeats:YES];
}

- (void)stopAnimationTimerIfIdle {
    if (self.activeAnimations != 0) {
        return;
    }
    if (self.animationTimer) {
        [self.animationTimer invalidate];
        self.animationTimer = nil;
    }
}

- (void)animationTimerFired:(NSTimer *)timer {
    if (!self.compositingActive || self.activeAnimations == 0) {
        [self stopAnimationTimerIfIdle];
        return;
    }
    [self damageScreen];
}

- (void)animateWindowMinimize:(xcb_window_t)windowId
                     fromRect:(XCBRect)startRect
                       toRect:(XCBRect)endRect {
        [self animateWindowTransition:windowId
                                                 fromRect:startRect
                                                     toRect:endRect
                                                 duration:0.42
                                                         fade:YES
                                                minimizing:YES];
}

- (void)animateWindowRestore:(xcb_window_t)windowId
                    fromRect:(XCBRect)startRect
                      toRect:(XCBRect)endRect {
        [self animateWindowTransition:windowId
                                                 fromRect:startRect
                                                     toRect:endRect
                                                 duration:0.42
                                                         fade:YES
                                                minimizing:NO];
}

- (void)animateWindowTransition:(xcb_window_t)windowId
                                                fromRect:(XCBRect)startRect
                                                    toRect:(XCBRect)endRect
                                                duration:(NSTimeInterval)duration
                                                        fade:(BOOL)fade {
                [self animateWindowTransition:windowId
                                                         fromRect:startRect
                                                             toRect:endRect
                                                         duration:duration
                                                                 fade:fade
                                                        minimizing:NO];
}

- (void)animateWindowTransition:(xcb_window_t)windowId
                                                fromRect:(XCBRect)startRect
                                                    toRect:(XCBRect)endRect
                                                duration:(NSTimeInterval)duration
                                                        fade:(BOOL)fade
                                             minimizing:(BOOL)minimizing {
        [self animateWindow:windowId fromRect:startRect toRect:endRect minimizing:minimizing duration:duration fade:fade];
}

- (void)animateWindow:(xcb_window_t)windowId
                         fromRect:(XCBRect)startRect
                             toRect:(XCBRect)endRect
                     minimizing:(BOOL)minimizing
                         duration:(NSTimeInterval)duration
                                 fade:(BOOL)fade {
    NSLog(@"[Compositor] animateWindow called for window %u startRect={%d,%d,%hu,%hu} endRect={%d,%d,%hu,%hu} duration=%.2f fade=%d minimizing=%d compositingActive=%d",
          windowId,
          (int)startRect.position.x, (int)startRect.position.y, startRect.size.width, startRect.size.height,
          (int)endRect.position.x, (int)endRect.position.y, endRect.size.width, endRect.size.height,
          duration, (int)fade, (int)minimizing, (int)self.compositingActive);

    if (!self.compositingActive || windowId == XCB_NONE) {
        NSLog(@"[Compositor] animateWindow aborted: compositingActive=%d, windowId=%u",
              (int)self.compositingActive, windowId);
        return;
    }

    URSCompositeWindow *cw = [self findCWindow:windowId];
    if (!cw) {
        [self addWindow:windowId];
        cw = [self findCWindow:windowId];
    }

    if (!cw) {
        NSLog(@"[Compositor] animateWindow aborted: could not create composite window for %u", windowId);
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    BOOL wasAnimating = cw.animating;

    cw.animationStartRect = startRect;
    cw.animationEndRect = endRect;
    cw.animationStart = now;
    cw.animationDuration = duration;
    cw.animating = YES;
    cw.animatingMinimize = minimizing;
    cw.animatingFade = fade;

    if (!wasAnimating) {
        self.activeAnimations += 1;
    }

    cw.pictureValid = NO;
    cw.needsPictureCreation = YES;

    [self startAnimationTimerIfNeeded];
    [self scheduleComposite];
}

- (void)finishAnimationForWindow:(URSCompositeWindow *)cw {
    if (!cw || !cw.animating) {
        return;
    }

    BOOL wasMinimized = cw.animatingMinimize;

    NSLog(@"[Compositor] Animation finished for window %u (wasMinimize=%d)", cw.windowId, (int)wasMinimized);

    cw.animating = NO;
    cw.animatingMinimize = NO;
    cw.animatingFade = NO;
    cw.animationStart = 0;
    cw.animationDuration = 0;
    cw.animationStartRect = XCBInvalidRect;
    cw.animationEndRect = XCBInvalidRect;

    if (self.activeAnimations > 0) {
        self.activeAnimations -= 1;
    }

    if (wasMinimized) {
        cw.viewable = NO;
        cw.damaged = NO;
        [self freeWindowData:cw delete:NO];
    } else if (!cw.viewable) {
        [self freeWindowData:cw delete:NO];
    }

    [self damageScreen];
    [self scheduleRepair];
    [self stopAnimationTimerIfIdle];
}

- (void)compositeScreen {
    [self damageScreen];
}

// OPTIMIZATION: Rebuild stacking order cache from X server
- (void)rebuildStackingOrderCache {
    xcb_connection_t *conn = [self.connection connection];
    
    xcb_query_tree_cookie_t tree_cookie = xcb_query_tree(conn, self.rootWindow);
    xcb_query_tree_reply_t *tree_reply = xcb_query_tree_reply(conn, tree_cookie, NULL);
    
    if (!tree_reply) {
        return;
    }
    
    [self.windowStackingOrder removeAllObjects];
    
    xcb_window_t *children = xcb_query_tree_children(tree_reply);
    int num_children = xcb_query_tree_children_length(tree_reply);
    
    for (int i = 0; i < num_children; i++) {
        [self.windowStackingOrder addObject:@(children[i])];
    }
    
    free(tree_reply);
    self.stackingOrderDirty = NO;
}

// OPTIMIZATION: Notify that stacking order changed (e.g., window raised/lowered)
- (void)markStackingOrderDirty {
    self.stackingOrderDirty = YES;
    if (self.compositingActive) {
        // ALWAYS damage the screen on stacking order change.
        // If we don't, and some other damage was already pending,
        // we might only repaint a small part of the screen while the
        // stacking change requires a full redraw of the affected windows.
        [self damageScreen];
    }
}

- (void)paintAll:(xcb_xfixes_region_t)region {
    xcb_connection_t *conn = [self.connection connection];
    
    if (self.rootBuffer == XCB_NONE) {
        return;
    }
    
    // OPTIMIZATION: Use cached stacking order, only query tree when dirty
    if (self.stackingOrderDirty || [self.windowStackingOrder count] == 0) {
        [self rebuildStackingOrderCache];
    }
    
    NSUInteger num_windows = [self.windowStackingOrder count];
    
    // Create a copy of the region for painting
    xcb_xfixes_region_t paint_region = xcb_generate_id(conn);
    xcb_xfixes_create_region(conn, paint_region, 0, NULL);
    xcb_xfixes_copy_region(conn, region, paint_region);
    
    // Paint background ONLY in damaged areas (performance optimization)
    xcb_xfixes_set_picture_clip_region(conn, self.rootBuffer, region, 0, 0);
    xcb_render_color_t bg_color = {0x8000, 0x8000, 0x8000, 0xFFFF}; // Mid grey background
    xcb_rectangle_t bg_rect = {0, 0, self.screenWidth, self.screenHeight};
    xcb_render_fill_rectangles(conn, XCB_RENDER_PICT_OP_SRC,
                               self.rootBuffer, bg_color, 1, &bg_rect);
    
    // Paint windows from bottom to top (so higher z-order windows are on top)
    for (NSUInteger i = 0; i < num_windows; i++) {
        xcb_window_t win = [self.windowStackingOrder[i] unsignedIntValue];
        
        // Skip overlay and output windows (our own compositor windows)
        if (win == self.overlayWindow || win == self.outputWindow) {
            continue;
        }
        
        URSCompositeWindow *cw = [self findCWindow:win];
        if (!cw) {
            // Window not tracked yet, try to add it
            [self addWindow:win];
            cw = [self findCWindow:win];
        }
        if (!cw || (!cw.viewable && !cw.animating)) {
            continue;
        }

        // Only paint top-level windows (root children). Child windows are
        // composited via IncludeInferiors on their parent.
        if (cw.parentWindowId != XCB_NONE && cw.parentWindowId != self.rootWindow) {
            continue;
        }
        
        // Paint the window - clip region is set inside paintWindow
        [self paintWindow:cw atX:cw.x atY:cw.y withClipRegion:paint_region];
    }
    
    xcb_xfixes_destroy_region(conn, paint_region);

    // BUGFIX: Flush all window painting commands before copying to screen.
    // This ensures all render operations on rootBuffer are complete before
    // we read from it, preventing partially-rendered content from appearing.
    xcb_flush(conn);

    // Copy ONLY damaged region to screen (performance optimization)
    xcb_xfixes_set_picture_clip_region(conn, self.rootPicture, region, 0, 0);
    xcb_render_composite(conn,
                        XCB_RENDER_PICT_OP_SRC,
                        self.rootBuffer,
                        XCB_NONE,
                        self.rootPicture,
                        0, 0,
                        0, 0,
                        0, 0,
                        self.screenWidth, self.screenHeight);

    [self.connection flush];
    
    // NSLog(@"[CompositingManager] paintAll: painted %lu windows", (unsigned long)num_windows);
}

// Gaussian function for shadow blur
static double gaussian(double r, double x, double y) {
    return ((1.0 / (sqrt(2.0 * 3.14159265358979323846 * r))) * exp(-(x * x + y * y) / (2.0 * r * r)));
}

// Create Gaussian convolution map
static double* make_gaussian_map(double r, int *size_out) {
    int size = ((int)ceil(r * 3.0) + 1) & ~1;  // Make it even
    int center = size / 2;
    double *map = calloc(size * size, sizeof(double));
    if (!map) return NULL;
    
    double t = 0.0;
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            double g = gaussian(r, (double)(x - center), (double)(y - center));
            t += g;
            map[y * size + x] = g;
        }
    }
    
    // Normalize
    for (int i = 0; i < size * size; i++) {
        map[i] /= t;
    }
    
    *size_out = size;
    return map;
}

// Sum Gaussian values over a region (for shadow intensity)
// cx, cy = center position of Gaussian relative to the window
// width, height = dimensions of the solid window being shadowed
static uint8_t sum_gaussian(double *map, int map_size, double opacity, 
                           int cx, int cy, int width, int height) {
    int center = map_size / 2;
    
    // Calculate the range of the Gaussian map to sum
    // These represent which part of the Gaussian kernel overlaps with the window
    int fx_start = center - cx;
    if (fx_start < 0) fx_start = 0;
    int fx_end = width + center - cx;
    if (fx_end > map_size) fx_end = map_size;
    
    int fy_start = center - cy;
    if (fy_start < 0) fy_start = 0;
    int fy_end = height + center - cy;
    if (fy_end > map_size) fy_end = map_size;
    
    double v = 0.0;
    for (int fy = fy_start; fy < fy_end; fy++) {
        for (int fx = fx_start; fx < fx_end; fx++) {
            v += map[fy * map_size + fx];
        }
    }
    
    // Clamp to 1.0 (as per xfwm4)
    if (v > 1.0) v = 1.0;
    
    return (uint8_t)(v * opacity * 255.0);
}

// Pre-compute shadow corners and edges for fast lookup
- (void)presumGaussianMap {
    if (!self.gaussianMap || self.gaussianSize <= 0) return;
    
    int center = self.gaussianSize / 2;
    
    // Allocate corner and top arrays (26 opacity levels for fine control)
    if (self.shadowCorner) free(self.shadowCorner);
    if (self.shadowTop) free(self.shadowTop);
    
    self.shadowCorner = calloc((self.gaussianSize + 1) * (self.gaussianSize + 1) * 26, sizeof(uint8_t));
    self.shadowTop = calloc((self.gaussianSize + 1) * 26, sizeof(uint8_t));
    
    // Pre-compute for full opacity
    for (int x = 0; x <= self.gaussianSize; x++) {
        self.shadowTop[25 * (self.gaussianSize + 1) + x] = 
            sum_gaussian(self.gaussianMap, self.gaussianSize, 1.0, center, x - center,
                        self.gaussianSize * 2, self.gaussianSize * 2);
        
        if (x == 0 || x == center || x == self.gaussianSize) {
            NSLog(@"[presumGaussian] shadowTop[%d] = %d", x, self.shadowTop[25 * (self.gaussianSize + 1) + x]);
        }
        
        // Scale for other opacity levels
        for (int opacity = 0; opacity < 25; opacity++) {
            self.shadowTop[opacity * (self.gaussianSize + 1) + x] = 
                (self.shadowTop[25 * (self.gaussianSize + 1) + x] * opacity) / 25;
        }
        
        for (int y = 0; y <= x; y++) {
            int idx_full = 25 * (self.gaussianSize + 1) * (self.gaussianSize + 1) + 
                          y * (self.gaussianSize + 1) + x;
            self.shadowCorner[idx_full] = 
                sum_gaussian(self.gaussianMap, self.gaussianSize, 1.0, 
                           x - center, y - center,
                           self.gaussianSize * 2, self.gaussianSize * 2);
            
            // Symmetric
            self.shadowCorner[25 * (self.gaussianSize + 1) * (self.gaussianSize + 1) + 
                            x * (self.gaussianSize + 1) + y] = 
                self.shadowCorner[idx_full];
            
            // Scale for other opacity levels
            for (int opacity = 0; opacity < 25; opacity++) {
                int idx = opacity * (self.gaussianSize + 1) * (self.gaussianSize + 1) + 
                         y * (self.gaussianSize + 1) + x;
                self.shadowCorner[idx] = (self.shadowCorner[idx_full] * opacity) / 25;
                
                // Symmetric
                self.shadowCorner[opacity * (self.gaussianSize + 1) * (self.gaussianSize + 1) + 
                                x * (self.gaussianSize + 1) + y] = self.shadowCorner[idx];
            }
        }
    }
}

// Create shadow image in memory (XImage equivalent)
- (uint8_t*)makeShadowImage:(int)width height:(int)height 
                 shadowWidth:(int*)swidth shadowHeight:(int*)sheight {
    int center = self.gaussianSize / 2;
    int opacity_int = (int)(SHADOW_OPACITY * 25.0);
    
    *swidth = width + self.gaussianSize;
    *sheight = height + self.gaussianSize;
    
    if (*swidth < 1 || *sheight < 1) return NULL;
    
    uint8_t *data = calloc(*swidth * *sheight, sizeof(uint8_t));
    if (!data) return NULL;
    
    // Fill with base shadow value
    uint8_t base_val = (self.gaussianSize > 0 && self.shadowTop != NULL) ? 
        self.shadowTop[opacity_int * (self.gaussianSize + 1) + self.gaussianSize] : 
        sum_gaussian(self.gaussianMap, self.gaussianSize, SHADOW_OPACITY, center, center, width, height);
    
    NSLog(@"[Shadow] makeShadowImage: center=%d, opacity_int=%d, base_val=%d, gaussianSize=%d, shadowTop=%p, shadowCorner=%p",
          center, opacity_int, base_val, self.gaussianSize, self.shadowTop, self.shadowCorner);
    
    memset(data, base_val, *swidth * *sheight);
    
    // Compute corners
    int ylimit = (self.gaussianSize < *sheight / 2) ? self.gaussianSize : (*sheight + 1) / 2;
    int xlimit = (self.gaussianSize < *swidth / 2) ? self.gaussianSize : (*swidth + 1) / 2;
    
    for (int y = 0; y < ylimit; y++) {
        for (int x = 0; x < xlimit; x++) {
            uint8_t d;
            if (xlimit == self.gaussianSize && ylimit == self.gaussianSize) {
                d = self.shadowCorner[opacity_int * (self.gaussianSize + 1) * (self.gaussianSize + 1) + 
                                     y * (self.gaussianSize + 1) + x];
            } else {
                d = sum_gaussian(self.gaussianMap, self.gaussianSize, SHADOW_OPACITY,
                               x - center, y - center, width, height);
            }
            data[y * *swidth + x] = d;
            data[(*sheight - y - 1) * *swidth + x] = d;
            data[(*sheight - y - 1) * *swidth + (*swidth - x - 1)] = d;
            data[y * *swidth + (*swidth - x - 1)] = d;
        }
    }
    
    // Top and bottom edges
    int x_diff = *swidth - (self.gaussianSize * 2);
    if (x_diff > 0 && ylimit > 0) {
        for (int y = 0; y < ylimit; y++) {
            uint8_t d = (ylimit == self.gaussianSize) ?
                self.shadowTop[opacity_int * (self.gaussianSize + 1) + y] :
                sum_gaussian(self.gaussianMap, self.gaussianSize, SHADOW_OPACITY, center, y - center, width, height);
            memset(&data[y * *swidth + self.gaussianSize], d, x_diff);
            memset(&data[(*sheight - y - 1) * *swidth + self.gaussianSize], d, x_diff);
        }
    }
    
    // Left and right edges
    for (int x = 0; x < xlimit; x++) {
        uint8_t d = (xlimit == self.gaussianSize) ?
            self.shadowTop[opacity_int * (self.gaussianSize + 1) + x] :
            sum_gaussian(self.gaussianMap, self.gaussianSize, SHADOW_OPACITY, x - center, center, width, height);
        
        for (int y = self.gaussianSize; y < *sheight - self.gaussianSize; y++) {
            data[y * *swidth + x] = d;
            data[y * *swidth + (*swidth - x - 1)] = d;
        }
    }
    
    return data;
}

- (void)createShadowForWindow:(URSCompositeWindow *)cw {
    xcb_connection_t *conn = [self.connection connection];
    
    if (self.argbFormat == XCB_NONE || !self.gaussianMap || cw.overrideRedirect) {
        return; // Can't create shadow without alpha support, Gaussian map, or if it's override-redirect
    }
    
    // Generate shadow image in memory
    int swidth, sheight;
    uint8_t *shadow_data = [self makeShadowImage:cw.width + 2 * cw.borderWidth 
                                          height:cw.height + 2 * cw.borderWidth
                                     shadowWidth:&swidth 
                                    shadowHeight:&sheight];
    if (!shadow_data) {
        NSLog(@"[Shadow] Failed to create shadow image");
        return;
    }
    
    // Validate shadow data - sample from different regions
    int corner_val = shadow_data[0];  // top-left corner
    int center_val = shadow_data[(sheight/2) * swidth + (swidth/2)];  // center
    int edge_val = shadow_data[10 * swidth + swidth/2];  // top edge
    int nonzero = 0, maxval = 0;
    for (int i = 0; i < swidth * sheight && i < 1000; i++) {
        if (shadow_data[i] > 0) nonzero++;
        if (shadow_data[i] > maxval) maxval = shadow_data[i];
    }
    NSLog(@"[Shadow] Shadow data: size=%dx%d, samples: corner=%d center=%d edge=%d, first1000: nonzero=%d max=%d", 
          swidth, sheight, corner_val, center_val, edge_val, nonzero, maxval);
    
    cw.shadowWidth = swidth;
    cw.shadowHeight = sheight;
    cw.shadowOffsetX = SHADOW_OFFSET_X;
    cw.shadowOffsetY = SHADOW_OFFSET_Y;
    
    // Create shadow using ARGB32 format directly
    // Convert 8-bit alpha data to ARGB32 (pre-multiplied black+alpha)
    uint32_t *argb_data = (uint32_t *)malloc(swidth * sheight * sizeof(uint32_t));
    if (!argb_data) {
        NSLog(@"[Shadow] Failed to allocate ARGB data");
        free(shadow_data);
        return;
    }
    
    // Convert A8 -> ARGB32 (black with alpha)
    // ARGB format on little-endian is BGRA in memory: B, G, R, A bytes
    for (int i = 0; i < swidth * sheight; i++) {
        uint8_t alpha = shadow_data[i];
        // ARGB32 little-endian: 0xAARRGGBB stored as BB GG RR AA in memory
        // For black (0,0,0) with alpha, it's just (alpha << 24)
        argb_data[i] = ((uint32_t)alpha << 24);  // 0xAA000000 = black with alpha
    }
    free(shadow_data);
    
    // Create 32-bit depth pixmap for ARGB shadow
    cw.shadowPixmap = xcb_generate_id(conn);
    xcb_create_pixmap(conn, 32, cw.shadowPixmap, self.rootWindow, swidth, sheight);
    
    // Upload ARGB32 shadow data
    xcb_gcontext_t gc = xcb_generate_id(conn);
    xcb_create_gc(conn, gc, cw.shadowPixmap, 0, NULL);
    
    xcb_put_image(conn, XCB_IMAGE_FORMAT_Z_PIXMAP, cw.shadowPixmap, gc,
                 swidth, sheight, 0, 0, 0, 32,
                 swidth * sheight * 4, (uint8_t *)argb_data);
    xcb_flush(conn);  // Ensure image data is uploaded before proceeding
    
    xcb_free_gc(conn, gc);
    free(argb_data);
    
    // Create Picture with ARGB format
    cw.shadowPicture = xcb_generate_id(conn);
    xcb_render_create_picture(conn, cw.shadowPicture, cw.shadowPixmap, self.argbFormat, 0, NULL);
    
    NSLog(@"[Shadow] ARGB32 shadow picture: 0x%x for window 0x%x (size %dx%d), pixmap: 0x%x", 
          cw.shadowPicture, cw.windowId, swidth, sheight, cw.shadowPixmap);
    
    // DO NOT free the pixmap - the Picture needs it to stay alive
    // It will be freed when the window is destroyed
}

- (void)paintWindow:(URSCompositeWindow *)cw 
                atX:(int16_t)screenX 
                atY:(int16_t)screenY 
     withClipRegion:(xcb_xfixes_region_t)clipRegion {
    
    xcb_connection_t *conn = [self.connection connection];
    BOOL animating = cw.animating;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    double destX = screenX;
    double destY = screenY;
    double destW = (double)cw.width + (2.0 * (double)cw.borderWidth);
    double destH = (double)cw.height + (2.0 * (double)cw.borderWidth);

    if (animating && FnCheckXCBRectIsValid(cw.animationStartRect) &&
        FnCheckXCBRectIsValid(cw.animationEndRect) && cw.animationDuration > 0.0) {
        double t = (now - cw.animationStart) / cw.animationDuration;
        t = URSClampDouble(t, 0.0, 1.0);
        double ease = URSEaseSmooth(t);
        double scaleEaseX = ease;
        double scaleEaseY = t * t;
        BOOL wasMinimize = cw.animatingMinimize;

        // Log the first frame of animation to help debugging (not spammy)
        if (t < 0.02) {
            NSLog(@"[Compositor] Animation started for window %u startRect={%d,%d,%hu,%hu} endRect={%d,%d,%hu,%hu} duration=%.2f",
                  cw.windowId,
                  (int)cw.animationStartRect.position.x, (int)cw.animationStartRect.position.y, cw.animationStartRect.size.width, cw.animationStartRect.size.height,
                  (int)cw.animationEndRect.position.x, (int)cw.animationEndRect.position.y, cw.animationEndRect.size.width, cw.animationEndRect.size.height,
                  cw.animationDuration);
        }

        double startW = fmax(1.0, (double)cw.animationStartRect.size.width);
        double startH = fmax(1.0, (double)cw.animationStartRect.size.height);
        double endW = fmax(1.0, (double)cw.animationEndRect.size.width);
        double endH = fmax(1.0, (double)cw.animationEndRect.size.height);

        double currentW = startW + (endW - startW) * scaleEaseX;
        double currentH = startH + (endH - startH) * scaleEaseY;

        double startCenterX = cw.animationStartRect.position.x + (startW * 0.5);
        double endCenterX = cw.animationEndRect.position.x + (endW * 0.5);
        double currentCenterX = startCenterX + (endCenterX - startCenterX) * ease;

        double startBottom = cw.animationStartRect.position.y + startH;
        double endBottom = cw.animationEndRect.position.y + endH;
        double currentBottom = startBottom + (endBottom - startBottom) * ease;

        destW = fmax(1.0, currentW);
        destH = fmax(1.0, currentH);
        destX = currentCenterX - (destW * 0.5);
        destY = currentBottom - destH;

        if (t >= 1.0 && wasMinimize) {
            [self finishAnimationForWindow:cw];
            return;
        }

        if (t >= 1.0) {
            XCBRect finalRect = cw.animationEndRect;
            [self finishAnimationForWindow:cw];
            animating = NO;
            destX = finalRect.position.x;
            destY = finalRect.position.y;
            destW = fmax(1.0, (double)finalRect.size.width);
            destH = fmax(1.0, (double)finalRect.size.height);
        }
    }
    
    // Create shadow if needed (after resize)
    if (cw.shadowPicture == XCB_NONE && self.argbFormat != XCB_NONE) {
        [self createShadowForWindow:cw];
    }
    
    // Draw shadow using Gaussian ARGB32 picture (smooth gradient)
    if (cw.shadowPicture != XCB_NONE && !animating) {
        int16_t shadowX = screenX + cw.shadowOffsetX;
        int16_t shadowY = screenY + cw.shadowOffsetY;
        
        // Composite ARGB32 shadow with proper alpha blending
        xcb_render_composite(conn,
                            XCB_RENDER_PICT_OP_OVER,
                            cw.shadowPicture,       // Source: ARGB32 shadow with alpha
                            XCB_NONE,               // No mask
                            self.rootBuffer,        // Destination
                            0, 0,                   // src x, y
                            0, 0,                   // mask x, y (unused)
                            shadowX,                // dst x
                            shadowY,                // dst y
                            cw.shadowWidth,
                            cw.shadowHeight);
    }
    
    // OPTIMIZATION: Lazy picture creation - only create when first painting
    // NOTE: The underlying NameWindowPixmap is automatically updated by X server on damage
    // so we only need to recreate when pictureValid is false (size change, etc.)
    if (!cw.pictureValid || cw.needsPictureCreation) {
        if (cw.picture != XCB_NONE) {
            xcb_render_free_picture(conn, cw.picture);
            cw.picture = XCB_NONE;
        }
        cw.picture = [self getWindowPicture:cw];
        if (cw.picture != XCB_NONE) {
            cw.pictureValid = YES;
            cw.needsPictureCreation = NO;
        }
    }
    
    if (cw.picture != XCB_NONE) {
        int16_t destXInt = (int16_t)llround(destX);
        int16_t destYInt = (int16_t)llround(destY);
        uint16_t destWInt = (uint16_t)URSClampDouble(destW, 1.0, 65535.0);
        uint16_t destHInt = (uint16_t)URSClampDouble(destH, 1.0, 65535.0);
        xcb_render_picture_t alphaMask = XCB_NONE;

        if (animating) {
            double srcW = fmax(1.0, (double)cw.width + (2.0 * (double)cw.borderWidth));
            double srcH = fmax(1.0, (double)cw.height + (2.0 * (double)cw.borderWidth));
            double sx = srcW / (double)destWInt;
            double sy = srcH / (double)destHInt;

            xcb_render_transform_t transform = URSIdentityTransform();
            transform.matrix11 = (xcb_render_fixed_t)(sx * 65536.0);
            transform.matrix22 = (xcb_render_fixed_t)(sy * 65536.0);
            xcb_render_set_picture_transform(conn, cw.picture, transform);

            if (cw.animatingFade) {
                double t = URSClampDouble((now - cw.animationStart) / cw.animationDuration, 0.0, 1.0);
                double alpha = cw.animatingMinimize ? (1.0 - (t * t)) : t;
                alpha = URSClampDouble(alpha, 0.0, 1.0);
                if (alpha < 0.999 && self.argbFormat != XCB_NONE) {
                    alphaMask = [self createSolidPicture:0.0 g:0.0 b:0.0 a:alpha];
                }
            }
        }

        // Paint the window - IncludeInferiors captures all child content
        // (titlebar, buttons, client content, etc.)
        xcb_render_composite(conn,
                            XCB_RENDER_PICT_OP_OVER,
                            cw.picture,
                            alphaMask,
                            self.rootBuffer,
                            0, 0,
                            0, 0,
                            destXInt, destYInt,
                            destWInt,
                            destHInt);

        if (animating) {
            xcb_render_transform_t reset = URSIdentityTransform();
            xcb_render_set_picture_transform(conn, cw.picture, reset);
        }

        if (alphaMask != XCB_NONE) {
            xcb_render_free_picture(conn, alphaMask);
        }
    }
    // No need to recursively paint children - IncludeInferiors handles that
}

// Note: Child window painting is handled automatically by IncludeInferiors
// No need for explicit recursive painting

- (xcb_render_picture_t)getWindowPicture:(URSCompositeWindow *)cw {
    xcb_connection_t *conn = [self.connection connection];
    xcb_drawable_t draw = cw.windowId;

    // Use NameWindowPixmap (the redirected offscreen storage) for proper content capture
    // Try to get the name_window_pixmap first
    if (cw.nameWindowPixmap == XCB_NONE) {
        // BUGFIX: Flush before creating NameWindowPixmap to ensure X server has
        // finished any pending drawing operations on the window. This prevents
        // capturing stale or partially-drawn content that causes ghost artifacts.
        xcb_flush(conn);

        cw.nameWindowPixmap = xcb_generate_id(conn);
        xcb_void_cookie_t cookie = xcb_composite_name_window_pixmap_checked(conn, cw.windowId, cw.nameWindowPixmap);
        xcb_generic_error_t *error = xcb_request_check(conn, cookie);
        if (error) {
            // Failed to get named pixmap, use window directly
            cw.nameWindowPixmap = XCB_NONE;
            free(error);
        }
    }
    
    // Use the named pixmap if available, otherwise fall back to window drawable
    if (cw.nameWindowPixmap != XCB_NONE) {
        draw = cw.nameWindowPixmap;
    }
    
    // Find appropriate format for this window's visual
    xcb_render_pictformat_t format = [self findVisualFormat:cw.visual];
    if (format == XCB_NONE) {
        // Fall back to depth-based format
        format = [self findFormatForDepth:cw.depth];
    }
    if (format == XCB_NONE) {
        NSLog(@"[CompositingManager] No format for visual %d depth %d", cw.visual, cw.depth);
        return XCB_NONE;
    }
    
    // Create picture with IncludeInferiors
    // This ensures child window content (like titlebar decorations) is captured
    xcb_render_picture_t picture = xcb_generate_id(conn);
    uint32_t pa_mask = XCB_RENDER_CP_SUBWINDOW_MODE;
    uint32_t pa_values[] = { XCB_SUBWINDOW_MODE_INCLUDE_INFERIORS };
    xcb_render_create_picture(conn, picture, draw, format, pa_mask, pa_values);
    
    // BEST PRACTICE: Set picture filter to 'good' or 'bilinear' for smooth scaling
    // especially during minimize/restore animations
    const char *filter = "good";
    xcb_render_set_picture_filter(conn, picture, strlen(filter), filter, 0, NULL);
    
    return picture;
}

- (xcb_render_pictformat_t)findVisualFormat:(xcb_visualid_t)visual {
    // OPTIMIZATION: Use cached visual-to-format mapping (built during init)
    NSNumber *cachedFormat = self.visualFormatCache[@(visual)];
    if (cachedFormat) {
        return [cachedFormat unsignedIntValue];
    }
    
    // Fallback: query server if not in cache (should rarely happen)
    xcb_connection_t *conn = [self.connection connection];
    
    xcb_render_query_pict_formats_cookie_t formats_cookie = 
        xcb_render_query_pict_formats(conn);
    xcb_render_query_pict_formats_reply_t *formats_reply = 
        xcb_render_query_pict_formats_reply(conn, formats_cookie, NULL);
    
    if (!formats_reply) {
        return XCB_NONE;
    }
    
    xcb_render_pictformat_t format = XCB_NONE;
    
    // Iterate through screens to find the matching visual
    xcb_render_pictscreen_iterator_t screen_iter = 
        xcb_render_query_pict_formats_screens_iterator(formats_reply);
    
    for (; screen_iter.rem; xcb_render_pictscreen_next(&screen_iter)) {
        xcb_render_pictdepth_iterator_t depth_iter = 
            xcb_render_pictscreen_depths_iterator(screen_iter.data);
        
        for (; depth_iter.rem; xcb_render_pictdepth_next(&depth_iter)) {
            xcb_render_pictvisual_iterator_t visual_iter = 
                xcb_render_pictdepth_visuals_iterator(depth_iter.data);
            
            for (; visual_iter.rem; xcb_render_pictvisual_next(&visual_iter)) {
                if (visual_iter.data->visual == visual) {
                    format = visual_iter.data->format;
                    // Cache it for future lookups
                    self.visualFormatCache[@(visual)] = @(format);
                    break;
                }
            }
            if (format != XCB_NONE) break;
        }
        if (format != XCB_NONE) break;
    }
    
    free(formats_reply);
    return format;
}

- (xcb_render_pictformat_t)findFormatForDepth:(uint8_t)depth {
    // OPTIMIZATION: Use cached depth-to-format mapping (built during init)
    NSNumber *cachedFormat = self.depthFormatCache[@(depth)];
    if (cachedFormat) {
        return [cachedFormat unsignedIntValue];
    }
    
    // Fallback: query server if not in cache
    xcb_connection_t *conn = [self.connection connection];
    
    xcb_render_query_pict_formats_cookie_t formats_cookie = 
        xcb_render_query_pict_formats(conn);
    xcb_render_query_pict_formats_reply_t *formats_reply = 
        xcb_render_query_pict_formats_reply(conn, formats_cookie, NULL);
    
    if (!formats_reply) {
        return XCB_NONE;
    }
    
    xcb_render_pictformat_t format = XCB_NONE;
    xcb_render_pictforminfo_iterator_t iter = 
        xcb_render_query_pict_formats_formats_iterator(formats_reply);
    
    for (; iter.rem; xcb_render_pictforminfo_next(&iter)) {
        if (iter.data->depth == depth) {
            format = iter.data->id;
            // Cache it for future lookups
            self.depthFormatCache[@(depth)] = @(format);
            break;
        }
    }
    
    free(formats_reply);
    return format;
}

- (uint8_t)damageEventBase {
    return _damageEventBase;
}

#pragma mark - Deactivation & Cleanup

- (void)deactivateCompositing {
    if (!self.compositingActive) {
        return;
    }
    
    NSLog(@"[CompositingManager] Deactivating compositing...");
    
    @try {
        xcb_connection_t *conn = [self.connection connection];
        
        // Unredirect windows
        xcb_composite_unredirect_subwindows(conn, self.rootWindow,
                                           XCB_COMPOSITE_REDIRECT_MANUAL);
        
        [self cleanup];
        self.compositingActive = NO;
        NSLog(@"[CompositingManager] Compositing deactivated");
        
    } @catch (NSException *exception) {
        NSLog(@"[CompositingManager] EXCEPTION deactivating: %@", exception.reason);
    }
}

- (void)cleanup {
    @try {
        xcb_connection_t *conn = [self.connection connection];
        
        // Free all window data
        for (NSNumber *key in [self.cwindows allKeys]) {
            URSCompositeWindow *cw = self.cwindows[key];
            [self freeWindowData:cw delete:YES];
        }
        [self.cwindows removeAllObjects];
        
        // Free damage regions
        if (self.allDamage != XCB_NONE) {
            xcb_xfixes_destroy_region(conn, self.allDamage);
            self.allDamage = XCB_NONE;
        }
        
        if (self.screenRegion != XCB_NONE) {
            xcb_xfixes_destroy_region(conn, self.screenRegion);
            self.screenRegion = XCB_NONE;
        }
        
        // Free shadow resources
        if (self.blackPicture != XCB_NONE) {
            xcb_render_free_picture(conn, self.blackPicture);
            self.blackPicture = XCB_NONE;
        }
        
        if (self.shadowCorner) {
            free(self.shadowCorner);
            self.shadowCorner = NULL;
        }
        
        if (self.shadowTop) {
            free(self.shadowTop);
            self.shadowTop = NULL;
        }
        
        if (self.gaussianMap) {
            free(self.gaussianMap);
            self.gaussianMap = NULL;
        }
        
        // Free root buffer and picture
        if (self.rootBuffer != XCB_NONE) {
            xcb_render_free_picture(conn, self.rootBuffer);
            self.rootBuffer = XCB_NONE;
        }
        
        if (self.rootPixmap != XCB_NONE) {
            xcb_free_pixmap(conn, self.rootPixmap);
            self.rootPixmap = XCB_NONE;
        }
        
        if (self.rootPicture != XCB_NONE) {
            xcb_render_free_picture(conn, self.rootPicture);
            self.rootPicture = XCB_NONE;
        }
        
        // Destroy output window (child of overlay)
        if (self.outputWindow != XCB_NONE) {
            xcb_destroy_window(conn, self.outputWindow);
            self.outputWindow = XCB_NONE;
        }
        
        // Release overlay window
        if (self.overlayWindow != XCB_NONE) {
            xcb_composite_release_overlay_window(conn, self.rootWindow);
            self.overlayWindow = XCB_NONE;
        }
        
        [self.connection flush];
        NSLog(@"[CompositingManager] Cleanup complete");
        
    } @catch (NSException *exception) {
        NSLog(@"[CompositingManager] EXCEPTION during cleanup: %@", exception.reason);
    }
}

- (void)dealloc {
    [self cleanup];
}

#pragma mark - Non-Compositing Zoom Rect Animation

// Class method for non-compositing zoom rect animation
// Uses XOR drawing to show outline rectangles animating from startRect to endRect
+ (void)animateZoomRectsFromRect:(XCBRect)startRect
                          toRect:(XCBRect)endRect
                      connection:(XCBConnection *)connection
                          screen:(xcb_screen_t *)screen
                        duration:(NSTimeInterval)duration {
    if (!connection || !screen) {
        NSLog(@"[ZoomRectAnimation] Invalid connection or screen");
        return;
    }
    
    // Validate rectangles
    if (!FnCheckXCBRectIsValid(startRect) || !FnCheckXCBRectIsValid(endRect)) {
        NSLog(@"[ZoomRectAnimation] Invalid rectangle coordinates");
        return;
    }
    
    xcb_connection_t *conn = [connection connection];
    xcb_window_t root = screen->root;
    
    // Create a graphics context for XOR drawing
    xcb_gcontext_t gc = xcb_generate_id(conn);
    uint32_t mask = XCB_GC_FOREGROUND | XCB_GC_FUNCTION | XCB_GC_SUBWINDOW_MODE | XCB_GC_LINE_WIDTH;
    uint32_t values[4];
    values[0] = screen->white_pixel; // Foreground color (white)
    values[1] = XCB_GX_XOR;          // XOR function for drawing/erasing
    values[2] = XCB_SUBWINDOW_MODE_INCLUDE_INFERIORS; // Draw over child windows
    values[3] = 2;                   // Line width
    
    xcb_create_gc(conn, gc, root, mask, values);
    
    // Animation parameters
    const int numFrames = 12;
    const double frameDuration = duration / numFrames;
    
    // Draw animation frames
    for (int i = 0; i <= numFrames; i++) {
        double progress = (double)i / numFrames;
        
        // Ease-in-out interpolation
        double t = progress < 0.5 
            ? 2.0 * progress * progress 
            : 1.0 - 2.0 * (1.0 - progress) * (1.0 - progress);
        
        // Interpolate rectangle
        XCBRect currentRect;
        currentRect.position.x = startRect.position.x + (endRect.position.x - startRect.position.x) * t;
        currentRect.position.y = startRect.position.y + (endRect.position.y - startRect.position.y) * t;
        currentRect.size.width = startRect.size.width + (endRect.size.width - startRect.size.width) * t;
        currentRect.size.height = startRect.size.height + (endRect.size.height - startRect.size.height) * t;
        
        // Draw rectangle (XOR will automatically erase previous frame)
        xcb_rectangle_t rect;
        rect.x = currentRect.position.x;
        rect.y = currentRect.position.y;
        rect.width = currentRect.size.width;
        rect.height = currentRect.size.height;
        
        xcb_poly_rectangle(conn, root, gc, 1, &rect);
        xcb_flush(conn);
        
        // Don't sleep after last frame
        if (i < numFrames) {
            usleep(frameDuration * 1000000);
        }
        
        // Erase the rectangle for next frame (draw again with XOR)
        xcb_poly_rectangle(conn, root, gc, 1, &rect);
    }
    
    // Clean up
    xcb_free_gc(conn, gc);
    xcb_flush(conn);
}

@end

# WindowManager Theory of Operation

This document explains the architecture and operation of the WindowManager (uroswm), a hybrid X11 window manager that combines XCB-based window management with GNUstep/AppKit rendering for window decorations.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Window Hierarchy](#window-hierarchy)
4. [Rendering Pipeline](#rendering-pipeline)
5. [Double Buffering Strategy](#double-buffering-strategy)
6. [Compositor Operation](#compositor-operation)
7. [Event Flow](#event-flow)
8. [GSTheme Integration](#gstheme-integration)
9. [Improvements](#improvements)

---

## Overview

WindowManager is an Objective-C window manager that operates as an **NSApplication** while managing X11 windows via **XCBKit**. It provides:

- Traditional X11 window management (reparenting, decorations, focus handling)
- GNUstep GSTheme-based titlebar rendering for visual consistency with AppKit applications
- Optional XRender-based compositing for transparency effects (`-c` flag)

### Operating Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| **Traditional** | Windows render directly to screen | Maximum performance, no transparency |
| **Compositing** | Windows render to offscreen buffers, compositor blits to overlay | Transparency effects, damage-based redraws |

---

## Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      NSApplication (UROSWMApplication)          │
│                              │                                   │
│                    NSRunLoop Event Integration                   │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    URSHybridEventHandler                         │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │ XCB Event Loop  │  │ GSTheme Integ.  │  │ Compositing Mgr │  │
│  │ (via RunLoop)   │  │                 │  │   (optional)    │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                         XCBKit Library                           │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │  XCBConnection  │  │    XCBFrame     │  │   XCBTitleBar   │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                         X11 Server                               │
│  (Root Window, Client Windows, Pixmaps, XRender Pictures)        │
└─────────────────────────────────────────────────────────────────┘
```

### Key Classes

| Class | Responsibility |
|-------|----------------|
| **UROSWMApplication** | Custom NSApplication subclass for WM behavior |
| **URSHybridEventHandler** | Main event handler, bridges XCB and NSRunLoop |
| **URSThemeIntegration** | Renders GNUstep themes to X11 titlebars |
| **URSCompositingManager** | XRender-based compositing (when enabled) |
| **XCBFrame** | Window decoration frame (from XCBKit) |
| **XCBTitleBar** | Titlebar window with pixmap storage (from XCBKit) |

---

## Window Hierarchy

When a client application creates a window, the window manager **reparents** it into a frame structure:

```
Root Window (X11 screen root)
│
├── XCBFrame (frame window - created by WM)
│   │
│   ├── XCBTitleBar (titlebar child window)
│   │   ├── pixmap      (active state buffer)
│   │   └── dPixmap     (inactive/dimmed state buffer)
│   │
│   └── ClientWindow (the actual application window)
│
├── XCBFrame (another managed window)
│   ├── XCBTitleBar
│   └── ClientWindow
│
└── ... (more managed windows)
```

### Window Types and Roles

| Window | X11 Type | Purpose |
|--------|----------|---------|
| **Root Window** | InputOutput | Screen background, parent of all top-level windows |
| **XCBFrame** | InputOutput | Decoration frame, receives border/resize events |
| **XCBTitleBar** | InputOutput | Titlebar area, contains buttons and title text |
| **ClientWindow** | InputOutput | Application's actual window content |
| **Overlay Window** | InputOutput | Compositor's output surface (compositing mode only) |

### Frame Structure Details

An `XCBFrame` maintains child windows via a dictionary with keys:
- `TitleBar` → The XCBTitleBar instance
- `ClientWindow` → The reparented application window

The frame's geometry encompasses both the titlebar and client:

```
┌─────────────────────────────────────────┐ ← Frame top (y=0)
│  [●][●][●]  Window Title                │ ← TitleBar (25px height)
├─────────────────────────────────────────┤ ← Client top (y=25)
│                                         │
│            Client Content               │
│          (Application draws here)       │
│                                         │
└─────────────────────────────────────────┘ ← Frame bottom
```

---

## Rendering Pipeline

### Titlebar Rendering Flow

The titlebar rendering involves multiple frameworks working together:

```
1. GNUstep GSTheme          2. NSImage (in-memory)       3. Cairo Transfer
   draws to NSImage    →       RGBA bitmap buffer    →      to X11 Pixmap
   
   ┌─────────────┐           ┌─────────────┐           ┌─────────────┐
   │ [GSTheme    │           │ NSBitmap    │           │ XCB Pixmap  │
   │  drawing    │           │ ImageRep    │           │  (X server) │
   │  context]   │           │ RGBA data   │           │             │
   └─────────────┘           └─────────────┘           └─────────────┘
        AppKit                   CoreGraphics              X11/Cairo
```

### Detailed Steps

1. **GSTheme Rendering** (`URSThemeIntegration.renderGSThemeToWindow:`)
   - Create `NSImage` at titlebar dimensions
   - Lock focus on image (creates drawing context)
   - Call `[theme drawWindowBorder:withFrame:forStyleMask:state:andTitle:]`
   - Draw window buttons (close, minimize, zoom) with Eau theme colors
   - Unlock focus

2. **Bitmap Extraction**
   - Get `NSBitmapImageRep` from the NSImage
   - Access raw RGBA pixel data

3. **Format Conversion**
   - Convert RGBA → BGRA (Cairo's ARGB32 format expects BGRA byte order)
   - In-place byte swapping: swap R and B channels

4. **Cairo Transfer**
   - Create `cairo_xcb_surface_t` targeting the titlebar's X11 pixmap
   - Create `cairo_image_surface_t` from the converted bitmap data
   - Paint image surface onto X11 surface using `CAIRO_OPERATOR_SOURCE`
   - Flush surfaces to ensure data reaches X server

5. **Inactive State**
   - Create dimmed version of image (desaturated overlay)
   - Paint to `dPixmap` for unfocused window state

### Window Content Display

After pixmap is populated:

```c
// Set pixmap as window background (X server handles expose events)
xcb_change_window_attributes(conn, titlebar_window, 
                            XCB_CW_BACK_PIXMAP, &pixmap);

// Or copy pixmap to window immediately
xcb_copy_area(conn, pixmap, titlebar_window, gc,
              0, 0, 0, 0, width, height);
```

---

## Double Buffering Strategy

Double buffering prevents flickering and tearing. Multiple levels exist:

### Level 1: Titlebar Pixmaps (Per-Window)

Each `XCBTitleBar` maintains two pixmaps:

| Pixmap | Purpose | When Used |
|--------|---------|-----------|
| `pixmap` | Active (focused) state | Window has focus |
| `dPixmap` | Inactive (dimmed) state | Window lost focus |

The `drawArea:` method selects which pixmap to copy:
```objc
xcb_pixmap_t source = isAbove ? self.pixmap : self.dPixmap;
xcb_copy_area(conn, source, window, gc, ...);
```

### Level 2: Compositor Root Buffer (Screen-Wide)

When compositing is enabled, `URSCompositingManager` maintains:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Root Buffer                               │
│  (xcb_pixmap_t + xcb_render_picture_t)                          │
│                                                                  │
│  - Full screen dimensions                                        │
│  - All windows composited here                                   │
│  - Only damaged regions repainted                                │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼ (copy to overlay)
┌─────────────────────────────────────────────────────────────────┐
│                       Overlay Window                             │
│  (Composite overlay - always on top, input-transparent)         │
│                                                                  │
│  - Visible to user                                               │
│  - Receives final composited image                               │
└─────────────────────────────────────────────────────────────────┘
```

### Level 3: NameWindowPixmap (Per-Window Offscreen Storage)

In compositing mode, X11's Composite extension redirects window rendering:

```c
// Redirect all child windows to offscreen storage
xcb_composite_redirect_subwindows(conn, root, XCB_COMPOSITE_REDIRECT_MANUAL);

// Get handle to window's offscreen pixmap
xcb_composite_name_window_pixmap(conn, window_id, pixmap_id);
```

Each window renders to its own offscreen pixmap. The compositor:
1. Creates XRender `Picture` from each NameWindowPixmap
2. Composites all Pictures onto the root buffer
3. Copies root buffer to the overlay window

---

## Compositor Operation

### Initialization Sequence

```
1. Check X Extensions
   ├── COMPOSITE (≥ v0.2 for NameWindowPixmap)
   ├── RENDER (for XRender Pictures)
   ├── DAMAGE (for change tracking)
   └── XFIXES (for region manipulation)

2. Redirect Windows
   └── xcb_composite_redirect_subwindows(MANUAL)

3. Create Overlay
   ├── xcb_composite_get_overlay_window()
   ├── Make input-transparent (XFixes shape)
   └── Create output child window

4. Create Root Buffer
   ├── Pixmap at screen dimensions
   └── XRender Picture from pixmap

5. Register Existing Windows
   └── For each window: create damage tracker

6. Damage Entire Screen
   └── Trigger initial full repaint
```

### Damage Tracking

The compositor tracks which screen regions need repainting:

```objc
@interface URSCompositeWindow : NSObject
@property xcb_damage_damage_t damage;    // X DAMAGE object
@property BOOL damaged;                   // Has pending damage?
@property xcb_xfixes_region_t extents;   // Window's screen area
@end
```

**Damage Flow:**
1. Window content changes → X server sends `DamageNotify` event
2. Event handler calls `handleDamageNotify:`
3. Compositor adds damaged region to `allDamage`
4. Schedules repair via `performSelector:afterDelay:`
5. `paintAll:` repaints only damaged regions

### Painting Algorithm

```objc
- (void)paintAll:(xcb_xfixes_region_t)region {
    // 1. Set clip region to damaged area
    xcb_xfixes_set_picture_clip_region(rootBuffer, region);
    
    // 2. Paint background
    xcb_render_fill_rectangles(rootBuffer, background_color);
    
    // 3. Paint windows bottom-to-top (stacking order)
    for (window in query_tree_children) {
        if (window.viewable) {
            // Get window's XRender picture (uses NameWindowPixmap)
            picture = getWindowPicture(window);
            
            // Composite with OVER operator
            xcb_render_composite(OVER, picture, rootBuffer,
                                window.x, window.y);
        }
    }
    
    // 4. Copy buffer to overlay (only damaged region)
    xcb_render_composite(SRC, rootBuffer, overlayPicture,
                        region.bounds);
}
```

### IncludeInferiors Mode

XRender Pictures are created with `XCB_SUBWINDOW_MODE_INCLUDE_INFERIORS`:

```c
uint32_t pa_values[] = { XCB_SUBWINDOW_MODE_INCLUDE_INFERIORS };
xcb_render_create_picture(conn, picture, window, format,
                         XCB_RENDER_CP_SUBWINDOW_MODE, pa_values);
```

This means the Picture captures the window **and all its children** (titlebar, client, etc.) as a single image, simplifying the compositing loop.

---

## Event Flow

### NSRunLoop Integration

WindowManager integrates XCB events with GNUstep's NSRunLoop:

```objc
// Add XCB file descriptor to run loop
int xcbFD = xcb_get_file_descriptor(connection);
[runLoop addEvent:(void*)xcbFD
             type:ET_RDESC
          watcher:self
          forMode:NSDefaultRunLoopMode];
```

When data is available on the XCB connection:
1. RunLoop calls `receivedEvent:type:extra:forMode:`
2. Handler calls `processAvailableXCBEvents`
3. Events are polled non-blocking with `xcb_poll_for_event()`

### Motion Event Compression

During window resize/move, many `MotionNotify` events occur:

```objc
while ((e = xcb_poll_for_event(conn))) {
    if (event_type == XCB_MOTION_NOTIFY) {
        // Save latest motion, check for more events
        if (moreEventsQueued) {
            continue;  // Skip intermediate motions
        }
        // Process only the final motion
        [self clearTitlebarBackgroundBeforeResize:motionEvent];
        [connection handleMotionNotify:motionEvent];
        [self handleResizeDuringMotion:motionEvent];
    }
}
```

### Event Types and Handlers

| Event | Handler | Compositor Action |
|-------|---------|-------------------|
| `XCB_EXPOSE` | Redraw window area | `updateWindow:` |
| `XCB_MAP_NOTIFY` | Window became visible | `mapWindow:` |
| `XCB_UNMAP_NOTIFY` | Window hidden | `unmapWindow:` |
| `XCB_CONFIGURE_NOTIFY` | Window moved/resized | `resizeWindow:x:y:width:height:` |
| `XCB_DESTROY_NOTIFY` | Window destroyed | `unregisterWindow:` |
| `DamageNotify` | Content changed | `handleDamageNotify:` |
| `XCB_FOCUS_IN/OUT` | Focus changed | Render active/inactive titlebar |

---

## GSTheme Integration

### Theme Loading

```objc
+ (void)initializeGSTheme {
    // Load the Eau theme bundle
    NSBundle *themeBundle = [NSBundle bundleWithPath:@"...Eau.theme"];
    
    // Activate theme globally
    [GSTheme setTheme:[[themeClass alloc] init]];
}
```

### Titlebar Button Colors (Eau Theme)

| Button | Color | RGB Values |
|--------|-------|------------|
| Close | Red | (0.929, 0.353, 0.353) |
| Miniaturize | Yellow | (0.9, 0.7, 0.3) |
| Zoom | Green | (0.322, 0.778, 0.244) |

### Button Positioning

Eau theme uses specific positioning constants:

```objc
#define EAU_TITLEBAR_BUTTON_SIZE    15
#define EAU_TITLEBAR_PADDING_LEFT   10.5
#define EAU_TITLEBAR_PADDING_TOP    5.5
#define EAU_BUTTON_SPACING          4
```

Buttons are drawn left-to-right: Close → Miniaturize → Zoom

### Active vs Inactive States

- **Active**: Full-color titlebar, vibrant button colors
- **Inactive**: Desaturated overlay applied (50% gray at 35% opacity)

Both states are pre-rendered to separate pixmaps for instant switching.

---

## Improvements

### 1. Eliminate Redundant Pixmap Copies

**Current State:**
- GSTheme renders to NSImage → copies to Cairo surface → copies to X11 pixmap
- Then pixmap is copied to window on expose

**Improvement:**
- Render directly to an XCB shared memory pixmap (MIT-SHM extension)
- Use `XCB_IMAGE_FORMAT_Z_PIXMAP` with matching visual
- Eliminates one copy operation and format conversion

```c
// Proposed: Direct SHM pixmap rendering
xcb_shm_create_pixmap(conn, pixmap, window, width, height, depth, shmseg, offset);
// Map shared memory, render GNUstep directly to it
memcpy(shm_addr, bitmap_data, size);
xcb_copy_area(...);  // Now a no-op on some drivers
```

### 2. Unified Damage Notification

**Current State:**
- Multiple places call `renderGSThemeToWindow:` but must manually call compositor
- Easy to miss compositor notifications

**Improvement:**
- Create `URSRenderingContext` that wraps all rendering operations
- Automatically notifies compositor on context release

```objc
@interface URSRenderingContext : NSObject
- (void)beginRenderingWindow:(xcb_window_t)window;
- (void)endRendering;  // Auto-notifies compositor
@end
```

### 3. Lazy Picture Creation

**Current State:**
- NameWindowPixmap and Picture created immediately on window add
- Some windows may never be painted (unmapped, obscured)

**Improvement:**
- Defer pixmap/picture creation until first `paintWindow:` call
- Add `pictureValid` flag, recreate only when needed

### 4. Smarter Damage Coalescing

**Current State:**
- All damage events scheduled with fixed 1ms delay
- Full screen damage on `scheduleComposite` without pending damage

**Improvement:**
- Adaptive delay based on event rate (shorter during active interaction)
- Damage only the specific window area, not entire screen
- Use `xcb_xfixes_union_region` to efficiently merge damage

```objc
- (void)scheduleCompositeForWindow:(xcb_window_t)window {
    [self damageWindowArea:window];  // Specific, not full screen
}
```

### 5. Batch X11 Requests

**Current State:**
- Individual `xcb_render_composite` for each window
- Flush after each operation

**Improvement:**
- Batch all composite operations
- Single flush at end of paint cycle
- Use `xcb_render_composite_glyphs*` for batched text if applicable

### 6. Cache XRender Formats

**Current State:**
- `findVisualFormat:` queries server on every call

**Improvement:**
- Query formats once during initialization
- Cache in `NSMapTable` keyed by visual ID

```objc
@property NSMapTable *visualFormatCache;  // visual_id → pictformat
```

### 7. Avoid Full Window Tree Queries

**Current State:**
- `paintAll:` calls `xcb_query_tree` on every repaint

**Improvement:**
- Maintain window stacking order locally
- Update on `ConfigureNotify` (sibling changes)
- Only query tree on compositor activation

### 8. Separate Titlebar from Compositor Path

**Current State:**
- Titlebars are child windows, captured via IncludeInferiors
- Any titlebar change requires full frame recomposite

**Improvement:**
- Track titlebar damage separately
- Use XRender subpicture or clip to update only titlebar region
- Reduces compositing work for focus changes

### 9. Hardware Acceleration Path

**Current State:**
- Software XRender compositing

**Improvement:**
- Detect and use GLAMOR (OpenGL-based XRender)
- Consider EGL/DRI3 direct rendering for modern GPUs
- Fall back gracefully to software path

### 10. Reduce Format Conversions

**Current State:**
- NSImage (RGBA) → manual swap → Cairo (BGRA) → X11

**Improvement:**
- Configure NSBitmapImageRep with `NSAlphaFirstBitmapFormat` (ARGB)
- Matches X11 visual order on little-endian systems
- Eliminates per-pixel byte swapping loop

```objc
NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
    initWithBitmapDataPlanes:NULL
    pixelsWide:width pixelsHigh:height
    bitsPerSample:8 samplesPerPixel:4
    hasAlpha:YES isPlanar:NO
    colorSpaceName:NSDeviceRGBColorSpace
    bitmapFormat:NSAlphaFirstBitmapFormat  // ARGB order
    bytesPerRow:0 bitsPerPixel:32];
```

---

## Implemented Optimizations (2026)

The following optimizations have been implemented to bring the window manager to production quality:

### A. Eliminated Redundant Cairo Rendering

**Problem:** When GSTheme is active, the XCBKit layer would render full titlebars using Cairo (buttons, text, gradients), then URSThemeIntegration would immediately overwrite everything with GSTheme-rendered content. This wasted CPU cycles on drawing that was never visible.

**Solution:** Added `isGSThemeActive` property to XCBTitleBar. When set, XCBFrame skips:
- Button generation via TitleBarSettingsService
- Cairo drawing of all buttons (close, minimize, maximize, etc.)
- Cairo text rendering for window title

The titlebar pixmap is still allocated for double-buffering, but Cairo drawing is bypassed entirely.

**Files Modified:**
- `XCBTitleBar.h/m` - Added `setInternalTitle:` and conditional rendering in `setWindowTitle:`
- `XCBFrame.m` - Added `isGSThemeActive` check before Cairo button drawing

### B. Single-Pass Pixel Conversion with LUT

**Problem:** The `transferImage:toTitlebar:` method was performing RGBA→BGRA conversion twice:
1. Once for the active titlebar pixmap
2. Once for the dimmed (inactive) titlebar pixmap

Additionally, the dimmed version was created using expensive NSImage operations:
- Create new NSImage
- Lock focus
- Draw original image
- Draw gray overlay with alpha
- Unlock focus
- Extract bitmap again

**Solution:** Pre-computed a 256-entry dimming lookup table:
```objc
static uint8_t dimLUT[256];  // Computed once: dimLUT[i] = (i * 0.65) + 44.8
```

A single pass now creates both BGRA versions:
```objc
for (int i = 0; i < pixelCount; i++) {
    uint8_t r = src[0], g = src[1], b = src[2], a = src[3];
    // Active: BGRA
    dstActive[0] = b; dstActive[1] = g; dstActive[2] = r; dstActive[3] = a;
    // Dimmed: Apply LUT during same loop
    dstDimmed[0] = dimLUT[b]; dstDimmed[1] = dimLUT[g]; 
    dstDimmed[2] = dimLUT[r]; dstDimmed[3] = a;
}
```

**Result:** Eliminated all NSImage-based dimming, reduced pixel iteration from 2× to 1×.

**Files Modified:**
- `URSThemeIntegration.m` - Complete rewrite of `transferImage:toTitlebar:`

### C. Removed Debug Logging

**Problem:** Verbose per-button and per-pixel NSLog calls were left in production code paths, causing significant I/O overhead during every titlebar render.

**Solution:** Removed all debug logging from hot paths. Remaining logs are for initialization and error conditions only.

**Files Modified:**
- `URSThemeIntegration.m` - Removed ~30 lines of debug NSLog calls

### D. Verified Already-Optimized Systems

The following systems were reviewed and found to be already well-optimized:

1. **URSCompositingManager Caching:** Uses `visualFormatCache`, `depthFormatCache`, and `windowStackingOrder` to avoid repeated X server queries.

2. **Double Buffering:** XCBTitleBar correctly maintains separate `activePixmap` and `inactivePixmap` with efficient `setActivePixmap:` to swap between them.

3. **Resize Handling:** Previous flush calls have already been removed from the resize path.

---

## Summary

WindowManager achieves its hybrid architecture through careful layering:

1. **NSApplication** provides the main loop and AppKit integration
2. **XCBKit** handles X11 protocol and basic window management
3. **URSThemeIntegration** bridges GNUstep theming to X11 visuals
4. **URSCompositingManager** optionally provides composited rendering

The key insight is using Cairo as the bridge between GNUstep's Quartz-like drawing model and X11's pixmap-based rendering. Double buffering at multiple levels (titlebar pixmaps, compositor root buffer) ensures smooth visual updates.

### Remaining Optimization Opportunities

1. **MIT-SHM Zero-Copy Transfers:** Use shared memory for pixmap data transfer instead of `xcb_put_image`
2. **ARGB Bitmap Format:** Configure NSBitmapImageRep with `NSAlphaFirstBitmapFormat` to eliminate byte swapping entirely
3. **Hardware Acceleration:** Detect GLAMOR/DRI3 for GPU-accelerated compositing

/* repairflush_unit.m - ARC half of the repairWindow: flush-batching test.
 *
 * URSCompositingManager.m is ARC and the GNUstep ObjectTesting macros
 * (Testing.h) are not - they can't share one translation unit (ARC forbids
 * the explicit -retain/-release the PASS macro expands to).  This file does
 * everything that needs the class under test and reports plain C values
 * back to the non-ARC test-tool main() in repairflush.m.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "../../WindowManager/URSCompositingManager.m"

static NSUInteger gFlushCount = 0;

@interface XCBConnection (FlushCounter)
- (int)counted_flush;
@end

@implementation XCBConnection (FlushCounter)
- (int)counted_flush {
    // After the swizzle in RFRunRepairWindowTest this IMP is bound to the
    // selector that now holds the ORIGINAL -flush implementation, so the
    // recursive-looking call below is really the real xcb_flush.
    gFlushCount++;
    return [self counted_flush];
}
@end

int RFRunRepairWindowTest(int *outConnected, int *outScreenOk, int *outInitialized,
                          int *outHasPendingDamage, int *outFlushCount,
                          int *outDeltaContainsDraw)
{
  @autoreleasepool {
    Method original = class_getInstanceMethod([XCBConnection class], @selector(flush));
    Method counted  = class_getInstanceMethod([XCBConnection class], @selector(counted_flush));
    method_exchangeImplementations(original, counted);

    XCBConnection *connection = [[XCBConnection alloc] initWithDisplay:@":90"
                                                        asWindowManager:NO];
    *outConnected = (connection != nil);
    if (!connection) {
        return 0;
    }

    xcb_connection_t *conn = [connection connection];
    xcb_screen_t *screen = [[[connection screens] firstObject] screen];
    *outScreenOk = (screen != NULL);
    if (!screen) {
        return 0;
    }

    URSCompositingManager *cm = [URSCompositingManager sharedManager];
    BOOL initialized = [cm initializeWithConnection:connection];
    *outInitialized = initialized;
    if (!initialized) {
        return 0;
    }

    // repairWindow: itself never reads compositingActive - only the real
    // event loop's -hasPendingDamage gate does (see URSHybridEventHandler's
    // -processAvailableXCBEvents).  Setting it directly here, instead of
    // running the full -activateCompositing (overlay window, root buffer,
    // desktop background), keeps the fixture to exactly what this test
    // needs: a compositor that will report pending damage truthfully.
    cm.compositingActive = YES;

    // A plain top-level window stands in for a client; repairWindow: never
    // performs a round trip that depends on its content, only on the
    // geometry and Damage object recorded on the URSCompositeWindow.
    // Placed away from the origin so the damage delta has something to be
    // translated by - a delta path that forgot to convert the window-local
    // X Damage region into root coordinates would register it at (30,40)
    // instead of (530,440) and fail below.
    xcb_window_t win = xcb_generate_id(conn);
    uint32_t mask = XCB_CW_EVENT_MASK;
    uint32_t values[] = { XCB_EVENT_MASK_EXPOSURE };
    xcb_create_window(conn, XCB_COPY_FROM_PARENT, win, screen->root,
                       500, 400, 100, 100, 0,
                       XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual,
                       mask, values);
    xcb_map_window(conn, win);
    xcb_damage_damage_t damage = xcb_generate_id(conn);
    xcb_damage_create(conn, damage, win, XCB_DAMAGE_REPORT_LEVEL_NON_EMPTY);
    xcb_flush(conn);

    URSCompositeWindow *cw = [[URSCompositeWindow alloc] init];
    cw.windowId = win;
    cw.x = 500;
    cw.y = 400;
    cw.width = 100;
    cw.height = 100;
    cw.borderWidth = 0;
    cw.damage = damage;
    cw.redirected = YES;
    cw.closeAnimating = NO;

    gFlushCount = 0;
    [cm repairWindow:cw];

    *outHasPendingDamage = [cm hasPendingDamage];

    // Consume what that first repair registered so the next one is
    // observable on its own.  The window has been repaired by now, which is
    // what makes the second call read the drained X Damage delta instead of
    // the full extents - the difference between repainting window+shadow for
    // every client redraw and repainting only what changed.
    if (cm.allDamage != XCB_NONE) {
        xcb_xfixes_destroy_region(conn, cm.allDamage);
        cm.allDamage = XCB_NONE;
    }

    // Draw a sub-rectangle.  Requests are ordered on one connection, so the
    // Damage object has recorded this by the time repairWindow: subtracts it.
    xcb_gcontext_t gc = xcb_generate_id(conn);
    uint32_t fg = 0x00ff00;
    xcb_create_gc(conn, gc, win, XCB_GC_FOREGROUND, &fg);
    xcb_rectangle_t drawn = { 530 - 500, 440 - 400, 20, 10 };  /* window-local */
    xcb_poly_fill_rectangle(conn, win, gc, 1, &drawn);
    xcb_free_gc(conn, gc);
    xcb_flush(conn);

    [cm repairWindow:cw];
    *outFlushCount = (int)gFlushCount;

    // The registered damage has to be the drawn rectangle in ROOT
    // coordinates: covering it proves the delta reached addDamage: at all,
    // lying inside (500,400)-(600,500) proves the window->root translation
    // happened, and not being the whole window proves repairWindow: stopped
    // promoting damage to full extents.
    *outDeltaContainsDraw = 0;
    if (cm.allDamage != XCB_NONE) {
        xcb_xfixes_fetch_region_reply_t *rr =
            xcb_xfixes_fetch_region_reply(
                conn, xcb_xfixes_fetch_region(conn, cm.allDamage), NULL);
        if (rr) {
            int32_t x = rr->extents.x, y = rr->extents.y;
            int32_t w = rr->extents.width, h = rr->extents.height;
            int covers   = (x <= 530 && y <= 440 && x + w >= 550 && y + h >= 450);
            int rootSpace = (x >= 500 && y >= 400 && x + w <= 600 && y + h <= 500);
            int isDelta  = !(x == 500 && y == 400 && w == 100 && h == 100);
            *outDeltaContainsDraw = (covers && rootSpace && isDelta) ? 1 : 0;
            free(rr);
        }
    }

    xcb_destroy_window(conn, win);
    xcb_flush(conn);
  }
  return 1;
}

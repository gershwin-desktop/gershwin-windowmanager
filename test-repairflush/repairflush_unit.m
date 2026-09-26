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
#include "../WindowManager/URSCompositingManager.m"

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
                          int *outHasPendingDamage, int *outFlushCount)
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
    xcb_window_t win = xcb_generate_id(conn);
    uint32_t mask = XCB_CW_EVENT_MASK;
    uint32_t values[] = { XCB_EVENT_MASK_EXPOSURE };
    xcb_create_window(conn, XCB_COPY_FROM_PARENT, win, screen->root,
                       0, 0, 100, 100, 0,
                       XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual,
                       mask, values);
    xcb_map_window(conn, win);
    xcb_damage_damage_t damage = xcb_generate_id(conn);
    xcb_damage_create(conn, damage, win, XCB_DAMAGE_REPORT_LEVEL_NON_EMPTY);
    xcb_flush(conn);

    URSCompositeWindow *cw = [[URSCompositeWindow alloc] init];
    cw.windowId = win;
    cw.x = 0;
    cw.y = 0;
    cw.width = 100;
    cw.height = 100;
    cw.borderWidth = 0;
    cw.damage = damage;
    cw.redirected = YES;
    cw.closeAnimating = NO;

    gFlushCount = 0;
    [cm repairWindow:cw];

    *outHasPendingDamage = [cm hasPendingDamage];
    *outFlushCount = (int)gFlushCount;

    xcb_destroy_window(conn, win);
    xcb_flush(conn);
  }
  return 1;
}

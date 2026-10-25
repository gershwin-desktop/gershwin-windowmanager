/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSDisplayController.h"
#import "URSMonitorGeometry.h"
#import "URSWorkareaManager.h"
#import "URSTitlebarController.h"
#import "XCBConnection.h"
#import "XCBScreen.h"
#import "XCBFrame.h"
#import "TitleBarSettingsService.h"

#import <xcb/randr.h>
#import <stdlib.h>

// A monitor plugged in or out sends a screen change, CRTC changes and output
// changes within a few milliseconds; once they stop the layout is settled.
static const NSTimeInterval URSDisplayDebounceInterval = 0.5;

static NSString * const URSDisplayConfigToolDefault = @"/System/Library/Tools/displayconfig";

@implementation URSDisplayController
{
    __weak XCBConnection *_connection;
    __weak URSWorkareaManager *_workareaManager;
    __weak URSTitlebarController *_titlebarController;
    NSTimer *_debounce;
    NSTask *_task;
    // Outputs with a monitor attached, to tell a monitor coming or going
    // from changes the user makes (Display pane, xrandr): only the former
    // may bring back the saved layout, or every change would be undone.
    NSMutableSet *_connectedOutputs;
    BOOL _monitorsChanged;
    BOOL _reportedMissingTool;
    // RandR monitor names (atoms) of the last settled layout, and the one
    // the pointer was on when the current burst of changes began: the
    // server only pushes the pointer to the edge of the shrunk screen, so a
    // pointer whose monitor went away is otherwise left at that edge.
    NSArray *_monitorNames;
    NSArray *_monitorRects;
    NSNumber *_pointerMonitorBefore;
}

- (instancetype)initWithConnection:(XCBConnection *)connection
                   workareaManager:(URSWorkareaManager *)workareaManager
                titlebarController:(URSTitlebarController *)titlebarController
{
    self = [super init];
    if (!self) return nil;
    _connection = connection;
    _workareaManager = workareaManager;
    _titlebarController = titlebarController;
    _connectedOutputs = [self queryConnectedOutputs];
    // Login (or a restart of the window manager): apply once.
    _monitorsChanged = YES;
    return self;
}

- (NSMutableSet *)queryConnectedOutputs
{
    NSMutableSet *result = [NSMutableSet set];
    xcb_connection_t *conn = [_connection connection];
    XCBScreen *screen = [[_connection screens] firstObject];
    if (!conn || !screen) return result;
    xcb_randr_get_screen_resources_current_reply_t *res =
        xcb_randr_get_screen_resources_current_reply(
            conn, xcb_randr_get_screen_resources_current(conn, [screen screen]->root), NULL);
    if (!res) return result;
    xcb_randr_output_t *outputs = xcb_randr_get_screen_resources_current_outputs(res);
    int n = xcb_randr_get_screen_resources_current_outputs_length(res);
    for (int i = 0; i < n; i++) {
        xcb_randr_get_output_info_reply_t *info = xcb_randr_get_output_info_reply(
            conn, xcb_randr_get_output_info(conn, outputs[i], res->config_timestamp), NULL);
        if (info && info->connection == XCB_RANDR_CONNECTION_CONNECTED) {
            [result addObject:@(outputs[i])];
        }
        free(info);
    }
    free(res);
    return result;
}

- (void)output:(uint32_t)output connected:(BOOL)connected
{
    NSNumber *key = @(output);
    if (connected != [_connectedOutputs containsObject:key]) {
        if (connected) {
            [_connectedOutputs addObject:key];
        } else {
            [_connectedOutputs removeObject:key];
        }
        _monitorsChanged = YES;
    }
    [self screenChanged];
}

- (void)screenChanged
{
    if (_debounce == nil && _task == nil) [self notePointerMonitor];
    [_debounce invalidate];
    _debounce = [NSTimer scheduledTimerWithTimeInterval:URSDisplayDebounceInterval
                                                 target:self
                                               selector:@selector(debounceFired:)
                                               userInfo:nil
                                                repeats:NO];
}

// The installed tool unless the URSDisplayConfigTool default names another
// build (used to test an uninstalled one).
- (NSString *)toolPath
{
    NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:@"URSDisplayConfigTool"];
    return [path length] ? path : URSDisplayConfigToolDefault;
}

- (void)debounceFired:(NSTimer *)timer
{
    _debounce = nil;
    // A running tool is followed by its own settling step.
    if (_task) return;
    if (!_monitorsChanged) {
        [self layoutSettled];
        return;
    }
    _monitorsChanged = NO;
    NSString *tool = [self toolPath];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:tool]) {
        if (!_reportedMissingTool) {
            NSLog(@"[Display] ERROR: %@ is missing; saved display layouts are not applied "
                  @"and no RandR primary is set", tool);
            _reportedMissingTool = YES;
        }
        [self layoutSettled];
        return;
    }
    // Asynchronous: the X event loop must keep running while the tool talks
    // to the server (it grabs it while applying).  Its messages go to our
    // own stderr, the WindowManager log.
    NSTask *task = [NSTask new];
    [task setLaunchPath:tool];
    [task setArguments:@[ @"apply" ]];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(toolExited:)
                                                 name:NSTaskDidTerminateNotification
                                               object:task];
    @try {
        [task launch];
    } @catch (NSException *e) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSTaskDidTerminateNotification
                                                      object:task];
        NSLog(@"[Display] ERROR: cannot run %@ apply: %@", tool, [e reason]);
        [self layoutSettled];
        return;
    }
    _task = task;
}

- (void)toolExited:(NSNotification *)notification
{
    NSTask *task = [notification object];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:task];
    if ([task terminationStatus] != 0) {
        NSLog(@"[Display] ERROR: %@ apply failed with status %d; the display layout "
              @"may not be the saved one", [task launchPath], [task terminationStatus]);
    }
    _task = nil;
    // A monitor that came or went while it ran was perhaps not seen by it.
    if (_monitorsChanged) {
        [self screenChanged];
    } else if (_debounce == nil) {
        [self layoutSettled];
    }
}

#pragma mark - After the layout settled

- (BOOL)queryPointer:(NSPoint *)where
{
    xcb_connection_t *conn = [_connection connection];
    XCBScreen *screen = [[_connection screens] firstObject];
    if (!conn || !screen) return NO;
    xcb_query_pointer_reply_t *p = xcb_query_pointer_reply(
        conn, xcb_query_pointer(conn, [screen screen]->root), NULL);
    if (!p) return NO;
    *where = NSMakePoint(p->root_x, p->root_y);
    free(p);
    return YES;
}

- (void)notePointerMonitor
{
    _pointerMonitorBefore = nil;
    NSPoint where;
    if (![self queryPointer:&where]) return;
    for (NSUInteger i = 0; i < [_monitorRects count]; i++) {
        if (URSPointIsOnRects(where, @[ [_monitorRects objectAtIndex:i] ])) {
            _pointerMonitorBefore = [_monitorNames objectAtIndex:i];
            return;
        }
    }
}

// The lit monitors from RandR 1.5, primary first in `primary`, their names
// in `names`.  nil when the server cannot tell, then the whole screen
// counts as one monitor.
- (NSArray *)queryMonitors:(NSUInteger *)primary names:(NSArray **)names
{
    xcb_connection_t *conn = [_connection connection];
    XCBScreen *screen = [[_connection screens] firstObject];
    if (!conn || !screen) return nil;
    xcb_randr_get_monitors_reply_t *reply = xcb_randr_get_monitors_reply(
        conn, xcb_randr_get_monitors(conn, [screen screen]->root, 1), NULL);
    if (!reply) return nil;
    NSMutableArray *monitors = [NSMutableArray array];
    NSMutableArray *monitorNames = [NSMutableArray array];
    NSInteger primaryIndex = -1, originIndex = -1;
    xcb_randr_monitor_info_iterator_t it = xcb_randr_get_monitors_monitors_iterator(reply);
    for (; it.rem; xcb_randr_monitor_info_next(&it)) {
        xcb_randr_monitor_info_t *m = it.data;
        NSRect r = NSMakeRect(m->x, m->y, m->width, m->height);
        if (m->primary && primaryIndex < 0) primaryIndex = (NSInteger)[monitors count];
        if (originIndex < 0 && NSPointInRect(NSZeroPoint, r)) originIndex = (NSInteger)[monitors count];
        [monitors addObject:[NSValue valueWithRect:r]];
        [monitorNames addObject:@(m->name)];
    }
    free(reply);
    // The same rule as Menu and the Display pane when no primary is set.
    *primary = primaryIndex >= 0 ? (NSUInteger)primaryIndex
             : originIndex >= 0 ? (NSUInteger)originIndex : 0;
    *names = monitorNames;
    return [monitors count] ? monitors : nil;
}

- (void)layoutSettled
{
    NSUInteger primary = 0;
    NSArray *names = nil;
    NSArray *monitors = [self queryMonitors:&primary names:&names];
    _monitorRects = monitors;
    _monitorNames = names;
    _workareaManager.monitors = monitors;
    _workareaManager.primaryMonitorIndex = primary;
    [_workareaManager recalculateWorkarea];
    NSUInteger moved = [self rescueWindows];
    BOOL warped = [self rescuePointer];
    NSLog(@"[Display] Layout settled: %lu monitor(s), primary %lu, %lu window(s) brought back%@",
          (unsigned long)[[_workareaManager effectiveMonitors] count], (unsigned long)primary,
          (unsigned long)moved, warped ? @", pointer moved to the primary" : @"");
}

- (NSUInteger)rescueWindows
{
    NSArray *usable = [_workareaManager usableMonitorRects];
    NSUInteger primary = _workareaManager.primaryMonitorIndex;
    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    NSUInteger moved = 0;
    for (XCBWindow *window in [[_connection windowsMap] allValues]) {
        if (![_workareaManager isRelocatableFrame:window]) continue;
        XCBFrame *frame = (XCBFrame *)window;
        XCBWindow *client = [frame childWindowForKey:ClientWindow];
        if (!client) continue;
        XCBRect r = [frame windowRect];
        NSRect old = NSMakeRect(r.position.x, r.position.y, r.size.width, r.size.height);
        NSRect now = URSRescueFrame(old, [settings heightForUtility:[client isUtilityPanel]],
                                    usable, primary, [client canResize]);
        if (NSEqualRects(old, now)) continue;
        XCBRect target = XCBMakeRect(XCBMakePoint((int32_t)NSMinX(now), (int32_t)NSMinY(now)),
                                     XCBMakeSize((uint32_t)NSWidth(now), (uint32_t)NSHeight(now)));
        if (NSEqualSizes(old.size, now.size)) {
            uint32_t values[2] = { (uint32_t)target.position.x, (uint32_t)target.position.y };
            xcb_configure_window([_connection connection], [frame window],
                                 XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y, values);
            [frame setWindowRect:target];
            // The client learns its new root position only from us.
            [frame configureClient];
        } else {
            [_titlebarController applyFrameRect:target toFrame:frame];
        }
        moved++;
    }
    [_connection flush];
    return moved;
}

- (BOOL)rescuePointer
{
    xcb_connection_t *conn = [_connection connection];
    XCBScreen *screen = [[_connection screens] firstObject];
    NSPoint where;
    if (!conn || !screen || ![self queryPointer:&where]) return NO;
    xcb_window_t root = [screen screen]->root;
    NSArray *monitors = [_workareaManager effectiveMonitors];
    BOOL monitorGone = _pointerMonitorBefore != nil && _monitorNames != nil
        && ![_monitorNames containsObject:_pointerMonitorBefore];
    _pointerMonitorBefore = nil;
    if (!monitorGone && URSPointIsOnRects(where, monitors)) return NO;
    NSUInteger primary = _workareaManager.primaryMonitorIndex;
    NSRect target = [[monitors objectAtIndex:(primary < [monitors count] ? primary : 0)] rectValue];
    xcb_warp_pointer(conn, XCB_NONE, root, 0, 0, 0, 0,
                     (int16_t)NSMidX(target), (int16_t)NSMidY(target));
    [_connection flush];
    return YES;
}

@end

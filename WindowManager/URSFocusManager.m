//
//  URSFocusManager.m
//  uroswm - Focus Tracking and Window Resolution
//
//  Manages which window has focus, resolves window/frame/titlebar/client
//  relationships, checks focusability, and reassigns focus after window removal.
//

#import "URSFocusManager.h"
#import "URSProfiler.h"
#import "XCBScreen.h"
#import "XCBAttributesReply.h"
#import "EWMHService.h"
#import <AppKit/AppKit.h>

@interface URSFocusManager ()
@property (strong, nonatomic) NSMutableSet *recentlyAutoFocusedWindowIds;
@end

@implementation URSFocusManager

- (void)refreshAppKitActivationState
{
    if (!NSApp) {
        return;
    }

    // Ensure AppKit global UI (including menu bar visuals) reflects the
    // window that was just focused via X11 path.
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp updateWindows];

    NSMenu *menu = [NSApp mainMenu];
    if (menu) {
        [menu update];
    }
}

- (instancetype)initWithConnection:(XCBConnection *)aConnection
                   selectionWindow:(XCBWindow *)aSelectionWindow
{
    self = [super init];
    if (!self) return nil;

    _connection = aConnection;
    _selectionManagerWindow = aSelectionWindow;
    _lastFocusedWindowId = XCB_NONE;
    _previousFocusedWindowId = XCB_NONE;
    _recentlyAutoFocusedWindowIds = [[NSMutableSet alloc] init];

    return self;
}

#pragma mark - Focus Tracking

- (void)trackFocusGain:(xcb_window_t)clientWindowId
{
    if (clientWindowId != XCB_NONE && clientWindowId != self.lastFocusedWindowId) {
        self.previousFocusedWindowId = self.lastFocusedWindowId;
        self.lastFocusedWindowId = clientWindowId;
    }
}

- (void)ensureFocusAfterWindowRemoval:(xcb_window_t)removedClientId
{
    // If the xcb connection is wedged, every xcb_*_reply we'd issue here
    // returns NULL and trips an unguarded deref somewhere downstream. Bail
    // early — there is no useful focus rebuild to do against a dead server.
    if (xcb_connection_has_error([self.connection connection])) {
        return;
    }

    URS_PROFILE_BEGIN(focusResolve);
    if (removedClientId != self.lastFocusedWindowId) {
        if (self.lastFocusedWindowId == XCB_NONE) {
            URS_PROFILE_END(focusResolve);
            return;
        }
        XCBWindow *currentFocus = [self windowForClientWindowId:self.lastFocusedWindowId];
        if (currentFocus && [self isWindowFocusable:currentFocus allowDesktop:NO]) {
            URS_PROFILE_END(focusResolve);
            return;
        }
        self.lastFocusedWindowId = XCB_NONE;
    }

    xcb_window_t targetId = XCB_NONE;

    // First, try to find a focusable window from the same application (PID)
    // This ensures that when a window closes, another window from the same app
    // gets focus if available (and not minimized).
    targetId = [self focusableWindowWithSamePidAs:removedClientId excluding:removedClientId];

    if (targetId == XCB_NONE && self.previousFocusedWindowId != XCB_NONE &&
        self.previousFocusedWindowId != removedClientId) {
        XCBWindow *previousWindow = [self windowForClientWindowId:self.previousFocusedWindowId];
        if (previousWindow && [self isWindowFocusable:previousWindow allowDesktop:NO]) {
            targetId = self.previousFocusedWindowId;
        }
    }

    if (targetId == XCB_NONE) {
        targetId = [self desktopWindowCandidateExcluding:removedClientId];
    }

    if (targetId == XCB_NONE) {
        targetId = [self anyFocusableWindowExcluding:removedClientId];
    }

    if (targetId == XCB_NONE) {
        URS_PROFILE_END(focusResolve);
        return;
    }

    XCBWindow *targetWindow = [self windowForClientWindowId:targetId];
    if (!targetWindow) {
        URS_PROFILE_END(focusResolve);
        return;
    }

    [targetWindow focus];
    [self refreshAppKitActivationState];

    self.previousFocusedWindowId = self.lastFocusedWindowId;
    self.lastFocusedWindowId = targetId;
    URS_PROFILE_END(focusResolve);
}

- (void)focusWindowDelayed:(XCBWindow *)clientWindow
{
    if (!clientWindow) {
        return;
    }

    xcb_window_t windowId = [clientWindow window];
    NSNumber *windowIdNum = @(windowId);

    if ([self.recentlyAutoFocusedWindowIds containsObject:windowIdNum]) {
        NSLog(@"[Focus] Window %u already auto-focused recently, skipping", windowId);
        return;
    }

    NSLog(@"[Focus] Focusing window %u after theme applied", windowId);
    if ([self isWindowFocusable:clientWindow allowDesktop:NO]) {
        [clientWindow focus];
        [self refreshAppKitActivationState];
        [self.recentlyAutoFocusedWindowIds addObject:windowIdNum];
        NSLog(@"[Focus] Successfully focused window %u", windowId);

        [self performSelector:@selector(removeWindowFromRecentlyFocused:)
                   withObject:windowIdNum
                   afterDelay:1.0];
    } else {
        NSLog(@"[Focus] Window %u is not focusable", windowId);
    }
}

- (void)focusWindowAfterThemeApplied:(XCBWindow *)clientWindow
{
    [self focusWindowDelayed:clientWindow];
}

- (void)focusNewlyMappedWindow:(XCBWindow *)clientWindow
{
    if (!clientWindow) {
        return;
    }

    xcb_window_t windowId = [clientWindow window];
    NSNumber *windowIdNum = @(windowId);

    NSLog(@"[Focus] Focusing newly mapped window %u", windowId);
    if ([self isWindowFocusable:clientWindow allowDesktop:NO]) {
        [clientWindow focus];
        [self refreshAppKitActivationState];
        [self.recentlyAutoFocusedWindowIds addObject:windowIdNum];
        [self trackFocusGain:windowId];
        NSLog(@"[Focus] Successfully focused newly mapped window %u", windowId);

        // Remove from anti-spam set after 1 second to allow other windows to be focused
        [self performSelector:@selector(removeWindowFromRecentlyFocused:)
                   withObject:windowIdNum
                   afterDelay:1.0];
    } else {
        NSLog(@"[Focus] Newly mapped window %u is not focusable, skipping focus", windowId);
    }
}

- (void)removeWindowFromRecentlyFocused:(NSNumber *)windowIdNum
{
    [self.recentlyAutoFocusedWindowIds removeObject:windowIdNum];
}

#pragma mark - Focusability Queries

- (BOOL)isWindowFocusable:(XCBWindow *)window allowDesktop:(BOOL)allowDesktop
{
    if (!window) {
        return NO;
    }

    if (self.selectionManagerWindow &&
        [window window] == [self.selectionManagerWindow window]) {
        return NO;
    }

    if ([window needDestroy]) {
        return NO;
    }

    if ([window isMinimized]) {
        return NO;
    }

    [window updateAttributes];
    XCBAttributesReply *attrs = [window attributes];
    if (attrs && attrs.mapState != XCB_MAP_STATE_VIEWABLE) {
        return NO;
    }

    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self.connection];
    NSString *windowType = [window windowType];

    BOOL isMenuWindow =
        [windowType isEqualToString:[ewmhService EWMHWMWindowTypeMenu]] ||
        [windowType isEqualToString:[ewmhService EWMHWMWindowTypePopupMenu]] ||
        [windowType isEqualToString:[ewmhService EWMHWMWindowTypeDropdownMenu]];

    if (isMenuWindow) {
        return NO;
    }

    BOOL isOtherNonFocusType =
        [windowType isEqualToString:[ewmhService EWMHWMWindowTypeTooltip]] ||
        [windowType isEqualToString:[ewmhService EWMHWMWindowTypeNotification]] ||
        [windowType isEqualToString:[ewmhService EWMHWMWindowTypeDock]] ||
        [windowType isEqualToString:[ewmhService EWMHWMWindowTypeToolbar]] ||
        [windowType isEqualToString:[ewmhService EWMHWMWindowTypeSplash]];

    if (isOtherNonFocusType) {
        return NO;
    }

    BOOL isDesktopWindow =
        [windowType isEqualToString:[ewmhService EWMHWMWindowTypeDesktop]];
    if (isDesktopWindow && !allowDesktop) {
        return NO;
    }

    return YES;
}

- (xcb_window_t)desktopWindowCandidateExcluding:(xcb_window_t)excludedId
{
    NSDictionary *windowsMap = [self.connection windowsMap];
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self.connection];

    for (NSString *mapWindowId in windowsMap) {
        XCBWindow *mapWindow = [windowsMap objectForKey:mapWindowId];
        if (!mapWindow) continue;

        XCBWindow *clientWindow = [self clientWindowForWindow:mapWindow fallbackFrame:nil];
        if (!clientWindow) continue;

        xcb_window_t clientId = [clientWindow window];
        if (clientId == excludedId) continue;

        if ([self isWindowFocusable:clientWindow allowDesktop:YES]) {
            NSString *windowType = [clientWindow windowType];
            if ([windowType isEqualToString:[ewmhService EWMHWMWindowTypeDesktop]]) {
                return clientId;
            }
        }
    }

    return XCB_NONE;
}

- (xcb_window_t)anyFocusableWindowExcluding:(xcb_window_t)excludedId
{
    NSDictionary *windowsMap = [self.connection windowsMap];

    for (NSString *mapWindowId in windowsMap) {
        XCBWindow *mapWindow = [windowsMap objectForKey:mapWindowId];
        if (!mapWindow) continue;

        XCBWindow *clientWindow = [self clientWindowForWindow:mapWindow fallbackFrame:nil];
        if (!clientWindow) continue;

        xcb_window_t clientId = [clientWindow window];
        if (clientId == excludedId) continue;

        if ([self isWindowFocusable:clientWindow allowDesktop:NO]) {
            return clientId;
        }
    }

    return XCB_NONE;
}

- (xcb_window_t)focusableWindowWithSamePidAs:(xcb_window_t)clientWindowId
                                  excluding:(xcb_window_t)excludedId
{
    if (clientWindowId == XCB_NONE) {
        return XCB_NONE;
    }

    XCBWindow *sourceWindow = [self windowForClientWindowId:clientWindowId];
    if (!sourceWindow) {
        return XCB_NONE;
    }

    // Get the PID of the source window
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self.connection];
    uint32_t sourcePid = [ewmhService netWMPidForWindow:sourceWindow];
    
    if (sourcePid == (uint32_t)-1) {
        // No PID available, cannot find same-app windows
        return XCB_NONE;
    }

    NSDictionary *windowsMap = [self.connection windowsMap];

    for (NSNumber *mapWindowId in windowsMap) {
        XCBWindow *mapWindow = [windowsMap objectForKey:mapWindowId];
        if (!mapWindow) continue;

        XCBWindow *clientWindow = [self clientWindowForWindow:mapWindow fallbackFrame:nil];
        if (!clientWindow) continue;

        xcb_window_t clientId = [clientWindow window];
        
        // Skip the excluded window (the one being closed)
        if (clientId == excludedId) continue;
        
        // Skip if it's the same as source (shouldn't happen, but be safe)
        if (clientId == clientWindowId) continue;

        // Check if this window has the same PID
        uint32_t windowPid = [ewmhService netWMPidForWindow:clientWindow];
        if (windowPid != sourcePid) {
            continue;
        }

        // Check if the window is focusable and not minimized
        if ([self isWindowFocusable:clientWindow allowDesktop:NO]) {
            return clientId;
        }
    }

    return XCB_NONE;
}

#pragma mark - Window Resolution Utilities

- (XCBWindow *)clientWindowForWindow:(XCBWindow *)window
                       fallbackFrame:(XCBFrame *)frame
{
    if (!window) {
        if (frame && [frame isKindOfClass:[XCBFrame class]]) {
            return [frame childWindowForKey:ClientWindow];
        }
        return nil;
    }

    if ([window isKindOfClass:[XCBFrame class]]) {
        return [(XCBFrame *)window childWindowForKey:ClientWindow];
    }

    if ([window isKindOfClass:[XCBTitleBar class]]) {
        XCBFrame *parentFrame = (XCBFrame *)[window parentWindow];
        if (parentFrame) {
            return [parentFrame childWindowForKey:ClientWindow];
        }
    }

    if ([window parentWindow] &&
        [[window parentWindow] isKindOfClass:[XCBFrame class]]) {
        return window;
    }

    if ([window parentWindow] &&
        [[window parentWindow] isKindOfClass:[XCBTitleBar class]]) {
        XCBFrame *parentFrame = (XCBFrame *)[[window parentWindow] parentWindow];
        if (parentFrame) {
            return [parentFrame childWindowForKey:ClientWindow];
        }
    }

    if (frame && [frame isKindOfClass:[XCBFrame class]]) {
        return [frame childWindowForKey:ClientWindow];
    }

    return window;
}

- (xcb_window_t)clientWindowIdForWindowId:(xcb_window_t)windowId
{
    if (windowId == XCB_NONE) {
        return XCB_NONE;
    }

    XCBWindow *window = [self.connection windowForXCBId:windowId];
    XCBWindow *clientWindow = [self clientWindowForWindow:window fallbackFrame:nil];
    if (clientWindow) {
        return [clientWindow window];
    }

    NSDictionary *windowsMap = [self.connection windowsMap];
    for (NSString *mapWindowId in windowsMap) {
        XCBWindow *mapWindow = [windowsMap objectForKey:mapWindowId];
        if (mapWindow && [mapWindow isKindOfClass:[XCBFrame class]]) {
            XCBFrame *frame = (XCBFrame *)mapWindow;
            XCBWindow *client = [frame childWindowForKey:ClientWindow];
            if (client && [client window] == windowId) {
                return windowId;
            }
        }
    }

    return windowId;
}

- (XCBWindow *)windowForClientWindowId:(xcb_window_t)clientId
{
    if (clientId == XCB_NONE) {
        return nil;
    }

    XCBWindow *window = [self.connection windowForXCBId:clientId];
    if (window) {
        return window;
    }

    NSDictionary *windowsMap = [self.connection windowsMap];
    for (NSString *mapWindowId in windowsMap) {
        XCBWindow *mapWindow = [windowsMap objectForKey:mapWindowId];
        if (mapWindow && [mapWindow isKindOfClass:[XCBFrame class]]) {
            XCBFrame *frame = (XCBFrame *)mapWindow;
            XCBWindow *client = [frame childWindowForKey:ClientWindow];
            if (client && [client window] == clientId) {
                return client;
            }
        }
    }

    return nil;
}

@end

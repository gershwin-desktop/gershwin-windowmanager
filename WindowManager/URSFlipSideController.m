/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSFlipSideController.h"
#import "URSFlipSidePlan.h"
#import "URSFlipSideOrphans.h"
#import "URSSourceDirectory.h"
#import "URSWindowRole.h"
#import "URSAttachmentRegistry.h"
#import "URSCompositingManager+WindowFlip.h"
#import "XCBConnection.h"
#import "ICCCMService.h"
#import "EWMHService.h"
#import "XCBFrame.h"
#import "XCBWindow.h"
#include <signal.h>

NSString * const URSWindowFlipSideTerminalKey = @"URSWindowFlipSideTerminal";

// Long enough for a terminal to start on a busy system, short enough that a
// window that never turns is noticed as a failure, not as slowness.
static const NSTimeInterval URSFlipSideStartTimeout = 10.0;

@implementation URSFlipSideController
{
    // Parent client -> the terminal started for it, while it runs.
    NSMutableDictionary<NSNumber *, NSTask *> *_helpers;
    // Terminals told to quit, kept until they have: an NSTask let go of
    // before its process has exited may leave the process unreaped.
    NSMutableSet<NSTask *> *_endingHelpers;
    // Parent client -> process of a flip side that was already there when
    // this window manager started (from the one before it).
    NSMutableDictionary<NSNumber *, NSNumber *> *_adoptedHelperPids;
    // Window of a terminal we started -> its parent client, while its map
    // request waits for the role that makes it a flip side.
    NSMutableDictionary<NSNumber *, NSNumber *> *_heldWindows;
    // Parent client -> the time limit of a turn waiting for its flip side.
    NSMutableDictionary<NSNumber *, NSTimer *> *_pendingTurns;
    // Parent client -> its frame.  Kept here because the frame is already
    // gone from the connection when its DestroyNotify says the flip side
    // has to go too.
    NSMutableDictionary<NSNumber *, NSNumber *> *_frames;
    // Flip side -> its parent client; the registry has forgotten that by the
    // time forgetAttachmentOfWindow: is called.
    NSMutableDictionary<NSNumber *, NSNumber *> *_parents;
    // Parent clients turned, or turning, to their flip side.
    NSMutableSet<NSNumber *> *_flipSideInView;
    // Parent clients at rest on their flip side.
    NSMutableSet<NSNumber *> *_backShown;
    // Parent client -> its application (WM_CLASS) and the source directory
    // its terminal runs in, read while the parent is there: an orphan is
    // matched by them once it is gone.
    NSMutableDictionary<NSNumber *, NSString *> *_applications;
    NSMutableDictionary<NSNumber *, NSString *> *_directories;
    URSFlipSideOrphans *_orphans;
}

+ (void)initialize
{
    if (self == [URSFlipSideController class]) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            URSWindowFlipSideTerminalKey: @YES,
        }];
    }
}

- (instancetype)initWithConnection:(XCBConnection *)connection
{
    self = [super initWithConnection:connection];
    if (self) {
        _helpers = [NSMutableDictionary new];
        _endingHelpers = [NSMutableSet new];
        _adoptedHelperPids = [NSMutableDictionary new];
        _heldWindows = [NSMutableDictionary new];
        _pendingTurns = [NSMutableDictionary new];
        _frames = [NSMutableDictionary new];
        _parents = [NSMutableDictionary new];
        _flipSideInView = [NSMutableSet new];
        _backShown = [NSMutableSet new];
        _applications = [NSMutableDictionary new];
        _directories = [NSMutableDictionary new];
        _orphans = [URSFlipSideOrphans new];
    }
    return self;
}

#pragma mark - What a flip side is

- (NSString *)role
{
    return URSWindowRoleFlipSide;
}

// One terminal per window.
- (BOOL)attachesExclusively
{
    return YES;
}

- (BOOL)stacksAboveParentForWindow:(xcb_window_t)window
{
    return [URSFlipSidePlan flipSideStacksAboveParentWithBackShown:
               [_backShown containsObject:@([self.registry parentOfWindow:window])]];
}

// While the back is shown, the window is the terminal: a click on the
// titlebar focuses the parent, and that focus belongs to the terminal.
- (BOOL)takesParentFocusOfWindow:(xcb_window_t)window
{
    return [_backShown containsObject:@([self.registry parentOfWindow:window])];
}

// It is only ever seen on the back of its parent, which turns instead.
- (BOOL)slidesWindow:(xcb_window_t)window
{
    return NO;
}

- (NSRect)rectForWindow:(xcb_window_t)window
                   size:(NSSize)size
            parentFrame:(NSRect)parentFrame
          parentContent:(NSRect)parentContent
                 screen:(NSRect)screen
{
    return parentContent;
}

- (void)willShowAttachedWindow:(xcb_window_t)window parent:(xcb_window_t)parent
{
    XCBFrame *frame = [self frameOfClient:parent];
    _parents[@(window)] = @(parent);
    _frames[@(parent)] = @([frame window]);
    if (_helpers[@(parent)] == nil) {
        // Started by an earlier window manager; ended by its process id.
        uint32_t pid = [[self.connection windowForXCBId:window] pid];
        if (pid > 0) {
            _adoptedHelperPids[@(parent)] = @(pid);
        }
    }
    if (_applications[@(parent)] == nil) {
        // Shown by an earlier window manager: what it belongs to is read
        // now, while its parent is still there to tell.
        NSString *application = [self applicationOfClient:[self.connection windowForXCBId:parent]];
        if (application != nil) {
            _applications[@(parent)] = application;
            NSString *directory = [self sourceDirectoryOfApplication:application];
            if (directory != nil) {
                _directories[@(parent)] = directory;
            }
        }
    }
    [self.compositingManager setFlipSideWindow:window ofFrame:[frame window]];
    if (_pendingTurns[@(parent)] != nil) {
        // The first turn must already show the terminal, so it waits for
        // the terminal to have drawn into its window.
        __weak URSFlipSideController *weakSelf = self;
        [self.compositingManager performWhenWindowHasContent:window block:^{
            [weakSelf flipSideHasContentForParent:parent];
        }];
    }
}

- (void)forgetAttachmentOfWindow:(xcb_window_t)window
{
    NSNumber *parent = _parents[@(window)];
    [_parents removeObjectForKey:@(window)];
    [self.compositingManager detachFlipSideWindow:window];
    if (parent == nil) {
        return;
    }
    [_backShown removeObject:parent];
    if ([_flipSideInView containsObject:parent]) {
        // The terminal went away (the user typed exit): nothing is left to
        // show on the back.
        [_flipSideInView removeObject:parent];
        XCBFrame *frame = [self frameOfClient:[parent unsignedIntValue]];
        if (frame && [self.compositingManager showsBackOfWindow:[frame window]]) {
            [self.compositingManager flipWindow:[frame window]];
        }
    }
}

#pragma mark - The terminal's window

// The terminal we started for a parent that has no flip side yet, by the
// process the window belongs to.
- (xcb_window_t)helperParentOfWindow:(xcb_window_t)window
{
    if ([_helpers count] == 0) {
        return XCB_NONE;
    }
    XCBWindow *probe = [[XCBWindow alloc] initWithXCBWindow:window andConnection:self.connection];
    if (![probe updatePid]) {
        return XCB_NONE;
    }
    for (NSNumber *parent in _helpers) {
        if ([_helpers[parent] processIdentifier] == (int)[probe pid] &&
            [self.registry windowOfParent:[parent unsignedIntValue]] == XCB_NONE) {
            return [parent unsignedIntValue];
        }
    }
    return XCB_NONE;
}

// GNUstep creates a window's X window when it is first ordered front, so
// the terminal can set the role and the transient hint only after its map
// request has gone out.  Mapped as it asks, the window would be shown as an
// ordinary window until they arrive; a window of a terminal we started is
// therefore held unmapped until it says what it is.
- (BOOL)handleMapRequest:(xcb_map_request_event_t *)event
{
    if ([super handleMapRequest:event]) {
        return YES;
    }
    xcb_window_t parent = [self helperParentOfWindow:event->window];
    if (parent == XCB_NONE) {
        return NO;
    }
    _heldWindows[@(event->window)] = @(parent);
    uint32_t mask = XCB_EVENT_MASK_PROPERTY_CHANGE;
    xcb_change_window_attributes([self.connection connection], event->window,
                                 XCB_CW_EVENT_MASK, &mask);
    // Set before the selection took effect, they would send no event.
    [self attachHeldWindow:event->window];
    return YES;
}

- (void)windowPropertyChanged:(xcb_property_notify_event_t *)event
{
    if (_heldWindows[@(event->window)] != nil && event->state == XCB_PROPERTY_NEW_VALUE) {
        [self attachHeldWindow:event->window];
    }
}

- (void)attachHeldWindow:(xcb_window_t)window
{
    xcb_window_t expected = [_heldWindows[@(window)] unsignedIntValue];
    xcb_window_t marked = [self markedParentOfWindow:window];
    if (marked == XCB_NONE) {
        // Not yet: the role and the hint arrive one after the other.
        return;
    }
    [_heldWindows removeObjectForKey:@(window)];
    if (marked != expected) {
        NSLog(@"[FlipSide] Window %u of the terminal started for window %u names window %u "
              @"as its parent; it is not shown", window, expected, marked);
        return;
    }
    if (![self attachMarkedWindow:window]) {
        NSLog(@"[FlipSide] Window %u cannot be attached to window %u; it is not shown",
              window, expected);
    }
}

#pragma mark - Turning

- (BOOL)usesFlipSide
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:URSWindowFlipSideTerminalKey];
}

- (BOOL)canFlipFrame:(XCBFrame *)frame
{
    if (![self.compositingManager canFlipWindows]) {
        return NO;
    }
    if (![self usesFlipSide]) {
        return YES;
    }
    XCBWindow *client = [frame childWindowForKey:ClientWindow];
    xcb_window_t parent = [client window];
    if (parent == XCB_NONE) {
        return NO;
    }
    NSNumber *key = @(parent);
    if ([self.compositingManager showsBackOfWindow:[frame window]] || _pendingTurns[key] != nil ||
        [self.registry windowOfParent:parent] != XCB_NONE || _helpers[key] != nil) {
        return YES;
    }
    return [self sourceDirectoryOfApplication:[self applicationOfClient:client]] != nil;
}

- (void)flipFrame:(XCBFrame *)frame
{
    URSCompositingManager *compositor = self.compositingManager;
    if (![compositor canFlipWindows]) {
        return;
    }
    xcb_window_t frameId = [frame window];
    XCBWindow *client = [frame childWindowForKey:ClientWindow];
    xcb_window_t parent = [client window];
    if (parent == XCB_NONE) {
        NSLog(@"[FlipSide] Frame %u has no client; it is not turned", frameId);
        return;
    }
    NSNumber *key = @(parent);
    _frames[key] = @(frameId);
    URSFlipSideAction action =
        [URSFlipSidePlan actionWithBackInView:[compositor showsBackOfWindow:frameId]
                                      waiting:_pendingTurns[key] != nil
                                      enabled:[self usesFlipSide]
                                  hasFlipSide:[self.registry windowOfParent:parent] != XCB_NONE
                                helperRunning:_helpers[key] != nil];
    switch (action) {
    case URSFlipSideActionTurnToFront:
        [self turnToFrontOfParent:parent];
        break;
    case URSFlipSideActionCancelWait:
        [self cancelPendingTurnOfParent:parent];
        break;
    case URSFlipSideActionPlainTurn:
        [compositor flipWindow:frameId];
        break;
    case URSFlipSideActionEndFlipSideAndPlainTurn:
        [self endFlipSideOfParent:parent];
        [compositor flipWindow:frameId];
        break;
    case URSFlipSideActionTurnToFlipSide:
        [self turnToFlipSideOfParent:parent];
        break;
    case URSFlipSideActionWaitForFlipSide:
        [self waitForFlipSideOfParent:parent];
        break;
    case URSFlipSideActionLookUpSourceDirectory: {
        NSString *application = [self applicationOfClient:client];
        NSString *directory = [self sourceDirectoryOfApplication:application];
        if (directory == nil) {
            // The menu does not offer the item then; nothing turns for a
            // caller that asks anyway.
            NSLog(@"[FlipSide] No source directory for window %u; it is not turned", parent);
        } else if ([self startHelperInDirectory:directory forParent:parent]) {
            _applications[key] = application;
            _directories[key] = directory;
            [self waitForFlipSideOfParent:parent];
        }
        break;
    }
    }
}

// A GNUstep application's WM_CLASS class is its name.
- (NSString *)applicationOfClient:(XCBWindow *)client
{
    if ([[client windowClass] count] == 0) {
        [[ICCCMService sharedInstanceWithConnection:self.connection] wmClassForWindow:client];
    }
    return [[client windowClass] firstObject];
}

- (NSString *)sourceDirectoryOfApplication:(NSString *)application
{
    if (application == nil) {
        return nil;
    }
    return [URSSourceDirectory sourceDirectoryForApplicationName:application];
}

- (void)turnToFlipSideOfParent:(xcb_window_t)parent
{
    XCBFrame *frame = [self frameOfClient:parent];
    if (frame == nil) {
        return;
    }
    __weak URSFlipSideController *weakSelf = self;
    BOOL turning = [self.compositingManager flipWindow:[frame window] completion:^{
        // A turn ends while the compositor paints; the stacking and the
        // focus change after that.
        [weakSelf performSelector:@selector(turnToFlipSideEnded:) withObject:@(parent) afterDelay:0.0];
    }];
    if (turning) {
        [_flipSideInView addObject:@(parent)];
    }
}

- (void)turnToFlipSideEnded:(NSNumber *)parent
{
    XCBFrame *frame = [self frameOfClient:[parent unsignedIntValue]];
    xcb_window_t side = [self.registry windowOfParent:[parent unsignedIntValue]];
    // Not when the window went (unmapped mid-turn) or was turned round.
    if (frame == nil || side == XCB_NONE || ![_flipSideInView containsObject:parent] ||
        ![self.compositingManager restsOnBackOfWindow:[frame window]]) {
        return;
    }
    [_backShown addObject:parent];
    [self placeWindow:side];
    [self passFocusToAttachedWindowOfWindow:[parent unsignedIntValue]];
}

- (void)turnToFrontOfParent:(xcb_window_t)parent
{
    [_flipSideInView removeObject:@(parent)];
    [_backShown removeObject:@(parent)];
    XCBFrame *frame = [self frameOfClient:parent];
    if (frame == nil) {
        return;
    }
    [self.compositingManager flipWindow:[frame window]];
    xcb_window_t side = [self.registry windowOfParent:parent];
    if (side != XCB_NONE) {
        // Behind the frame again, so the clicks and the keys go to the
        // window the user sees.
        [self placeWindow:side];
        [self returnFocusFromWindow:side toParent:parent];
    }
}

#pragma mark - Waiting for the terminal

- (void)waitForFlipSideOfParent:(xcb_window_t)parent
{
    _pendingTurns[@(parent)] =
        [NSTimer scheduledTimerWithTimeInterval:URSFlipSideStartTimeout
                                         target:self
                                       selector:@selector(flipSideTimedOut:)
                                       userInfo:@(parent)
                                        repeats:NO];
}

- (void)cancelPendingTurnOfParent:(xcb_window_t)parent
{
    [_pendingTurns[@(parent)] invalidate];
    [_pendingTurns removeObjectForKey:@(parent)];
}

- (void)flipSideHasContentForParent:(xcb_window_t)parent
{
    if (_pendingTurns[@(parent)] == nil) {
        return;
    }
    [self cancelPendingTurnOfParent:parent];
    [self turnToFlipSideOfParent:parent];
}

- (void)flipSideTimedOut:(NSTimer *)timer
{
    NSNumber *parent = [timer userInfo];
    if (_pendingTurns[parent] != timer) {
        return;
    }
    [_pendingTurns removeObjectForKey:parent];
    NSLog(@"[FlipSide] The terminal for window %u did not show its window within %.0f s; "
          @"the window is not turned", [parent unsignedIntValue], URSFlipSideStartTimeout);
}

#pragma mark - The terminal process

- (BOOL)startHelperInDirectory:(NSString *)directory forParent:(xcb_window_t)parent
{
    NSString *applications = [NSSearchPathForDirectoriesInDomains(NSApplicationDirectory,
                                                                  NSSystemDomainMask, YES) firstObject];
    NSString *executable = [[NSBundle bundleWithPath:
                                [applications stringByAppendingPathComponent:@"Terminal.app"]]
                               executablePath];
    if (executable == nil) {
        NSLog(@"[FlipSide] No Terminal.app in %@; window %u is not turned", applications, parent);
        return NO;
    }
    NSTask *task = [NSTask new];
    [task setLaunchPath:executable];
    [task setCurrentDirectoryPath:directory];
    // Its own process whatever Terminal is running already: a second copy
    // would otherwise hand over to the running one and exit, and the shell
    // of this window would be one of the running Terminal's windows.
    [task setArguments:@[ @"-NSUseRunningCopy", @"NO",
                          @"-FlipSideDirectory", directory,
                          @"-FlipSideParent", [NSString stringWithFormat:@"%u", parent] ]];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(helperExited:)
                                                 name:NSTaskDidTerminateNotification
                                               object:task];
    @try {
        [task launch];
    } @catch (NSException *e) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSTaskDidTerminateNotification
                                                      object:task];
        NSLog(@"[FlipSide] Cannot start %@ for window %u: %@; it is not turned",
              executable, parent, e);
        return NO;
    }
    _helpers[@(parent)] = task;
    return YES;
}

- (void)helperExited:(NSNotification *)notification
{
    NSTask *task = [notification object];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:task];
    [_endingHelpers removeObject:task];
    URSFlipSideOrphan *orphan = [_orphans orphanWithToken:task];
    if (orphan != nil) {
        // Its window went with it.
        [_orphans removeOrphanWithWindow:[orphan window]];
    }
    for (NSNumber *parent in [_helpers allKeysForObject:task]) {
        [_helpers removeObjectForKey:parent];
        [self forgetHeldWindowsOfParent:parent];
        if (_pendingTurns[parent] != nil) {
            [self cancelPendingTurnOfParent:[parent unsignedIntValue]];
            NSLog(@"[FlipSide] The terminal for window %u exited with status %d before showing "
                  @"its window; the window is not turned",
                  [parent unsignedIntValue], [task terminationStatus]);
        }
    }
}

- (void)forgetHeldWindowsOfParent:(NSNumber *)parent
{
    for (NSNumber *window in [_heldWindows allKeysForObject:parent]) {
        [_heldWindows removeObjectForKey:window];
    }
}

// The flip side goes with its parent, or when it is switched off: the
// terminal is told to quit, and its window is unmapped at once, since until
// the terminal has quit it would still take the clicks over the client area.
- (void)endFlipSideOfParent:(xcb_window_t)parent
{
    NSNumber *key = @(parent);
    [self cancelPendingTurnOfParent:parent];
    [self forgetHeldWindowsOfParent:key];
    [_flipSideInView removeObject:key];
    [_backShown removeObject:key];
    xcb_window_t side = [self.registry windowOfParent:parent];
    if (side != XCB_NONE) {
        xcb_unmap_window([self.connection connection], side);
        [self.connection flush];
    }
    id token = _helpers[key] ?: _adoptedHelperPids[key];
    [_helpers removeObjectForKey:key];
    [_adoptedHelperPids removeObjectForKey:key];
    [self endHelper:token];
}

// A terminal we started, by its task, or one an earlier window manager
// started, by its process id.
- (void)endHelper:(id)token
{
    if ([token isKindOfClass:[NSTask class]]) {
        NSTask *task = token;
        if ([task isRunning]) {
            [_endingHelpers addObject:task];
            [task terminate];
        }
    } else if ([token isKindOfClass:[NSNumber class]]) {
        kill((pid_t)[token intValue], SIGTERM);
    }
}

#pragma mark - Following the parent

- (void)windowWillUnmap:(xcb_window_t)window
{
    // An unmapped (minimised) frame loses its turn in the compositor and
    // comes back showing its front.
    for (NSNumber *parent in [_flipSideInView allObjects]) {
        if ([[self frameOfClient:[parent unsignedIntValue]] window] == window) {
            [_flipSideInView removeObject:parent];
            [_backShown removeObject:parent];
        }
    }
    [super windowWillUnmap:window];
}

- (void)windowDestroyed:(xcb_window_t)window
{
    [_heldWindows removeObjectForKey:@(window)];
    URSFlipSideOrphan *orphan = [_orphans orphanWithWindow:window];
    if (orphan != nil) {
        // Closed, or the user typed exit: its terminal quits with its
        // window, and is reaped once it has.
        [_orphans removeOrphanWithWindow:window];
        if ([[orphan token] isKindOfClass:[NSTask class]]) {
            [_endingHelpers addObject:[orphan token]];
        }
    }
    // The parent's client or its frame (whichever is seen first): the
    // window is gone, and its flip side stays on as an orphan.
    for (NSNumber *parent in [_frames allKeys]) {
        if ([parent unsignedIntValue] == window || [_frames[parent] unsignedIntValue] == window) {
            [self orphanFlipSideOfParent:[parent unsignedIntValue]];
            [_frames removeObjectForKey:parent];
            [_applications removeObjectForKey:parent];
            [_directories removeObjectForKey:parent];
        }
    }
    [super windowDestroyed:window];
}

#pragma mark - Orphans

- (void)orphanFlipSideOfParent:(xcb_window_t)parent
{
    NSNumber *key = @(parent);
    xcb_window_t side = [self.registry windowOfParent:parent];
    if (side == XCB_NONE) {
        // Its terminal had not shown its window yet: the user never saw it.
        [self endFlipSideOfParent:parent];
        return;
    }
    [self cancelPendingTurnOfParent:parent];
    [self forgetHeldWindowsOfParent:key];
    [_flipSideInView removeObject:key];
    [_backShown removeObject:key];
    id token = _helpers[key] ?: _adoptedHelperPids[key];
    [_helpers removeObjectForKey:key];
    [_adoptedHelperPids removeObjectForKey:key];

    [self releaseAttachedWindow:side];
    [self.compositingManager releaseFlipSideWindow:side];
    // It hangs from nothing now, and the id it named may soon belong to an
    // unrelated window.
    xcb_delete_property([self.connection connection], side, XCB_ATOM_WM_TRANSIENT_FOR);
    // Framed like a window seen for the first time, which it is to the
    // framing code.
    XCBWindow *attached = [self.connection windowForXCBId:side];
    if (attached != nil) {
        [self.connection unregisterWindow:attached];
    }
    XCBWindow *client = [self.framer frameWindowAsOrdinary:side
                                              closeHandler:[self closeHandlerForWindow:side token:token]];
    if (client == nil) {
        NSLog(@"[FlipSide] The terminal of window %u cannot be framed as a window of its own; "
              @"it is ended", parent);
        xcb_unmap_window([self.connection connection], side);
        [self.connection flush];
        [self endHelper:token];
        return;
    }
    [_orphans addOrphanWindow:side application:_applications[key] directory:_directories[key]
                        token:token];
}

// Its borderless window takes no WM_DELETE_WINDOW, so its close button
// ends its terminal, taking the shell with it as typing exit would.
- (void (^)(void))closeHandlerForWindow:(xcb_window_t)window token:(id)token
{
    __weak URSFlipSideController *weakSelf = self;
    return ^{
        [weakSelf closeOrphanWindow:window token:token];
    };
}

- (void)closeOrphanWindow:(xcb_window_t)window token:(id)token
{
    // Going, so it must not go back onto a window meanwhile.
    [_orphans removeOrphanWithWindow:window];
    if (token == nil) {
        NSLog(@"[FlipSide] The terminal in window %u cannot be ended: its process is not known",
              window);
        return;
    }
    [self endHelper:token];
}

- (BOOL)isOrphanedFlipSide:(xcb_window_t)window
{
    return [self carriesRoleWithoutParent:window];
}

- (void (^)(void))closeHandlerForAdoptedOrphan:(xcb_window_t)window
{
    XCBWindow *probe = [[XCBWindow alloc] initWithXCBWindow:window andConnection:self.connection];
    return [self closeHandlerForWindow:window token:[probe updatePid] ? @([probe pid]) : nil];
}

// Only a window like the one the terminal was on: not a panel, a dialog,
// another window's helper or an orphan itself.
- (BOOL)isPlainApplicationWindow:(XCBWindow *)client
{
    EWMHService *ewmh = [EWMHService sharedInstanceWithConnection:self.connection];
    NSString *type = [client windowType];
    if ([client framedAsOrdinary] || [client isUtilityPanel] ||
        (type != nil && ![type isEqualToString:[ewmh EWMHWMWindowTypeNormal]])) {
        return NO;
    }
    xcb_connection_t *c = [self.connection connection];
    xcb_get_property_reply_t *transient =
        xcb_get_property_reply(c, xcb_get_property(c, 0, [client window], XCB_ATOM_WM_TRANSIENT_FOR,
                                                   XCB_ATOM_WINDOW, 0, 1), NULL);
    BOOL plain = transient == NULL || xcb_get_property_value_length(transient) == 0;
    free(transient);
    return plain;
}

- (void)clientWindowFramed:(XCBWindow *)client
{
    if ([_orphans count] == 0) {
        return;
    }
    xcb_window_t parent = [client window];
    if ([self.registry windowOfParent:parent] != XCB_NONE || ![self isPlainApplicationWindow:client]) {
        return;
    }
    NSString *application = [self applicationOfClient:client];
    if (![_orphans hasOrphansOfApplication:application]) {
        return;
    }
    NSString *directory = [self sourceDirectoryOfApplication:application];
    URSFlipSideOrphan *orphan = [_orphans oldestOrphanOfApplication:application directory:directory];
    if (orphan != nil) {
        [self returnOrphan:orphan toParent:parent application:application directory:directory];
    }
}

// The new window shows its front; the orphan goes behind it as its flip
// side, exactly as if it had been started for it.
- (void)returnOrphan:(URSFlipSideOrphan *)orphan
            toParent:(xcb_window_t)parent
         application:(NSString *)application
           directory:(NSString *)directory
{
    xcb_window_t side = [orphan window];
    XCBWindow *client = [self.connection windowForXCBId:side];
    XCBFrame *frame = (XCBFrame *)[client parentWindow];
    if (![frame isKindOfClass:[XCBFrame class]]) {
        NSLog(@"[FlipSide] Orphaned terminal window %u has no frame to be taken out of; "
              @"it stays a window of its own", side);
        return;
    }
    [_orphans removeOrphanWithWindow:side];
    NSNumber *key = @(parent);
    id token = [orphan token];
    if ([token isKindOfClass:[NSTask class]]) {
        _helpers[key] = token;
    } else if (token != nil) {
        _adoptedHelperPids[key] = token;
    }
    _applications[key] = application;
    _directories[key] = directory;
    [client setCloseHandler:nil];
    [client cancelCloseTimer];

    xcb_connection_t *c = [self.connection connection];
    // Taken out of its frame while mapped, the window is unmapped and mapped
    // again by the X server.  Seen, that unmap would end the attachment made
    // below before it was seen; neither the frame, which goes, nor the
    // window are told.
    uint32_t noEvents = 0;
    xcb_change_window_attributes(c, [frame window], XCB_CW_EVENT_MASK, &noEvents);
    uint32_t focusOnly = XCB_EVENT_MASK_FOCUS_CHANGE;
    xcb_change_window_attributes(c, side, XCB_CW_EVENT_MASK, &focusOnly);
    [self.connection unframeClientWindow:client root:[[[self.connection screens] firstObject] rootWindow]];
    xcb_change_property(c, XCB_PROP_MODE_REPLACE, side, XCB_ATOM_WM_TRANSIENT_FOR,
                        XCB_ATOM_WINDOW, 32, 1, &parent);
    if (![self attachMarkedWindow:side]) {
        NSLog(@"[FlipSide] Orphaned terminal window %u cannot go onto the back of window %u; "
              @"it is ended", side, parent);
        xcb_unmap_window(c, side);
        [self.connection flush];
        [self endFlipSideOfParent:parent];
    }
}

- (void)windowManagerWillExit
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:nil];
    for (NSTimer *timer in [_pendingTurns allValues]) {
        [timer invalidate];
    }
    [_pendingTurns removeAllObjects];
    [_helpers removeAllObjects];
    [_endingHelpers removeAllObjects];
    [_adoptedHelperPids removeAllObjects];
    _orphans = [URSFlipSideOrphans new];
}

@end

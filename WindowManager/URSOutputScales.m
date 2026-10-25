/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSOutputScales.h"
#import "URSOutputScale.h"
#import "XCBConnection.h"
#import "XCBScreen.h"
#import "XCBFrame.h"
#import "TitleBarSettingsService.h"
#import <GNUstepGUI/GSTheme.h>
#import <xcb/randr.h>

@implementation URSOutputScales
{
    NSArray *_outputIds;   // NSNumber xcb_randr_output_t
    NSArray *_rects;       // NSValue rect, X screen coordinates
    NSArray *_factors;     // NSNumber
    xcb_atom_t _scaleAtom;
}

+ (instancetype)sharedScales
{
    static URSOutputScales *shared = nil;
    if (shared == nil)
        shared = [[URSOutputScales alloc] init];
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _outputIds = @[];
        _rects = @[];
        _factors = @[];
    }
    return self;
}

- (xcb_atom_t)scaleAtom
{
    return _scaleAtom;
}

static long ReadDPI(xcb_connection_t *conn, xcb_randr_output_t output, xcb_atom_t atom)
{
    long dpi = 0;
    xcb_randr_get_output_property_reply_t *reply = xcb_randr_get_output_property_reply(
        conn, xcb_randr_get_output_property(conn, output, atom, XCB_ATOM_ANY, 0, 1, 0, 0), NULL);

    if (reply && reply->format == 32 && reply->num_items == 1)
        dpi = *(int32_t *)xcb_randr_get_output_property_data(reply);
    free(reply);
    return dpi;
}

- (void)reloadWithConnection:(XCBConnection *)connection
{
    xcb_connection_t *conn = [connection connection];
    XCBScreen *screen = [[connection screens] firstObject];
    NSMutableArray *ids = [NSMutableArray array];
    NSMutableArray *rects = [NSMutableArray array];
    NSMutableArray *factors = [NSMutableArray array];

    if (conn == NULL || screen == nil)
        return;

    /* Only an existing atom: the property is created by XLibre or by the
     * display configuration, and interning it here would be noise. */
    xcb_intern_atom_reply_t *atomReply = xcb_intern_atom_reply(
        conn, xcb_intern_atom(conn, 1, 3, "DPI"), NULL);
    _scaleAtom = atomReply ? atomReply->atom : XCB_NONE;
    free(atomReply);

    xcb_randr_get_screen_resources_current_reply_t *res =
        xcb_randr_get_screen_resources_current_reply(
            conn, xcb_randr_get_screen_resources_current(conn, [screen screen]->root), NULL);
    if (res == NULL)
        return;

    xcb_randr_output_t *outputs = xcb_randr_get_screen_resources_current_outputs(res);
    int n = xcb_randr_get_screen_resources_current_outputs_length(res);
    for (int i = 0; i < n; i++) {
        xcb_randr_get_output_info_reply_t *info = xcb_randr_get_output_info_reply(
            conn, xcb_randr_get_output_info(conn, outputs[i], res->config_timestamp), NULL);
        if (info == NULL)
            continue;
        /* Lit is what counts: a virtual output (dummy, VNC) reports itself
         * disconnected while it shows part of the screen. */
        if (info->crtc == XCB_NONE) {
            free(info);
            continue;
        }
        xcb_randr_get_crtc_info_reply_t *crtc = xcb_randr_get_crtc_info_reply(
            conn, xcb_randr_get_crtc_info(conn, info->crtc, res->config_timestamp), NULL);
        free(info);
        if (crtc == NULL)
            continue;
        if (crtc->width > 0 && crtc->height > 0) {
            /* An output without the property is 1.0x, as libs-back reports
             * it (72 dpi) to the applications, so both agree on "mixed". */
            CGFloat factor = _scaleAtom != XCB_NONE
                ? URSScaleFactorForDPI(ReadDPI(conn, outputs[i], _scaleAtom)) : 0;
            [ids addObject:[NSNumber numberWithUnsignedInt:outputs[i]]];
            [rects addObject:[NSValue valueWithRect:NSMakeRect(crtc->x, crtc->y,
                                                               crtc->width, crtc->height)]];
            [factors addObject:[NSNumber numberWithDouble:factor > 0 ? factor : 1.0]];
        }
        free(crtc);
    }
    free(res);

    _outputIds = ids;
    _rects = rects;
    _factors = factors;
    /* Logged only when it matters: with one factor nothing changes. */
    if ([self mixed])
        NSLog(@"[OutputScales] per-monitor factors %@ on outputs %@", _factors, _rects);
}

- (BOOL)mixed
{
    /* The window manager can only size a title bar per monitor when the
     * theme draws it at that monitor's factor too. */
    return URSOutputScalesAreMixed(_factors) &&
           [[GSTheme theme] respondsToSelector:@selector(setDecorationScaleFactor:)];
}

/* The factor of each output as a C array; the caller frees it. */
- (CGFloat *)factorArray
{
    NSUInteger count = [_factors count];
    CGFloat *factors = calloc(count > 0 ? count : 1, sizeof(CGFloat));

    for (NSUInteger i = 0; i < count; i++)
        factors[i] = [[_factors objectAtIndex:i] doubleValue];
    return factors;
}

- (CGFloat)factorForNewFrameRect:(NSRect)rect utility:(BOOL)utility
                          output:(uint32_t *)output
{
    *output = XCB_NONE;
    if (![self mixed])
        return 0;
    CGFloat *factors = [self factorArray];
    URSDecoration none = { 0, 0, 0 };
    NSUInteger i = URSOutputForFrame(rect, _rects, factors, NSNotFound, none, NSZeroSize);
    free(factors);
    if (i == NSNotFound)
        return 0;
    *output = [[_outputIds objectAtIndex:i] unsignedIntValue];
    return [[_factors objectAtIndex:i] doubleValue];
}

- (BOOL)updateFrame:(XCBFrame *)frame forRect:(NSRect)rect
{
    return [self updateFrame:frame forRect:rect force:NO];
}

- (BOOL)updateFrame:(XCBFrame *)frame forRect:(NSRect)rect force:(BOOL)force
{
    CGFloat old = [frame decorationScaleFactor];

    if (![self mixed]) {
        [frame setDecorationOutput:XCB_NONE];
        [frame setDecorationScaleFactor:0];
        [frame setDecorationContentFactor:0];
        [frame setDecorationPendingClientSize:NSZeroSize];
        return old != 0;
    }

    /* The client is laid out at the factor it last followed: after a switch
     * it is still at the old one until it resizes itself. */
    NSSize client = NSMakeSize(NSWidth(rect) - 2 * [frame clientBorder],
                               NSHeight(rect) - [frame decorationTitleHeight] - [frame clientBorder]);
    NSSize pending = [frame decorationPendingClientSize];
    if ([frame decorationContentFactor] <= 0 ||
        (!NSEqualSizes(pending, NSZeroSize) && !NSEqualSizes(pending, client))) {
        [frame setDecorationContentFactor:old];
        [frame setDecorationPendingClientSize:NSZeroSize];
    }

    /* Only a move can take a frame to another monitor.  A ConfigureNotify
     * for a size change alone (the window manager's own title bar change,
     * the client following it) is left alone, or a window resting where
     * the rule of libs-gui flips both ways would be re-framed for ever. */
    if (!force && NSEqualPoints(rect.origin, [frame decorationCheckedOrigin]) && old > 0)
        return NO;
    [frame setDecorationCheckedOrigin:rect.origin];

    NSUInteger current = [_outputIds indexOfObject:
                          [NSNumber numberWithUnsignedInt:[frame decorationOutput]]];
    URSDecoration now = { old, [frame decorationTitleHeight], [frame clientBorder] };
    CGFloat contentFactor = [frame decorationContentFactor];
    NSSize points = contentFactor > 0
        ? NSMakeSize(client.width / contentFactor, client.height / contentFactor) : client;
    CGFloat *factors = [self factorArray];
    NSUInteger i = URSOutputForFrame(rect, _rects, factors, current, now, points);
    free(factors);
    /* A frame on no monitor keeps the factor it has. */
    if (i == NSNotFound)
        return NO;

    CGFloat factor = [[_factors objectAtIndex:i] doubleValue];
    [frame setDecorationOutput:[[_outputIds objectAtIndex:i] unsignedIntValue]];
    if (factor == old)
        return NO;
    [frame setDecorationScaleFactor:factor];
    if (old > 0)
        [frame setDecorationPendingClientSize:client];
    else
        [frame setDecorationContentFactor:factor];
    return YES;
}

@end

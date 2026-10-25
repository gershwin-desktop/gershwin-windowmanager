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

- (NSArray *)titleHeightsForUtility:(BOOL)utility
{
    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    NSMutableArray *heights = [NSMutableArray arrayWithCapacity:[_factors count]];

    for (NSNumber *factor in _factors)
        [heights addObject:[NSNumber numberWithUnsignedShort:
                            [settings heightForUtility:utility scaleFactor:[factor doubleValue]]]];
    return heights;
}

- (CGFloat)factorForNewFrameRect:(NSRect)rect utility:(BOOL)utility
                          output:(uint32_t *)output
{
    *output = XCB_NONE;
    if (![self mixed])
        return 0;
    NSUInteger i = URSOutputForFrame(rect, _rects, [self titleHeightsForUtility:utility],
                                     NSNotFound, 0);
    if (i == NSNotFound)
        return 0;
    *output = [[_outputIds objectAtIndex:i] unsignedIntValue];
    return [[_factors objectAtIndex:i] doubleValue];
}

- (BOOL)updateFrame:(XCBFrame *)frame forRect:(NSRect)rect
{
    CGFloat old = [frame decorationScaleFactor];

    if (![self mixed]) {
        [frame setDecorationOutput:XCB_NONE];
        [frame setDecorationScaleFactor:0];
        return old != 0;
    }

    BOOL utility = [[frame childWindowForKey:ClientWindow] isUtilityPanel];
    NSUInteger current = [_outputIds indexOfObject:
                          [NSNumber numberWithUnsignedInt:[frame decorationOutput]]];
    NSUInteger i = URSOutputForFrame(rect, _rects, [self titleHeightsForUtility:utility],
                                     current, [frame decorationTitleHeight]);
    /* A frame on no monitor keeps the factor it has. */
    if (i == NSNotFound)
        return NO;

    CGFloat factor = [[_factors objectAtIndex:i] doubleValue];
    [frame setDecorationOutput:[[_outputIds objectAtIndex:i] unsignedIntValue]];
    [frame setDecorationScaleFactor:factor];
    return factor != old;
}

@end

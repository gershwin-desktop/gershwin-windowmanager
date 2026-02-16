//
// XCBCursor.m
// XCBKit
//
// Created by slex on 15/12/20.

#import "XCBCursor.h"
#import "XCBConnection.h"
#import <xcb/xcb.h>

// X11 cursor font glyph indices (from X11/cursorfont.h)
#define XC_left_ptr              68
#define XC_bottom_side           16
#define XC_right_side            96
#define XC_left_side             70
#define XC_top_side              138
#define XC_bottom_right_corner   14
#define XC_top_left_corner       134
#define XC_top_right_corner      136
#define XC_bottom_left_corner    12

@implementation XCBCursor

@synthesize connection;
@synthesize context;
@synthesize screen;
@synthesize cursorPath;
@synthesize cursor;
@synthesize leftPointerName;
@synthesize resizeBottomCursorName;
@synthesize resizeRightCursorName;
@synthesize cursors;
@synthesize leftPointerSelected;
@synthesize resizeBottomSelected;
@synthesize resizeRightSelected;
@synthesize resizeLeftCursorName;
@synthesize resizeLeftSelected;
@synthesize resizeBottomRightCornerCursorName;
@synthesize resizeBottomRightCornerSelected;
@synthesize resizeTopLeftCornerCursorName;
@synthesize resizeTopLeftCornerSelected;
@synthesize resizeTopRightCornerCursorName;
@synthesize resizeTopRightCornerSelected;
@synthesize resizeBottomLeftCornerCursorName;
@synthesize resizeBottomLeftCornerSelected;
@synthesize resizeTopCursorName;
@synthesize resizeTopSelected;

- (instancetype)initWithConnection:(XCBConnection *)aConnection screen:(XCBScreen*)aScreen
{
    self = [super init];

    if (self == nil)
    {
        NSLog(@"Unable to init...");
        return nil;
    }

    connection = aConnection;
    screen = aScreen;

    BOOL success = [self createContext];

    if (!success)
    {
        NSLog(@"Error creating a new cursor context: %d", success);
        return self;
    }

    cursors = [[NSMutableDictionary alloc] init];

    // Use standard X11 cursor font names (same as XCreateFontCursor)
    leftPointerName = @"left_ptr";
    resizeBottomCursorName = @"bottom_side";
    resizeRightCursorName = @"right_side";
    resizeLeftCursorName = @"left_side";
    resizeBottomRightCornerCursorName = @"bottom_right_corner";
    resizeTopLeftCornerCursorName = @"top_left_corner";
    resizeTopRightCornerCursorName = @"top_right_corner";
    resizeBottomLeftCornerCursorName = @"bottom_left_corner";
    resizeTopCursorName = @"top_side";


    // Open the legacy X cursor font for fallback
    xcb_font_t cursorFont = xcb_generate_id([connection connection]);
    xcb_void_cookie_t fontCookie = xcb_open_font_checked([connection connection], cursorFont, 6, "cursor");
    xcb_generic_error_t *fontError = xcb_request_check([connection connection], fontCookie);
    if (fontError)
    {
        NSLog(@"Warning: Failed to open X cursor font (error code %d), glyph fallback unavailable", fontError->error_code);
        free(fontError);
        cursorFont = 0;
    }

    // Load each cursor from theme, falling back to X cursor font glyph
    [self loadCursor:leftPointerName glyphIndex:XC_left_ptr font:cursorFont];
    [self loadCursor:resizeBottomCursorName glyphIndex:XC_bottom_side font:cursorFont];
    [self loadCursor:resizeRightCursorName glyphIndex:XC_right_side font:cursorFont];
    [self loadCursor:resizeLeftCursorName glyphIndex:XC_left_side font:cursorFont];
    [self loadCursor:resizeBottomRightCornerCursorName glyphIndex:XC_bottom_right_corner font:cursorFont];
    [self loadCursor:resizeTopLeftCornerCursorName glyphIndex:XC_top_left_corner font:cursorFont];
    [self loadCursor:resizeTopRightCornerCursorName glyphIndex:XC_top_right_corner font:cursorFont];
    [self loadCursor:resizeBottomLeftCornerCursorName glyphIndex:XC_bottom_left_corner font:cursorFont];
    [self loadCursor:resizeTopCursorName glyphIndex:XC_top_side font:cursorFont];

    if (cursorFont != 0)
        xcb_close_font([connection connection], cursorFont);

    return self;
}

- (xcb_cursor_t) selectLeftPointerCursor
{
    cursor = [[cursors objectForKey:leftPointerName] unsignedIntValue];
    leftPointerSelected = YES;
    resizeBottomSelected = NO;
    resizeRightSelected = NO;
    resizeLeftSelected = NO;
    resizeTopSelected = NO;
    resizeBottomRightCornerSelected = NO;
    resizeTopLeftCornerSelected = NO;
    resizeTopRightCornerSelected = NO;
    resizeBottomLeftCornerSelected = NO;
    return cursor;
}

- (xcb_cursor_t) selectResizeCursorForPosition:(MousePosition)position
{
    switch (position)
    {
        case BottomBorder:
            cursor = [[cursors objectForKey:resizeBottomCursorName] unsignedIntValue];
            leftPointerSelected = NO;
            resizeBottomSelected = YES;
            resizeRightSelected = NO;
            resizeLeftSelected = NO;
            resizeBottomRightCornerSelected = NO;
            resizeTopLeftCornerSelected = NO;
            resizeTopRightCornerSelected = NO;
            resizeBottomLeftCornerSelected = NO;
            resizeTopSelected = NO;
            break;
        case RightBorder:
            cursor = [[cursors objectForKey:resizeRightCursorName] unsignedIntValue];
            leftPointerSelected = NO;
            resizeBottomSelected = NO;
            resizeRightSelected = YES;
            resizeLeftSelected = NO;
            resizeBottomRightCornerSelected = NO;
            resizeTopLeftCornerSelected = NO;
            resizeTopRightCornerSelected = NO;
            resizeBottomLeftCornerSelected = NO;
            resizeTopSelected = NO;
            break;
        case LeftBorder:
            cursor = [[cursors objectForKey:resizeLeftCursorName] unsignedIntValue];
            leftPointerSelected = NO;
            resizeBottomSelected = NO;
            resizeRightSelected = NO;
            resizeLeftSelected = YES;
            resizeBottomRightCornerSelected = NO;
            resizeTopLeftCornerSelected = NO;
            resizeTopRightCornerSelected = NO;
            resizeBottomLeftCornerSelected = NO;
            resizeTopSelected = NO;
            break;
        case BottomRightCorner:
            cursor = [[cursors objectForKey:resizeBottomRightCornerCursorName] unsignedIntValue];
            leftPointerSelected = NO;
            resizeBottomSelected = NO;
            resizeRightSelected = NO;
            resizeLeftSelected = NO;
            resizeBottomRightCornerSelected = YES;
            resizeTopLeftCornerSelected = NO;
            resizeTopRightCornerSelected = NO;
            resizeBottomLeftCornerSelected = NO;
            resizeTopSelected = NO;
            break;
        case TopBorder:
            cursor = [[cursors objectForKey:resizeTopCursorName] unsignedIntValue];
            leftPointerSelected = NO;
            resizeBottomSelected = NO;
            resizeRightSelected = NO;
            resizeLeftSelected = NO;
            resizeBottomRightCornerSelected = NO;
            resizeTopLeftCornerSelected = NO;
            resizeTopRightCornerSelected = NO;
            resizeBottomLeftCornerSelected = NO;
            resizeTopSelected = YES;
            break;
        case TopLeftCorner:
            cursor = [[cursors objectForKey:resizeTopLeftCornerCursorName] unsignedIntValue];
            leftPointerSelected = NO;
            resizeBottomSelected = NO;
            resizeRightSelected = NO;
            resizeLeftSelected = NO;
            resizeBottomRightCornerSelected = NO;
            resizeTopLeftCornerSelected = YES;
            resizeTopRightCornerSelected = NO;
            resizeBottomLeftCornerSelected = NO;
            resizeTopSelected = NO;
            break;
        case TopRightCorner:
            cursor = [[cursors objectForKey:resizeTopRightCornerCursorName] unsignedIntValue];
            leftPointerSelected = NO;
            resizeBottomSelected = NO;
            resizeRightSelected = NO;
            resizeLeftSelected = NO;
            resizeBottomRightCornerSelected = NO;
            resizeTopLeftCornerSelected = NO;
            resizeTopRightCornerSelected = YES;
            resizeBottomLeftCornerSelected = NO;
            resizeTopSelected = NO;
            break;
        case BottomLeftCorner:
            cursor = [[cursors objectForKey:resizeBottomLeftCornerCursorName] unsignedIntValue];
            leftPointerSelected = NO;
            resizeBottomSelected = NO;
            resizeRightSelected = NO;
            resizeLeftSelected = NO;
            resizeBottomRightCornerSelected = NO;
            resizeTopLeftCornerSelected = NO;
            resizeTopRightCornerSelected = NO;
            resizeBottomLeftCornerSelected = YES;
            resizeTopSelected = NO;
            break;

        default:
            break;
    }

    return cursor;
}

- (void) loadCursor:(NSString *)name glyphIndex:(uint16_t)glyph font:(xcb_font_t)cursorFont
{
    cursor = xcb_cursor_load_cursor(context, [name UTF8String]);

    if (cursor == 0)
    {
        NSLog(@"Cursor '%@': theme lookup returned 0, using X cursor font fallback (glyph %u)", name, glyph);
        if (cursorFont != 0)
        {
            cursor = xcb_generate_id([connection connection]);
            xcb_create_glyph_cursor([connection connection],
                                    cursor,
                                    cursorFont,         // source font
                                    cursorFont,         // mask font
                                    glyph,              // source glyph
                                    glyph + 1,          // mask glyph (convention: source + 1)
                                    0, 0, 0,            // foreground RGB (black)
                                    0xFFFF, 0xFFFF, 0xFFFF);  // background RGB (white)
        }
        else
        {
            NSLog(@"Warning: No cursor font available, cursor '%@' will be unavailable", name);
        }
    }
    else
    {
        NSLog(@"Cursor '%@': loaded from theme (id %u)", name, cursor);
    }

    [cursors setObject:[NSNumber numberWithUnsignedInt:cursor] forKey:name];
}

- (xcb_cursor_t) cursorIdForPosition:(MousePosition)position
{
    NSString *name = nil;
    switch (position)
    {
        case BottomBorder:      name = resizeBottomCursorName; break;
        case RightBorder:       name = resizeRightCursorName; break;
        case LeftBorder:        name = resizeLeftCursorName; break;
        case TopBorder:         name = resizeTopCursorName; break;
        case BottomRightCorner: name = resizeBottomRightCornerCursorName; break;
        case TopLeftCorner:     name = resizeTopLeftCornerCursorName; break;
        case TopRightCorner:    name = resizeTopRightCornerCursorName; break;
        case BottomLeftCorner:  name = resizeBottomLeftCornerCursorName; break;
        default:                name = leftPointerName; break;
    }
    return [[cursors objectForKey:name] unsignedIntValue];
}

- (BOOL) createContext
{
    int success = xcb_cursor_context_new([connection connection], [screen screen], &context);

    if (success < 0)
        return NO;

    return YES;
}

- (void) destroyContext
{
    xcb_cursor_context_free(context);
}

- (void) destroyCursor
{
    xcb_free_cursor([connection connection], cursor);
}

- (void) dealloc
{
    connection = nil;
    screen = nil;
    cursorPath = nil;
    cursors = nil;

    resizeTopCursorName = nil;
    resizeBottomRightCornerCursorName = nil;
    resizeTopLeftCornerCursorName = nil;
    resizeTopRightCornerCursorName = nil;
    resizeBottomLeftCornerCursorName = nil;
    resizeLeftCursorName = nil;
    resizeRightCursorName = nil;
    resizeBottomCursorName = nil;
    leftPointerName = nil;

    if (context != NULL)
        [self destroyContext];


}

@end
//
// XCBShape.m
// XCBKit
//
// Created by slex on 26/03/21.

#import "XCBShape.h"
#import "XCBConnection.h"

@implementation XCBShape

@synthesize connection;
@synthesize shapeExtensionReply;
@synthesize winId;
@synthesize borderPixmap;
@synthesize windowPixmap;
@synthesize black;
@synthesize white;
@synthesize borderWidth;
@synthesize height;
@synthesize width;
@synthesize orHeight;
@synthesize orWidth;
@synthesize radius;

- (id) initWithConnection:(XCBConnection*)aConnection withWinId:(xcb_window_t)aWinId
{
    self = [super init];

    if (!self)
    {
        NSLog(@"Unable to initialize...");
        return nil;
    }

    connection = aConnection;
    winId = aWinId;

    return self;
}

- (BOOL) checkSupported
{
    const xcb_query_extension_reply_t *shape_query;
    xcb_shape_query_extents_cookie_t extents_cookie;
    xcb_connection_t *conn = [connection connection];

    shape_query = xcb_get_extension_data(conn, &xcb_shape_id);

    if (!shape_query)
        return NO;

    extents_cookie = xcb_shape_query_extents(conn, winId);
    shapeExtensionReply = xcb_shape_query_extents_reply(conn, extents_cookie, NULL);

    return YES;
}

- (void) calculateDimensionsFromGeometries:(XCBGeometryReply*)aGeometryReply
{
    borderWidth = [aGeometryReply geometryReply]->border_width;
    width = [aGeometryReply geometryReply]->width;
    height = [aGeometryReply geometryReply]->height;
    orWidth = width + 2 * borderWidth;
    orHeight = height + 2 * borderWidth;
}

- (void) createPixmapsAndGCs
{
    xcb_connection_t *conn = [connection connection];
    borderPixmap = xcb_generate_id(conn);
    windowPixmap = xcb_generate_id(conn);

    xcb_create_pixmap(conn, 1, borderPixmap, winId, orWidth, orHeight);
    xcb_create_pixmap(conn, 1, winId, winId, width, height);

    black = xcb_generate_id(conn);
    white = xcb_generate_id(conn);

    xcb_create_gc(conn, black, borderPixmap, XCB_GC_FOREGROUND, (uint32_t[]){0, 0});
    xcb_create_gc(conn, white, borderPixmap, XCB_GC_FOREGROUND, (uint32_t[]){1, 0});
}

- (void) createArcsWithRadius:(int)aRadius
{
    xcb_connection_t *conn = [connection connection];
    radius = aRadius;
    int diameter = radius*2;

    radius += borderWidth;
    diameter -= 1;

    xcb_arc_t bArcs[] = {
            { -1,     -1,     diameter, diameter, 0, 360 << 6 },
            { -1,     orHeight-diameter, diameter, diameter, 0, 360 << 6 },
            { orWidth-diameter, -1,     diameter, diameter, 0, 360 << 6 },
            { orWidth-diameter, orHeight-diameter, diameter, diameter, 0, 360 << 6 },
    };

    xcb_rectangle_t brects[] = {
            { radius, 0, orWidth-diameter, orHeight },
            { 0, radius, orWidth, orHeight-diameter },
    };

    radius -= borderWidth;
    diameter = radius*2-1;

    xcb_arc_t cArcs[] = {
            { -1,    -1,    diameter, diameter, 0, 360 << 6 },
            { -1,    height-diameter, diameter, diameter, 0, 360 << 6 },
            { width-diameter, -1,    diameter, diameter, 0, 360 << 6 },
            { width-diameter, height-diameter, diameter, diameter, 0, 360 << 6 },
    };
    xcb_rectangle_t crects[] = {
            { radius, 0, width-diameter, height },
            { 0, radius, width, height-diameter },
    };

    borderArcs = bArcs;
    windowArcs = cArcs;

    xcb_rectangle_t bounding = {0, 0, orWidth, orHeight};
    xcb_poly_fill_rectangle(conn, borderPixmap, black, 1, &bounding);
    xcb_poly_fill_rectangle(conn, borderPixmap, white, 2, brects);
    xcb_poly_fill_arc(conn, borderPixmap, white, 4, borderArcs);

    xcb_rectangle_t clipping = {0, 0, width, height};
    xcb_poly_fill_rectangle(conn, windowPixmap, black, 1, &clipping);
    xcb_poly_fill_rectangle(conn, windowPixmap, white, 2, crects);
    xcb_poly_fill_arc(conn, windowPixmap, white, 4, windowArcs);

    xcb_shape_mask(conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_BOUNDING,  winId, -borderWidth, -borderWidth, borderPixmap);
    xcb_shape_mask(conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_CLIP, winId, 0, 0, windowPixmap);

}

- (void) createTopArcsWithRadius:(int)aRadius
{
    xcb_connection_t *conn = [connection connection];
    radius = aRadius;
    int diameter = radius * 2;

    // Only top corners get arcs, bottom stays rectangular
    xcb_arc_t bArcs[] = {
        { 0, 0, diameter, diameter, 0, 360 << 6 },                    // top-left
        { orWidth - diameter - 1, 0, diameter, diameter, 0, 360 << 6 }, // top-right
    };

    xcb_rectangle_t brects[] = {
        { radius, 0, orWidth - diameter, orHeight },  // center vertical strip
        { 0, radius, orWidth, orHeight - radius },    // below top corners
    };

    // Clear to black (transparent), then fill valid regions white (opaque)
    xcb_rectangle_t bounding = {0, 0, orWidth, orHeight};
    xcb_poly_fill_rectangle(conn, borderPixmap, black, 1, &bounding);
    xcb_poly_fill_rectangle(conn, borderPixmap, white, 2, brects);
    xcb_poly_fill_arc(conn, borderPixmap, white, 2, bArcs);

    // Apply shape mask
    xcb_shape_mask(conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_BOUNDING, winId, -borderWidth, -borderWidth, borderPixmap);
}

- (void) createRoundedCornersWithTopRadius:(int)topRadius bottomRadius:(int)bottomRadius
{
    xcb_connection_t *conn = [connection connection];

    NSLog(@"XCBShape: Creating rounded corners with topRadius=%d, bottomRadius=%d", topRadius, bottomRadius);
    NSLog(@"XCBShape: Window dimensions: width=%d, height=%d, orWidth=%d, orHeight=%d, borderWidth=%d",
          width, height, orWidth, orHeight, borderWidth);

    // Clear pixmap to black (transparent)
    xcb_rectangle_t bounding = {0, 0, orWidth, orHeight};
    xcb_poly_fill_rectangle(conn, borderPixmap, black, 1, &bounding);

    // Build rectangles for the straight edges
    // Note: diameter is (radius * 2) to match createTopArcsWithRadius
    int topDiameter = (topRadius > 0) ? (topRadius * 2) : 0;
    int bottomDiameter = (bottomRadius > 0) ? (bottomRadius * 2) : 0;

    NSLog(@"XCBShape: Calculated diameters: topDiameter=%d, bottomDiameter=%d", topDiameter, bottomDiameter);

    // Center strip (between left and right corners)
    int leftEdge = (topRadius > bottomRadius) ? topRadius : bottomRadius;
    int rightEdge = (topRadius > bottomRadius) ? topRadius : bottomRadius;
    xcb_rectangle_t centerStrip = { leftEdge, 0, orWidth - leftEdge - rightEdge, orHeight };
    xcb_poly_fill_rectangle(conn, borderPixmap, white, 1, &centerStrip);

    // Left strip (between top-left and bottom-left corners)
    if (topRadius > 0 || bottomRadius > 0) {
        int leftStripTop = topRadius;
        int leftStripBottom = bottomRadius;
        int leftStripHeight = orHeight - leftStripTop - leftStripBottom;
        if (leftStripHeight > 0) {
            xcb_rectangle_t leftStrip = { 0, leftStripTop, leftEdge, leftStripHeight };
            xcb_poly_fill_rectangle(conn, borderPixmap, white, 1, &leftStrip);
        }
    }

    // Right strip (between top-right and bottom-right corners)
    if (topRadius > 0 || bottomRadius > 0) {
        int rightStripTop = topRadius;
        int rightStripBottom = bottomRadius;
        int rightStripHeight = orHeight - rightStripTop - rightStripBottom;
        if (rightStripHeight > 0) {
            xcb_rectangle_t rightStrip = { orWidth - rightEdge, rightStripTop, rightEdge, rightStripHeight };
            xcb_poly_fill_rectangle(conn, borderPixmap, white, 1, &rightStrip);
        }
    }

    // Draw corner arcs
    if (topRadius > 0) {
        xcb_arc_t topArcs[] = {
            { 0, 0, topDiameter, topDiameter, 0, 360 << 6 },                        // top-left
            { orWidth - topDiameter - 1, 0, topDiameter, topDiameter, 0, 360 << 6 }, // top-right
        };
        xcb_poly_fill_arc(conn, borderPixmap, white, 2, topArcs);
    }

    if (bottomRadius > 0) {
        xcb_arc_t bottomArcs[] = {
            { -1, orHeight - bottomDiameter, bottomDiameter, bottomDiameter, 0, 360 << 6 },                    // bottom-left
            { orWidth - bottomDiameter, orHeight - bottomDiameter, bottomDiameter, bottomDiameter, 0, 360 << 6 }, // bottom-right
        };
        xcb_poly_fill_arc(conn, borderPixmap, white, 2, bottomArcs);
    }

    // Apply shape mask
    xcb_shape_mask(conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_BOUNDING, winId, -borderWidth, -borderWidth, borderPixmap);
}

- (void) dealloc
{
    if (shapeExtensionReply)
        free(shapeExtensionReply);

    if (borderPixmap != 0)
        xcb_free_pixmap([connection connection], borderPixmap);

    if (windowPixmap != 0)
        xcb_free_pixmap([connection connection], windowPixmap);

    connection = nil;
    borderArcs = NULL;
    windowArcs = NULL;
}

@end
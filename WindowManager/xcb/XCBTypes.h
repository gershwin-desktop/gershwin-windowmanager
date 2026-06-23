//
//  XCBShape.h
//  XCBKit
//
//  Created by Alessandro Sangiuliano on 15/06/20.
//  Copyright (c) 2020 alex. All rights reserved.
//

#import <Foundation/Foundation.h>
#include <xcb/xcb.h>

typedef struct _XCBPoint
{
    double x;
    double y;
    
} XCBPoint;

typedef struct _XCBSize
{
    uint16_t width;
    uint16_t height;
    
} XCBSize;

typedef struct _XCBRect
{
    XCBPoint position;
    XCBSize size;
} XCBRect;

typedef struct _XCBColor
{
    double redComponent;
    double greenComponent;
    double blueComponent;
    double alphaComponent;
} XCBColor;

static const XCBRect XCBInvalidRect = {{0xffff, 0xffff}, {0xffff, 0xffff}};

// MARK: - GSWorkspace Window Birth Protocol
// Used by the GNUstep Workspace to communicate window birth animation
// parameters to the Window Manager via X11 properties.
// See PRD.md section 8 for the protocol specification.

#define GSWORKSPACE_WINDOW_BIRTH_ATOM "_GSWORKSPACE_WINDOW_BIRTH"
#define GSWORKSPACE_WINDOW_BIRTH_NUM_INTS 9
#define GSWORKSPACE_WINDOW_BIRTH_BYTE_LEN (GSWORKSPACE_WINDOW_BIRTH_NUM_INTS * 4)

// Animation type values for the birth protocol
typedef NS_ENUM(int32_t, GSWindowBirthAnimationType) {
    GSWindowBirthAnimationOpen       = 0,  // Standard folder-open birth animation
    GSWindowBirthAnimationNoAnimation = 1,  // Suppress animation (Reduce Motion)
};

// Layout of the 9 int32 values written to the _GSWORKSPACE_WINDOW_BIRTH property:
//   [0] = sourceX      [1] = sourceY      [2] = sourceWidth    [3] = sourceHeight
//   [4] = targetX      [5] = targetY      [6] = targetWidth    [7] = targetHeight
//   [8] = animationType
//
// All coordinates are in root-window (X11 absolute) coordinates
// with origin at top-left.
#define GSWORKSPACE_BIRTH_IDX_SRC_X 0
#define GSWORKSPACE_BIRTH_IDX_SRC_Y 1
#define GSWORKSPACE_BIRTH_IDX_SRC_W 2
#define GSWORKSPACE_BIRTH_IDX_SRC_H 3
#define GSWORKSPACE_BIRTH_IDX_DST_X 4
#define GSWORKSPACE_BIRTH_IDX_DST_Y 5
#define GSWORKSPACE_BIRTH_IDX_DST_W 6
#define GSWORKSPACE_BIRTH_IDX_DST_H 7
#define GSWORKSPACE_BIRTH_IDX_ANIM_TYPE 8

/*** Utility functions ***/

static inline XCBColor XCBMakeColor(double redComponent, double greenComponent, double blueComponent, double alphaComponent)
{
    XCBColor color = {redComponent, greenComponent, blueComponent, alphaComponent};
    return color;
}

static inline XCBPoint XCBMakePoint(double x, double y)
{
    XCBPoint point = {x, y};
    return point;
}

static inline XCBSize XCBMakeSize(uint16_t width, uint16_t height)
{
    XCBSize size = {width, height};
    return size;
}

static inline XCBRect XCBMakeRect(XCBPoint point, XCBSize size)
{
    XCBRect rect = {point, size};
    return rect;
}

static inline xcb_rectangle_t FnFromXCBRectToXcbRectangle(XCBRect rect)
{
    xcb_rectangle_t r = {rect.position.x, rect.position.y, rect.size.width, rect.size.height};
    return r;
}

static inline XCBRect FnFromXcbRectangleToXCBRect(xcb_rectangle_t rect)
{
    XCBRect r = {{rect.x, rect.y,}, {rect.width, rect.height}};
    return r;
}

static inline BOOL FnCheckXCBRectIsValid(XCBRect rect)
{
    BOOL valid = YES;
    
    if (rect.position.x == XCBInvalidRect.position.x &&
        rect.position.y == XCBInvalidRect.position.y &&
        rect.size.width == XCBInvalidRect.size.width &&
        rect.size.height == XCBInvalidRect.size.height)
        
        valid = NO;

    return valid;
}

static inline NSString* FnFromXCBRectToString(XCBRect rect)
{
    return [NSString stringWithFormat:@"Position: (x: %f, y: %f), Size: (width: %hd, height: %hd)",
            rect.position.x, rect.position.y, rect.size.width, rect.size.height];
}


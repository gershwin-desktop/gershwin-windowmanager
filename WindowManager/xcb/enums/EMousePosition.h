//
// EMousePosition.h
// XCBKit
//
// Created by slex on 01/01/21.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, MousePosition)
{
    None = 0,
    RightBorder,
    LeftBorder,
    TopBorder,
    BottomBorder,
    BottomRightCorner,
    TopLeftCorner,
    TopRightCorner,
    BottomLeftCorner,
    Error
};
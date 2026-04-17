//
// EResizeDirection.h
// XCBKit
//
// Resize direction enumeration for theme-driven resize zones.
// These values are used by themes implementing the resize zone protocol
// and by the window manager to create invisible capture windows.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, EResizeDirection) {
    EResizeDirectionNone = 0,
    EResizeDirectionNorth,        // Top edge
    EResizeDirectionSouth,        // Bottom edge
    EResizeDirectionEast,         // Right edge
    EResizeDirectionWest,         // Left edge
    EResizeDirectionNorthWest,    // Top-left corner
    EResizeDirectionNorthEast,    // Top-right corner
    EResizeDirectionSouthEast,    // Bottom-right corner
    EResizeDirectionSouthWest     // Bottom-left corner
};

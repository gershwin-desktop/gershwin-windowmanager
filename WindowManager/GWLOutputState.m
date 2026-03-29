/*
 * GWLOutputState.m
 * Gershwin Window Manager - Wayland Mode
 */

#import "GWLOutputState.h"

@implementation GWLOutputState

- (instancetype)init
{
    self = [super init];
    if (self) {
        _workarea = NSZeroRect;
    }
    return self;
}

- (NSRect)fullRect
{
    return NSMakeRect(_x, _y, _width, _height);
}

@end

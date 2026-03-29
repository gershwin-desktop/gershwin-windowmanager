/*
 * GWLWindowState.m
 * Gershwin Window Manager - Wayland Mode
 */

#import "GWLWindowState.h"

@implementation GWLWindowState

- (instancetype)init
{
    self = [super init];
    if (self) {
        _children = [[NSMutableArray alloc] init];
        _decorationHint = GWLDecorationHintNoPreference;
        _savedGeometry = NSZeroRect;
        _snapDirection = GWLSnapNone;
    }
    return self;
}

- (BOOL)isFixedSize
{
    return (_minWidth > 0 && _maxWidth > 0 && _minWidth == _maxWidth &&
            _minHeight > 0 && _maxHeight > 0 && _minHeight == _maxHeight);
}

- (BOOL)isDialog
{
    return _parent != nil;
}

@end

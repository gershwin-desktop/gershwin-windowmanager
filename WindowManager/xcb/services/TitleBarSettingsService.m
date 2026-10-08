//
// TitleBarSettingsService.m
// XCBKit
//
// Created by slex on 05/02/21.

#import "TitleBarSettingsService.h"

#define HEIGHT 22

// Utility panel titlebars are a fixed height, not proportional to the
// normal titlebar (which varies by theme/metrics) - scaled by
// GSScaleFactor like every other metric here so it stays consistent at
// HiDPI.
#define UTILITY_HEIGHT 16

@implementation TitleBarSettingsService

@synthesize heightDefined;
@synthesize closePosition;
@synthesize minimizePosition;
@synthesize maximizePosition;

- (id) init
{
    self = [super init];

    if (self == nil)
    {
        NSLog(@"Unabl to init...");
        return nil;
    }

    defaultHeight = HEIGHT;
    height = -1;

    return self;
}

+ (id) sharedInstance
{
    static TitleBarSettingsService *sharedInstance = nil;

    if (sharedInstance == nil)
        sharedInstance = [[self alloc] init];

    return sharedInstance;
}

- (void) setHeight:(uint16_t)aHeight
{
    height = aHeight;
    heightDefined = YES;
}

- (uint16_t)height
{
    return height;
}

- (CGFloat)scaleFactor
{
    return _scaleFactor > 0 ? _scaleFactor : 1.0;
}

- (void)setScaleFactor:(CGFloat)factor
{
    _scaleFactor = factor > 0 ? factor : 1.0;
}

- (uint16_t) defaultHeight
{
    return defaultHeight;
}

- (uint16_t) heightForUtility:(BOOL)isUtility
{
    if (!isUtility)
        return heightDefined ? height : defaultHeight;

    uint16_t fixed = (uint16_t)(UTILITY_HEIGHT * self.scaleFactor);
    return fixed < 1 ? 1 : fixed;
}

@end
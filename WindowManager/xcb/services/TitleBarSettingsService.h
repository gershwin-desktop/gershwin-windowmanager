//
// TitleBarSettingsService.h
// XCBKit
//
// Created by slex on 05/02/21.
//

#import <Foundation/Foundation.h>
#import "XCBTypes.h"

@interface TitleBarSettingsService : NSObject
{
    uint16_t height;
    uint16_t defaultHeight;
    CGFloat _scaleFactor;
}

@property (nonatomic, assign) BOOL heightDefined;
@property (nonatomic, assign) CGFloat scaleFactor;
@property (nonatomic, assign) XCBPoint closePosition;
@property (nonatomic, assign) XCBPoint minimizePosition;
@property (nonatomic, assign) XCBPoint maximizePosition;

- (id) init;
+ (id) sharedInstance;

/*** ACCESSORS ***/

- (void)setHeight:(uint16_t)aHeight;
- (uint16_t)height;
- (uint16_t) defaultHeight;

// Effective titlebar height for a client window: the normal (possibly
// theme-configured) height, or a fixed 16px (scaled by GSScaleFactor,
// never below 1px) for a utility panel - see XCBWindow's isUtilityPanel.
- (uint16_t) heightForUtility:(BOOL)isUtility;

@end
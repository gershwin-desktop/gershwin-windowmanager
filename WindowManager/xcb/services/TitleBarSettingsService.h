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
    // Normal title bar height per scale factor other than the global one
    // (NSNumber factor -> NSNumber height), asked of the theme once.
    NSMutableDictionary *heightsByFactor;
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

// The same for a window decorated at `factor`, the factor of the monitor it
// is on when the monitors' factors are mixed.  A factor of 0 is the global
// one and answers exactly what -heightForUtility: answers.
- (uint16_t) heightForUtility:(BOOL)isUtility scaleFactor:(CGFloat)factor;

@end
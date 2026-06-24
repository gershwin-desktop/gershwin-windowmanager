#import "UROSWMApplication.h"

@implementation UROSWMApplication

+ (UROSWMApplication *)sharedApplication
{
    static UROSWMApplication *sharedInstance = nil;

    if (sharedInstance == nil) {
        if (NSApp == nil) {
            sharedInstance = [[UROSWMApplication alloc] init];
            // Set ourselves as the global NSApp
            NSApp = sharedInstance;
        } else {
            // NSApp already exists, cast it to our type
            sharedInstance = (UROSWMApplication *)NSApp;
        }
    }

    return sharedInstance;
}

- (void)finishLaunching
{
    [super finishLaunching];
}

@end

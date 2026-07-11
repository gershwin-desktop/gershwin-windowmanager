#import <AppKit/AppKit.h>

@interface StubbornWindow : NSWindow
@end

@implementation StubbornWindow
- (void)close
{
    NSLog(@"StubbornWindow: close requested but I refuse!");
}
@end

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *win = [[StubbornWindow alloc] initWithContentRect:NSMakeRect(200, 200, 400, 300)
                                                          styleMask:NSTitledWindowMask
                                                                   | NSClosableWindowMask
                                                                   | NSMiniaturizableWindowMask
                                                                   | NSResizableWindowMask
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO];
        [win setTitle:@"Kill Test — try closing me"];
        [win setReleasedWhenClosed:NO];
        [win makeKeyAndOrderFront:nil];
        [[NSApplication sharedApplication] run];
    }
    return 0;
}

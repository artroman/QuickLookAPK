#import "AppDelegate.h"

@interface AppDelegate ()
@property(nonatomic, strong) NSWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSRect frame = NSMakeRect(0, 0, 420, 220);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                               styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    self.window.title = @"QuickLookAPK";
    self.window.releasedWhenClosed = NO;

    NSTextField *label = [NSTextField wrappingLabelWithString:
        @"QuickLookAPK is installed.\n\n"
        @"Its Quick Look Preview and Thumbnail extensions let Finder show previews and "
        @"icons for .apk files. If previews don't appear, confirm the extensions are "
        @"enabled below."];
    label.frame = NSMakeRect(20, 80, 380, 120);
    label.alignment = NSTextAlignmentLeft;
    [self.window.contentView addSubview:label];

    NSButton *button = [NSButton buttonWithTitle:@"Open Extensions Settings…"
                                           target:self
                                           action:@selector(openExtensionsSettings:)];
    button.frame = NSMakeRect(20, 30, 220, 32);
    [self.window.contentView addSubview:button];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)openExtensionsSettings:(id)sender
{
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.ExtensionsPreferences"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

@end

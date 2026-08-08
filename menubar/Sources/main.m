// Cove Menu Bar — macOS menu bar companion for Cove.
//
// Originally created by Robby McCullough (github.com/RobbyMcCullough/cove-menubar,
// MIT) and folded into the official Cove project with his blessing.
// Copyright (c) 2026 Robby McCullough. MIT License.
//
// This source is embedded into cove.sh at compile time (see compile.sh) and
// built on the user's machine by `cove menubar enable` — dependency-free,
// clang + system frameworks only. Keep it that way.

#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#import <ServiceManagement/ServiceManagement.h>

typedef void (^CoveCommandCompletion)(int status, NSString *output, NSError *error);

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic, assign) BOOL caddyRunning;
@property(nonatomic, assign) BOOL mariaDBRunning;
@property(nonatomic, assign) BOOL mailpitRunning;
@property(nonatomic, assign) BOOL busy;
@property(nonatomic, copy) NSString *lastError;
@property(nonatomic, strong) NSImage *runningImage;
@property(nonatomic, strong) NSImage *partialImage;
@property(nonatomic, strong) NSImage *stoppedImage;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [self loadStatusImages];

    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
        selector:@selector(refreshStatus)
        name:NSWorkspaceDidWakeNotification
        object:nil];

    [self rebuildMenu];
    [self refreshStatus];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:8.0
                                                        target:self
                                                      selector:@selector(refreshStatus)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self refreshStatus];
}

- (void)refreshStatus {
    if (self.busy) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self runCoveWithArguments:@[@"status"] completion:^(int status, NSString *output, NSError *error) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        if (status == 0) {
            strongSelf.caddyRunning = [strongSelf serviceNamed:@"Caddy Server" isRunningInOutput:output];
            strongSelf.mariaDBRunning = [strongSelf serviceNamed:@"MariaDB" isRunningInOutput:output];
            strongSelf.mailpitRunning = [strongSelf serviceNamed:@"Mailpit" isRunningInOutput:output];
            strongSelf.lastError = nil;
        } else {
            strongSelf.lastError = error.localizedDescription ?: @"Unable to read Cove status.";
        }

        [strongSelf rebuildMenu];
    }];
}

- (void)startCove {
    [self runActionWithArguments:@[@"enable"] actionName:@"start"];
}

- (void)stopCove {
    [self runActionWithArguments:@[@"disable"] actionName:@"stop"];
}

- (void)runActionWithArguments:(NSArray<NSString *> *)arguments actionName:(NSString *)actionName {
    if (self.busy) {
        return;
    }

    self.busy = YES;
    self.lastError = nil;
    [self rebuildMenu];

    __weak typeof(self) weakSelf = self;
    [self runCoveWithArguments:arguments completion:^(int status, NSString *output, NSError *error) {
        (void)output;
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        strongSelf.busy = NO;
        if (status != 0) {
            strongSelf.lastError = error.localizedDescription ?: @"The Cove command failed.";
            [strongSelf showErrorWithTitle:[NSString stringWithFormat:@"Could not %@ Cove", actionName]
                                   message:strongSelf.lastError];
            [strongSelf rebuildMenu];
            return;
        }

        [strongSelf refreshStatus];
    }];
}

- (void)runCoveWithArguments:(NSArray<NSString *> *)arguments
                  completion:(CoveCommandCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *executable = [self coveExecutablePath];
        NSArray<NSString *> *actualArguments = arguments;
        if ([executable isEqualToString:@"/usr/bin/env"]) {
            actualArguments = [@[@"cove"] arrayByAddingObjectsFromArray:arguments];
        }

        NSTask *task = [[NSTask alloc] init];
        NSPipe *outputPipe = [NSPipe pipe];
        task.executableURL = [NSURL fileURLWithPath:executable];
        task.arguments = actualArguments;
        task.standardOutput = outputPipe;
        task.standardError = outputPipe;

        NSMutableDictionary<NSString *, NSString *> *environment =
            [[[NSProcessInfo processInfo] environment] mutableCopy];
        environment[@"PATH"] =
            @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        task.environment = environment;

        NSError *launchError = nil;
        BOOL launched = [task launchAndReturnError:&launchError];
        if (!launched) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(-1, @"", launchError);
            });
            return;
        }

        NSData *data = [[outputPipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        int terminationStatus = task.terminationStatus;
        NSError *commandError = nil;

        if (terminationStatus != 0) {
            NSString *message = [output stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (message.length == 0) {
                message = @"The Cove command exited with an error.";
            }
            commandError = [NSError errorWithDomain:@"CoveMenuBar"
                                                code:terminationStatus
                                            userInfo:@{NSLocalizedDescriptionKey: message}];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(terminationStatus, output, commandError);
        });
    });
}

- (NSString *)coveExecutablePath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in @[@"/opt/homebrew/bin/cove", @"/usr/local/bin/cove"]) {
        if ([fileManager isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return @"/usr/bin/env";
}

- (BOOL)serviceNamed:(NSString *)serviceName isRunningInOutput:(NSString *)output {
    for (NSString *line in [output componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        if ([line containsString:serviceName] && [line containsString:@"Running"]) {
            return YES;
        }
    }
    return NO;
}

- (void)rebuildMenu {
    [self updateStatusButton];

    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;

    NSMenuItem *summary = [[NSMenuItem alloc] initWithTitle:[self summaryText]
                                                    action:nil
                                             keyEquivalent:@""];
    summary.enabled = NO;
    [menu addItem:summary];
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItem:[self serviceMenuItemWithName:@"Caddy" running:self.caddyRunning]];
    [menu addItem:[self serviceMenuItemWithName:@"MariaDB" running:self.mariaDBRunning]];
    [menu addItem:[self serviceMenuItemWithName:@"Mailpit" running:self.mailpitRunning]];

    if (self.lastError.length > 0) {
        [menu addItem:[NSMenuItem separatorItem]];
        NSString *firstLine = [[self.lastError componentsSeparatedByCharactersInSet:
                                [NSCharacterSet newlineCharacterSet]] firstObject];
        NSMenuItem *errorItem =
            [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Error: %@", firstLine]
                                      action:nil
                               keyEquivalent:@""];
        errorItem.enabled = NO;
        [menu addItem:errorItem];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    BOOL allRunning = [self allServicesRunning];
    NSMenuItem *actionItem =
        [[NSMenuItem alloc] initWithTitle:(allRunning ? @"Stop Cove" : @"Start Cove")
                                  action:(allRunning ? @selector(stopCove) : @selector(startCove))
                           keyEquivalent:@""];
    actionItem.target = self;
    actionItem.enabled = !self.busy;
    [menu addItem:actionItem];

    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"Refresh Status"
                                                        action:@selector(refreshStatus)
                                                 keyEquivalent:@"r"];
    refreshItem.target = self;
    refreshItem.enabled = !self.busy;
    [menu addItem:refreshItem];

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self linkItemWithTitle:@"Open Cove Dashboard"
                                   action:@selector(openDashboard)
                                  enabled:self.caddyRunning]];
    [menu addItem:[self linkItemWithTitle:@"Open Adminer"
                                   action:@selector(openAdminer)
                                  enabled:self.caddyRunning]];
    [menu addItem:[self linkItemWithTitle:@"Open Mailpit"
                                   action:@selector(openMailpit)
                                  enabled:self.mailpitRunning]];
    [menu addItem:[self linkItemWithTitle:@"Open Cove Logs"
                                   action:@selector(openLogs)
                                  enabled:YES]];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *launchItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                                                        action:@selector(toggleLaunchAtLogin)
                                                 keyEquivalent:@""];
    launchItem.target = self;
    launchItem.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    [menu addItem:launchItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Cove Menu Bar"
                                                     action:@selector(quitApp)
                                              keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
}

- (void)updateStatusButton {
    NSStatusBarButton *button = self.statusItem.button;
    if (!button) {
        return;
    }

    NSImage *image;
    if ([self allServicesRunning] && !self.busy && self.lastError.length == 0) {
        image = self.runningImage;
    } else if ([self runningServiceCount] > 0) {
        image = self.partialImage;
    } else {
        image = self.stoppedImage;
    }

    button.title = @"";
    button.image = image;
    button.imagePosition = NSImageOnly;
    button.toolTip = [self summaryText];
    button.accessibilityLabel = [self summaryText];
}

- (void)loadStatusImages {
    NSURL *assetURL = [[NSBundle mainBundle] URLForResource:@"cove-favicon-source"
                                             withExtension:@"png"
                                              subdirectory:@"Assets"];
    NSImage *source = assetURL ? [[NSImage alloc] initWithContentsOfURL:assetURL] : nil;
    if (!source) {
        return;
    }

    source.size = NSMakeSize(18, 18);
    self.runningImage = source;
    self.partialImage = [self imageByDesaturating:source brightness:0.02 contrast:1.05];
    self.stoppedImage = [self imageByDesaturating:source brightness:-0.12 contrast:1.20];
}

- (NSImage *)imageByDesaturating:(NSImage *)source
                      brightness:(CGFloat)brightness
                        contrast:(CGFloat)contrast {
    NSData *sourceData = [source TIFFRepresentation];
    CIImage *inputImage = sourceData ? [CIImage imageWithData:sourceData] : nil;
    if (!inputImage) {
        return source;
    }

    CIFilter *filter = [CIFilter filterWithName:@"CIColorControls"];
    [filter setValue:inputImage forKey:kCIInputImageKey];
    [filter setValue:@0.0 forKey:kCIInputSaturationKey];
    [filter setValue:@(brightness) forKey:kCIInputBrightnessKey];
    [filter setValue:@(contrast) forKey:kCIInputContrastKey];

    CIImage *outputImage = filter.outputImage;
    if (!outputImage) {
        return source;
    }

    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [context createCGImage:outputImage fromRect:outputImage.extent];
    if (!cgImage) {
        return source;
    }

    NSImage *result = [[NSImage alloc] initWithCGImage:cgImage size:NSMakeSize(18, 18)];
    CGImageRelease(cgImage);
    return result;
}

- (NSString *)summaryText {
    if (self.busy) {
        return @"Cove is updating...";
    }
    if (self.lastError.length > 0) {
        return @"Cove status unavailable";
    }
    if ([self allServicesRunning]) {
        return @"Cove is running";
    }
    if ([self runningServiceCount] > 0) {
        return @"Cove is partially running";
    }
    return @"Cove is stopped";
}

- (NSInteger)runningServiceCount {
    return (self.caddyRunning ? 1 : 0)
        + (self.mariaDBRunning ? 1 : 0)
        + (self.mailpitRunning ? 1 : 0);
}

- (BOOL)allServicesRunning {
    return [self runningServiceCount] == 3;
}

- (NSMenuItem *)serviceMenuItemWithName:(NSString *)name running:(BOOL)running {
    NSString *title = [NSString stringWithFormat:@"%@: %@", name, running ? @"Running" : @"Stopped"];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.image = [NSImage imageWithSystemSymbolName:(running ? @"checkmark.circle.fill" : @"circle")
                          accessibilityDescription:nil];
    item.enabled = NO;
    return item;
}

- (NSMenuItem *)linkItemWithTitle:(NSString *)title
                           action:(SEL)action
                          enabled:(BOOL)enabled {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.enabled = enabled;
    return item;
}

- (void)openDashboard {
    [self openCoveHost:@"cove.localhost"];
}

- (void)openAdminer {
    [self openCoveHost:@"db.cove.localhost"];
}

- (void)openMailpit {
    [self openCoveHost:@"mail.cove.localhost"];
}

- (void)openCoveHost:(NSString *)host {
    NSString *urlString = [NSString stringWithFormat:@"https://%@%@", host, [self httpsPortSuffix]];
    NSURL *url = [NSURL URLWithString:urlString];
    if (url) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (NSString *)httpsPortSuffix {
    NSString *configPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Cove/config"];
    NSString *config = [NSString stringWithContentsOfFile:configPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (!config) {
        return @"";
    }

    NSString *port = nil;
    for (NSString *line in [config componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        if ([line hasPrefix:@"HTTPS_PORT="]) {
            port = [[line substringFromIndex:[@"HTTPS_PORT=" length]]
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"'\" "]];
        }
    }

    if (port.length == 0 || [port isEqualToString:@"443"]) {
        return @"";
    }
    return [@":" stringByAppendingString:port];
}

- (void)openLogs {
    NSURL *logsURL = [NSURL fileURLWithPath:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Cove/Logs"]
                               isDirectory:YES];
    [[NSWorkspace sharedWorkspace] openURL:logsURL];
}

- (void)toggleLaunchAtLogin {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL succeeded;
    if (service.status == SMAppServiceStatusEnabled) {
        succeeded = [service unregisterAndReturnError:&error];
    } else {
        succeeded = [service registerAndReturnError:&error];
    }

    if (!succeeded) {
        [self showErrorWithTitle:@"Launch at Login"
                         message:error.localizedDescription ?: @"Unable to change the login item."];
    }
    [self rebuildMenu];
}

- (void)showErrorWithTitle:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = message;
    [alert runModal];
}

- (void)quitApp {
    [NSApp terminate:nil];
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}

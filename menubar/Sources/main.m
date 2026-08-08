// Cove Menu Bar — macOS menu bar companion for Cove.
//
// Originally created by Robby McCullough (github.com/RobbyMcCullough/cove-menubar,
// MIT) and folded into the official Cove project with his blessing.
// Copyright (c) 2026 Robby McCullough. MIT License.
//
// This source is embedded into cove.sh at compile time (see compile.sh) and
// built on the user's machine by `cove menubar enable` — dependency-free,
// clang + system frameworks only. Keep it that way.
//
// Status is read via `cove status --porcelain` (key=value per line) — a
// stable contract defined in commands/status. The human-readable status
// output can change freely; the porcelain keys cannot.

#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>

typedef void (^CoveCommandCompletion)(int status, NSString *output, NSError *error);

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic, strong) NSTimer *updateCheckTimer;
// Ordered porcelain keys (caddy, mariadb, mailpit, php-fpm-<ver>...) and
// their running state from the most recent successful poll.
@property(nonatomic, strong) NSArray<NSString *> *serviceKeys;
@property(nonatomic, strong) NSDictionary<NSString *, NSNumber *> *serviceStates;
@property(nonatomic, assign) BOOL statesKnown;
@property(nonatomic, assign) BOOL busy;
@property(nonatomic, copy) NSString *lastError;
@property(nonatomic, copy) NSString *coveVersion;
@property(nonatomic, copy) NSString *latestVersion;
@property(nonatomic, assign) CFAbsoluteTime lastUserActionTime;
@property(nonatomic, assign) BOOL notificationsAllowed;
@property(nonatomic, strong) NSImage *runningImage;
@property(nonatomic, strong) NSImage *partialImage;
@property(nonatomic, strong) NSImage *stoppedImage;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [self loadStatusImages];

    self.serviceKeys = @[];
    self.serviceStates = @{};

    // One menu instance for the app's lifetime, mutated in place. Rebuilding a
    // fresh NSMenu per refresh left the *open* menu showing stale state — an
    // assigned-but-replaced menu doesn't update what's already on screen.
    self.menu = [[NSMenu alloc] init];
    self.menu.autoenablesItems = NO;
    self.menu.delegate = self;
    self.statusItem.menu = self.menu;

    __weak typeof(self) weakSelf = self;
    [[UNUserNotificationCenter currentNotificationCenter]
        requestAuthorizationWithOptions:UNAuthorizationOptionAlert
                      completionHandler:^(BOOL granted, NSError *error) {
                          (void)error;
                          dispatch_async(dispatch_get_main_queue(), ^{
                              weakSelf.notificationsAllowed = granted;
                          });
                      }];

    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
        selector:@selector(refreshStatus)
        name:NSWorkspaceDidWakeNotification
        object:nil];

    [self rebuildMenu];
    [self refreshStatus];

    // The menu refreshes on open (menuWillOpen:), so the timer only keeps the
    // *icon* honest. A generous interval + tolerance lets macOS coalesce the
    // wakeups instead of spinning up a bash pipeline every few seconds.
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:20.0
                                                        target:self
                                                      selector:@selector(refreshStatus)
                                                      userInfo:nil
                                                       repeats:YES];
    self.refreshTimer.tolerance = 5.0;

    [self checkForUpdates];
    self.updateCheckTimer = [NSTimer scheduledTimerWithTimeInterval:86400.0
                                                             target:self
                                                           selector:@selector(checkForUpdates)
                                                           userInfo:nil
                                                            repeats:YES];
    self.updateCheckTimer.tolerance = 3600.0;
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self refreshStatus];
}

#pragma mark - Status polling

- (void)refreshStatus {
    if (self.busy) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self runCoveWithArguments:@[@"status", @"--porcelain"]
                    completion:^(int status, NSString *output, NSError *error) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        if (status == 0) {
            [strongSelf applyPorcelainOutput:output];
            strongSelf.lastError = nil;
        } else {
            strongSelf.lastError = error.localizedDescription ?: @"Unable to read Cove status.";
        }

        [strongSelf rebuildMenu];
    }];
}

- (void)applyPorcelainOutput:(NSString *)output {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *states = [NSMutableDictionary dictionary];

    for (NSString *rawLine in [output componentsSeparatedByCharactersInSet:
                               [NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound || eq.location == 0) {
            continue;
        }
        NSString *key = [line substringToIndex:eq.location];
        NSString *value = [line substringFromIndex:eq.location + 1];

        if ([key isEqualToString:@"version"]) {
            self.coveVersion = value;
            continue;
        }
        if ([value isEqualToString:@"running"] || [value isEqualToString:@"stopped"]) {
            [keys addObject:key];
            states[key] = @([value isEqualToString:@"running"]);
        }
    }

    if (keys.count == 0) {
        // Porcelain output we can't read — treat as an error, not "all down".
        self.lastError = @"Unexpected status output from Cove.";
        return;
    }

    [self notifyUnexpectedStopsFrom:self.serviceStates to:states];

    self.serviceKeys = keys;
    self.serviceStates = states;
    self.statesKnown = YES;
}

// Post a notification for a service that died out from under a running stack.
// Suppressed when: states aren't established yet, the user just acted through
// the menu (start/stop churn), or EVERYTHING went down at once — that shape is
// almost always a deliberate `cove disable` from a terminal, not a crash.
- (void)notifyUnexpectedStopsFrom:(NSDictionary<NSString *, NSNumber *> *)oldStates
                               to:(NSDictionary<NSString *, NSNumber *> *)newStates {
    if (!self.statesKnown || !self.notificationsAllowed) {
        return;
    }
    if (CFAbsoluteTimeGetCurrent() - self.lastUserActionTime < 20.0) {
        return;
    }

    BOOL anyStillRunning = NO;
    for (NSNumber *running in newStates.allValues) {
        if (running.boolValue) {
            anyStillRunning = YES;
            break;
        }
    }
    if (!anyStillRunning) {
        return;
    }

    for (NSString *key in newStates) {
        if (oldStates[key].boolValue && !newStates[key].boolValue) {
            UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
            content.title = @"Cove";
            content.body = [NSString stringWithFormat:@"%@ stopped unexpectedly.",
                            [self displayNameForServiceKey:key]];
            UNNotificationRequest *request =
                [UNNotificationRequest requestWithIdentifier:[NSUUID UUID].UUIDString
                                                     content:content
                                                     trigger:nil];
            [[UNUserNotificationCenter currentNotificationCenter]
                addNotificationRequest:request withCompletionHandler:nil];
        }
    }
}

- (NSString *)displayNameForServiceKey:(NSString *)key {
    if ([key isEqualToString:@"caddy"])   { return @"Caddy"; }
    if ([key isEqualToString:@"mariadb"]) { return @"MariaDB"; }
    if ([key isEqualToString:@"mailpit"]) { return @"Mailpit"; }
    if ([key hasPrefix:@"php-fpm-"]) {
        return [NSString stringWithFormat:@"PHP-FPM %@",
                [key substringFromIndex:[@"php-fpm-" length]]];
    }
    return key;
}

- (BOOL)serviceRunning:(NSString *)key {
    return self.serviceStates[key].boolValue;
}

- (NSInteger)runningServiceCount {
    NSInteger count = 0;
    for (NSNumber *running in self.serviceStates.allValues) {
        if (running.boolValue) {
            count++;
        }
    }
    return count;
}

- (BOOL)allServicesRunning {
    return self.statesKnown
        && self.serviceKeys.count > 0
        && [self runningServiceCount] == (NSInteger)self.serviceKeys.count;
}

#pragma mark - Actions

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
    self.lastUserActionTime = CFAbsoluteTimeGetCurrent();
    [self rebuildMenu];

    __weak typeof(self) weakSelf = self;
    [self runCoveWithArguments:arguments completion:^(int status, NSString *output, NSError *error) {
        (void)output;
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        strongSelf.busy = NO;
        strongSelf.lastUserActionTime = CFAbsoluteTimeGetCurrent();
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

#pragma mark - Menu

- (void)rebuildMenu {
    [self updateStatusButton];

    NSMenu *menu = self.menu;
    [menu removeAllItems];

    NSMenuItem *summary = [[NSMenuItem alloc] initWithTitle:[self summaryText]
                                                    action:nil
                                             keyEquivalent:@""];
    summary.enabled = NO;
    [menu addItem:summary];
    [menu addItem:[NSMenuItem separatorItem]];

    for (NSString *key in self.serviceKeys) {
        [menu addItem:[self serviceMenuItemWithName:[self displayNameForServiceKey:key]
                                            running:[self serviceRunning:key]]];
    }

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
    [menu addItem:[self sitesMenuItem]];

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self linkItemWithTitle:@"Open Cove Dashboard"
                                   action:@selector(openDashboard)
                                  enabled:[self serviceRunning:@"caddy"]]];
    [menu addItem:[self linkItemWithTitle:@"Open Adminer"
                                   action:@selector(openAdminer)
                                  enabled:[self serviceRunning:@"caddy"]]];
    [menu addItem:[self linkItemWithTitle:@"Open Mailpit"
                                   action:@selector(openMailpit)
                                  enabled:[self serviceRunning:@"mailpit"]]];
    [menu addItem:[self linkItemWithTitle:@"Open Cove Logs"
                                   action:@selector(openLogs)
                                  enabled:YES]];
    [menu addItem:[self linkItemWithTitle:@"Open Sites Folder"
                                   action:@selector(openSitesFolder)
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

    if ([self updateAvailable]) {
        NSMenuItem *updateItem =
            [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Update Cove to v%@…",
                                               self.latestVersion]
                                      action:@selector(runUpgradeInTerminal)
                               keyEquivalent:@""];
        updateItem.target = self;
        [menu addItem:updateItem];
    } else if (self.coveVersion.length > 0) {
        NSMenuItem *versionItem =
            [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Cove v%@", self.coveVersion]
                                      action:nil
                               keyEquivalent:@""];
        versionItem.enabled = NO;
        [menu addItem:versionItem];
    }

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Cove Menu Bar"
                                                     action:@selector(quitApp)
                                              keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];
}

#pragma mark - Sites submenu

- (NSString *)sitesDirectory {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Cove/Sites"];
}

// Cove's convention: every site is a directory named <name>.localhost inside
// ~/Cove/Sites. The directory also collects loose files (logs, scripts), so
// filter strictly. A cheap readdir on the main thread — sites lists are small.
- (NSMenuItem *)sitesMenuItem {
    NSMenuItem *sitesItem = [[NSMenuItem alloc] initWithTitle:@"Sites"
                                                      action:nil
                                               keyEquivalent:@""];
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *sitesDir = [self sitesDirectory];
    NSArray<NSString *> *entries =
        [[fileManager contentsOfDirectoryAtPath:sitesDir error:nil]
            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    NSUInteger siteCount = 0;
    for (NSString *entry in entries) {
        if (![entry hasSuffix:@".localhost"]) {
            continue;
        }
        BOOL isDirectory = NO;
        NSString *sitePath = [sitesDir stringByAppendingPathComponent:entry];
        if (![fileManager fileExistsAtPath:sitePath isDirectory:&isDirectory] || !isDirectory) {
            continue;
        }
        siteCount++;

        NSMenuItem *siteItem = [[NSMenuItem alloc] initWithTitle:entry
                                                          action:@selector(openSite:)
                                                   keyEquivalent:@""];
        siteItem.target = self;
        siteItem.representedObject = entry;
        [submenu addItem:siteItem];

        // WordPress sites get an option-key alternate that generates a
        // one-time admin login via `cove login`.
        NSString *wpConfig = [sitePath stringByAppendingPathComponent:@"public/wp-config.php"];
        if ([fileManager fileExistsAtPath:wpConfig]) {
            NSMenuItem *loginItem =
                [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Log in to %@", entry]
                                          action:@selector(loginToSite:)
                                   keyEquivalent:@""];
            loginItem.target = self;
            loginItem.representedObject = entry;
            loginItem.keyEquivalentModifierMask = NSEventModifierFlagOption;
            loginItem.alternate = YES;
            [submenu addItem:loginItem];
        }
    }

    if (siteCount == 0) {
        NSMenuItem *emptyItem = [[NSMenuItem alloc] initWithTitle:@"No sites yet"
                                                           action:nil
                                                    keyEquivalent:@""];
        emptyItem.enabled = NO;
        [submenu addItem:emptyItem];
    } else {
        sitesItem.title = [NSString stringWithFormat:@"Sites (%lu)", (unsigned long)siteCount];
    }

    sitesItem.submenu = submenu;
    return sitesItem;
}

- (void)openSite:(NSMenuItem *)sender {
    NSString *host = sender.representedObject;
    if (host.length > 0) {
        [self openCoveHost:host];
    }
}

- (void)loginToSite:(NSMenuItem *)sender {
    NSString *host = sender.representedObject;
    if (host.length == 0) {
        return;
    }
    // `cove login` takes the site name without the .localhost suffix and
    // prints a one-time login URL (inside a decorative box) — extract the
    // first URL from the output and open it.
    NSString *siteName = [host stringByReplacingOccurrencesOfString:@".localhost"
                                                         withString:@""
                                                            options:NSAnchoredSearch | NSBackwardsSearch
                                                              range:NSMakeRange(0, host.length)];

    __weak typeof(self) weakSelf = self;
    [self runCoveWithArguments:@[@"login", siteName]
                    completion:^(int status, NSString *output, NSError *error) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        NSString *loginURL = nil;
        if (status == 0) {
            NSRegularExpression *regex =
                [NSRegularExpression regularExpressionWithPattern:@"https://[A-Za-z0-9.:/_?=&%-]+"
                                                          options:0
                                                            error:nil];
            NSTextCheckingResult *match =
                [regex firstMatchInString:output
                                  options:0
                                    range:NSMakeRange(0, output.length)];
            if (match) {
                loginURL = [output substringWithRange:match.range];
            }
        }

        if (loginURL) {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:loginURL]];
        } else {
            [strongSelf showErrorWithTitle:[NSString stringWithFormat:@"Could not log in to %@", host]
                                   message:error.localizedDescription
                                           ?: @"cove login did not return a login URL."];
        }
    }];
}

- (void)openSitesFolder {
    NSURL *sitesURL = [NSURL fileURLWithPath:[self sitesDirectory] isDirectory:YES];
    [[NSWorkspace sharedWorkspace] openURL:sitesURL];
}

#pragma mark - Update check

// Resolve the latest released version by following the GitHub redirect for
// releases/latest → .../releases/tag/v<version>. No API token, no rate-limit
// concerns at once a day, and no JSON parsing needed.
- (void)checkForUpdates {
    NSURL *url = [NSURL URLWithString:@"https://github.com/anchorhost/cove/releases/latest"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"HEAD";
    request.timeoutInterval = 15.0;

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              (void)data;
              if (error || !response.URL) {
                  return;
              }
              NSString *tag = response.URL.lastPathComponent;
              if (![tag hasPrefix:@"v"] || tag.length < 2) {
                  return;
              }
              NSString *version = [tag substringFromIndex:1];
              dispatch_async(dispatch_get_main_queue(), ^{
                  AppDelegate *strongSelf = weakSelf;
                  if (!strongSelf) {
                      return;
                  }
                  strongSelf.latestVersion = version;
                  [strongSelf rebuildMenu];
              });
          }];
    [task resume];
}

- (BOOL)updateAvailable {
    if (self.coveVersion.length == 0 || self.latestVersion.length == 0) {
        return NO;
    }
    return [self compareVersion:self.latestVersion to:self.coveVersion] == NSOrderedDescending;
}

// Numeric segment-by-segment comparison, so 1.10 > 1.9.
- (NSComparisonResult)compareVersion:(NSString *)a to:(NSString *)b {
    NSArray<NSString *> *aParts = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *bParts = [b componentsSeparatedByString:@"."];
    NSUInteger count = MAX(aParts.count, bParts.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger aValue = i < aParts.count ? aParts[i].integerValue : 0;
        NSInteger bValue = i < bParts.count ? bParts[i].integerValue : 0;
        if (aValue != bValue) {
            return aValue > bValue ? NSOrderedDescending : NSOrderedAscending;
        }
    }
    return NSOrderedSame;
}

// `cove upgrade` can install Homebrew packages and ask questions — that
// belongs in a real terminal, not a headless NSTask. A .command file opens in
// Terminal via Launch Services with no automation (TCC) prompt.
- (void)runUpgradeInTerminal {
    NSString *script = @"#!/bin/zsh\n"
                        "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\n"
                        "cove upgrade\n";
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"cove-upgrade.command"];
    NSError *error = nil;
    if (![script writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        [self showErrorWithTitle:@"Update Cove" message:error.localizedDescription];
        return;
    }
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755}
                                     ofItemAtPath:path
                                            error:nil];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

#pragma mark - Status button

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
    if (!self.statesKnown) {
        return @"Checking Cove status...";
    }
    if ([self allServicesRunning]) {
        return @"Cove is running";
    }
    if ([self runningServiceCount] > 0) {
        return @"Cove is partially running";
    }
    return @"Cove is stopped";
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

#pragma mark - Quick links

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

#pragma mark - Housekeeping

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
    // Accessory apps have no key window; without activation the alert can
    // appear behind whatever the user is working in.
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)quitApp {
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[]) {
    // `CoveMenuBar unregister` — invoked by `cove menubar disable` before the
    // bundle is deleted, because SMAppService login items can only be
    // unregistered from inside the app they belong to. Without this, disable
    // would leave a stale entry in System Settings → Login Items.
    if (argc > 1 && strcmp(argv[1], "unregister") == 0) {
        @autoreleasepool {
            [SMAppService.mainAppService unregisterAndReturnError:nil];
        }
        return 0;
    }

    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}

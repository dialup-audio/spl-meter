#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>

static NSString * const kRepo    = @"dialup-audio/rew-spl-meter";
static NSString * const kSiteURL = @"https://dialup.audio";

static NSString * const kRewUrl =
    @"http://127.0.0.1:4735/spl-meter/1/levels";

static double kOffsetDb = 0; // rack reads hotter than LP

// The mic REW should measure with. Stored in NSUserDefaults:
//   defaults read audio.dialup.rew-spl-meter inputDevice
static NSString * const kInputDeviceKey = @"inputDevice";
static NSString * const kRewBase = @"http://127.0.0.1:4735";

// REW's /levels can contain `"spl": NaN` (not valid JSON), so read the number from the text.
// Returns YES with the level if the meter is actually reading; NO for NaN, REW's -180 floor
// (meter stopped / no signal), or a missing value.
static BOOL ParseSplLevel(NSData *data, double *level) {
    NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!body) return NO;

    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:@"\"spl\"\\s*:\\s*([^,}\\s]+)"
                                                  options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:body options:0
                                                      range:NSMakeRange(0, body.length)];
    if (!match) return NO;

    double value = [[body substringWithRange:[match rangeAtIndex:1]] doubleValue];
    if (!isfinite(value) || value <= -170) return NO;   // "NaN".doubleValue is 0, so check the text too
    if ([[body substringWithRange:[match rangeAtIndex:1]] isEqualToString:@"NaN"]) return NO;

    if (level) *level = value;
    return YES;
}

static NSString *Trim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

// Names of every Core Audio device that has input channels.
static NSArray<NSString *> *CoreAudioInputDeviceNames(void) {
    AudioObjectPropertyAddress addr = { kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr) {
        return @[];
    }

    NSMutableData *idData = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size,
                                   idData.mutableBytes) != noErr) {
        return @[];
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    const AudioDeviceID *ids = (const AudioDeviceID *)idData.bytes;
    UInt32 count = size / sizeof(AudioDeviceID);

    for (UInt32 i = 0; i < count; i++) {
        AudioObjectPropertyAddress cfg = { kAudioDevicePropertyStreamConfiguration,
            kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
        UInt32 cfgSize = 0;
        if (AudioObjectGetPropertyDataSize(ids[i], &cfg, 0, NULL, &cfgSize) != noErr || cfgSize == 0) continue;

        NSMutableData *bufData = [NSMutableData dataWithLength:cfgSize];
        if (AudioObjectGetPropertyData(ids[i], &cfg, 0, NULL, &cfgSize, bufData.mutableBytes) != noErr) continue;

        const AudioBufferList *list = (const AudioBufferList *)bufData.bytes;
        UInt32 channels = 0;
        for (UInt32 b = 0; b < list->mNumberBuffers; b++) channels += list->mBuffers[b].mNumberChannels;
        if (channels == 0) continue;

        CFStringRef cfName = NULL;
        UInt32 nameSize = sizeof(cfName);
        AudioObjectPropertyAddress nameAddr = { kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        if (AudioObjectGetPropertyData(ids[i], &nameAddr, 0, NULL, &nameSize, &cfName) == noErr && cfName) {
            [names addObject:(__bridge_transfer NSString *)cfName];
        }
    }
    return names;
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSTimer *timer;
@property NSInteger meterStartAttempts;
// Bumped whenever a start sequence begins or is cancelled, so stale retries and
// callbacks from an earlier sequence can tell they're obsolete and bail out.
@property NSUInteger sequenceGeneration;
@property (copy) NSString *wantedInput;   // mic REW should use (REW's device name)
@property BOOL micPresent;                // is that mic currently connected?
@property (strong) NSMenuItem *inputItem;
@property (strong) NSMenu *inputMenu;
@property (copy) NSArray<NSString *> *rewInputDevices;
@property pid_t rewApiPid;
@end

typedef NS_ENUM(NSInteger, RewState) {
    RewStateNotRunning,
    RewStateRunningWithApi,
    RewStateRunningWithoutApi,
};

static const NSInteger kMaxMeterStartAttempts = 30;
static const NSTimeInterval kMeterStartRetryDelay = 2.0;

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"REW SPL menubar app launched");
    self.statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:48];

    self.statusItem.button.title = @"--.-";

    NSMenu *menu = [[NSMenu alloc] init];

    menu.delegate = self;

    // Greyed-out line showing the current mic, then a submenu to change it.
    self.inputItem = [[NSMenuItem alloc] initWithTitle:@"Input: …" action:nil keyEquivalent:@""];
    [menu addItem:self.inputItem];

    self.inputMenu = [[NSMenu alloc] init];
    NSMenuItem *inputParent = [[NSMenuItem alloc] initWithTitle:@"Input device"
                                                         action:nil keyEquivalent:@""];
    inputParent.submenu = self.inputMenu;
    [menu addItem:inputParent];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *about = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"About %@", self.appName]
               action:@selector(showAbout:)
        keyEquivalent:@""];
    about.target = self;
    [menu addItem:about];

    NSMenuItem *check = [[NSMenuItem alloc] initWithTitle:@"Check for Updates…"
                                                   action:@selector(checkForUpdates:)
                                            keyEquivalent:@""];
    check.target = self;
    [menu addItem:check];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit"
               action:@selector(terminate:)
        keyEquivalent:@"q"];

    [menu addItem:quit];
    self.statusItem.menu = menu;

    // Prompts for Accessibility access (needed to minimize REW's windows) if not yet granted.
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES });

    self.wantedInput = [[NSUserDefaults standardUserDefaults] stringForKey:kInputDeviceKey];
    [self updateInputMenuTitles];

    // Fires when any audio device is plugged in or removed.
    AudioObjectPropertyAddress devicesAddr = { kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &devicesAddr,
                                        dispatch_get_main_queue(),
                                        ^(UInt32 n, const AudioObjectPropertyAddress *a) {
        [self evaluateMicPresence];
    });

    [self ensureRewRunningWithApi];

    if (self.wantedInput && ![self wantedInputIsPresent]) {
        [self showNoMic];
    } else {
        // No saved mic yet: the start sequence adopts whatever REW is currently using.
        self.micPresent = YES;
        [self startRewMeter];
        [self startSPLPolling];
    }
    [self refreshRewInputDevices];
}

#pragma mark - Input device

- (BOOL)wantedInputIsPresent {
    if (!self.wantedInput) return YES;
    NSString *wanted = Trim(self.wantedInput);
    // REW's "Default Device" entries follow the system default; there's nothing to unplug.
    if ([wanted hasPrefix:@"Default"]) return YES;
    for (NSString *name in CoreAudioInputDeviceNames()) {
        if ([Trim(name) isEqualToString:wanted]) return YES;
    }
    return NO;
}

- (void)showNoMic {
    self.micPresent = NO;
    self.sequenceGeneration++;   // cancel any start sequence that's still retrying
    [self stopSPLPolling];
    self.statusItem.button.title = @"NO MIC";
}

// Called on every device add/remove. Unplug: stop and show NO MIC.
// Plug back in: run the full start sequence again (set device, open, configure, start).
- (void)evaluateMicPresence {
    BOOL present = [self wantedInputIsPresent];

    if (present && !self.micPresent) {
        NSLog(@"mic connected: %@", self.wantedInput);
        self.micPresent = YES;
        [self startRewMeter];
        [self startSPLPolling];
    } else if (!present && self.micPresent) {
        NSLog(@"mic disconnected: %@", self.wantedInput);
        [self showNoMic];
    }
}

- (void)updateInputMenuTitles {
    self.inputItem.title = self.wantedInput
        ? [NSString stringWithFormat:@"Input: %@", Trim(self.wantedInput)]
        : @"Input: (none)";

    [self.inputMenu removeAllItems];
    if (self.rewInputDevices.count == 0) {
        [self.inputMenu addItemWithTitle:@"No devices (is REW running?)" action:nil keyEquivalent:@""];
        return;
    }
    for (NSString *name in self.rewInputDevices) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:Trim(name)
                                                      action:@selector(selectInputDevice:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = name;
        item.state = (self.wantedInput && [Trim(name) isEqualToString:Trim(self.wantedInput)])
            ? NSControlStateValueOn : NSControlStateValueOff;
        [self.inputMenu addItem:item];
    }
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self refreshRewInputDevices];
}

// Asks REW which inputs it can use, then rebuilds the submenu.
- (void)refreshRewInputDevices {
    NSURL *url = [NSURL URLWithString:[kRewBase stringByAppendingString:@"/audio/java/input-devices"]];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *devices = [json isKindOfClass:[NSArray class]] ? json : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.rewInputDevices = devices;
            [self updateInputMenuTitles];
        });
    }] resume];
}

- (void)selectInputDevice:(NSMenuItem *)sender {
    self.wantedInput = sender.representedObject;
    [[NSUserDefaults standardUserDefaults] setObject:self.wantedInput forKey:kInputDeviceKey];
    [self updateInputMenuTitles];

    // Re-run everything for the new mic (or show NO MIC if it isn't connected).
    if ([self wantedInputIsPresent]) {
        self.micPresent = YES;
        [self startRewMeter];
        [self startSPLPolling];
    } else {
        [self showNoMic];
    }
}

// Tells REW to use the wanted input. If we don't have one saved yet, adopt REW's current one.
- (void)applyInputDeviceWithCompletion:(void (^)(BOOL ok))completion {
    NSURL *url = [NSURL URLWithString:[kRewBase stringByAppendingString:@"/audio/java/input-device"]];

    if (!self.wantedInput) {
        [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:
          ^(NSData *data, NSURLResponse *response, NSError *error) {
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *device = [json isKindOfClass:[NSDictionary class]] ? json[@"device"] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![device isKindOfClass:[NSString class]] || device.length == 0) {
                    completion(NO);
                    return;
                }
                self.wantedInput = device;
                [[NSUserDefaults standardUserDefaults] setObject:device forKey:kInputDeviceKey];
                [self updateInputMenuTitles];
                completion(YES);
            });
        }] resume];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"device": self.wantedInput }
                                                       options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        BOOL ok = !error && status >= 200 && status < 300;
        if (!ok) NSLog(@"failed setting REW input device: HTTP %ld %@", (long)status, error);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok); });
    }] resume];
}

- (NSString *)appName {
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: @"REW SPL";
}

- (NSString *)appVersion {
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.0.0";
}

- (void)showAbout:(id)sender {
    NSString *text = @"Free tools by dialup.audio";
    NSMutableAttributedString *credits = [[NSMutableAttributedString alloc] initWithString:text];

    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.alignment = NSTextAlignmentCenter;
    [credits addAttributes:@{ NSParagraphStyleAttributeName: para,
                              NSFontAttributeName: [NSFont systemFontOfSize:11],
                              NSForegroundColorAttributeName: NSColor.labelColor }
                     range:NSMakeRange(0, text.length)];
    [credits addAttribute:NSLinkAttributeName
                    value:[NSURL URLWithString:kSiteURL]
                    range:[text rangeOfString:@"dialup.audio"]];

    [NSApp activateIgnoringOtherApps:YES];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{ NSAboutPanelOptionCredits: credits }];
}

#pragma mark - Updates

- (void)alert:(NSString *)message info:(NSString *)info downloadURL:(NSString *)url {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = info;
    if (url) {
        [alert addButtonWithTitle:@"Download"];
        [alert addButtonWithTitle:@"Later"];
    }
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] == NSAlertFirstButtonReturn && url) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
    }
}

- (void)checkForUpdates:(id)sender {
    NSURL *url = [NSURL URLWithString:
        [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", kRepo]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15;
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"dialup-audio-rew-spl-meter" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        id json = (!error && data && status == 200)
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *tag = [json isKindOfClass:[NSDictionary class]] ? json[@"tag_name"] : nil;
        NSString *page = [json isKindOfClass:[NSDictionary class]] ? json[@"html_url"] : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (![tag isKindOfClass:[NSString class]]) {
                NSLog(@"update check failed (status %ld): %@", (long)status, error);
                [self alert:@"Couldn't check for updates"
                       info:@"Check your internet connection and try again."
                downloadURL:nil];
                return;
            }

            NSString *latest = [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;
            BOOL newer = [latest compare:[self appVersion] options:NSNumericSearch]
                         == NSOrderedDescending;

            if (!newer) {
                [self alert:@"You're up to date"
                       info:[NSString stringWithFormat:@"%@ %@ is the latest version.",
                             [self appName], [self appVersion]]
                downloadURL:nil];
                return;
            }

            // Only ever open a page on this project's own GitHub repo.
            NSString *repoPrefix = [NSString stringWithFormat:@"https://github.com/%@/", kRepo];
            NSString *target = ([page isKindOfClass:[NSString class]] && [page hasPrefix:repoPrefix])
                ? page : [repoPrefix stringByAppendingString:@"releases/latest"];

            [self alert:[NSString stringWithFormat:@"Version %@ is available", latest]
                   info:[NSString stringWithFormat:@"You have version %@.", [self appVersion]]
            downloadURL:target];
        });
    }];
    [task resume];
}

// Looks for the REW process in `ps -A` and checks for the -api flag, e.g.
// 36507 ??  0:07.89 /Applications/REW/REW.app/Contents/MacOS/JavaApplicationStub -api
- (RewState)currentRewState {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/ps"];
    task.arguments = @[@"-A", @"-o", @"pid=,command="];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"failed to run ps: %@", error);
        return RewStateNotRunning;
    }

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    RewState state = RewStateNotRunning;
    self.rewApiPid = 0;

    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        if ([line rangeOfString:@"REW.app/Contents/MacOS/"].location == NSNotFound) continue;

        NSArray<NSString *> *args = [[line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]]
            componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if ([args containsObject:@"-api"]) {
            self.rewApiPid = (pid_t)[args.firstObject intValue];
            return RewStateRunningWithApi;
        }
        state = RewStateRunningWithoutApi;
    }

    return state;
}

- (void)ensureRewRunningWithApi {
    switch ([self currentRewState]) {
        case RewStateRunningWithApi:
            NSLog(@"REW already running with -api");
            break;

        case RewStateNotRunning:
        case RewStateRunningWithoutApi: {
            // -n opens a new instance even if a non-api REW is already running. Who cares.
            // If this isn't the beta build, REW errors on the unknown arg. Ignored for now.
            NSLog(@"launching REW with -api");
            NSError *error = nil;
            NSTask *task = [[NSTask alloc] init];
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
            task.arguments = @[@"-na", @"REW.app", @"--args", @"-api"];
            if (![task launchAndReturnError:&error]) {
                NSLog(@"failed to launch REW: %@", error);
            }
            break;
        }
    }
}

// Real minimize (not Cmd+H hide) goes through the Accessibility API, so the app
// needs to be granted Accessibility access in System Settings > Privacy & Security.
- (void)minimizeRewWindowsAttempt:(NSInteger)attempt {
    if (attempt >= 10) {
        NSLog(@"gave up minimizing REW windows");
        return;
    }

    BOOL done = NO;

    if ([self currentRewState] == RewStateRunningWithApi) {
        AXUIElementRef appElement = AXUIElementCreateApplication(self.rewApiPid);
        CFArrayRef windows = NULL;
        AXError err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute,
                                                    (CFTypeRef *)&windows);
        if (err == kAXErrorSuccess && windows && CFArrayGetCount(windows) > 0) {
            done = YES;
            for (CFIndex i = 0; i < CFArrayGetCount(windows); i++) {
                AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
                AXError setErr = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute,
                                                              kCFBooleanTrue);
                if (setErr != kAXErrorSuccess) {
                    NSLog(@"failed to minimize REW window: AXError %d", (int)setErr);
                }
            }
        } else if (err != kAXErrorSuccess) {
            NSLog(@"couldn't read REW windows: AXError %d", (int)err);
        }
        if (windows) CFRelease(windows);
        CFRelease(appElement);
    }

    if (done) return;

    // Window may not exist yet; try again shortly.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self minimizeRewWindowsAttempt:attempt + 1];
    });
}

// Full start sequence: set the input device, open the SPL meter, configure it, start it.
// Each step retries from the top on failure (REW may still be starting up).
- (void)startRewMeter {
    self.meterStartAttempts = 0;
    [self runStartSequence:++self.sequenceGeneration];
}

- (void)retryStartSequence:(NSUInteger)generation reason:(NSString *)reason {
    if (generation != self.sequenceGeneration) return;

    if (++self.meterStartAttempts >= kMaxMeterStartAttempts) {
        NSLog(@"start sequence failed (%@), giving up", reason);
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMeterStartRetryDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == self.sequenceGeneration) [self runStartSequence:generation];
    });
}

// REW applies an input-device change asynchronously (the POST returns 202). Starting the meter
// before the swap finishes gets the Start undone, so wait until REW reports the new device.
- (void)waitForRewInputDevice:(NSString *)device attempts:(NSInteger)attempts
                   generation:(NSUInteger)generation completion:(void (^)(void))completion {
    NSURL *url = [NSURL URLWithString:[kRewBase stringByAppendingString:@"/audio/java/input-device"]];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *current = [json isKindOfClass:[NSDictionary class]] ? json[@"device"] : nil;
        BOOL matches = [current isKindOfClass:[NSString class]]
            && [Trim(current) isEqualToString:Trim(device)];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.sequenceGeneration) return;
            if (matches || attempts <= 1) {
                if (!matches) NSLog(@"REW input still %@, wanted %@; continuing anyway", current, device);
                completion();
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self waitForRewInputDevice:device attempts:attempts - 1
                                 generation:generation completion:completion];
            });
        });
    }] resume];
}

// REW has no meter status endpoint; /levels reads -180 or NaN while the meter isn't running.
// After Start, check it's really producing levels and press Start again if it isn't.
- (void)verifyMeterRunning:(NSUInteger)generation attempt:(NSInteger)attempt {
    NSURL *url = [NSURL URLWithString:kRewUrl];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL live = ParseSplLevel(data, NULL);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.sequenceGeneration || live) return;

            if (attempt >= 6) {
                NSLog(@"meter still not reading after %ld tries", (long)attempt);
                return;
            }

            // REW sometimes fails to open the mic and only recovers when the device is
            // selected again (same as picking it by hand in REW), so do that on later tries.
            BOOL reselect = (attempt == 2 || attempt == 4);
            NSLog(@"meter not running yet, %@ (%ld)",
                  reselect ? @"reselecting the input device" : @"pressing Start again",
                  (long)(attempt + 1));

            void (^pressStart)(void) = ^{
                [self sendRewCommand:@"Start" completion:^(BOOL ok) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        [self verifyMeterRunning:generation attempt:attempt + 1];
                    });
                }];
            };

            if (!reselect) { pressStart(); return; }

            [self applyInputDeviceWithCompletion:^(BOOL ok) {
                if (generation != self.sequenceGeneration) return;
                [self waitForRewInputDevice:self.wantedInput attempts:15 generation:generation
                                 completion:pressStart];
            }];
        });
    }] resume];
}

- (void)runStartSequence:(NSUInteger)generation {
    [self applyInputDeviceWithCompletion:^(BOOL ok) {
        if (generation != self.sequenceGeneration) return;
        if (!ok) { [self retryStartSequence:generation reason:@"input device"]; return; }

        // The device may have been resolved just now; make sure it's actually connected.
        if (![self wantedInputIsPresent]) { [self showNoMic]; return; }

        [self waitForRewInputDevice:self.wantedInput attempts:15 generation:generation completion:^{
        [self sendRewCommand:@"Open" completion:^(BOOL ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.sequenceGeneration) return;
                if (!ok) { [self retryStartSequence:generation reason:@"open"]; return; }

                [self sendRewConfigurationWithCompletion:^(BOOL ok) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (generation != self.sequenceGeneration) return;
                        if (!ok) { [self retryStartSequence:generation reason:@"configuration"]; return; }

                        [self sendRewCommand:@"Start" completion:^(BOOL ok) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (generation != self.sequenceGeneration) return;
                                if (!ok) { [self retryStartSequence:generation reason:@"start"]; return; }

                                self.meterStartAttempts = 0;
                                [self minimizeRewWindowsAttempt:0];
                                [self verifyMeterRunning:generation attempt:0];
                            });
                        }];
                    });
                }];
            });
        }];
        }];
    }];
}

- (void)sendRewConfigurationWithCompletion:(void (^)(BOOL ok))completion {
    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:4735/spl-meter/1/configuration"];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"showSPL": @YES,
        @"showLeq": @YES,
        @"showSEL": @NO,

        @"splWeighting": @"C",
        @"leqWeighting": @"C",
        @"selWeighting": @"C",

        @"filter": @"Slow",

        @"highPassActive": @NO,
        @"rollingLeqActive": @NO,
        @"rollingLeqMinutes": @1
    };

    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body
                                                       options:0
                                                         error:&jsonError];

    if (jsonError) {
        completion(NO);
        NSLog(@"configure input device json error");
        return;
    }

    if (!bodyData) {
        completion(NO);
        NSLog(@"configure input device returned no body");
        return;
    }

    request.HTTPBody = bodyData;

    NSURLSessionDataTask *task =
    [[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:
     ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"Failed while configuring meter: %@", error);
            completion(NO);
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        BOOL ok = http.statusCode >= 200 && http.statusCode < 300;

        if (!ok) {
            NSLog(@"Failed while configuring meter: HTTP %ld", (long)http.statusCode);
        }

        completion(ok);
    }];

    [task resume];
}

- (void)sendRewCommand:(NSString *)command completion:(void (^)(BOOL ok))completion {
    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:4735/spl-meter/1/command"];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{ @"command": command };

    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body
                                                       options:0
                                                         error:&jsonError];

    if (jsonError) {
        completion(NO);
        NSLog(@"configure input device json error");
        return;
    }

    if (!bodyData) {
        completion(NO);
        NSLog(@"configure input device returned no body");
        return;
    }

    request.HTTPBody = bodyData;

    NSURLSessionDataTask *task =
    [[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"Failed sending meter command: %@", error);
                completion(NO);
                return;
            }

            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            BOOL ok = http.statusCode >= 200 && http.statusCode < 300;

            if (!ok) {
                NSLog(@"Failed sending meter command: HTTP %ld",
                      (long)http.statusCode);
            }

            completion(ok);
        }
    ];

    [task resume];
}

- (void)updateSpl {
    NSURL *url = [NSURL URLWithString:kRewUrl];

    NSURLSessionDataTask *task =
    [[NSURLSession sharedSession] dataTaskWithURL:url
                                completionHandler:
     ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (error || !data || status != 200) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setMeterTitle:@"REWAPI?"];
            });
            return;
        }

        // Not live (NaN, REW's -180 floor, missing) means the meter isn't reading anything:
        // wrong/stuck input, bad sample rate, meter stopped. Say so instead of going blank.
        double spl = 0;
        NSString *title = ParseSplLevel(data, &spl)
            ? [NSString stringWithFormat:@"%.0f dBC", spl + kOffsetDb]
            : @"-- dBC";

        dispatch_async(dispatch_get_main_queue(), ^{
            [self setMeterTitle:title];
        });
    }];

    [task resume];
}

- (void)startSPLPolling {
    if (self.timer) return;

    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                  target:self
                                                selector:@selector(updateSpl)
                                                userInfo:nil
                                                 repeats:YES];
    [self updateSpl];
}

- (void)stopSPLPolling {
    [self.timer invalidate];
    self.timer = nil;
}

// In-flight meter requests can finish after the mic is gone; don't let them
// overwrite "NO MIC".
- (void)setMeterTitle:(NSString *)title {
    if (!self.micPresent) return;
    self.statusItem.button.title = title;
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];

        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;

        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }

    return 0;
}

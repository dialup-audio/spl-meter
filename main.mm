#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>

static NSString * const kRepo    = @"dialup-audio/spl-meter";
static NSString * const kSiteURL = @"https://dialup.audio";
// Links go through dialup.audio (which redirects to GitHub for now) so they can be
// repointed later without shipping a new version.
static NSString * const kHelpURL     = @"https://dialup.audio/spl-meter";
static NSString * const kIssuesURL   = @"https://dialup.audio/spl-meter/issues";
static NSString * const kCheckOnStartupKey = @"checkUpdatesOnStartup";

// Unset until the user answers the first-launch question.
static BOOL CheckOnStartupAnswered() {
    return [[NSUserDefaults standardUserDefaults] objectForKey:kCheckOnStartupKey] != nil;
}
static BOOL CheckOnStartup() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kCheckOnStartupKey];
}


// The mic REW should measure with. Stored in NSUserDefaults:
//   defaults read audio.dialup.spl-meter inputDevice
static NSString * const kInputDeviceKey = @"inputDevice";
// Meter settings, in NSUserDefaults too (defaults: C-weighted, Slow). REW accepts A/C/Z and Fast/Slow.
// Added to every reading before it's displayed (REW's API has no live meter offset).
static NSString * const kOffsetKey = @"splOffset";
static NSString * const kWeightingKey = @"weighting";
static NSString * const kFilterKey    = @"averaging";

// REW's API port (Settings > API in REW; the app has to match) and whether REW is launched
// headless. Both in NSUserDefaults: apiPort, headless.
static NSString * const kPortKey     = @"apiPort";
static NSString * const kHeadlessKey = @"headless";
static const NSInteger kDefaultApiPort = 4735;

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
@property (copy) NSString *weighting;     // "A", "C" or "Z"
@property (copy) NSString *filter;        // "Fast" or "Slow"
@property (strong) NSMenuItem *weightingItem;
@property (strong) NSMenuItem *filterItem;
@property double splOffset;               // dB, applied to the displayed level
@property (strong) NSMenuItem *offsetItem;
@property (strong) NSMenuItem *startupCheckItem;
@property (strong) NSMenuItem *offsetClearItem;
@property (copy) NSArray<NSString *> *rewInputDevices;
@property NSInteger apiPort;
@property BOOL headless;                  // launch REW with -nogui
@property BOOL noApi;                     // REW is running but its API isn't reachable
@property (strong) NSTimer *apiWatchTimer;
@property BOOL startedHeadlessRew;        // we launched a headless REW, so we shut it down on quit
@property (strong) NSMenuItem *headlessItem;
@property (strong) NSMenuItem *portItem;
@end

static const NSInteger kMaxMeterStartAttempts = 30;
static const NSTimeInterval kMeterStartRetryDelay = 2.0;

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"SPL Meter launched");
    self.statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:48];

    self.statusItem.button.title = @"--.-";

    NSMenu *menu = [[NSMenu alloc] init];

    menu.delegate = self;

    self.inputItem = [[NSMenuItem alloc] initWithTitle:@"Input: …" action:nil keyEquivalent:@""];
    [menu addItem:self.inputItem];

    self.inputMenu = [[NSMenu alloc] init];
    NSMenuItem *inputParent = [[NSMenuItem alloc] initWithTitle:@"Input device"
                                                         action:nil keyEquivalent:@""];
    inputParent.submenu = self.inputMenu;
    [menu addItem:inputParent];

    [menu addItem:[NSMenuItem separatorItem]];

    // Weighting and averaging apply to the meter immediately.
    NSDictionary<NSString *, NSArray *> *options = @{
        @"weighting": @[@[@"A", @"A-weighted"], @[@"C", @"C-weighted"], @[@"Z", @"Z (unweighted)"]],
        @"filter":    @[@[@"Fast", @"Fast (125 ms)"], @[@"Slow", @"Slow (1 s)"]],
    };
    for (NSString *kind in @[@"weighting", @"filter"]) {
        NSMenu *sub = [[NSMenu alloc] init];
        for (NSArray *opt in options[kind]) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:opt[1]
                                                          action:@selector(selectMeterOption:)
                                                   keyEquivalent:@""];
            item.target = self;
            item.representedObject = @{ @"kind": kind, @"value": opt[0] };
            [sub addItem:item];
        }
        NSMenuItem *parent = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
        parent.submenu = sub;
        [menu addItem:parent];
        if ([kind isEqualToString:@"weighting"]) self.weightingItem = parent; else self.filterItem = parent;
    }

    NSMenu *offsetMenu = [[NSMenu alloc] init];
    offsetMenu.autoenablesItems = NO;
    NSMenuItem *change = [[NSMenuItem alloc] initWithTitle:@"Change offset…"
                                                    action:@selector(editSplOffset:)
                                             keyEquivalent:@""];
    change.target = self;
    [offsetMenu addItem:change];
    self.offsetClearItem = [[NSMenuItem alloc] initWithTitle:@"Clear offset"
                                                      action:@selector(clearSplOffset:)
                                               keyEquivalent:@""];
    self.offsetClearItem.target = self;
    [offsetMenu addItem:self.offsetClearItem];
    self.offsetItem = [[NSMenuItem alloc] initWithTitle:@"SPL offset" action:nil keyEquivalent:@""];
    self.offsetItem.submenu = offsetMenu;
    [menu addItem:self.offsetItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // REW connection settings.
    NSMenu *rewMenu = [[NSMenu alloc] init];
    self.headlessItem = [[NSMenuItem alloc] initWithTitle:@"Run REW headless"
                                                   action:@selector(toggleHeadless:)
                                            keyEquivalent:@""];
    self.headlessItem.target = self;
    self.headlessItem.toolTip = @"Applies the next time this app starts REW.";
    [rewMenu addItem:self.headlessItem];

    self.portItem = [[NSMenuItem alloc] initWithTitle:@"API port…"
                                               action:@selector(editApiPort:)
                                        keyEquivalent:@""];
    self.portItem.target = self;
    [rewMenu addItem:self.portItem];
    [rewMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *reconnect = [[NSMenuItem alloc] initWithTitle:@"Reconnect to REW"
                                                       action:@selector(reconnect:)
                                                keyEquivalent:@""];
    reconnect.target = self;
    [rewMenu addItem:reconnect];

    NSMenuItem *rewParent = [[NSMenuItem alloc] initWithTitle:@"REW" action:nil keyEquivalent:@""];
    rewParent.submenu = rewMenu;
    [menu addItem:rewParent];

    [menu addItem:[NSMenuItem separatorItem]];

    // App submenu: about, updates, and links to the project.
    NSMenu *appMenu = [[NSMenu alloc] init];
    NSMenuItem *(^add)(NSString *, SEL) = ^NSMenuItem *(NSString *title, SEL action) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
        item.target = self;
        [appMenu addItem:item];
        return item;
    };
    add([NSString stringWithFormat:@"About %@", self.appName], @selector(showAbout:));
    [appMenu addItem:[NSMenuItem separatorItem]];
    add(@"Check for Updates Now", @selector(checkForUpdates:));
    self.startupCheckItem = add(@"Check for Updates on Startup", @selector(toggleUpdateOnStartup:));
    self.startupCheckItem.state = CheckOnStartup()
        ? NSControlStateValueOn : NSControlStateValueOff;
    [appMenu addItem:[NSMenuItem separatorItem]];
    add(@"Help (web)", @selector(openHelp:));
    add(@"Report an Issue (web)", @selector(openIssues:));
    NSMenuItem *appParent = [[NSMenuItem alloc] initWithTitle:self.appName action:nil keyEquivalent:@""];
    appParent.submenu = appMenu;
    [menu addItem:appParent];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit"
               action:@selector(terminate:)
        keyEquivalent:@"q"];

    [menu addItem:quit];
    self.statusItem.menu = menu;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.wantedInput = [defaults stringForKey:kInputDeviceKey];
    self.weighting = [@[@"A", @"C", @"Z"] containsObject:[defaults stringForKey:kWeightingKey]]
        ? [defaults stringForKey:kWeightingKey] : @"C";
    self.filter = [@[@"Fast", @"Slow"] containsObject:[defaults stringForKey:kFilterKey]]
        ? [defaults stringForKey:kFilterKey] : @"Slow";
    self.apiPort = [defaults integerForKey:kPortKey] > 0 ? [defaults integerForKey:kPortKey] : kDefaultApiPort;
    self.headless = [defaults objectForKey:kHeadlessKey] ? [defaults boolForKey:kHeadlessKey] : YES;
    self.splOffset = [defaults doubleForKey:kOffsetKey];
    [self updateMeterOptionMenus];
    [self updateRewMenu];
    [self updateInputMenuTitles];

    // Fires when any audio device is plugged in or removed.
    AudioObjectPropertyAddress devicesAddr = { kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &devicesAddr,
                                        dispatch_get_main_queue(),
                                        ^(UInt32 n, const AudioObjectPropertyAddress *a) {
        [self evaluateMicPresence];
    });

    [self connectToRew];
    if (!CheckOnStartupAnswered()) {
        // First launch: ask before touching the network. Deferred so the menubar item is up first.
        dispatch_async(dispatch_get_main_queue(), ^{ [self askAboutStartupUpdateCheck]; });
    } else if (CheckOnStartup()) {
        [self checkForUpdatesSilently:YES];
    }
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

- (void)updateMeterOptionMenus {
    self.weightingItem.title = [NSString stringWithFormat:@"Weighting: %@", self.weighting];
    self.filterItem.title = [NSString stringWithFormat:@"Averaging: %@", self.filter];
    self.offsetItem.title = [NSString stringWithFormat:self.splOffset == 0 ? @"SPL offset: %g dB" : @"SPL offset: %+g dB",
                                                       self.splOffset];
    self.offsetClearItem.hidden = self.splOffset == 0;

    for (NSMenuItem *parent in @[self.weightingItem, self.filterItem]) {
        for (NSMenuItem *item in parent.submenu.itemArray) {
            NSDictionary *info = item.representedObject;
            NSString *current = [info[@"kind"] isEqualToString:@"weighting"] ? self.weighting : self.filter;
            item.state = [info[@"value"] isEqualToString:current] ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
}

- (void)editSplOffset:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"SPL offset";
    alert.informativeText = @"Added to every reading in the menubar. Use a negative number to read lower, e.g. -3.2. This is useful for monitoring situations where you're forced to mount the microphone outside of the listening position. Even a few feet off can be surprisingly accurate, especially with dBC slow.";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 120, 24)];
    field.stringValue = [NSString stringWithFormat:@"%g", self.splOffset];
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert.window setInitialFirstResponder:field];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSString *text = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    double value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:text];
    BOOL valid = text.length == 0 || ([scanner scanDouble:&value] && scanner.isAtEnd && fabs(value) <= 100);
    if (!valid) {
        NSAlert *bad = [[NSAlert alloc] init];
        bad.messageText = @"That isn't a valid offset";
        bad.informativeText = @"Enter a number between -100 and 100.";
        [bad runModal];
        return;
    }

    self.splOffset = value;
    if (value == 0) [[NSUserDefaults standardUserDefaults] removeObjectForKey:kOffsetKey];
    else [[NSUserDefaults standardUserDefaults] setDouble:value forKey:kOffsetKey];
    [self updateMeterOptionMenus];
}

- (void)clearSplOffset:(id)sender {
    self.splOffset = 0;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kOffsetKey];
    [self updateMeterOptionMenus];
}

- (void)selectMeterOption:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    NSString *key = [info[@"kind"] isEqualToString:@"weighting"] ? kWeightingKey : kFilterKey;
    if ([info[@"kind"] isEqualToString:@"weighting"]) self.weighting = info[@"value"];
    else self.filter = info[@"value"];

    [[NSUserDefaults standardUserDefaults] setObject:info[@"value"] forKey:key];
    [self updateMeterOptionMenus];

    // REW applies configuration changes while the meter is running; no restart needed.
    if (self.micPresent) {
        [self sendRewConfigurationWithCompletion:^(BOOL ok) {
            if (!ok) NSLog(@"failed applying meter settings");
        }];
    }
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
    if (self.noApi) return;   // nothing to restart until REW's API is reachable
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
    if (self.noApi) {
        self.inputItem.title = @"REW is running without its API";
    } else {
        self.inputItem.title = self.wantedInput
            ? [NSString stringWithFormat:@"Input: %@", Trim(self.wantedInput)]
            : @"Input: (none)";
    }

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
    NSURL *url = [NSURL URLWithString:[[self rewBase] stringByAppendingString:@"/audio/java/input-devices"]];
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
    NSURL *url = [NSURL URLWithString:[[self rewBase] stringByAppendingString:@"/audio/java/input-device"]];

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
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: @"SPL Meter";
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

#pragma mark - Quitting

// A headless REW has no window to close, so if we started one, shut it down on the way out.
// A REW that was already running (or that we started with its window) is left alone.
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (!self.startedHeadlessRew) return NSTerminateNow;

    NSURL *url = [NSURL URLWithString:[[self rewBase] stringByAppendingString:@"/application/command"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 3;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"command": @"Shutdown" }
                                                       options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (error || status < 200 || status >= 300) {
            NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            NSLog(@"REW shutdown failed: HTTP %ld %@ %@", (long)status, error, body);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp replyToApplicationShouldTerminate:YES];
        });
    }] resume];

    return NSTerminateLater;   // wait for REW to acknowledge (or time out) before exiting
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
    [self checkForUpdatesSilently:NO];
}

- (void)setCheckOnStartup:(BOOL)on {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kCheckOnStartupKey];
    self.startupCheckItem.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleUpdateOnStartup:(NSMenuItem *)sender {
    [self setCheckOnStartup:sender.state != NSControlStateValueOn];
}

// Shown once, on first launch. The app makes no network request until the user says yes.
- (void)askAboutStartupUpdateCheck {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Check for updates on startup?";
    alert.informativeText = @"Nothing is downloaded or installed automatically. If an update is available, you'll be prompted with a link to the latest release, where you can review the changes before downloading and installing.\n\nYou can change this any time from the app's menu.";
    [alert addButtonWithTitle:@"Yes"];
    [alert addButtonWithTitle:@"No"];
    [NSApp activateIgnoringOtherApps:YES];
    BOOL yes = [alert runModal] == NSAlertFirstButtonReturn;
    [self setCheckOnStartup:yes];
    if (yes) [self checkForUpdatesSilently:YES];   // we're still technically starting up
}

- (void)openHelp:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:kHelpURL]];
}

- (void)openIssues:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:kIssuesURL]];
}

// With silent=YES (the startup check) it says nothing unless a newer version exists.
- (void)checkForUpdatesSilently:(BOOL)silent {
    NSURL *url = [NSURL URLWithString:
        [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", kRepo]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15;
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"dialup-audio-spl-meter" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        id json = (!error && data && status == 200)
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *tag = [json isKindOfClass:[NSDictionary class]] ? json[@"tag_name"] : nil;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![tag isKindOfClass:[NSString class]]) {
                NSLog(@"update check failed (status %ld): %@", (long)status, error);
                if (silent) return;
                [self alert:@"Couldn't check for updates"
                       info:@"Check your internet connection and try again."
                downloadURL:nil];
                return;
            }

            NSString *latest = [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;
            BOOL newer = [latest compare:[self appVersion] options:NSNumericSearch]
                         == NSOrderedDescending;

            if (!newer) {
                if (silent) return;
                [self alert:@"You're up to date"
                       info:[NSString stringWithFormat:@"%@ %@ is the latest version.",
                             [self appName], [self appVersion]]
                downloadURL:nil];
                return;
            }

            [self alert:[NSString stringWithFormat:@"Version %@ is available", latest]
                   info:[NSString stringWithFormat:@"You have version %@.", [self appVersion]]
            downloadURL:kHelpURL];
        });
    }];
    [task resume];
}

#pragma mark - Connecting to REW

- (NSString *)rewBase {
    return [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)self.apiPort];
}

- (void)updateRewMenu {
    self.headlessItem.state = self.headless ? NSControlStateValueOn : NSControlStateValueOff;
    self.portItem.title = [NSString stringWithFormat:@"API port: %ld…", (long)self.apiPort];
}

// Process ids of every running REW (it might not have its API on).
- (NSArray<NSNumber *> *)rewProcessIDs {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/ps"];
    task.arguments = @[@"-A", @"-o", @"pid=,command="];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"failed to run ps: %@", error);
        return @[];
    }

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        if ([line rangeOfString:@"REW.app/Contents/MacOS/"].location == NSNotFound) continue;
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        pid_t pid = (pid_t)[trimmed intValue];
        if (pid > 0) [pids addObject:@(pid)];
    }
    return pids;
}

- (BOOL)rewIsRunning {
    return [self rewProcessIDs].count > 0;
}

// Asks REW to quit (so it can prompt about unsaved measurements), waits for it to exit
// (REW is slow to close), then starts it again with the API on.
- (void)restartRewWithApi {
    for (NSNumber *pid in [self rewProcessIDs]) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue];
        if (app) [app terminate];
        else kill(pid.intValue, SIGTERM);
    }
    self.statusItem.button.title = @"REW…";
    [self relaunchRewWhenGone:90];
}

- (void)relaunchRewWhenGone:(NSInteger)secondsLeft {
    if (![self rewIsRunning]) {
        [self launchRew];   // the watch timer notices when the API comes up
        return;
    }

    if (secondsLeft <= 0) {
        NSLog(@"REW didn't quit");
        self.statusItem.button.title = @"NO API";
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"REW didn't quit";
        alert.informativeText = @"Quit REW yourself, then choose REW → Reconnect to REW.";
        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self relaunchRewWhenGone:secondsLeft - 1];
    });
}

- (void)launchRew {
    // -nogui runs REW headless so there's no window to get in the way. -n always opens a new
    // instance. If REW is older than the beta that added these flags, it errors on them.
    NSMutableArray<NSString *> *args = [@[@"-na", @"REW.app", @"--args", @"-api"] mutableCopy];
    if (self.headless) [args addObject:@"-nogui"];
    NSLog(@"launching REW: open %@", [args componentsJoinedByString:@" "]);
    self.startedHeadlessRew = self.headless;

    NSError *error = nil;
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = args;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"failed to launch REW: %@", error);
    }
}

// Does something answer on REW's API port?
- (void)probeApi:(void (^)(BOOL up))completion {
    NSURL *url = [NSURL URLWithString:[[self rewBase] stringByAppendingString:@"/audio/java/input-device"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 2;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL up = !error && [(NSHTTPURLResponse *)response statusCode] == 200;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(up); });
    }] resume];
}

// Works out what state REW is in and gets metering going:
//   API answers          -> use it
//   REW isn't running    -> launch it with the API on, then wait for it to come up
//   REW without its API  -> say so, and keep watching in case that changes
- (void)connectToRew {
    [self.apiWatchTimer invalidate];
    self.apiWatchTimer = nil;

    [self probeApi:^(BOOL up) {
        if (up) { [self beginMetering]; return; }

        if (![self rewIsRunning]) {
            [self launchRew];
            [self beginMetering];   // the start sequence retries until the API is up
            return;
        }

        [self showNoApi];
    }];
}

- (void)beginMetering {
    self.noApi = NO;
    [self updateInputMenuTitles];

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

- (void)showNoApi {
    self.noApi = YES;
    self.micPresent = NO;
    self.sequenceGeneration++;
    [self stopSPLPolling];
    self.statusItem.button.title = @"NO API";
    [self updateInputMenuTitles];

    // If the user turns the API on (or restarts REW with it), pick up from there.
    self.apiWatchTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES
                                                           block:^(NSTimer *timer) {
        [self probeApi:^(BOOL up) {
            if (up && self.noApi) {
                [self.apiWatchTimer invalidate];
                self.apiWatchTimer = nil;
                [self beginMetering];
            }
        }];
    }];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"REW is running without its API";
    alert.informativeText = [NSString stringWithFormat:
        @"This app can quit REW and start it again with the API on. REW will ask to save anything "
        @"unsaved first.\n\n"
        @"To avoid this next time, turn on Settings → API → “Start the API when REW starts” in REW.\n\n"
        @"Looking for the API on port %ld. If yours is different, set it under REW → API port.",
        (long)self.apiPort];
    [alert addButtonWithTitle:@"Quit REW and Restart With API"];
    [alert addButtonWithTitle:@"Not Now"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [self restartRewWithApi];
    }
}

- (void)reconnect:(id)sender {
    [self connectToRew];
}

- (void)toggleHeadless:(id)sender {
    self.headless = !self.headless;
    [[NSUserDefaults standardUserDefaults] setBool:self.headless forKey:kHeadlessKey];
    [self updateRewMenu];
}

- (void)editApiPort:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"REW API port";
    alert.informativeText = @"The default is 4735.";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 120, 24)];
    field.stringValue = [NSString stringWithFormat:@"%ld", (long)self.apiPort];
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert.window setInitialFirstResponder:field];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSInteger port = field.integerValue;
    if (port < 1 || port > 65535) {
        NSAlert *bad = [[NSAlert alloc] init];
        bad.messageText = @"That isn't a valid port";
        bad.informativeText = @"Enter a number from 1 to 65535.";
        [bad runModal];
        return;
    }

    self.apiPort = port;
    [[NSUserDefaults standardUserDefaults] setInteger:port forKey:kPortKey];
    [self updateRewMenu];
    [self connectToRew];
}

// Full start sequence: set the input device, configure the SPL meter, start it.
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
    NSURL *url = [NSURL URLWithString:[[self rewBase] stringByAppendingString:@"/audio/java/input-device"]];
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
    NSURL *url = [NSURL URLWithString:[[self rewBase] stringByAppendingString:@"/spl-meter/1/levels"]];
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
        [self sendRewConfigurationWithCompletion:^(BOOL ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.sequenceGeneration) return;
                if (!ok) { [self retryStartSequence:generation reason:@"configuration"]; return; }

                [self sendRewCommand:@"Start" completion:^(BOOL ok) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (generation != self.sequenceGeneration) return;
                        if (!ok) { [self retryStartSequence:generation reason:@"start"]; return; }

                        self.meterStartAttempts = 0;
                        [self verifyMeterRunning:generation attempt:0];
                    });
                }];
            });
        }];
        }];
    }];
}

- (void)sendRewConfigurationWithCompletion:(void (^)(BOOL ok))completion {
    NSURL *url = [NSURL URLWithString:[[self rewBase] stringByAppendingString:@"/spl-meter/1/configuration"]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"showSPL": @YES,
        @"showLeq": @YES,
        @"showSEL": @NO,

        @"splWeighting": self.weighting,
        @"leqWeighting": self.weighting,
        @"selWeighting": self.weighting,

        @"filter": self.filter,

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
    NSURL *url = [NSURL URLWithString:[[self rewBase] stringByAppendingString:@"/spl-meter/1/command"]];

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
    NSURL *url = [NSURL URLWithString:[[self rewBase] stringByAppendingString:@"/spl-meter/1/levels"]];

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
            ? [NSString stringWithFormat:@"%.0f dB%@", spl + self.splOffset, self.weighting]
            : [NSString stringWithFormat:@"-- dB%@", self.weighting];

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

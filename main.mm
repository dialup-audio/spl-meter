#import <Cocoa/Cocoa.h>

static NSString * const kRewUrl =
    @"http://127.0.0.1:4735/spl-meter/1/levels";

static double kOffsetDb = 0; // rack reads hotter than LP
static NSString * const kWantedInputDevice = @"Umik-1  Gain: 18dB  ";

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSTimer *timer;
@property (strong) NSTimer *inputDeviceUpdateTimer;
@property double smoothedSpl;
@property BOOL hasValue;
@property BOOL inputDeviceOk;
@property NSInteger meterStartAttempts;
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

    [menu addItemWithTitle:@"REW SPL"
                    action:nil
             keyEquivalent:@""];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit"
               action:@selector(terminate:)
        keyEquivalent:@"q"];

    [menu addItem:quit];
    self.statusItem.menu = menu;

    //dispatch_async(dispatch_get_main_queue(), ^{
    //    self.inputDeviceUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
    //                                                  target:self
    //                                                selector:@selector(checkInputDevice)
    //                                                userInfo:nil
    //                                                 repeats:YES];

    //    [self checkInputDevice];
    //});

    // Prompts for Accessibility access (needed to minimize REW's windows) if not yet granted.
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES });

    [self ensureRewRunningWithApi];
    [self startRewMeter];
    [self startSPLPolling];
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

- (void)startRewMeter {
    [self sendRewCommand:@"Open" completion:^(BOOL ok) {
        if (!ok) {
            // REW may still be starting up and its API not listening yet; retry.
            if (++self.meterStartAttempts < kMaxMeterStartAttempts) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(kMeterStartRetryDelay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self startRewMeter];
                });
            } else {
                NSLog(@"failed open, giving up");
            }
            return;
        }
        self.meterStartAttempts = 0;

        [self sendRewConfigurationWithCompletion:^(BOOL ok) {
            if (!ok) {
                NSLog(@"failed configuration");
                return;
            }

            [self sendRewCommand:@"Start" completion:^(BOOL ok) {
                if (!ok) { 
                    NSLog(@"failed start");
                    return;
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    [self minimizeRewWindowsAttempt:0];
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

- (void)checkInputDevice {
    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:4735/audio/java/input-device"];

    NSURLSessionDataTask *task =
    [[NSURLSession sharedSession] dataTaskWithURL:url
                                completionHandler:
     ^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL deviceMatches = NO;

        if (!error && data) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

            if ([json isKindOfClass:[NSDictionary class]]) {
                NSString *device = ((NSDictionary *)json)[@"device"];
                if ([device isKindOfClass:[NSString class]]) {
                    deviceMatches = [device isEqualToString:kWantedInputDevice];
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (deviceMatches) {
                self.inputDeviceOk = YES;
                [self startRewMeter];
                [self startSPLPolling];
            } else {
                self.inputDeviceOk = NO;
                [self stopSPLPolling];
                [self updateInputDevice]; // POST only when needed
            }
        });
    }];

    [task resume];
}

- (void)updateInputDevice {
    NSLog(@"updating input device");

    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:4735/audio/java/input-device"];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{ @"device": kWantedInputDevice };

    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bodyData) {
        NSLog(@"input device json failed");
        return;
    }

    request.HTTPBody = bodyData;

    NSURLSessionDataTask *task =
    [[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:
     ^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ok = NO;

        if (!error && data) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

            if ([json isKindOfClass:[NSDictionary class]]) {
                NSString *message = ((NSDictionary *)json)[@"message"];
                NSLog(@"REW message: %@", message);

                if ([message isKindOfClass:[NSString class]]) {
                    ok = [message containsString:kWantedInputDevice];
                }
            }
        }
    }];

    [task resume];
}

- (void)updateSpl {
    NSURL *url = [NSURL URLWithString:kRewUrl];

    NSURLSessionDataTask *task =
    [[NSURLSession sharedSession] dataTaskWithURL:url
                                completionHandler:
     ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusItem.button.title = @"REWAPI?";
            });
            return;
        }

        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data
                                                  options:0
                                                    error:&jsonError];

        if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusItem.button.title = @"";
            });
            return;
        }

        NSDictionary *dict = (NSDictionary *)json;

        NSString *weighting = [dict[@"splWeighting"] lowercaseString];
        if (![weighting isKindOfClass:[NSString class]]) {
            weighting = @"?";
        }
        

        // TODO: adjust this key after seeing REW's actual JSON.
        NSNumber *splNumber = dict[@"spl"];

        if (!splNumber) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusItem.button.title = @"";
            });
            return;
        }

        double spl = [splNumber doubleValue] + kOffsetDb;

        // gentle smoothing so typing/key clicks don't spaz it out
        //if (!self.hasValue) {
        //    self.smoothedSpl = spl;
        //    self.hasValue = YES;
        //} else {
        //    self.smoothedSpl = self.smoothedSpl * 0.8 + spl * 0.2;
        //}

        //NSString *title = [NSString stringWithFormat:@"%.0f db%@", self.smoothedSpl, weighting];
        //NSString *title = [NSString stringWithFormat:@"%.0f%@", self.smoothedSpl, weighting];
        NSString *title = [NSString stringWithFormat:@"%.0f dBC", spl];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusItem.button.title = title;
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

    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusItem.button.title = @"";
    });
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

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h> 
#import <Foundation/NSUserDefaults+Private.h>
#import <AssetsLibrary/AssetsLibrary.h>

// Forward-declare the required MobileCoreServices functions to avoid importing broken headers
#if __cplusplus
extern "C" {
#endif
    extern const CFStringRef kUTTagClassMIMEType;
    CFStringRef UTTypeCopyPreferredTagWithClass(CFStringRef inUTI, CFStringRef inTagClass);
#if __cplusplus
}
#endif

@interface NSTask : NSObject
@property (copy) NSString *launchPath;
@property (copy) NSArray *arguments;
@property (copy) NSDictionary *environment; // Add this line
@property (retain) id standardOutput;
@property (retain) id standardError;
@property (readonly) int terminationStatus;
- (void)launch;
- (void)waitUntilExit;
@end
static NSString * nsDomainString = @"dev.pzurek.flareshare";
static NSString * nsNotificationString = @"dev.pzurek.flareshare/preferences.changed";
static BOOL enabled;

static void notificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSNumber * enabledValue = (NSNumber *)[[NSUserDefaults standardUserDefaults] objectForKey:@"enabled" inDomain:nsDomainString];
    enabled = (enabledValue)? [enabledValue boolValue] : YES;
}

@interface FlareShareActivity : UIActivity <UIAlertViewDelegate>
@property (nonatomic, strong) NSArray *itemsToShare;
@property (nonatomic, strong) NSURL *uploadedURL; 
@end

@implementation FlareShareActivity

- (NSString *)activityType {
    return @"dev.pzurek.flareshare.share";
}

- (NSString *)activityTitle {
    return @"Flare";
}

- (UIImage *)activityImage {
    NSString *imagePath = @"/Library/Application Support/FlareShare/icon.png";
    return [UIImage imageWithContentsOfFile:imagePath];
}

- (BOOL)canPerformWithActivityItems:(NSArray *)activityItems {
    for (id item in activityItems) {
        NSLog(@"[FlareShare] Checking item: %@", item);
        if ([NSStringFromClass([item class]) isEqualToString:@"PLManagedAsset"]) {
            return YES;
        } else if ([item isKindOfClass:[NSURL class]]) {
            NSURL *url = (NSURL *)item;
            if ([url.scheme isEqualToString:@"assets-library"]) {
                return YES;
            }
            if ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"]) {
                return YES;
            }
        }
    }
    return NO;
}

- (void)prepareWithActivityItems:(NSArray *)activityItems {
    self.itemsToShare = activityItems;
}

- (void)performActivity {
    NSLog(@"[FlareShare] Sharing begin...");
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (id item in self.itemsToShare) {
            NSLog(@"[FlareShare] Processing item: %@", item);
            if ([item isKindOfClass:[NSURL class]] && ( [[(NSURL *)item scheme] isEqualToString:@"http"] || [[(NSURL *)item scheme] isEqualToString:@"https"] )) {
                NSURL *url = (NSURL *)item;
                [self shortenURL:url];
            } else if ([item isKindOfClass:[NSURL class]] && [[(NSURL *)item scheme] isEqualToString:@"assets-library"]) {
                ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
                [library assetForURL:(NSURL *)item resultBlock:^(ALAsset *asset) {
                    if (asset) {
                        ALAssetRepresentation *rep = [asset defaultRepresentation];
                        Byte *buffer = (Byte*)malloc(rep.size);
                        NSUInteger bytesRead = [rep getBytes:buffer fromOffset:0.0 length:rep.size error:nil];
                        NSData *fileData = [NSData dataWithBytesNoCopy:buffer length:bytesRead freeWhenDone:YES];
                        // === DYNAMIC MIME TYPE RESOLUTION ===
                        // Grab the Uniform Type Identifier (UTI), e.g., "public.jpeg" or "public.png"
                        NSString *uti = [rep UTI];
                        
                        // Convert the UTI into a standard MIME type, e.g., "image/jpeg" or "image/png"
                        NSString *mimeType = (__bridge_transfer NSString *)UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)uti, kUTTagClassMIMEType);
                        
                        // Fallback mechanism in case the MIME type could not be derived
                        if (!mimeType || mimeType.length == 0) {
                            mimeType = @"application/octet-stream"; 
                        }
                        NSLog(@"[FlareShare] MimeType detected: %@", mimeType);
                        [self uploadData:fileData filename:[rep filename] mimeType:mimeType]; 
                    }
                } failureBlock:^(NSError *error) {
                    [self cleanupAndFinish:NO];
                }];
            }
        }
    });
}

- (void)shortenURL:(NSURL *)url {
    NSString *apiKey = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("apiKey"), CFSTR("dev.pzurek.flareshare"));
    NSString *baseEndpoint = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("apiEndpoint"), CFSTR("dev.pzurek.flareshare"));
    
    NSString *endpoint;
    if (baseEndpoint && baseEndpoint.length > 0) {
        endpoint = [baseEndpoint stringByAppendingString:@"api/urls"];
    } else {
        endpoint = @"https://cdn.fl1nt.dev/api/urls";
        baseEndpoint = @"https://cdn.fl1nt.dev";
    }
    NSLog(@"[FlareShare] Using endpoint: %@", endpoint);
    if (!apiKey) apiKey = @"";
    
    NSString *authHeader = [NSString stringWithFormat:@"Authorization: Bearer %@", apiKey];

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/curl"]; 
    
    [task setArguments:@[@"--tlsv1.2", @"-X", @"POST", 
                         @"-H", authHeader, 
                         @"-H", @"Content-Type: application/json", 
                         @"--data", [NSString stringWithFormat:@"{\"url\": \"%@\"}", url.absoluteString],
                         endpoint]];
    
    // Scrub MobileSubstrate injections from the cURL process
    NSMutableDictionary *cleanEnv = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [cleanEnv removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    [task setEnvironment:cleanEnv];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    NSLog(@"[FlareShare] Launching cURL task...");
    
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        NSLog(@"[FlareShare] NSTask Exception CRASH: %@", exception.reason);
        [self cleanupAndFinish:NO];
        return;
    }
    
    // Read stdout and stderr
    NSData *responseData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
    
    NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
    
    NSLog(@"[FlareShare] cURL Exit Code: %d", [task terminationStatus]);
    if (errorString && errorString.length > 0) {
        NSLog(@"[FlareShare] cURL STDERR: \n%@", errorString);
    }
    
    if (responseData && responseData.length > 0) {
        NSError *error;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&error];
        NSLog(@"[FlareShare] Server Response: %@", json);
        
        NSNumber *successStatus = json[@"success"];
        if ([successStatus boolValue]) {
            NSString *fileShortCodeString = json[@"data"][@"shortCode"]; 
            NSString *fileURLString = [NSString stringWithFormat:@"%@u/%@", baseEndpoint, fileShortCodeString];
            if (fileURLString) {
                self.uploadedURL = [NSURL URLWithString:fileURLString];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Shorten Complete" 
                                                                    message:fileURLString 
                                                                   delegate:self 
                                                          cancelButtonTitle:@"Close" 
                                                          otherButtonTitles:@"Open in Browser", nil];
                    [alert show];
                });
                return; 
            }
        }
    } else {
        NSLog(@"[FlareShare] cURL output was completely empty.");
    }
    
    [self cleanupAndFinish:NO];
} 

- (void)uploadData:(NSData *)fileData filename:(NSString *)filename mimeType:(NSString *)mimeType {
    
    NSString *apiKey = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("apiKey"), CFSTR("dev.pzurek.flareshare"));
    NSString *baseEndpoint = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("apiEndpoint"), CFSTR("dev.pzurek.flareshare"));
    
    NSString *endpoint;
    if (baseEndpoint && baseEndpoint.length > 0) {
        endpoint = [baseEndpoint stringByAppendingString:@"api/file"];
    } else {
        endpoint = @"https://cdn.fl1nt.dev/api/file";
        baseEndpoint = @"https://cdn.fl1nt.dev";
    }
    if (!apiKey) apiKey = @"";

    // Write to the global /var/tmp/ instead of the app sandbox to guarantee cURL can read it
    NSString *tempPath = [NSString stringWithFormat:@"/var/tmp/FlareShare_%@", filename];
    [fileData writeToFile:tempPath atomically:YES];
    
    NSString *authHeader = [NSString stringWithFormat:@"Authorization: Bearer %@", apiKey];
    NSString *typeHeader = [NSString stringWithFormat:@"X-File-Type: %@", mimeType];
    NSString *fileArg = [NSString stringWithFormat:@"file=@%@;type=%@", tempPath, mimeType];
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/curl"]; 
    
    [task setArguments:@[@"--tlsv1.2", @"-X", @"POST", 
                         @"-H", authHeader, 
                         @"-H", typeHeader, 
                         @"-F", fileArg, 
                         endpoint]];
                         
    // Scrub MobileSubstrate injections from the cURL process
    NSMutableDictionary *cleanEnv = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [cleanEnv removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    [task setEnvironment:cleanEnv];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    NSLog(@"[FlareShare] Launching cURL task...");
    
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        NSLog(@"[FlareShare] NSTask Exception CRASH: %@", exception.reason);
        [self cleanupAndFinish:NO];
        return;
    }
    
    // Read stdout and stderr
    NSData *responseData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
    
    NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
    
    NSLog(@"[FlareShare] cURL Exit Code: %d", [task terminationStatus]);
    if (errorString && errorString.length > 0) {
        NSLog(@"[FlareShare] cURL STDERR: \n%@", errorString);
    }
    
    // Clean up the temp file
    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
    
    if (responseData && responseData.length > 0) {
        NSError *error;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&error];
        NSLog(@"[FlareShare] Server Response: %@", json);
        
        NSNumber *successStatus = json[@"success"];
        if ([successStatus boolValue]) {
            NSString *fileURLString = json[@"data"][@"rawUrl"]; 
            
            if (fileURLString) {
                self.uploadedURL = [NSURL URLWithString:fileURLString];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Upload Complete" 
                                                                    message:fileURLString 
                                                                   delegate:self 
                                                          cancelButtonTitle:@"Close" 
                                                          otherButtonTitles:@"Open in Browser", nil];
                    [alert show];
                });
                return; 
            }
        }
    } else {
        NSLog(@"[FlareShare] cURL output was completely empty.");
    }
    
    [self cleanupAndFinish:NO];
} 
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == 1) { 
        [[UIApplication sharedApplication] openURL:self.uploadedURL];
    }
    [self cleanupAndFinish:YES];
}

- (void)cleanupAndFinish:(BOOL)success {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self activityDidFinish:success];
    });
}

@end

%hook UIActivityViewController

- (id)initWithActivityItems:(NSArray *)activityItems applicationActivities:(NSArray *)applicationActivities {
    NSMutableArray *customActivities = applicationActivities ? [applicationActivities mutableCopy] : [NSMutableArray array];
    
    FlareShareActivity *flareActivity = [[FlareShareActivity alloc] init];
    [customActivities addObject:flareActivity];

    return %orig(activityItems, [customActivities copy]);
}

%end

%ctor {
    %init;
    notificationCallback(NULL, NULL, NULL, NULL, NULL);

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), 
        NULL, 
        notificationCallback, 
        (__bridge CFStringRef)nsNotificationString, 
        NULL, 
        CFNotificationSuspensionBehaviorCoalesce
    );
}
// Runtime EDID override for a single, exactly identified external monitor.
// No monitor firmware writes. See README for the staged test/enable workflow.
@import Foundation;
@import CoreGraphics;
@import AppKit;
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <poll.h>
#include <unistd.h>
#include <limits.h>
#include <signal.h>

typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*CreateFunc)(CFAllocatorRef, io_service_t);
typedef IOReturn (*SetFunc)(IOAVServiceRef, uint32_t, CFDataRef);
typedef IOReturn (*CopyFunc)(IOAVServiceRef, CFDataRef *);
static CreateFunc createService;
static SetFunc setEDID;
static CopyFunc copyEDID;
static NSData *targetEDID;
static BOOL pending;

static NSString *installDir(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@".config/edid-override"]; }
static NSString *installedProfile(void) { return [installDir() stringByAppendingPathComponent:@"edid.bin"]; }
static NSString *approvalPath(void) { return [installDir() stringByAppendingPathComponent:@"approved-edid.bin"]; }
static NSString *agentPath(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.edid-override.plist"]; }
static NSString *binaryPath(void) {
    return NSBundle.mainBundle.executablePath;
}
static int fail(NSString *message) { fprintf(stderr, "%s\n", message.UTF8String); return 1; }

// Validate the whole container before it reaches the private display API.
static BOOL validEDID(NSData *data) {
    const unsigned char header[] = {0,255,255,255,255,255,255,0};
    if (!data || data.length < 128 || data.length > 32768 || data.length % 128) return NO;
    const uint8_t *b = data.bytes;
    if (memcmp(b, header, 8) || (b[126] + 1) * 128 != data.length) return NO;
    for (NSUInteger off = 0; off < data.length; off += 128) {
        unsigned sum = 0;
        for (NSUInteger j = 0; j < 128; j++) sum += b[off+j];
        if (sum % 256) return NO;
        if (off && b[off] == 0x70) {
            // DisplayID section has its own checksum as well as the EDID checksum.
            NSUInteger end = 5 + b[off+2];
            if (end > 126) return NO;
            sum = 0;
            for (NSUInteger j = 1; j <= end; j++) sum += b[off+j];
            if (sum % 256) return NO;
        }
    }
    return YES;
}

// Manufacturer/product/numeric serial plus serial descriptor, if present.
// A unique serial is required; matching by model alone is not safe.
static NSData *identity(NSData *data) {
    if (!validEDID(data)) return nil;
    const uint8_t *b = data.bytes;
    NSMutableData *result = [NSMutableData dataWithBytes:b+8 length:8];
    BOOL hasSerial = (b[12] || b[13] || b[14] || b[15]) &&
                     !(b[12] == 255 && b[13] == 255 && b[14] == 255 && b[15] == 255);
    for (NSUInteger off = 54; off <= 108; off += 18) {
        if (!b[off] && !b[off+1] && !b[off+2] && b[off+3] == 0xff) {
            NSMutableData *serial = [NSMutableData data];
            for (NSUInteger j = off+5; j < off+18 && b[j] != 10; j++) {
                if (b[j] > 32 && b[j] < 127) [serial appendBytes:b+j length:1];
            }
            if (serial.length) { [result appendData:serial]; hasSerial = YES; }
        }
    }
    return hasSerial ? result : nil;
}

static BOOL loadAPI(void) {
    void *lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!lib) return NO;
    createService = (CreateFunc)dlsym(lib, "IOAVServiceCreateWithService");
    setEDID = (SetFunc)dlsym(lib, "IOAVServiceSetVirtualEDIDMode");
    copyEDID = (CopyFunc)dlsym(lib, "IOAVServiceCopyEDID");
    return createService && setEDID && copyEDID;
}

// Return a retained service only when exactly one connected external monitor matches.
static IOAVServiceRef findTarget(void) {
    io_iterator_t iter = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) != KERN_SUCCESS) return NULL;
    IOAVServiceRef result = NULL;
    unsigned matches = 0;
    io_service_t s;
    while ((s = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        CFTypeRef location = IORegistryEntryCreateCFProperty(s, CFSTR("Location"), kCFAllocatorDefault, 0);
        if (location && CFGetTypeID(location) == CFStringGetTypeID() && CFEqual(location, CFSTR("External"))) {
            IOAVServiceRef service = createService(kCFAllocatorDefault, s);
            if (service) {
                CFDataRef current = NULL;
                if (copyEDID(service, &current) == KERN_SUCCESS && current &&
                    [identity((__bridge NSData *)current) isEqualToData:identity(targetEDID)]) {
                    matches++;
                    if (!result) result = CFRetain(service);
                }
                if (current) CFRelease(current);
                CFRelease(service);
            }
        }
        if (location) CFRelease(location);
        IOObjectRelease(s);
    }
    IOObjectRelease(iter);
    if (matches != 1 && result) { CFRelease(result); result = NULL; }
    return result;
}

static int resetTarget(void) {
    IOAVServiceRef service = findTarget();
    if (!service) return fail(@"Target absent, unreadable or ambiguous; no display was changed.");
    IOReturn r = setEDID(service, 0, NULL);
    CFRelease(service);
    return r == KERN_SUCCESS ? 0 : fail(@"Failed to restore factory EDID.");
}

static int inject(void) {
    IOAVServiceRef service = findTarget();
    if (!service) { fail(@"Target absent, unreadable or ambiguous; no display was changed."); return 2; }
    CFDataRef before = NULL;
    if (copyEDID(service, &before) != KERN_SUCCESS || !before) {
        if (before) CFRelease(before);
        CFRelease(service);
        return fail(@"Cannot read current EDID; refusing to change it.");
    }
    if ([(__bridge NSData *)before isEqualToData:targetEDID]) {
        CFRelease(before); CFRelease(service); return 0;
    }
    CFRelease(before);
    // No preliminary reset: a failed new apply must not first erase the working state.
    IOReturn r = setEDID(service, 1, (__bridge CFDataRef)targetEDID);
    if (r != KERN_SUCCESS) {
        CFRelease(service); return fail(@"EDID apply failed.");
    }
    CFDataRef after = NULL;
    r = copyEDID(service, &after);
    BOOL verified = r == KERN_SUCCESS && after && [(__bridge NSData *)after isEqualToData:targetEDID];
    if (after) CFRelease(after);
    if (!verified) setEDID(service, 0, NULL);
    CFRelease(service);
    return verified ? 0 : fail(@"EDID readback did not match; attempted factory reset.");
}

static int launchctl(NSArray<NSString *> *args) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = args;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return fail(error.localizedDescription);
    [task waitUntilExit];
    return task.terminationStatus;
}
static BOOL approved(void) {
    return [targetEDID isEqualToData:[NSData dataWithContentsOfFile:approvalPath()]];
}
static int enableAgent(void) {
    if (!approved()) return fail(@"Profile not approved. Run --test and confirm the picture first.");
    NSString *installedBinary = [installDir() stringByAppendingPathComponent:@"edid_override"];
    if (![[binaryPath() stringByResolvingSymlinksInPath] isEqualToString:[installedBinary stringByResolvingSymlinksInPath]])
        return fail(@"Enable must be run from the installed binary.");
    NSDictionary *agent = @{@"Label":@"com.edid-override", @"ProgramArguments":@[installedBinary,@"--daemon"],
                           @"RunAtLoad":@YES};
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:agentPath().stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (![agent writeToFile:agentPath() atomically:YES]) return fail(@"Cannot write LaunchAgent.");
    NSString *domain = [NSString stringWithFormat:@"gui/%u",getuid()];
    NSString *label = [domain stringByAppendingString:@"/com.edid-override"];
    // Do not start a second instance or create concurrent injectors.
    if (launchctl(@[@"print", label]) == 0) return 0;
    return launchctl(@[@"bootstrap", domain, agentPath()]);
}

static BOOL confirmed(int fd, int timeout) {
    struct pollfd input = {fd, POLLIN, 0};
    char c = 0;
    return poll(&input,1,timeout)>0 && read(fd,&c,1)==1 && c=='K';
}
// Separate process: EOF (parent exits/crashes) or 45 seconds triggers factory reset.
static int watchdog(void) {
    if (write(STDOUT_FILENO,"R",1) != 1) return 1;
    if (confirmed(STDIN_FILENO,45000)) return 0;
    fprintf(stderr,"Test not confirmed; restoring factory EDID.\n");
    resetTarget();
    return 1; // A timed-out test is never a successful confirmation.
}
static int testProfile(NSString *path) {
    if (!isatty(STDIN_FILENO)) return fail(@"--test requires an interactive terminal for confirmation.");
    NSString *label = [NSString stringWithFormat:@"gui/%u/com.edid-override", getuid()];
    if (launchctl(@[@"print",label]) == 0) return fail(@"Stop the installed daemon with --reset before testing.");
    // Clear stale approval before applying any new test.
    [NSFileManager.defaultManager removeItemAtPath:approvalPath() error:nil];
    // Give the watchdog the same immutable bytes, not a mutable user-supplied path.
    (void)path;
    NSString *snapshotDir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:snapshotDir withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:nil]) return fail(@"Cannot create watchdog snapshot.");
    NSString *snapshot = [snapshotDir stringByAppendingPathComponent:@"edid.bin"];
    if (![targetEDID writeToFile:snapshot options:NSDataWritingAtomic error:nil]) {
        [NSFileManager.defaultManager removeItemAtPath:snapshotDir error:nil];
        return fail(@"Cannot save watchdog snapshot.");
    }
    NSTask *guard = [NSTask new];
    NSPipe *pipe = [NSPipe pipe];
    NSPipe *readyPipe = [NSPipe pipe];
    guard.executableURL = [NSURL fileURLWithPath:binaryPath()];
    guard.arguments = @[@"--watchdog", snapshot];
    guard.standardInput = pipe;
    guard.standardOutput = readyPipe;
    NSError *error = nil;
    if (![guard launchAndReturnError:&error]) {
        [NSFileManager.defaultManager removeItemAtPath:snapshotDir error:nil];
        return fail(error.localizedDescription);
    }
    struct pollfd ready = {readyPipe.fileHandleForReading.fileDescriptor, POLLIN, 0};
    char marker = 0;
    BOOL armed = poll(&ready,1,5000) > 0 && read(ready.fd,&marker,1) == 1 && marker == 'R';
    [NSFileManager.defaultManager removeItemAtPath:snapshotDir error:nil];
    if (!armed) {
        [pipe.fileHandleForWriting closeFile];
        [guard terminate]; [guard waitUntilExit];
        return fail(@"Watchdog did not become ready; no display was changed.");
    }
    if (inject() != 0) {
        [pipe.fileHandleForWriting closeFile]; [guard waitUntilExit]; return 1;
    }
    printf("Select the desired mode in Displays. Within 35 seconds, type KEEP and Enter only if the picture is stable.\n");
    fflush(stdout);
    struct pollfd fd = {STDIN_FILENO, POLLIN, 0};
    char answer[16] = {0};
    BOOL keep = poll(&fd, 1, 35000) > 0 && fgets(answer,sizeof(answer),stdin) && strcmp(answer,"KEEP\n") == 0;
    if (keep && guard.running) {
        signal(SIGPIPE, SIG_IGN);
        keep = [pipe.fileHandleForWriting writeData:[NSData dataWithBytes:"K" length:1] error:nil];
    } else keep = NO;
    [pipe.fileHandleForWriting closeFile];
    [guard waitUntilExit];
    if (!keep || guard.terminationStatus != 0) {
        [NSFileManager.defaultManager removeItemAtPath:approvalPath() error:nil];
        return fail(@"Test not approved. Automatic startup remains disabled.");
    }
    [NSFileManager.defaultManager createDirectoryAtPath:installDir() withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    if (![targetEDID writeToFile:approvalPath() options:NSDataWritingAtomic error:nil]) {
        resetTarget(); return fail(@"Cannot save approval; attempted factory reset.");
    }
    puts("Test approved. Automatic startup is still disabled; --enable is a separate step.");
    return 0;
}

static void backgroundCheck(void) {
    // Missing/ambiguous target is harmless. A real apply/readback failure stops
    // automatic attempts instead of repeatedly blanking the screen.
    if (inject()==1) {
        [NSFileManager.defaultManager removeItemAtPath:approvalPath() error:nil];
        fprintf(stderr,"Automatic apply stopped after failure; test again before enabling.\n");
        exit(0);
    }
}
static void scheduleCheck(void) {
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        @autoreleasepool { pending = NO; backgroundCheck(); }
    });
}
static void changed(CGDirectDisplayID d, CGDisplayChangeSummaryFlags flags, void *ctx) {
    (void)d; (void)ctx;
    if (!(flags & kCGDisplayBeginConfigurationFlag)) scheduleCheck();
}
@interface WakeObserver : NSObject
@end
@implementation WakeObserver
- (void)wake:(NSNotification *)note { scheduleCheck(); }
@end
static int daemonMode(void) {
    if (!approved()) return fail(@"Unapproved profile; daemon will not apply it.");
    backgroundCheck();
    CGDisplayRegisterReconfigurationCallback(changed,NULL);
    WakeObserver *observer = [WakeObserver new];
    NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
    [nc addObserver:observer selector:@selector(wake:) name:NSWorkspaceDidWakeNotification object:nil];
    [nc addObserver:observer selector:@selector(wake:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *t) {
        @autoreleasepool { (void)t; backgroundCheck(); }
    }];
    (void)timer;
    [NSRunLoop.mainRunLoop run];
    return 0;
}

static int selfTest(void) {
    NSMutableData *fixture = [NSMutableData dataWithLength:128];
    uint8_t *b = fixture.mutableBytes;
    memset(b+1,255,6); b[8]=0x10; b[9]=0xac; b[10]=0xfd; b[11]=0xa2; b[12]=1;
    unsigned sum=0; for(int i=0;i<127;i++) sum+=b[i]; b[127]=(uint8_t)-sum;
    if (!validEDID(fixture) || !identity(fixture) || validEDID([NSData data])) return 1;
    NSData *id1 = identity(fixture);
    b[12]=2; b[127]--; if ([identity(fixture) isEqualToData:id1]) return 1;
    b[126]=1; b[127]--; if (validEDID(fixture)) return 1;
    b[126]=0; b[127]++; b[20]++; if (validEDID(fixture)) return 1;
    int fds[2];
    if (pipe(fds)) return 1;
    if (confirmed(fds[0],0)) return 1; // No confirmation / timeout.
    if (write(fds[1],"N",1)!=1 || confirmed(fds[0],0)) return 1;
    if (write(fds[1],"K",1)!=1 || !confirmed(fds[0],0)) return 1;
    close(fds[1]);
    if (confirmed(fds[0],0)) return 1; // EOF / parent crash.
    close(fds[0]);
    puts("Validation, identity and watchdog confirmation self-tests passed."); return 0;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *mode = argc>1 ? @(argv[1]) : @"--help";
        if ([mode isEqualToString:@"--self-test"]) return selfTest();
        if ([mode isEqualToString:@"--help"]) {
            puts("Usage: edid_override --validate FILE | --test FILE | --enable | --reset | --status | --self-test\nInstall stages files only. Test requires interactive confirmation. Enable is opt-in."); return 0;
        }
        if (![@[@"--validate",@"--test",@"--watchdog",@"--enable",@"--reset",@"--status",@"--daemon"] containsObject:mode]) return fail(@"Unknown command; use --help.");
        BOOL needsFile = [@[@"--validate",@"--test",@"--watchdog"] containsObject:mode];
        if (argc != (needsFile ? 3 : 2)) return fail(@"Wrong argument count; use --help.");
        NSString *path = needsFile ? [@(argv[2]) stringByStandardizingPath] : installedProfile();
        targetEDID = [NSData dataWithContentsOfFile:path];
        if (!validEDID(targetEDID) || !identity(targetEDID)) return fail(@"Invalid EDID or no unique serial; no display was changed.");
        if ([mode isEqualToString:@"--validate"]) { puts("EDID structure, checksums and target identity validated."); return 0; }
        if (!loadAPI()) return fail(@"Required macOS display functions unavailable; no display was changed.");
        if ([mode isEqualToString:@"--watchdog"]) return watchdog();
        if ([mode isEqualToString:@"--test"]) return testProfile(path);
        if ([mode isEqualToString:@"--enable"]) return enableAgent();
        if ([mode isEqualToString:@"--daemon"]) return daemonMode();
        if ([mode isEqualToString:@"--reset"]) {
            NSString *service = [NSString stringWithFormat:@"gui/%u/com.edid-override",getuid()];
            if (launchctl(@[@"print",service]) == 0 && launchctl(@[@"bootout",service]) != 0) return fail(@"Could not stop daemon; reset aborted.");
            [NSFileManager.defaultManager removeItemAtPath:approvalPath() error:nil];
            return resetTarget();
        }
        IOAVServiceRef service = findTarget();
        if (!service) return fail(@"Target absent, unreadable or ambiguous.");
        CFDataRef current = NULL;
        IOReturn r = copyEDID(service,&current);
        BOOL active = r == KERN_SUCCESS && current && [(__bridge NSData *)current isEqualToData:targetEDID];
        BOOL readable = r == KERN_SUCCESS && current != NULL;
        if(current) CFRelease(current); CFRelease(service);
        puts(active ? "Custom EDID active." : "Custom EDID not active.");
        return readable ? 0 : 1;
    }
}

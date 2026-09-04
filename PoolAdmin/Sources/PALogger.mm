#import "PALogger.h"

#import <stdio.h>
#import "PARuntimeBridge.h"

namespace {

FILE *LogFile(void) {
    static FILE *file = nullptr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            NSArray *dirs = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES);
            NSString *docDir = [dirs firstObject];
            if (!docDir) return;
            NSString *path =
                [docDir stringByAppendingPathComponent:@"PoolAdmin.log"];
            // Rotate: keep the log small across installs.
            @try {
                NSDictionary *attrs = [[NSFileManager defaultManager]
                    attributesOfItemAtPath:path error:nil];
                unsigned long long size =
                    [attrs[NSFileSize] unsignedLongLongValue];
                if (size > 512 * 1024) {
                    [[NSFileManager defaultManager]
                        removeItemAtPath:path error:nil];
                }
            } @catch (NSException *e) {}
            file = fopen([path UTF8String], "a");
            if (file) {
                fprintf(file, "--- PoolAdmin session start ---\n");
                fflush(file);
            }
        } @catch (NSException *e) {
            file = nullptr;
        }
    });
    return file;
}

NSString *Timestamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale =
            [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"HH:mm:ss.SSS";
    });
    @try {
        return [formatter stringFromDate:[NSDate date]];
    } @catch (NSException *e) {
        return @"--:--:--";
    }
}

}  // namespace

void PALog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = nil;
    @try {
        message = [[NSString alloc] initWithFormat:format arguments:args];
    } @catch (NSException *e) {
        message = @"<format error>";
    }
    va_end(args);
    if (!message) message = @"<nil>";

    NSLog(@"[PoolAdmin] %@", message);

    static NSObject *lock;
    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        @try {
            FILE *file = LogFile();
            if (file) {
                fprintf(file, "%s %s\n", [Timestamp() UTF8String],
                        [message UTF8String]);
                fflush(file);
            }
        } @catch (NSException *e) {}
    }
}

NSString *_Nullable PALogFilePath(void) {
    @try {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = [dirs firstObject];
        if (!docDir) return nil;
        return [docDir stringByAppendingPathComponent:@"PoolAdmin.log"];
    } @catch (NSException *e) {
        return nil;
    }
}

void PAStartHeartbeat(void) {
    @try {
        // Timer retains nothing; the block captures only class calls.
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         repeats:YES
                                           block:^(NSTimer *timer) {
            (void)timer;
            @try {
                BOOL ready = NO;
                BOOL inGame = NO;
                @try {
                    NSDictionary *summary =
                        [PARuntimeBridge.shared playerSummary];
                    ready = [summary[@"ready"] boolValue];
                } @catch (NSException *e) {}
                @try {
                    inGame = [PARuntimeBridge.shared isInGame];
                } @catch (NSException *e) {}
                PALog(@"hb ready=%d inGame=%d main=%d", (int)ready,
                      (int)inGame, (int)NSThread.isMainThread);
            } @catch (NSException *e) {}
        }];
    } @catch (NSException *e) {}
}

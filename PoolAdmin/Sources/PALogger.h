#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// File-backed logging: mirrors to NSLog AND appends to
/// Documents/PoolAdmin.log (flushed per line, so silent exits and kills
/// keep everything up to the last line). Enable "File Sharing" when
/// signing so the file is visible in the Files app under 8 Ball Pool.
/// Safe to call from any thread; never throws.
FOUNDATION_EXPORT void PALog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Absolute path of the log file (nil if Documents is unavailable).
FOUNDATION_EXPORT NSString *_Nullable PALogFilePath(void);

/// Starts a 1-second main-thread heartbeat ("hb ready=.. inGame=..").
/// If heartbeats keep flowing while the UI is frozen, the main thread is
/// alive and the game logic itself is stalled; if they stop, something
/// blocks the main thread.
FOUNDATION_EXPORT void PAStartHeartbeat(void);

NS_ASSUME_NONNULL_END

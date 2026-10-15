#import <stdatomic.h>
#import "DeckLinkDevice.h"

#import "DeckLinkAPI.h"
#import "DeckLinkDevice.h"
#import "DeckLinkDevice+Capture.h"
#import "DeckLinkDeviceInternalInputCallback.h"
#import "DeckLinkDeviceInternalOutputCallback.h"
#import "DeckLinkDevice+Playback.h"

@class DeckLinkPlaybackSession;
@class DeckLinkPlaybackGroup;
class DeckLinkProfileCallback;

/// Stop progress tracked exclusively on playbackQueue.
typedef NS_ENUM(NSUInteger, DeckLinkScheduledStopState) {
    DeckLinkScheduledStopIdle,
    DeckLinkScheduledStopWaitingForDriver,
    DeckLinkScheduledStopWaitingForFrames,
};
typedef void (^DeckLinkPlaybackStatusCompletion)(HRESULT status);
typedef void (^DeckLinkScheduledFrameCompletion)(BMDOutputFrameCompletionResult result);

struct DeckLinkPlaybackClock {
    bool running;
    /// Output timeline position at 48000 units per second. Valid only while running.
    int64_t streamTime;
    /// Host-clock time in seconds, sampled around the native stream-time query.
    double hostTime;
    /// Playback rate reported with streamTime; 1.0 is normal speed.
    double speed;
    /// Audio sample frames buffered by the driver, each containing all channels.
    uint32_t audioSamples;
};


@interface DeckLinkDevice ()
{
	IDeckLink *deckLink;
	IDeckLinkProfileAttributes *deckLinkAttributes;
	IDeckLinkConfiguration *deckLinkConfiguration;
	IDeckLinkKeyer *deckLinkKeyer;
	IDeckLinkInput *deckLinkInput;
	IDeckLinkOutput *deckLinkOutput;
    IDeckLinkStatus *deckLinkStatus;
    IDeckLinkProfileManager *deckLinkProfileManager;
    DeckLinkProfileCallback *deckLinkProfileCallback;
    BMDVideoOutputFlags _playbackVideoOutputFlags;
    int64_t _previousPlaybackGroup;
    BOOL _hasPreviousPlaybackGroup;
	
	DeckLinkDeviceInternalInputCallback *deckLinkInputCallback;
	DeckLinkDeviceInternalOutputCallback *deckLinkOutputCallback;
	
    atomic_uint_fast64_t _scheduledFrameCount;
    atomic_uint_fast64_t _playbackGeneration;
    atomic_bool _scheduledStopRequested;
    NSMutableDictionary<NSValue *, id> *_scheduledFrames;
    NSMutableArray *_scheduledStopHandlers;
    BOOL _audioPrerollActive;
    DeckLinkScheduledStopState _scheduledStopState;
}

- (instancetype)initWithDeckLink:(IDeckLink *)deckLink;

@property (nonatomic, assign, readonly) IDeckLink *deckLink;

@property (nonatomic, copy) NSString *modelName;
@property (nonatomic, copy) NSString *displayName;

@property (nonatomic, assign) int32_t persistantID;
@property (nonatomic, assign) int32_t topologicalID;

/// The only mutable storage for group attributes; publishes a complete snapshot.
@property (atomic, strong) DeckLinkPlaybackGroupAttributes *playbackGroupAttributes;
- (void)refreshPlaybackGroupAttributes;
- (void)invalidatePlayback;

// capture

// Set during construction; immutable once the device is exposed.
@property (nonatomic, assign) BOOL captureSupported;
@property (atomic, assign) BOOL captureActive;
@property (atomic, assign) BOOL captureInputSourceConnected;

@property (nonatomic, strong) dispatch_queue_t captureQueue;

@property (nonatomic, copy) NSArray *captureVideoFormatDescriptions;
@property (atomic, strong) __attribute__((NSObject)) CMVideoFormatDescriptionRef captureActiveVideoFormatDescription;

@property (nonatomic, copy) NSArray *captureAudioFormatDescriptions;
@property (atomic, strong) __attribute__((NSObject)) CMAudioFormatDescriptionRef captureActiveAudioFormatDescription;

@property (nonatomic, copy) NSArray *captureVideoConnections;
@property (atomic, strong) NSString *captureActiveVideoConnection;

@property (nonatomic, copy) NSArray *captureAudioConnections;
@property (atomic, strong) NSString *captureActiveAudioConnection;

@property (nonatomic, weak) id<DeckLinkDeviceCaptureVideoDelegate> captureVideoDelegate;
@property (nonatomic, strong) dispatch_queue_t captureVideoDelegateQueue;

@property (nonatomic, weak) id<DeckLinkDeviceCaptureAudioDelegate> captureAudioDelegate;
@property (nonatomic, strong) dispatch_queue_t captureAudioDelegateQueue;

// playback

// Set during construction; immutable once the device is exposed.
@property (nonatomic, assign) BOOL playbackSupported;
@property (atomic, assign) BOOL playbackActive;

@property (nonatomic, weak) DeckLinkPlaybackSession *scheduledPlaybackSession;
@property (nonatomic, strong) dispatch_queue_t playbackQueue;
@property (nonatomic, strong) dispatch_queue_t frameDownloadQueue;

// Replaced on profile activation; atomic access publishes immutable lists.
@property (atomic, copy) NSArray *playbackVideoFormatDescriptions;
@property (atomic, strong) __attribute__((NSObject)) CMVideoFormatDescriptionRef playbackActiveVideoFormatDescription;

@property (atomic, copy) NSArray *playbackAudioFormatDescriptions;
@property (atomic, strong) __attribute__((NSObject)) CMAudioFormatDescriptionRef playbackActiveAudioFormatDescription;

@property (atomic, copy) NSArray *playbackKeyingModes;

@end

@interface DeckLinkDevice (PlaybackInitialization)
- (void)initializePlaybackScheduling;
@end

/// Internal operations used by DeckLinkPlaybackSession and DeckLinkPlaybackGroup.
/// Methods ending in OnQueue must be called on playbackQueue.
@interface DeckLinkDevice (PlaybackSessionSupport)
/// Returns whether the device is idle and available for a session.
- (BOOL)canOpenPlaybackSessionOnQueue;
/// Whether the device plays the format's display mode and pixel format, with the keyer on
/// unless keyingMode is nil or DeckLinkKeyingModeNone.
- (HRESULT)validateVideoFormatOnQueue:(CMVideoFormatDescriptionRef)format keyingMode:(NSString *)keyingMode;
- (void)refreshPlaybackFormats;
/// Joins the SDK playback group; enabled video then synchronizes to it.
- (HRESULT)configurePlaybackGroupOnQueue:(int64_t)groupID;
/// Best effort; always returns the output to ungrouped flags.
- (void)restorePlaybackGroupOnQueue;
/// Enables the video format, or disables video for NULL. Call after stopping.
- (HRESULT)setVideoFormatOnPlaybackQueue:(CMVideoFormatDescriptionRef)format;
/// Enables timestamped audio in the format, or disables audio for NULL. Call after stopping.
- (HRESULT)setAudioFormatOnPlaybackQueue:(CMAudioFormatDescriptionRef)format;
/// Applies the keying mode at full alpha.
- (HRESULT)setKeyingOnPlaybackQueue:(NSString *)mode;
- (HRESULT)endAudioPrerollOnQueue;
/// Starts output at time zero; for a synchronized group, starts every member.
- (HRESULT)startPlaybackOnQueue:(int64_t)timeScale;
/// Cancels preparations immediately; armed runs on playbackQueue once they have drained.
/// completion runs on playbackQueue after driver stop and frame release, or with a failure.
- (void)armStopWithCompletion:(DeckLinkPlaybackStatusCompletion)completion armed:(DeckLinkPlaybackStatusCompletion)armed;
- (HRESULT)getPlaybackRunningOnQueue:(BOOL *)running;
/// One SDK stop; for a synchronized group, stops every member.
- (HRESULT)requestStopOnQueue;
/// Completes an armed stop. An output that was not running has no stopped callback,
/// so disabling video flushes its retained frames instead.
- (void)completeStopOnQueue:(HRESULT)status wasRunning:(BOOL)running;
/// Runs block synchronously on playbackQueue, or inline if already on that queue.
- (void)performPlaybackSync:(dispatch_block_t)block;
/// Submits PCM without waiting for playback; written receives the accepted sample-frame count.
/// Begins audio preroll if output has not started. The driver copies the accepted prefix
/// during the call; this method does not retain bytes.
- (HRESULT)writeAudioOnPlaybackQueue:(const void *)bytes sampleFrameCount:(UInt32)count streamTime:(int64_t)time timeScale:(int64_t)scale written:(UInt32 *)written;
/// Queries playback state, stream time, paired host time, and buffered audio.
- (HRESULT)readPlaybackClockOnQueue:(DeckLinkPlaybackClock *)clock;
/// Retains and prepares a frame asynchronously, then schedules it on playbackQueue.
/// Callable from any queue. maximum bounds all outstanding frames, including preparation.
/// The time block runs on playbackQueue immediately before scheduling; return a negative
/// value to skip the frame (S_FALSE). accepted always runs on playbackQueue. completed
/// runs only for accepted frames, also on playbackQueue.
- (void)enqueuePlaybackPixelBuffer:(CVPixelBufferRef)buffer frameDuration:(int64_t)duration timeScale:(int64_t)scale maximumFrames:(NSUInteger)maximum displayTime:(int64_t (^)(void))time accepted:(void (^)(HRESULT))accepted completed:(DeckLinkScheduledFrameCompletion)completed;
@end

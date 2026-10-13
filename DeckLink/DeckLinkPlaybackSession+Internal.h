#import "DeckLinkPlaybackOutput.h"
#import "DeckLinkDevice+Internal.h"
@class DeckLinkPlaybackGroup;

/// One output's scheduling state inside a group: native frames, preroll and the audio worker.
/// Created and driven only by its group. Methods ending in OnQueue must be called on the
/// device's playbackQueue.
@interface DeckLinkPlaybackSession : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithOutput:(DeckLinkPlaybackOutput *)output group:(DeckLinkPlaybackGroup *)group NS_DESIGNATED_INITIALIZER;

@property (nonatomic, strong, readonly) DeckLinkDevice *device;
/// kCMTimeInvalid when the video format has no DeckLink frame rate; opening then fails.
@property (nonatomic, assign, readonly) CMTime frameDuration;
@property (nonatomic, assign, readonly) BOOL hasAudio;

/// Validates settings and claims the device.
- (HRESULT)reserveOnQueue;
/// Enables formats and keying. A nonzero groupID first joins that SDK playback group.
- (HRESULT)openOnQueue:(int64_t)groupID;
/// Schedules a frame at an exact frame boundary of the output timeline. Preroll times start
/// at zero and are contiguous; running times must not be in the past. Late or excess frames
/// report S_FALSE or E_OUTOFMEMORY without failing playback. accepted runs on playbackQueue.
- (void)submitPixelBuffer:(CVPixelBufferRef)buffer atTime:(int64_t)time accepted:(void (^)(HRESULT status))accepted;
- (BOOL)isReadyForGroupStartOnQueue;
- (HRESULT)prepareGroupStartOnQueue;
- (void)groupDidStartOnQueue;
/// Stops source reads.
- (void)beginGroupCloseOnQueue;
/// One audio worker tick: keeps about one video frame of audio ahead of the output clock.
/// Does nothing unless prerolling or running.
- (void)serviceAudio;
- (HRESULT)disableGroupOutputOnQueue;
- (void)releaseGroupOwnershipOnQueue;
- (void)fail:(HRESULT)status;
- (void)devicePlaybackStoppedOnQueue;
@end

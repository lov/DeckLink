#import <DeckLink/DeckLinkPlaybackOutput.h>

FOUNDATION_EXPORT NSString * const DeckLinkPlaybackGroupErrorDomain;
/// Every playback error uses DeckLinkPlaybackGroupErrorDomain. Driver failures carry the
/// native status as an NSOSStatusErrorDomain NSUnderlyingErrorKey.
typedef NS_ENUM(NSInteger, DeckLinkPlaybackGroupError) {
    DeckLinkPlaybackGroupInvalidConfiguration = 1,
    DeckLinkPlaybackGroupUnsupportedDevice,
    DeckLinkPlaybackGroupReferenceUnavailable,
    DeckLinkPlaybackGroupPrerollTimedOut,
    DeckLinkPlaybackGroupDeviceFailure,
    /// An output skipped a frame that arrived too late or exceeded its buffer limit. Playback continues.
    DeckLinkPlaybackGroupFrameRejected,
};
typedef NS_ENUM(NSUInteger, DeckLinkPlaybackGroupState) {
    DeckLinkPlaybackGroupNew, DeckLinkPlaybackGroupOpening, DeckLinkPlaybackGroupPrerolling,
    /// All initial media is prerolled; waiting without a deadline for required reference lock.
    DeckLinkPlaybackGroupWaitingForReference,
    DeckLinkPlaybackGroupStarting,
    DeckLinkPlaybackGroupRunning, DeckLinkPlaybackGroupClosing,
    DeckLinkPlaybackGroupClosed, DeckLinkPlaybackGroupFailed,
};
/// Whether outputs must report a locked reference signal before and during playback.
typedef NS_ENUM(NSUInteger, DeckLinkPlaybackGroupReferencePolicy) {
    /// Each device's playbackGroupRequiresReference decides (only the DeckLink 8K Pro is exempt).
    DeckLinkPlaybackGroupReferenceAutomatic,
    /// Always require a locked reference.
    DeckLinkPlaybackGroupReferenceRequired,
    /// Never require one; for hardware known to synchronize sub-devices internally.
    DeckLinkPlaybackGroupReferenceNotRequired,
};

/// Scheduled output for one or more outputs that start, run and stop together.
///
/// A single output is an ordinary independent output. Two or more outputs must be
/// sub-devices of ONE physical card; they are synchronized through the SDK playback group.
/// Every output keeps an independent video/audio source and can pause/seek its content.
/// Keep the group alive until close completes. Dropping it initiates asynchronous cleanup.
/// Group callbacks run on a private serial callback queue, separate from scheduling.
@interface DeckLinkPlaybackGroup : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/// @param outputs One or more outputs, in submission order. Settings are fixed; close the
/// group and create a new one to change them.
- (instancetype)initWithOutputs:(NSArray<DeckLinkPlaybackOutput *> *)outputs;
@property (nonatomic, copy, readonly) NSArray<DeckLinkPlaybackOutput *> *outputs;
@property (atomic, assign, readonly) DeckLinkPlaybackGroupState state;
@property (atomic, strong, readonly) NSError *error;
/// Configure before open. Runtime failure stops every output and begins cleanup.
/// Call close and await success before opening a replacement group.
@property (nonatomic, copy) void (^errorHandler)(NSError *error);
/// Receives every state transition on the group's callback queue. Configure before open.
@property (nonatomic, copy) void (^stateHandler)(DeckLinkPlaybackGroupState state);
/// Configure before open. Defaults to DeckLinkPlaybackGroupReferenceAutomatic.
/// Ignored for a single output, which never requires reference.
@property (nonatomic, assign) DeckLinkPlaybackGroupReferencePolicy referencePolicy;
/// Positive seconds from successful open until every output has its initial preroll.
/// Waiting for required reference afterward has no deadline. Configure before open. Defaults to 5.
@property (nonatomic, assign) NSTimeInterval prerollTimeout;

/// Reserves and configures every output. Completion permits submissions.
/// Playback starts automatically once every output has sufficient video/audio preroll
/// and, when required, reference lock. Missing initial content fails after prerollTimeout;
/// no placeholder content is generated.
- (void)openWithCompletion:(DeckLinkPlaybackCompletion)completion;
/// Submits one frame set: one CVPixelBufferRef per output, in the order of `outputs`.
/// The first set after open fills preroll, repeating each output's buffer to its device's
/// minimum. Later sets are dropped until the group runs. While running, every output is
/// scheduled at the same time: the next output frame boundary plus one frame of lead for
/// native preparation. A set that would not advance past the last scheduled time is dropped.
/// Completion runs on the group's callback queue with the scheduled time, or kCMTimeInvalid
/// with a nil error when the set was dropped. An output's rejection is reported as the error;
/// rejections during preroll fail the group. Do not modify submitted buffers.
- (void)submitPixelBuffers:(NSArray *)buffers completion:(void (^)(CMTime time, NSError *error))completion;
/// Stops audio source reads, waits for preparations, driver stop, frame release and disabling
/// output, then restores each device's previous SDK playback-group ID (best effort).
/// Repeated calls join the close; failed cleanup retains ownership and can be retried.
- (void)closeWithCompletion:(DeckLinkPlaybackCompletion)completion;
@end

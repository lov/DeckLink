#import <DeckLink/DeckLinkDevice+Playback.h>

/// Supplies audio to one output on its device's serial scheduling queue.
///
/// Return interleaved PCM in the configured format, with exactly the requested number
/// of sample frames. nil or an incorrectly sized buffer produces silence. Do not mutate
/// returned data while the output uses it. Never wait for decoding, video, or UI work.
/// The source is fixed for the output's lifetime: switch, pause or mute media inside it.
/// During recovery, the output may read and discard audio whose output time has passed.
/// @param samples Number of sample frames to consume, each containing one sample per channel.
/// @param channels Number of channels in the output's audio format.
/// @param presentationTime Position in the output timeline, with a timescale of 48000.
/// @param discontinuity YES when recovering from missed output time.
/// @return The requested PCM data, or nil for silence.
typedef NSData * (^DeckLinkPlaybackAudioSource)(NSUInteger samples, NSUInteger channels, CMTime presentationTime, BOOL discontinuity);

/// Immutable settings for one output of a DeckLinkPlaybackGroup.
/// The frame duration is the video format's own DeckLink frame rate.
@interface DeckLinkPlaybackOutput : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// @param device Device whose output the group will claim.
/// @param videoFormat One of the device's playbackVideoFormatDescriptions.
/// @param audioFormat One of the device's playbackAudioFormatDescriptions, or NULL for video only.
/// @param keyingMode Keying mode to use, or nil to disable keying.
/// @param audioSource Audio for this output, or nil for silence. Ignored without an audio format.
- (instancetype)initWithDevice:(DeckLinkDevice *)device
                   videoFormat:(CMVideoFormatDescriptionRef)videoFormat
                   audioFormat:(CMAudioFormatDescriptionRef)audioFormat
                    keyingMode:(NSString *)keyingMode
                   audioSource:(DeckLinkPlaybackAudioSource)audioSource NS_DESIGNATED_INITIALIZER;

@property (nonatomic, strong, readonly) DeckLinkDevice *device;
@property (nonatomic, strong, readonly) __attribute__((NSObject)) CMVideoFormatDescriptionRef videoFormat;
@property (nonatomic, strong, readonly) __attribute__((NSObject)) CMAudioFormatDescriptionRef audioFormat;
@property (nonatomic, copy, readonly) NSString *keyingMode;
@property (nonatomic, copy, readonly) DeckLinkPlaybackAudioSource audioSource;
@end

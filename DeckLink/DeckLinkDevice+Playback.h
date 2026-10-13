#import <DeckLink/DeckLinkDevice.h>

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

typedef void (^DeckLinkPlaybackCompletion)(BOOL success, NSError *error);

/// Output capabilities. Playback itself goes through DeckLinkPlaybackGroup.
@interface DeckLinkDevice (Playback)

/// Thread-safe, nonblocking getters; returned arrays are immutable and replaced on profile activation.
@property (atomic, copy, readonly) NSArray *playbackVideoFormatDescriptions;
@property (atomic, copy, readonly) NSArray *playbackAudioFormatDescriptions;
@property (atomic, copy, readonly) NSArray *playbackKeyingModes;

@property (nonatomic, assign, readonly) BOOL playbackSupported;

@end

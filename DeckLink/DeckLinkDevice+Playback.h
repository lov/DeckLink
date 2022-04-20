#import <DeckLink/DeckLinkDevice.h>

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

@interface DeckLinkDevice (Playback)

@property (nonatomic, copy, readonly) NSArray *playbackVideoFormatDescriptions;
@property (atomic, strong, readonly) __attribute__((NSObject)) CMVideoFormatDescriptionRef playbackActiveVideoFormatDescription;
- (void)setPlaybackActiveVideoFormatDescription:(CMVideoFormatDescriptionRef)formatDescription completedHandler:(void (^)(BOOL status, NSError *outError))callbackBlock;

@property (nonatomic, copy, readonly) NSArray *playbackAudioFormatDescriptions;
@property (atomic, strong, readonly) __attribute__((NSObject)) CMAudioFormatDescriptionRef playbackActiveAudioFormatDescription;
- (void)setPlaybackActiveAudioFormatDescription:(CMAudioFormatDescriptionRef)formatDescription completedHandler:(void (^)(BOOL status, NSError *outError))callbackBlock;

@property (atomic, assign, readonly) BOOL playbackSupported;
@property (atomic, assign, readonly) BOOL playbackActive;

@property (nonatomic, copy, readonly) NSArray *playbackKeyingModes;
@property (atomic, strong, readonly) NSString *playbackActiveKeyingMode;
- (void)setPlaybackActiveKeyingMode:(NSString *)keyingMode alpha:(float)alpha completedHandler:(void (^)(BOOL status, NSError *outError))callbackBlock;

- (void)startScheduledPlaybackWithStartTime:(NSUInteger)startTime timeScale:(NSUInteger)timeScale;
- (void)schedulePlaybackOfPixelBuffer:(CVPixelBufferRef)pixelBuffer displayTime:(NSUInteger)displayTime frameDuration:(NSUInteger)frameDuration timeScale:(NSUInteger)timeScale;
- (void)stopScheduledPlaybackWithCompletionHandler:(DeckLinkDeviceStopPlaybackCompletionHandler)completionHandler;
- (void)playbackPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)playbackPixelBuffer:(CVPixelBufferRef)pixelBuffer isFlipped:(BOOL)flipped;

- (void)playbackMetalBuffer:(id<MTLBuffer>)metalBuffer ofSize:(NSSize)size rowBytes:(NSUInteger)rowBytes pixelFormat:(uint32_t)pixelformat isFlipped:(BOOL)flipped;

- (void)playbackContinuousAudioBufferList:(AudioBufferList *)audioBufferList numberOfSamples:(UInt32)numberOfSamples completionHandler:(void(^)(void))completionHandler;
- (void)playback16bitAudioBuffer:(short *)audiobuffer numberOfSamples:(UInt32)numberOfSamples completionHandler:(void(^)(void))completionHandler;

#if 0

@property (nonatomic, copy, readonly) NSArray *playbackVideoConnections;
@property (atomic, strong, readonly) NSString *playbackActiveVideoConnection;
- (void)setPlaybackActiveVideoConnection:(NSString *)connection completedHandler:(void (^)(BOOL status, NSError *outError))callbackBlock;

@property (nonatomic, copy, readonly) NSArray *playbackAudioConnections;
@property (atomic, strong, readonly) NSString *playbackActiveAudioConnection;
- (void)setPlaybackActiveAudioConnection:(NSString *)connection completedHandler:(void (^)(BOOL status, NSError *outError))callbackBlock;

- (BOOL)startPlaybackWithError:(NSError **)error;
- (void)stopPlayback;

#endif

#if 0
- (CMVideoFormatDescriptionRef)recordVideoFormatDescriptionWithDisplayMode:(int32_t)displayMode;
- (CMVideoFormatDescriptionRef)recordVideoFormatDescriptionWithName:(NSString *)name;

- (CMAudioFormatDescriptionRef)recordAudioFormatDescriptionWithName:(NSString *)name;

- (BOOL)startRecordWithError:(NSError **)error;
- (void)stopRecord;

- (void)recordPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)recordAudioBufferList:(const AudioBufferList *)audioBufferList numberOfSamples:(UInt32)numberOfSamples;

- (void)recordVideoData:(const void *)data presentationTimeStamp:(CMTime)presentationTimeStamp duration:(CMTime)duration;
- (void)recordVideoDataPresentationTimeStamp:(CMTime)presentationTimeStamp duration:(CMTime)duration frameCallbackHandler:(void(^)(void *data, int32_t width, int32_t height, int32_t bytesPerRow, CMPixelFormatType pixelFormat))callback;
#endif

@end

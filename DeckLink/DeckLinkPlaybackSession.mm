#import "DeckLinkPlaybackSession+Internal.h"
#import "DeckLinkPlaybackGroup+Internal.h"
#import "CMFormatDescription+DeckLink.h"
#import "DeckLinkKeying.h"
#include <cmath>

typedef NS_ENUM(NSUInteger, DeckLinkSessionState) {
    DeckLinkSessionNew, DeckLinkSessionReady, DeckLinkSessionPrerolling,
    DeckLinkSessionStarting, DeckLinkSessionRunning, DeckLinkSessionClosing, DeckLinkSessionClosed, DeckLinkSessionFailed,
};

// Created and accessed exclusively on the device's playback queue.
@interface DeckLinkSessionAudioPacket : NSObject
@property (nonatomic, copy) NSData *data;
@property (nonatomic, assign) UInt32 samples, offset;
@property (nonatomic, assign) int64_t time;
@end
@implementation DeckLinkSessionAudioPacket
@end

@implementation DeckLinkPlaybackOutput
- (instancetype)initWithDevice:(DeckLinkDevice *)device videoFormat:(CMVideoFormatDescriptionRef)video
                   audioFormat:(CMAudioFormatDescriptionRef)audio keyingMode:(NSString *)keyer audioSource:(DeckLinkPlaybackAudioSource)source {
    if ((self = [super init])) {
        _device = device; _videoFormat = video; _audioFormat = audio;
        _keyingMode = [keyer copy] ?: DeckLinkKeyingModeNone; _audioSource = [source copy];
    }
    return self;
}
@end

@interface DeckLinkPlaybackSession () {
    id _videoFormat, _audioFormat;
    CMTime _frameDuration;
    NSString *_keyingMode;
    DeckLinkSessionState _state;
    DeckLinkPlaybackAudioSource _audioSource;
    DeckLinkSessionAudioPacket *_pendingAudio;
    NSUInteger _channels, _bytesPerFrame, _audioCapacity;
    int64_t _audioCursor, _lastVideoTime;
    double _lastAudioProgressHostTime;
    BOOL _sourceDiscontinuity, _reportedReady;
    NSUInteger _minimumVideoPreroll, _prerolledVideoFrames;
    __weak DeckLinkPlaybackGroup *_group;
}
@end

@implementation DeckLinkPlaybackSession
- (instancetype)initWithOutput:(DeckLinkPlaybackOutput *)output group:(DeckLinkPlaybackGroup *)group {
    if ((self = [super init])) {
        _device = output.device; _videoFormat = (__bridge id)output.videoFormat; _audioFormat = (__bridge id)output.audioFormat;
        _keyingMode = output.keyingMode; _audioSource = output.audioSource; _group = group;
        _frameDuration = kCMTimeInvalid;
        if (output.videoFormat) CMVideoFormatDescriptionGetDeckLinkFrameRate(output.videoFormat, &_frameDuration);
        _lastVideoTime = -1;
    }
    return self;
}

- (CMTime)frameDuration { return _frameDuration; }
- (BOOL)hasAudio { return _audioFormat != nil; }

- (HRESULT)reserveOnQueue {
    if (_state != DeckLinkSessionNew || ![_device canOpenPlaybackSessionOnQueue]) return E_ACCESSDENIED;
    if (!CMTIME_IS_NUMERIC(_frameDuration) || _frameDuration.value <= 0) return E_INVALIDARG;
    HRESULT supported = [_device validateVideoFormatOnQueue:(__bridge CMVideoFormatDescriptionRef)_videoFormat];
    if (supported != S_OK) return supported;
    _device.scheduledPlaybackSession = self;
    return S_OK;
}

// A failed open keeps ownership; the group's close disables whatever was enabled.
- (HRESULT)openOnQueue:(int64_t)groupID {
    if (_state != DeckLinkSessionNew || _device.scheduledPlaybackSession != self) return E_ACCESSDENIED;
    const AudioStreamBasicDescription *asbd = _audioFormat ? CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)_audioFormat) : NULL;
    HRESULT status = S_OK;
    if (_audioFormat && (!asbd || asbd->mSampleRate != 48000 || asbd->mFormatID != kAudioFormatLinearPCM || !asbd->mChannelsPerFrame ||
        (asbd->mBitsPerChannel != 16 && asbd->mBitsPerChannel != 32) ||
        !(asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) || (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved))) status = E_INVALIDARG;
    _minimumVideoPreroll = MAX((NSUInteger)1, _device.playbackGroupAttributes.minimumPrerollVideoFrames);
    if (_minimumVideoPreroll > 64) status = E_INVALIDARG;
    CMTime capacity = CMTimeConvertScale(_frameDuration, 48000, kCMTimeRoundingMethod_RoundAwayFromZero);
    NSUInteger bytesPerFrame = asbd ? (NSUInteger)asbd->mChannelsPerFrame * (asbd->mBitsPerChannel / 8) : 0;
    if (status == S_OK && (!CMTIME_IS_NUMERIC(capacity) || capacity.value <= 0 || capacity.value > UINT32_MAX ||
        (bytesPerFrame && (uint64_t)capacity.value > (8 * 1024 * 1024) / bytesPerFrame))) status = E_INVALIDARG;
    if (status == S_OK) {
        _channels = asbd ? asbd->mChannelsPerFrame : 0;
        _bytesPerFrame = bytesPerFrame;
        _audioCapacity = (NSUInteger)capacity.value;
        if (groupID) status = [_device configurePlaybackGroupOnQueue:groupID];
        if (status == S_OK) status = [_device setVideoFormatOnPlaybackQueue:(__bridge CMVideoFormatDescriptionRef)_videoFormat];
        if (status == S_OK) status = [_device setAudioFormatOnPlaybackQueue:(__bridge CMAudioFormatDescriptionRef)_audioFormat];
        if (status == S_OK) status = [_device setKeyingOnPlaybackQueue:_keyingMode];
    }
    _state = status == S_OK ? DeckLinkSessionReady : DeckLinkSessionFailed;
    return status;
}

- (void)fail:(HRESULT)status {
    if (_state == DeckLinkSessionFailed || _state == DeckLinkSessionClosing || _state == DeckLinkSessionClosed) return;
    _state = DeckLinkSessionFailed;
    [_group memberFailed:status];
}

- (BOOL)readClock:(DeckLinkPlaybackClock *)clock {
    HRESULT status = [_device readPlaybackClockOnQueue:clock];
    if (status == S_OK && (!clock->running || clock->streamTime < 0 || !std::isfinite(clock->speed) || clock->speed <= 0)) status = E_FAIL;
    if (status != S_OK) { [self fail:status]; return NO; }
    return YES;
}

// The earliest frame boundary this session may still schedule, or -1.
- (int64_t)nextVideoTime {
    if (_state == DeckLinkSessionReady || _state == DeckLinkSessionPrerolling) {
        return _lastVideoTime < 0 ? 0 : (_lastVideoTime <= INT64_MAX - _frameDuration.value ? _lastVideoTime + _frameDuration.value : -1);
    }
    if (_state != DeckLinkSessionRunning) return -1;
    DeckLinkPlaybackClock clock;
    if (![self readClock:&clock]) return -1;
    double now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
    int64_t samples = clock.streamTime + (int64_t)(MAX(0, now - clock.hostTime) * 48000 * clock.speed);
    int64_t time = CMTimeConvertScale(CMTimeMake(samples, 48000), _frameDuration.timescale, kCMTimeRoundingMethod_RoundTowardZero).value;
    return (time / _frameDuration.value + 1) * _frameDuration.value;
}

- (void)submitPixelBuffer:(CVPixelBufferRef)buffer atTime:(int64_t)target accepted:(void (^)(HRESULT))accepted {
    [_device performPlaybackSync:^{
        if (!buffer || target < 0 || target % self->_frameDuration.value || target > INT64_MAX - self->_frameDuration.value) { accepted(E_INVALIDARG); return; }
        if (self->_state != DeckLinkSessionReady && self->_state != DeckLinkSessionPrerolling && self->_state != DeckLinkSessionRunning) { accepted(E_ACCESSDENIED); return; }
        __weak typeof(self) weakSelf = self;
        [self->_device enqueuePlaybackPixelBuffer:buffer frameDuration:self->_frameDuration.value timeScale:self->_frameDuration.timescale
            maximumFrames:MAX((NSUInteger)3, self->_minimumVideoPreroll) displayTime:^int64_t {
                typeof(self) session = weakSelf;
                if (!session) return -1;
                int64_t next = [session nextVideoTime];
                if (next < 0 || target < next || target <= session->_lastVideoTime) return -1;
                // Preroll is contiguous from zero.
                if (session->_state != DeckLinkSessionRunning && target != next) return -1;
                return target;
            } accepted:^(HRESULT status) {
                typeof(self) session = weakSelf;
                if (session && session->_state != DeckLinkSessionClosing && session->_state != DeckLinkSessionClosed &&
                    status != S_FALSE && status != E_OUTOFMEMORY) {
                    if (status != S_OK) [session fail:status];
                    else [session frameAccepted:target];
                }
                if (accepted) accepted(status);
            } completed:^(BMDOutputFrameCompletionResult result) {
                typeof(self) session = weakSelf;
                if (session && result == bmdOutputFrameFlushed &&
                    (session->_state == DeckLinkSessionRunning || session->_state == DeckLinkSessionPrerolling || session->_state == DeckLinkSessionStarting)) [session fail:E_FAIL];
            }];
    }];
}

- (void)frameAccepted:(int64_t)time {
    _lastVideoTime = time;
    if (_state != DeckLinkSessionReady && _state != DeckLinkSessionPrerolling) return;
    ++_prerolledVideoFrames;
    if (_state == DeckLinkSessionReady) {
        _state = DeckLinkSessionPrerolling;
        _lastAudioProgressHostTime = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
    }
    [self serviceAudio];
    [self reportReadyIfPrerolled];
}

- (BOOL)isReadyForGroupStartOnQueue {
    return _state == DeckLinkSessionPrerolling && _prerolledVideoFrames >= _minimumVideoPreroll && !_pendingAudio && (!_channels || _audioCursor >= (int64_t)_audioCapacity);
}

- (void)reportReadyIfPrerolled {
    if (_reportedReady || ![self isReadyForGroupStartOnQueue]) return;
    _reportedReady = YES;
    [_group memberReady];
}

- (HRESULT)prepareGroupStartOnQueue {
    if (![self isReadyForGroupStartOnQueue]) return E_ABORT;
    _state = DeckLinkSessionStarting; // Suspend workers until every member is marked running.
    return [_device endAudioPrerollOnQueue];
}

- (void)groupDidStartOnQueue {
    if (_state == DeckLinkSessionStarting) { _device.playbackActive = YES; _state = DeckLinkSessionRunning; }
}

- (void)devicePlaybackStoppedOnQueue {
    if (_state == DeckLinkSessionRunning || _state == DeckLinkSessionStarting) [self fail:E_ABORT];
}

- (void)beginGroupCloseOnQueue {
    _state = DeckLinkSessionClosing;
    _audioSource = nil; _pendingAudio = nil;
}

- (HRESULT)disableGroupOutputOnQueue {
    // Both disables run even if one fails, so partial cleanup is retryable.
    HRESULT audio = [_device setAudioFormatOnPlaybackQueue:NULL];
    HRESULT video = [_device setVideoFormatOnPlaybackQueue:NULL];
    if (audio != S_OK || video != S_OK) return audio != S_OK ? audio : video;
    [_device restorePlaybackGroupOnQueue];
    return S_OK;
}

- (void)releaseGroupOwnershipOnQueue {
    _state = DeckLinkSessionClosed;
    if (_device.scheduledPlaybackSession == self) _device.scheduledPlaybackSession = nil;
}

- (void)serviceAudio {
    if (_state != DeckLinkSessionPrerolling && _state != DeckLinkSessionRunning) return;
    DeckLinkPlaybackClock clock = {};
    clock.hostTime = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
    if (_state == DeckLinkSessionRunning && ![self readClock:&clock]) return;
    if (!_channels) { [self reportReadyIfPrerolled]; return; }
    if (_state == DeckLinkSessionRunning) {
        if (_pendingAudio && _pendingAudio.time + _pendingAudio.offset < clock.streamTime) {
            // Never retry a stale timestamp. Its PCM has already been consumed;
            // keep the reserved cursor and resume with fresh source data.
            _pendingAudio = nil;
            _sourceDiscontinuity = YES;
        }
        if (_audioCursor < clock.streamTime) {
            NSUInteger missed = (NSUInteger)MIN(clock.streamTime - _audioCursor, 48000);
            if (_audioSource) _audioSource(missed, _channels, CMTimeMake(_audioCursor, 48000), YES);
            _audioCursor = clock.streamTime + 96;
            _sourceDiscontinuity = YES;
        }
    }
    if (!_pendingAudio) {
        int64_t needed = clock.streamTime + _audioCapacity - _audioCursor;
        if (needed <= 0 || clock.audioSamples >= _audioCapacity) return;
        UInt32 count = (UInt32)MIN((NSUInteger)needed, _audioCapacity - clock.audioSamples);
        NSData *data = _audioSource ? _audioSource(count, _channels, CMTimeMake(_audioCursor, 48000), _sourceDiscontinuity) : nil;
        _sourceDiscontinuity = NO;
        if (data.length != count * _bytesPerFrame) data = [NSMutableData dataWithLength:count * _bytesPerFrame];
        DeckLinkSessionAudioPacket *packet = [DeckLinkSessionAudioPacket new];
        packet.data = data; packet.samples = count; packet.time = _audioCursor;
        _pendingAudio = packet; _audioCursor += count;
    }
    // A source is required to be nonblocking, but a contended source lock can
    // still overrun its deadline. Refresh after a slow read before submitting PCM.
    if (_state == DeckLinkSessionRunning && CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - clock.hostTime > 0.002) {
        if (![self readClock:&clock]) return;
        if (_pendingAudio.time + _pendingAudio.offset < clock.streamTime) {
            _pendingAudio = nil; _sourceDiscontinuity = YES; return;
        }
    }
    DeckLinkSessionAudioPacket *packet = _pendingAudio;
    if (clock.audioSamples >= _audioCapacity) return;
    UInt32 requested = (UInt32)MIN(packet.samples - packet.offset, _audioCapacity - clock.audioSamples);
    UInt32 written = 0;
    const uint8_t *bytes = (const uint8_t *)packet.data.bytes + packet.offset * _bytesPerFrame;
    HRESULT status = [_device writeAudioOnPlaybackQueue:bytes sampleFrameCount:requested
        streamTime:packet.time + packet.offset timeScale:48000 written:&written];
    if (status != S_OK || written > requested) { [self fail:status == S_OK ? E_FAIL : status]; return; }
    if (written) {
        packet.offset += written;
        _lastAudioProgressHostTime = clock.hostTime;
        if (packet.offset == packet.samples) _pendingAudio = nil;
        [self reportReadyIfPrerolled];
    } else if (clock.hostTime - _lastAudioProgressHostTime >= 0.25) {
        [self fail:E_FAIL];
    }
    // Zero/partial acceptance is backpressure. Retry on the next 2 ms tick;
    // retain the original PCM and offset, without allocating/copying its suffix.
}

@end

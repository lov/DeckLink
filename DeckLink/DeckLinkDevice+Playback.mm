#import "DeckLinkDevice+Playback.h"

#import "CMFormatDescription+DeckLink.h"
#import "DeckLinkAPI.h"
#import "DeckLinkAudioConnection+Internal.h"
#import "DeckLinkDevice+Internal.h"
#import "DeckLinkPlaybackSession+Internal.h"
#import "DeckLinkKeying.h"
#import "DeckLinkVideoConnection+Internal.h"


#include <limits.h>

static char DeckLinkPlaybackQueueKey;

@interface DeckLinkScheduledFrame : NSObject {
@public
    IDeckLinkMutableVideoFrame *frame;
    CVPixelBufferRef pixelBuffer;
}
// Set before preparation is dispatched; unchanged through completion.
@property (nonatomic, copy) DeckLinkScheduledFrameCompletion completion;
@end
@implementation DeckLinkScheduledFrame
- (void)dealloc {
    if (frame) frame->Release();
    if (pixelBuffer) CFRelease(pixelBuffer);
}
@end

@implementation DeckLinkDevice (Playback)

- (void)initializePlaybackScheduling {
    self.playbackQueue = dispatch_queue_create("DeckLinkDevice.playbackQueue", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_queue_set_specific(self.playbackQueue, &DeckLinkPlaybackQueueKey, (__bridge void *)self, NULL);
    self.frameDownloadQueue = dispatch_queue_create("DeckLinkDevice.frameDownloadQueue", DISPATCH_QUEUE_SERIAL);
    _scheduledFrames = [NSMutableDictionary new];
    _scheduledStopHandlers = [NSMutableArray new];
    atomic_init(&_scheduledFrameCount, 0);
    atomic_init(&_playbackGeneration, 0);
    atomic_init(&_scheduledStopRequested, false);
}

- (HRESULT)installScheduledPlaybackCallback {
    if (deckLinkOutputCallback) return S_OK;
    DeckLinkDeviceInternalOutputCallback *callback = new DeckLinkDeviceInternalOutputCallback((id<DeckLinkDeviceInternalOutputCallbackDelegate>)self);
    HRESULT status = deckLinkOutput->SetScheduledFrameCompletionCallback(callback);
    if (status != S_OK) callback->Release();
    else deckLinkOutputCallback = callback;
    return status;
}

- (void)finishScheduledStop:(HRESULT)status {
    _scheduledStopState = DeckLinkScheduledStopIdle;
    if (status == S_OK) self.playbackActive = NO;
    atomic_store(&_scheduledStopRequested, false);
    NSArray *handlers = [_scheduledStopHandlers copy];
    [_scheduledStopHandlers removeAllObjects];
    // Finish the current frame/preparation callback before session cleanup can disable output.
    dispatch_async(self.playbackQueue, ^{
        for (DeckLinkPlaybackStatusCompletion handler in handlers) handler(status);
    });
}

- (void)finishScheduledStopIfReady {
    if (_scheduledStopState == DeckLinkScheduledStopWaitingForFrames && !atomic_load(&_scheduledFrameCount))
        [self finishScheduledStop:S_OK];
}

- (void)finishScheduledFrame:(NSValue *)key result:(BMDOutputFrameCompletionResult)result {
    DeckLinkScheduledFrame *entry = _scheduledFrames[key];
    if (!entry) return;
    [_scheduledFrames removeObjectForKey:key];
    atomic_fetch_sub(&_scheduledFrameCount, 1);
    DeckLinkScheduledFrameCompletion completion = entry.completion;
    if (completion) completion(result);
    [self finishScheduledStopIfReady];
}


- (void)setupPlayback
{
	if(deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&deckLinkOutput) != S_OK)
	{
		return;
	}
	
	HRESULT status = deckLinkConfiguration->SetFlag(bmdDeckLinkConfigFieldFlickerRemoval, false);
	if (status != S_OK)
	{
		NSLog(@"Decklink: error turning off bmdDeckLinkConfigFieldFlickerRemoval");
	} else {
		
		NSLog(@"Decklink: turned off bmdDeckLinkConfigFieldFlickerRemoval");

	}

	
	self.playbackSupported = YES;
	
	[self initializePlaybackScheduling];
	
	[self refreshPlaybackFormats];
    if (deckLinkKeyer) {
        deckLinkKeyer->SetLevel(255);
        deckLinkKeyer->Disable();
    }
}

- (void)refreshPlaybackFormats {
	// Video
	IDeckLinkDisplayModeIterator *displayModeIterator = NULL;
	if (deckLinkOutput->GetDisplayModeIterator(&displayModeIterator) == S_OK)
	{
		BMDPixelFormat pixelFormats[] = {
			bmdFormat8BitYUV, // 8-bit Y'CbCr 4:2:2, == kCVPixelFormatType_422YpCbCr8 == '2vuy'
			bmdFormat10BitYUV, // 10-bit Y'CbCr 4:2:2, == kCVPixelFormatType_422YpCbCr10 == 'v210'
			bmdFormat10BitYUVA, // 10-bit Y'CbCrA 4:2:2:4 with alpha, 'Ay10'
			kDeckLinkPrimaryRGBPixelFormat, // 8-bit BGRA with alpha
		};
		
		NSMutableArray *formatDescriptions = [NSMutableArray array];
		
		IDeckLinkDisplayMode *displayMode = NULL;
		while (displayModeIterator->Next(&displayMode) == S_OK)
		{
			BMDDisplayMode displayModeKey = displayMode->GetDisplayMode();
			
			for (size_t index = 0; index < sizeof(pixelFormats) / sizeof(*pixelFormats); ++index)
			{
				BMDPixelFormat pixelFormat = pixelFormats[index];
				
				bool supported = false;
				if (deckLinkOutput->DoesSupportVideoMode(bmdVideoConnectionUnspecified, displayModeKey, pixelFormat, bmdNoVideoOutputConversion, bmdVideoOutputFlagDefault, NULL, &supported) == S_OK && supported)
				{
					CMVideoFormatDescriptionRef formatDescription = NULL;
					if(CMVideoFormatDescriptionCreateWithDeckLinkDisplayMode(displayMode, pixelFormat, true, &formatDescription) == noErr)
					{
						[formatDescriptions addObject:(__bridge id)formatDescription];
						CFRelease(formatDescription);
					}
				}
			}
            displayMode->Release();
		}
		displayModeIterator->Release();
		
		self.playbackVideoFormatDescriptions = formatDescriptions;
		// TODO: get active format description from the device
	}
	
	// Audio
	{
		int64_t maxaudiochannels;
		deckLinkAttributes->GetInt(BMDDeckLinkMaximumAudioChannels, &maxaudiochannels);

		NSMutableArray *formatDescriptions = [NSMutableArray new];
		
		if (maxaudiochannels>=2) {
			
			//
			// for now, we only support 16bit audio
			//
			
			// bmdAudioSampleRate48kHz / bmdAudioSampleType16bitInteger
			{
				const AudioStreamBasicDescription streamBasicDescription = { 48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 4, 1, 4, 2, 16, 0 };
				const AudioChannelLayout channelLayout = { kAudioChannelLayoutTag_Stereo, 0 };
				
				NSDictionary *extensions = @{
					(__bridge id)kCMFormatDescriptionExtension_FormatName: @"48.000 Hz, 16-bit, stereo"
				};
				
				CMAudioFormatDescriptionRef formatDescription = NULL;
				CMAudioFormatDescriptionCreate(NULL, &streamBasicDescription, sizeof(channelLayout), &channelLayout, 0, NULL, (__bridge CFDictionaryRef)extensions, &formatDescription);
				
				if (formatDescription != NULL)
				{
					[formatDescriptions addObject:(__bridge id)formatDescription];
				}
			}
			
			/*
			// bmdAudioSampleRate48kHz / bmdAudioSampleType32bitInteger
			{
				const AudioStreamBasicDescription streamBasicDescription = { 48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 8, 1, 8, 2, 32, 0 };
				const AudioChannelLayout channelLayout = { kAudioChannelLayoutTag_Stereo, 0 };
				
				NSDictionary *extensions = @{
					(__bridge id)kCMFormatDescriptionExtension_FormatName: @"48.000 Hz, 32-bit, stereo"
				};
				
				CMAudioFormatDescriptionRef formatDescription = NULL;
				CMAudioFormatDescriptionCreate(NULL, &streamBasicDescription, sizeof(channelLayout), &channelLayout, 0, NULL, (__bridge CFDictionaryRef)extensions, &formatDescription);
				
				if (formatDescription != NULL)
				{
					[formatDescriptions addObject:(__bridge id)formatDescription];
				}
			}
			*/

		}
		
		if (maxaudiochannels>=8) {
			
			
			// bmdAudioSampleRate48kHz / bmdAudioSampleType16bitInteger
			{
				const AudioStreamBasicDescription streamBasicDescription = { 48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 4, 1, 4, 8, 16, 0 };
				const AudioChannelLayout channelLayout = { kAudioChannelLayoutTag_DiscreteInOrder| 8, 0 };
				
				
				NSDictionary *extensions = @{
					(__bridge id)kCMFormatDescriptionExtension_FormatName: @"48.000 Hz, 16-bit, 8 channels"
				};
				
				CMAudioFormatDescriptionRef formatDescription = NULL;
				CMAudioFormatDescriptionCreate(NULL, &streamBasicDescription, sizeof(channelLayout), &channelLayout, 0, NULL, (__bridge CFDictionaryRef)extensions, &formatDescription);
				
				if (formatDescription != NULL)
				{
					[formatDescriptions addObject:(__bridge id)formatDescription];
				}
			}
			
			/*
			// bmdAudioSampleRate48kHz / bmdAudioSampleType32bitInteger
			{
				const AudioStreamBasicDescription streamBasicDescription = { 48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 8, 1, 8, 8, 32, 0 };
				const AudioChannelLayout channelLayout = { kAudioChannelLayoutTag_DiscreteInOrder | 8, 0 };

				NSDictionary *extensions = @{
					(__bridge id)kCMFormatDescriptionExtension_FormatName: @"48.000 Hz, 32-bit, 8 channels"
				};
				
				CMAudioFormatDescriptionRef formatDescription = NULL;
				CMAudioFormatDescriptionCreate(NULL, &streamBasicDescription, sizeof(channelLayout), &channelLayout, 0, NULL, (__bridge CFDictionaryRef)extensions, &formatDescription);
				
				if (formatDescription != NULL)
				{
					[formatDescriptions addObject:(__bridge id)formatDescription];
				}
			}
			*/
		}

		if (maxaudiochannels>=16) {
			
			
			// bmdAudioSampleRate48kHz / bmdAudioSampleType16bitInteger
			{
				const AudioStreamBasicDescription streamBasicDescription = { 48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 4, 1, 4, 16, 16, 0 };
				const AudioChannelLayout channelLayout = { kAudioChannelLayoutTag_DiscreteInOrder| 16, 0 };
				
				
				NSDictionary *extensions = @{
					(__bridge id)kCMFormatDescriptionExtension_FormatName: @"48.000 Hz, 16-bit, 16 channels"
				};
				
				CMAudioFormatDescriptionRef formatDescription = NULL;
				CMAudioFormatDescriptionCreate(NULL, &streamBasicDescription, sizeof(channelLayout), &channelLayout, 0, NULL, (__bridge CFDictionaryRef)extensions, &formatDescription);
				
				if (formatDescription != NULL)
				{
					[formatDescriptions addObject:(__bridge id)formatDescription];
				}
			}
			
			/*
			// bmdAudioSampleRate48kHz / bmdAudioSampleType32bitInteger
			{
				const AudioStreamBasicDescription streamBasicDescription = { 48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 8, 1, 8, 16, 32, 0 };
				const AudioChannelLayout channelLayout = { kAudioChannelLayoutTag_DiscreteInOrder | 16, 0 };

				NSDictionary *extensions = @{
					(__bridge id)kCMFormatDescriptionExtension_FormatName: @"48.000 Hz, 32-bit, 16 channels"
				};
				
				CMAudioFormatDescriptionRef formatDescription = NULL;
				CMAudioFormatDescriptionCreate(NULL, &streamBasicDescription, sizeof(channelLayout), &channelLayout, 0, NULL, (__bridge CFDictionaryRef)extensions, &formatDescription);
				
				if (formatDescription != NULL)
				{
					[formatDescriptions addObject:(__bridge id)formatDescription];
				}
			}
			 */

		}

		
		self.playbackAudioFormatDescriptions = formatDescriptions;
		// TODO: get active format description
	}
	
	if (deckLinkKeyer != NULL)
	{
		NSMutableArray *keyingModes = [NSMutableArray array];
		
		[keyingModes addObject:DeckLinkKeyingModeNone];
		
		bool supportsInternalKeying = false;
		deckLinkAttributes->GetFlag(BMDDeckLinkSupportsInternalKeying, &supportsInternalKeying);
		if (supportsInternalKeying)
		{
			[keyingModes addObject:DeckLinkKeyingModeInternal];
		}

		bool supportsExternalKeying = false;
		deckLinkAttributes->GetFlag(BMDDeckLinkSupportsExternalKeying, &supportsExternalKeying);
		if (supportsExternalKeying)
		{
			[keyingModes addObject:DeckLinkKeyingModeExternal];
		}

		self.playbackKeyingModes = keyingModes;

	}
	else
	{
		self.playbackKeyingModes = @[ DeckLinkKeyingModeNone ];
	}
}

// Shared exclusion check for configuration changes. Call on playbackQueue.
- (BOOL)hasScheduledPlaybackOnQueue {
    return self.playbackActive || atomic_load(&_scheduledFrameCount) || atomic_load(&_scheduledStopRequested);
}

- (BOOL)canOpenPlaybackSessionOnQueue {
    return deckLinkOutput && !self.scheduledPlaybackSession && ![self hasScheduledPlaybackOnQueue] && !_audioPrerollActive;
}

- (void)performPlaybackSync:(dispatch_block_t)block {
    if (dispatch_get_specific(&DeckLinkPlaybackQueueKey) == (__bridge void *)self) block();
    else dispatch_sync(self.playbackQueue, block);
}

- (HRESULT)validateVideoFormatOnQueue:(CMVideoFormatDescriptionRef)format keyingMode:(NSString *)keyingMode {
    if (!deckLinkAttributes || !deckLinkOutput || !format) return E_INVALIDARG;
    int64_t support = 0, duplex = bmdDuplexInactive;
    if (deckLinkAttributes->GetInt(BMDDeckLinkVideoIOSupport, &support) != S_OK || !(support & bmdDeviceSupportsPlayback) ||
        deckLinkAttributes->GetInt(BMDDeckLinkDuplex, &duplex) != S_OK || duplex == bmdDuplexInactive) return E_ACCESSDENIED;
    NSNumber *mode = (__bridge NSNumber *)CMFormatDescriptionGetExtension(format, DeckLinkFormatDescriptionDisplayModeKey);
    if (![mode isKindOfClass:NSNumber.class]) return E_INVALIDARG;
    // A keyed output must play the mode and pixel format with the keyer on, not merely without it.
    BOOL keying = keyingMode && ![keyingMode isEqualToString:DeckLinkKeyingModeNone];
    bool supported = false;
    HRESULT status = deckLinkOutput->DoesSupportVideoMode(bmdVideoConnectionUnspecified, mode.intValue,
        CMFormatDescriptionGetMediaSubType(format), bmdNoVideoOutputConversion, keying ? bmdSupportedVideoModeKeying : bmdSupportedVideoModeDefault,
        NULL, &supported);
    return status != S_OK ? status : (supported ? S_OK : E_INVALIDARG);
}

- (HRESULT)configurePlaybackGroupOnQueue:(int64_t)groupID {
    if (!deckLinkConfiguration || [self hasScheduledPlaybackOnQueue]) return E_ACCESSDENIED;
    HRESULT status = deckLinkConfiguration->GetInt(bmdDeckLinkConfigPlaybackGroup, &_previousPlaybackGroup);
    if (status == S_OK) {
        _hasPreviousPlaybackGroup = YES;
        status = deckLinkConfiguration->SetInt(bmdDeckLinkConfigPlaybackGroup, groupID);
    }
    if (status == S_OK) _playbackVideoOutputFlags = bmdVideoOutputSynchronizeToPlaybackGroup;
    return status;
}

// Best effort: outputs join a group only when enabled with
// bmdVideoOutputSynchronizeToPlaybackGroup, so a stale ID must not block cleanup.
// The flags always reset, so later single outputs never request grouping.
- (void)restorePlaybackGroupOnQueue {
    if (_hasPreviousPlaybackGroup && deckLinkConfiguration &&
        deckLinkConfiguration->SetInt(bmdDeckLinkConfigPlaybackGroup, _previousPlaybackGroup) != S_OK)
        NSLog(@"DeckLink: could not restore playback group %lld", _previousPlaybackGroup);
    _hasPreviousPlaybackGroup = NO;
    _playbackVideoOutputFlags = bmdVideoOutputFlagDefault;
}

- (HRESULT)setVideoFormatOnPlaybackQueue:(CMVideoFormatDescriptionRef)format {
    if (!deckLinkOutput || [self hasScheduledPlaybackOnQueue]) return E_ACCESSDENIED;
    NSNumber *mode = nil;
    if (format) {
        if (![self.playbackVideoFormatDescriptions containsObject:(__bridge id)format]) return E_INVALIDARG;
        mode = (__bridge NSNumber *)CMFormatDescriptionGetExtension(format, DeckLinkFormatDescriptionDisplayModeKey);
        if (![mode isKindOfClass:NSNumber.class]) return E_INVALIDARG;
    }
    HRESULT status = self.playbackActiveVideoFormatDescription ? deckLinkOutput->DisableVideoOutput() : S_OK;
    if (status != S_OK) return status;
    self.playbackActiveVideoFormatDescription = NULL;
    if (format) status = deckLinkOutput->EnableVideoOutput(mode.intValue, _playbackVideoOutputFlags);
    if (status == S_OK) self.playbackActiveVideoFormatDescription = format;
    return status;
}

- (HRESULT)setAudioFormatOnPlaybackQueue:(CMAudioFormatDescriptionRef)format {
    if (!deckLinkOutput || [self hasScheduledPlaybackOnQueue]) return E_ACCESSDENIED;
    const AudioStreamBasicDescription *asbd = format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
    if (format && (![self.playbackAudioFormatDescriptions containsObject:(__bridge id)format] || !asbd)) return E_INVALIDARG;
    HRESULT status = self.playbackActiveAudioFormatDescription ? deckLinkOutput->DisableAudioOutput() : S_OK;
    if (status != S_OK) return status;
    self.playbackActiveAudioFormatDescription = NULL;
    if (format) status = deckLinkOutput->EnableAudioOutput((BMDAudioSampleRate)asbd->mSampleRate,
        (BMDAudioSampleType)asbd->mBitsPerChannel, asbd->mChannelsPerFrame, bmdAudioOutputStreamTimestamped);
    if (status == S_OK) self.playbackActiveAudioFormatDescription = format;
    return status;
}

- (HRESULT)setKeyingOnPlaybackQueue:(NSString *)mode {
    if (!deckLinkOutput || [self hasScheduledPlaybackOnQueue]) return E_ACCESSDENIED;
    if (!mode || [mode isEqualToString:DeckLinkKeyingModeNone]) return deckLinkKeyer ? deckLinkKeyer->Disable() : S_OK;
    if (!deckLinkKeyer || !([mode isEqualToString:DeckLinkKeyingModeInternal] || [mode isEqualToString:DeckLinkKeyingModeExternal])) return E_INVALIDARG;
    HRESULT status = deckLinkKeyer->Enable([mode isEqualToString:DeckLinkKeyingModeExternal]);
    return status == S_OK ? deckLinkKeyer->SetLevel(255) : status;
}

- (HRESULT)endAudioPrerollOnQueue {
    HRESULT status = _audioPrerollActive ? deckLinkOutput->EndAudioPreroll() : S_OK;
    if (status == S_OK) _audioPrerollActive = NO;
    return status;
}

- (HRESULT)startPlaybackOnQueue:(int64_t)timeScale {
    if (!deckLinkOutput || atomic_load(&_scheduledStopRequested) || timeScale <= 0) return E_ACCESSDENIED;
    HRESULT status = [self installScheduledPlaybackCallback];
    return status == S_OK ? deckLinkOutput->StartScheduledPlayback(0, timeScale, 1.0) : status;
}

// Admission includes frames still being prepared. The time provider executes on
// playbackQueue immediately before ScheduleVideoFrame, not before GPU/CPU work.
- (void)enqueuePlaybackPixelBuffer:(CVPixelBufferRef)pixelBuffer frameDuration:(int64_t)duration timeScale:(int64_t)scale
                    maximumFrames:(NSUInteger)maximum displayTime:(int64_t (^)(void))displayTime
                         accepted:(void (^)(HRESULT))accepted completed:(DeckLinkScheduledFrameCompletion)completed {
    void (^reject)(HRESULT) = ^(HRESULT status) { dispatch_async(self.playbackQueue, ^{ if (accepted) accepted(status); }); };
    if (!deckLinkOutput || !pixelBuffer || duration <= 0 || scale <= 0 || !maximum) { reject(E_INVALIDARG); return; }
    if (atomic_load(&_scheduledStopRequested)) { reject(E_ABORT); return; }
    uint64_t generation = atomic_load(&_playbackGeneration);
    uint_fast64_t count = atomic_load(&_scheduledFrameCount);
    do {
        if (count >= maximum) { reject(E_OUTOFMEMORY); return; }
    } while (!atomic_compare_exchange_weak(&_scheduledFrameCount, &count, count + 1));
    DeckLinkScheduledFrame *entry = [DeckLinkScheduledFrame new];
    entry->pixelBuffer = CVPixelBufferRetain(pixelBuffer);
    entry.completion = completed;
    dispatch_async(self.frameDownloadQueue, ^{
        HRESULT prepared = E_ABORT;
        if (generation == atomic_load(&_playbackGeneration) && !atomic_load(&_scheduledStopRequested)) {
            IDeckLinkMacOutput *macOutput = NULL;
            prepared = deckLinkOutput->QueryInterface(IID_IDeckLinkMacOutput, (void **)&macOutput);
            if (prepared == S_OK) prepared = macOutput->CreateVideoFrameFromCVPixelBufferRef(entry->pixelBuffer, &entry->frame);
            if (macOutput) macOutput->Release();
        }
        dispatch_async(self.playbackQueue, ^{
            HRESULT status = prepared;
            if (generation != atomic_load(&_playbackGeneration) || atomic_load(&_scheduledStopRequested)) status = E_ABORT;
            int64_t time = -1;
            if (status == S_OK) {
                time = displayTime();
                // A negative time means the session no longer needs this frame/slot.
                if (time < 0) status = S_FALSE;
                else if (time > INT64_MAX - duration) status = E_INVALIDARG;
            }
            if (status == S_OK) status = [self installScheduledPlaybackCallback];
            if (status == S_OK) {
                NSValue *key = [NSValue valueWithPointer:entry->frame];
                _scheduledFrames[key] = entry;
                status = deckLinkOutput->ScheduleVideoFrame(entry->frame, time, duration, scale);
                if (status != S_OK) [_scheduledFrames removeObjectForKey:key];
            }
            if (status != S_OK) atomic_fetch_sub(&_scheduledFrameCount, 1);
            if (accepted) accepted(status);
            [self finishScheduledStopIfReady];
        });
    });
}

- (void)scheduledFrameCompleted:(IDeckLinkVideoFrame *)frame result:(BMDOutputFrameCompletionResult)result {
    NSValue *key = [NSValue valueWithPointer:frame];
    dispatch_async(self.playbackQueue, ^{ [self finishScheduledFrame:key result:result]; });
}

- (void)scheduledPlaybackHasStopped {
    dispatch_async(self.playbackQueue, ^{
        if (_scheduledStopState == DeckLinkScheduledStopWaitingForDriver)
            _scheduledStopState = DeckLinkScheduledStopWaitingForFrames;
        self.playbackActive = NO;
        [self.scheduledPlaybackSession devicePlaybackStoppedOnQueue];
        [self finishScheduledStopIfReady];
    });
}

- (void)armStopWithCompletion:(DeckLinkPlaybackStatusCompletion)completion armed:(DeckLinkPlaybackStatusCompletion)armed {
    atomic_store(&_scheduledStopRequested, true);
    atomic_fetch_add(&_playbackGeneration, 1);
    // Drain preparation first. Cancellation is visible immediately, so prepared
    // frames cannot enter the old scheduler.
    dispatch_async(self.frameDownloadQueue, ^{
        dispatch_async(self.playbackQueue, ^{
            if (completion) [_scheduledStopHandlers addObject:[completion copy]];
            _scheduledStopState = DeckLinkScheduledStopWaitingForDriver;
            HRESULT status = [self endAudioPrerollOnQueue];
            if (armed) armed(status);
        });
    });
}

- (HRESULT)getPlaybackRunningOnQueue:(BOOL *)running {
    bool nativeRunning = false;
    HRESULT status = deckLinkOutput->IsScheduledPlaybackRunning(&nativeRunning);
    *running = nativeRunning;
    return status;
}

- (HRESULT)requestStopOnQueue {
    return deckLinkOutput->StopScheduledPlayback(0, NULL, 0);
}

- (void)completeStopOnQueue:(HRESULT)status wasRunning:(BOOL)running {
    if (status != S_OK) { [self finishScheduledStop:status]; return; }
    if (running) { [self finishScheduledStopIfReady]; return; }
    // Never-started or already-stopped output has no future stopped callback.
    // Disabling flushes retained native frames; closed outputs are never reenabled.
    status = self.playbackActiveVideoFormatDescription || _scheduledFrames.count ? deckLinkOutput->DisableVideoOutput() : S_OK;
    if (status == S_OK) {
        self.playbackActiveVideoFormatDescription = NULL;
        for (NSValue *key in [_scheduledFrames.allKeys copy]) [self finishScheduledFrame:key result:bmdOutputFrameFlushed];
        if (self.playbackActiveAudioFormatDescription) status = deckLinkOutput->FlushBufferedAudioSamples();
    }
    _scheduledStopState = DeckLinkScheduledStopWaitingForFrames;
    if (status == S_OK) [self finishScheduledStopIfReady];
    else [self finishScheduledStop:status];
}

- (HRESULT)writeAudioOnPlaybackQueue:(const void *)bytes sampleFrameCount:(UInt32)count
                         streamTime:(int64_t)time timeScale:(int64_t)scale written:(UInt32 *)written {
    *written = 0;
    if (!deckLinkOutput || !bytes || !count || time < 0 || scale <= 0) return E_INVALIDARG;
    if (atomic_load(&_scheduledStopRequested)) return E_ABORT;
    HRESULT status = S_OK;
    if (!self.playbackActive && !_audioPrerollActive) {
        status = deckLinkOutput->BeginAudioPreroll();
        if (status == S_OK) _audioPrerollActive = YES;
    }
    if (status == S_OK) status = deckLinkOutput->ScheduleAudioSamples((void *)bytes, count, time, scale, written);
    return status;
}

- (HRESULT)readPlaybackClockOnQueue:(DeckLinkPlaybackClock *)clock {
    *clock = {};
    if (!deckLinkOutput) return E_ACCESSDENIED;
    HRESULT status = deckLinkOutput->IsScheduledPlaybackRunning(&clock->running);
    if (status == S_OK && self.playbackActiveAudioFormatDescription) status = deckLinkOutput->GetBufferedAudioSampleFrameCount(&clock->audioSamples);
    // Pair host and stream time at the native query, before any callback dispatch.
    double before = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
    if (status == S_OK && clock->running) status = deckLinkOutput->GetScheduledStreamTime(48000, &clock->streamTime, &clock->speed);
    double after = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
    clock->hostTime = (before + after) * 0.5;
    return status;
}

@end

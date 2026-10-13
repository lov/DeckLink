#import "DeckLinkDevice.h"

#import <CoreMedia/CoreMedia.h>
#include <atomic>
#import "DeckLinkAPI.h"
#import "DeckLinkDevice+Internal.h"
#import "DeckLinkPlaybackSession+Internal.h"

@interface DeckLinkPlaybackGroupAttributes ()
- (instancetype)initWithAttributes:(IDeckLinkProfileAttributes *)attributes modelName:(NSString *)modelName;
@end

@implementation DeckLinkPlaybackGroupAttributes
- (instancetype)initWithAttributes:(IDeckLinkProfileAttributes *)attributes modelName:(NSString *)modelName {
    self = [super init];
    if (self) {
        int64_t value = 0;
        _deviceGroupID = attributes && attributes->GetInt(BMDDeckLinkDeviceGroupID, &value) == S_OK ? @(value) : nil;
        _subDeviceIndex = attributes && attributes->GetInt(BMDDeckLinkSubDeviceIndex, &value) == S_OK ? @(value) : nil;
        _numberOfSubDevices = attributes && attributes->GetInt(BMDDeckLinkNumberOfSubDevices, &value) == S_OK && value > 0 ? (NSUInteger)value : 0;
        bool supported = false;
        _supportsPlaybackSynchronization = attributes && attributes->GetFlag(BMDDeckLinkSupportsSynchronizeToPlaybackGroup, &supported) == S_OK && supported;
        _minimumPrerollVideoFrames = attributes && attributes->GetInt(BMDDeckLinkMinimumPrerollFrames, &value) == S_OK && value > 0 ? (NSUInteger)value : 1;
        _playbackGroupRequiresReference = ![modelName isEqualToString:@"DeckLink 8K Pro"];
    }
    return self;
}
@end

class DeckLinkProfileCallback : public IDeckLinkProfileCallback {
    std::atomic<ULONG> refs {1};
    __weak DeckLinkDevice *device;
public:
    DeckLinkProfileCallback(DeckLinkDevice *value) : device(value) {}
    HRESULT QueryInterface(REFIID iid, LPVOID *value) override {
        if (!value) return E_POINTER;
        *value = nullptr;
        CFUUIDBytes unknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (memcmp(&iid, &IID_IDeckLinkProfileCallback, sizeof(iid)) && memcmp(&iid, &unknown, sizeof(iid))) return E_NOINTERFACE;
        *value = this; AddRef(); return S_OK;
    }
    ULONG AddRef() override { return ++refs; }
    ULONG Release() override { ULONG count = --refs; if (!count) delete this; return count; }
    HRESULT ProfileChanging(IDeckLinkProfile *, bool) override { [device invalidatePlayback]; return S_OK; }
    HRESULT ProfileActivated(IDeckLinkProfile *) override {
        DeckLinkDevice *target = device;
        if (target.playbackQueue) dispatch_async(target.playbackQueue, ^{
            [target refreshPlaybackGroupAttributes];
            [target refreshPlaybackFormats];
        });
        else [target refreshPlaybackGroupAttributes];
        return S_OK;
    }
};


@interface DeckLinkDevice (CaptureSetup)

- (void)setupCapture;

@end


@interface DeckLinkDevice (PlaybackSetup)

- (void)setupPlayback;

@end


@implementation DeckLinkDevice

@dynamic referenceSignalLocked;

@synthesize deckLink = deckLink;

- (instancetype)initWithDeckLink:(IDeckLink *)deckLink_
{
	NSParameterAssert(deckLink_);
	
	self = [super init];
	if (self != nil)
	{
		deckLink = deckLink_;
		deckLink->AddRef();
		
		if (deckLink->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&deckLinkAttributes) != S_OK)
		{
			return nil;
		}
		
		if (deckLink->QueryInterface(IID_IDeckLinkConfiguration, (void **)&deckLinkConfiguration) != S_OK)
		{
			return nil;
		}
				
		if (deckLink->QueryInterface(IID_IDeckLinkKeyer, (void **)&deckLinkKeyer) != S_OK)
		{
			// keyer may be nil
		}
		
		CFStringRef modelName = NULL;
		if (deckLink->GetModelName(&modelName) == S_OK)
		{
			self.modelName = CFBridgingRelease(modelName);
		}
		
		CFStringRef displayName = NULL;
		if (deckLink->GetDisplayName(&displayName) == S_OK)
		{
			self.displayName = CFBridgingRelease(displayName);
		}
		
		int64_t persistantID = 0;
		if(deckLinkAttributes->GetInt(BMDDeckLinkPersistentID, &persistantID) == S_OK)
		{
			self.persistantID = (int32_t)persistantID;
		}
		
		int64_t topologicalID = 0;
		if(deckLinkAttributes->GetInt(BMDDeckLinkTopologicalID, &topologicalID) == S_OK)
		{
			self.topologicalID = (int32_t)topologicalID;
		}
		
		[self setupCapture];
		[self setupPlayback];
        deckLink->QueryInterface(IID_IDeckLinkStatus, (void **)&deckLinkStatus);
        [self refreshPlaybackGroupAttributes];
        if (deckLink->QueryInterface(IID_IDeckLinkProfileManager, (void **)&deckLinkProfileManager) == S_OK) {
            deckLinkProfileCallback = new DeckLinkProfileCallback(self);
            if (deckLinkProfileManager->SetCallback(deckLinkProfileCallback) != S_OK) {
                deckLinkProfileCallback->Release(); deckLinkProfileCallback = NULL;
            }
        }
	}
	return self;
}

- (void)refreshPlaybackGroupAttributes {
    dispatch_block_t refresh = ^{
        self.playbackGroupAttributes = [[DeckLinkPlaybackGroupAttributes alloc] initWithAttributes:deckLinkAttributes modelName:self.modelName];
    };
    // Serialize driver queries with playback and other profile refreshes.
    if (self.playbackQueue) [self performPlaybackSync:refresh];
    else refresh();
}

- (BOOL)referenceSignalLocked {
    if (!self.playbackQueue) return NO;
    __block bool locked = false;
    [self performPlaybackSync:^{
        if (deckLinkStatus) deckLinkStatus->GetFlag(bmdDeckLinkStatusReferenceSignalLocked, &locked);
    }];
    return locked;
}

- (void)invalidatePlayback {
    if (!self.playbackQueue) return;
    dispatch_async(self.playbackQueue, ^{ [self.scheduledPlaybackSession fail:E_ABORT]; });
}

- (void)dealloc
{
    if (deckLinkProfileManager) {
        if (deckLinkProfileCallback) deckLinkProfileManager->SetCallback(NULL);
        deckLinkProfileManager->Release();
    }
    if (deckLinkProfileCallback) deckLinkProfileCallback->Release();
    if (deckLinkStatus) deckLinkStatus->Release();
	if (deckLinkOutput != NULL)
	{
		// Stop/disable before dropping retained scheduled buffers or the callback.
        if (self.playbackActive) deckLinkOutput->StopScheduledPlayback(0, NULL, 0);
        deckLinkOutput->DisableAudioOutput();
        deckLinkOutput->DisableVideoOutput();
        deckLinkOutput->SetScheduledFrameCompletionCallback(NULL);
        deckLinkOutput->SetAudioCallback(NULL);
        [_scheduledFrames removeAllObjects];
        if (deckLinkOutputCallback) {
            deckLinkOutputCallback->Release();
            deckLinkOutputCallback = NULL;
        }
        deckLinkOutput->Release();
		deckLinkOutput = NULL;
	}
	
	if (deckLinkInputCallback != NULL)
	{
		deckLinkInputCallback->Release();
		deckLinkInputCallback = NULL;
	}
	
	if (deckLinkInput != NULL)
	{
		deckLinkInput->Release();
		deckLinkInput = NULL;
	}
	
	if (deckLinkKeyer != NULL)
	{
		deckLinkKeyer->Release();
		deckLinkKeyer = NULL;
	}
	
	if (deckLinkConfiguration != NULL)
	{
		deckLinkConfiguration->Release();
		deckLinkConfiguration = NULL;
	}
	
	if (deckLinkAttributes != NULL)
	{
		deckLinkAttributes->Release();
		deckLinkAttributes = NULL;
	}
	
	if (deckLink != NULL)
	{
		deckLink->Release();
		deckLink = NULL;
	}
}

@end

#include <vector>
#include <algorithm>
#include <string>
#include <atomic>
#import "../DeckLink/DeckLinkPlaybackGroup+Internal.h"
#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "../DeckLink/DeckLinkDevice+Internal.h"
#import "../DeckLink/DeckLinkPlaybackSession+Internal.h"
#import "../DeckLink/CMFormatDescription+DeckLink.h"


static atomic_int liveFrames = 0;
class TestFrame : public IDeckLinkMutableVideoFrame {
    atomic_uint refs;
public:
    TestFrame() { atomic_init(&refs, 1); ++liveFrames; }
    ~TestFrame() { --liveFrames; }
    HRESULT QueryInterface(REFIID iid, LPVOID *value) override { *value = nullptr; return E_NOINTERFACE; }
    ULONG AddRef() override { return ++refs; }
    ULONG Release() override { auto n = --refs; if (!n) delete this; return n; }
long GetWidth (void) override { return 16; }
long GetHeight (void) override { return 16; }
long GetRowBytes (void) override { return 64; }
BMDPixelFormat GetPixelFormat (void) override { return bmdFormat8BitBGRA; }
BMDFrameFlags GetFlags (void) override { return bmdFrameFlagDefault; }
HRESULT GetTimecode ( BMDTimecodeFormat format,  IDeckLinkTimecode** timecode) override { return E_NOTIMPL; }
HRESULT GetAncillaryData ( IDeckLinkVideoFrameAncillary** ancillary) override { return E_NOTIMPL; }
HRESULT SetFlags ( BMDFrameFlags newFlags) override { return E_NOTIMPL; }
HRESULT SetTimecode ( BMDTimecodeFormat format,  IDeckLinkTimecode* timecode) override { return E_NOTIMPL; }
HRESULT SetTimecodeFromComponents ( BMDTimecodeFormat format,  uint8_t hours,  uint8_t minutes,  uint8_t seconds,  uint8_t frames,  BMDTimecodeFlags flags) override { return E_NOTIMPL; }
HRESULT SetAncillaryData ( IDeckLinkVideoFrameAncillary* ancillary) override { return E_NOTIMPL; }
HRESULT SetTimecodeUserBits ( BMDTimecodeFormat format,  BMDTimecodeUserBits userBits) override { return E_NOTIMPL; }
HRESULT SetInterfaceProvider ( REFIID iid,  IUnknown* iface) override { return E_NOTIMPL; }
};
class TestHardware : public IDeckLinkProfileAttributes, public IDeckLinkConfiguration, public IDeckLinkStatus, public IDeckLinkProfileManager {
    std::atomic<ULONG> refs {1};
public:
    IDeckLinkProfileCallback *profileCallback = nullptr;
    ~TestHardware() { if (profileCallback) profileCallback->Release(); }
    int64_t cardID = 42, index = 0, groupID = 17, minimumPreroll = 1;
    bool identityAvailable = true, supported = true, outputAvailable = true;
    dispatch_semaphore_t attributesQueryEntered = nil, attributesQueryRelease = nil;
    std::atomic<bool> locked {true};
    HRESULT setGroupStatus = S_OK;
    std::vector<int64_t> groupWrites;
    HRESULT QueryInterface(REFIID, LPVOID *value) override { *value = nullptr; return E_NOINTERFACE; }
    ULONG AddRef() override { return ++refs; }
    ULONG Release() override { auto n = --refs; if (!n) delete this; return n; }
    HRESULT GetFlag(uint32_t key, bool *value) override {
        if (key == BMDDeckLinkSupportsSynchronizeToPlaybackGroup) *value = supported;
        else if (key == bmdDeckLinkStatusReferenceSignalLocked) *value = locked;
        else return E_NOTIMPL;
        return S_OK;
    }
    HRESULT GetInt(uint32_t key, int64_t *value) override {
        switch (key) {
            case BMDDeckLinkDeviceGroupID: if (!identityAvailable) return E_NOTIMPL; *value = cardID; break;
            case BMDDeckLinkSubDeviceIndex:
                if (attributesQueryEntered) {
                    dispatch_semaphore_signal(attributesQueryEntered);
                    dispatch_semaphore_wait(attributesQueryRelease, DISPATCH_TIME_FOREVER);
                }
                *value = index; break;
            case BMDDeckLinkPersistentID: *value = 100 + index; break;
            case BMDDeckLinkMaximumAudioChannels: *value = 2; break;
            case BMDDeckLinkNumberOfSubDevices: *value = 4; break;
            case BMDDeckLinkMinimumPrerollFrames: *value = minimumPreroll; break;
            case BMDDeckLinkVideoIOSupport: *value = bmdDeviceSupportsPlayback; break;
            case BMDDeckLinkDuplex: *value = bmdDuplexHalf; break;
            case bmdDeckLinkConfigPlaybackGroup: *value = groupID; break;
            default: return E_NOTIMPL;
        }
        return S_OK;
    }
    HRESULT SetInt(uint32_t key, int64_t value) override {
        if (key != bmdDeckLinkConfigPlaybackGroup) return E_NOTIMPL;
        if (setGroupStatus != S_OK) return setGroupStatus;
        groupID = value; groupWrites.push_back(value); return S_OK;
    }
    HRESULT SetFlag(uint32_t, bool) override { return E_NOTIMPL; }
    HRESULT GetFloat(uint32_t, double *) override { return E_NOTIMPL; }
    HRESULT SetFloat(uint32_t, double) override { return E_NOTIMPL; }
    HRESULT GetString(uint32_t, CFStringRef *) override { return E_NOTIMPL; }
    HRESULT SetString(uint32_t, CFStringRef) override { return E_NOTIMPL; }
    HRESULT GetBytes(uint32_t, void *, uint32_t *) override { return E_NOTIMPL; }
    HRESULT WriteConfigurationToPreferences() override { return E_NOTIMPL; }
    HRESULT GetProfiles(IDeckLinkProfileIterator **) override { return E_NOTIMPL; }
    HRESULT GetProfile(BMDProfileID, IDeckLinkProfile **) override { return E_NOTIMPL; }
    HRESULT SetCallback(IDeckLinkProfileCallback *callback) override {
        if (callback) callback->AddRef();
        if (profileCallback) profileCallback->Release();
        profileCallback = callback; return S_OK;
    }
};

class TestOutput : public IDeckLinkOutput, public IDeckLinkMacOutput {
    atomic_uint refs;
public:
    TestOutput() { atomic_init(&refs, 1); }
    IDeckLinkVideoOutputCallback *callback = nullptr;
    std::vector<TestOutput *> *peers = nullptr;
    TestHardware *hardware = nullptr;
    BMDVideoOutputFlags outputFlags = bmdVideoOutputFlagDefault;
    bool flushBeforeStopped = false, allAudioPrerollEndedAtStart = false;
    bool running = false;
    bool preroll = false;
    HRESULT beginPrerollStatus = S_OK, endPrerollStatus = S_OK;
    bool videoEnabled = false, audioEnabled = false;
    HRESULT disableVideoStatus = S_OK, disableAudioStatus = S_OK;
    NSUInteger videoDisableCalls = 0, audioDisableCalls = 0, displayedFrames = 0, writtenAudioFrames = 0;
    HRESULT callbackStatus = S_OK;
    BMDSupportedVideoModeFlags supportFlags = bmdSupportedVideoModeDefault;
    bool keyingModeSupported = true;
    HRESULT scheduleStatus = S_OK, startStatus = S_OK, stopStatus = S_OK, createStatus = S_OK;
    BMDAudioOutputStreamType audioType = bmdAudioOutputStreamContinuous;
    uint32_t audioLimit = 32;
    uint32_t bufferedAudio = 0;
    int64_t streamTime = 1001;
    HRESULT audioStatus = S_OK, enableAudioStatus = S_OK;
    dispatch_semaphore_t preparationEntered = nullptr, preparationRelease = nullptr;
    std::vector<int64_t> videoTimes, videoScales, audioTimes;
    std::vector<uint32_t> audioCounts;
    BMDTimeValue audioTime = 0;
    NSData *lastAudio;
    std::vector<IDeckLinkVideoFrame *> frames;
    std::vector<std::string> events;
    ~TestOutput() { flush(); if (callback) callback->Release(); }
    void complete(BMDOutputFrameCompletionResult result) {
        auto frame = frames.front(); frames.erase(frames.begin());
        callback->ScheduledFrameCompleted(frame, result); frame->Release();
    }
    void flush() { while (!frames.empty()) complete(bmdOutputFrameFlushed); }
    void stopped() { running = false; callback->ScheduledPlaybackHasStopped(); }
    HRESULT QueryInterface(REFIID iid, LPVOID *value) override {
        *value = nullptr;
        if (memcmp(&iid, &IID_IDeckLinkMacOutput, sizeof(iid))) return E_NOINTERFACE;
        *value = static_cast<IDeckLinkMacOutput *>(this); AddRef(); return S_OK;
    }
    ULONG AddRef() override { return ++refs; }
    ULONG Release() override { auto n = --refs; if (!n) delete this; return n; }
    HRESULT CreateVideoFrameFromCVPixelBufferRef(void *buffer, IDeckLinkMutableVideoFrame **frame) override {
        if (preparationEntered) dispatch_semaphore_signal(preparationEntered);
        if (preparationRelease) dispatch_semaphore_wait(preparationRelease, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        if (createStatus != S_OK) return createStatus;
        *frame = new TestFrame(); return S_OK;
    }
HRESULT DoesSupportVideoMode ( BMDVideoConnection connection ,  BMDDisplayMode requestedMode,  BMDPixelFormat requestedPixelFormat,  BMDVideoOutputConversionMode conversionMode,  BMDSupportedVideoModeFlags flags,  BMDDisplayMode* actualMode,  bool* supported) override {
    supportFlags = flags; *supported = keyingModeSupported || !(flags & bmdSupportedVideoModeKeying); return S_OK;
}
HRESULT GetDisplayMode ( BMDDisplayMode displayMode,  IDeckLinkDisplayMode** resultDisplayMode) override { return E_NOTIMPL; }
HRESULT GetDisplayModeIterator ( IDeckLinkDisplayModeIterator** iterator) override { return E_NOTIMPL; }
HRESULT SetScreenPreviewCallback ( IDeckLinkScreenPreviewCallback* previewCallback) override { return E_NOTIMPL; }
HRESULT EnableVideoOutput ( BMDDisplayMode displayMode,  BMDVideoOutputFlags flags) override { videoEnabled = true; outputFlags = flags; return S_OK; }
HRESULT DisableVideoOutput (void) override { ++videoDisableCalls; if (disableVideoStatus != S_OK) return disableVideoStatus; flush(); videoEnabled = false; return S_OK; }
HRESULT CreateVideoFrame ( int32_t width,  int32_t height,  int32_t rowBytes,  BMDPixelFormat pixelFormat,  BMDFrameFlags flags,  IDeckLinkMutableVideoFrame** outFrame) override { return E_NOTIMPL; }
HRESULT CreateVideoFrameWithBuffer ( int32_t width,  int32_t height,  int32_t rowBytes,  BMDPixelFormat pixelFormat,  BMDFrameFlags flags,  IDeckLinkVideoBuffer* buffer,  IDeckLinkMutableVideoFrame** outFrame) override { return E_NOTIMPL; }
HRESULT RowBytesForPixelFormat ( BMDPixelFormat pixelFormat,  int32_t width,  int32_t* rowBytes) override { return E_NOTIMPL; }
HRESULT CreateAncillaryData ( BMDPixelFormat pixelFormat,  IDeckLinkVideoFrameAncillary** outBuffer) override { return E_NOTIMPL; }
HRESULT DisplayVideoFrameSync ( IDeckLinkVideoFrame* theFrame) override { if (!videoEnabled) return E_ACCESSDENIED; ++displayedFrames; return S_OK; }
HRESULT ScheduleVideoFrame ( IDeckLinkVideoFrame* theFrame,  BMDTimeValue displayTime,  BMDTimeValue displayDuration,  BMDTimeScale timeScale) override { events.push_back("schedule"); videoTimes.push_back(displayTime); videoScales.push_back(timeScale); if (scheduleStatus != S_OK) return scheduleStatus; theFrame->AddRef(); frames.push_back(theFrame); return S_OK; }
HRESULT SetScheduledFrameCompletionCallback ( IDeckLinkVideoOutputCallback* theCallback) override { if (theCallback && callbackStatus != S_OK) return callbackStatus; if (theCallback) theCallback->AddRef(); if (callback) callback->Release(); callback = theCallback; return S_OK; }
HRESULT GetBufferedVideoFrameCount ( uint32_t* bufferedFrameCount) override { *bufferedFrameCount = (uint32_t)frames.size(); return S_OK; }
HRESULT EnableAudioOutput ( BMDAudioSampleRate sampleRate,  BMDAudioSampleType sampleType,  uint32_t channelCount,  BMDAudioOutputStreamType streamType) override { audioType = streamType; if (enableAudioStatus == S_OK) audioEnabled = true; return enableAudioStatus; }
HRESULT DisableAudioOutput (void) override { ++audioDisableCalls; if (disableAudioStatus != S_OK) return disableAudioStatus; audioEnabled = false; return S_OK; }
HRESULT WriteAudioSamplesSync ( void* buffer,  uint32_t sampleFrameCount,  uint32_t* sampleFramesWritten) override { *sampleFramesWritten = 0; if (!audioEnabled) return E_ACCESSDENIED; *sampleFramesWritten = sampleFrameCount; writtenAudioFrames += sampleFrameCount; return S_OK; }
HRESULT BeginAudioPreroll (void) override { events.push_back("beginAudio"); if (beginPrerollStatus == S_OK) preroll = true; return beginPrerollStatus; }
HRESULT EndAudioPreroll (void) override { events.push_back("endAudio"); if (endPrerollStatus == S_OK) preroll = false; return endPrerollStatus; }
HRESULT ScheduleAudioSamples ( void* buffer,  uint32_t sampleFrameCount,  BMDTimeValue streamTime,  BMDTimeScale timeScale,  uint32_t* sampleFramesWritten) override { *sampleFramesWritten = 0; if (!running && !preroll) return E_UNEXPECTED; events.push_back("audio"); if (audioStatus != S_OK) return audioStatus; audioTimes.push_back(streamTime); audioCounts.push_back(sampleFrameCount); *sampleFramesWritten = MIN(sampleFrameCount, audioLimit); audioTime = streamTime; lastAudio = [NSData dataWithBytes:buffer length:*sampleFramesWritten * 4]; return S_OK; }
HRESULT GetBufferedAudioSampleFrameCount ( uint32_t* bufferedSampleFrameCount) override { *bufferedSampleFrameCount = bufferedAudio; return S_OK; }
HRESULT FlushBufferedAudioSamples (void) override { return S_OK; }
HRESULT SetAudioCallback ( IDeckLinkAudioOutputCallback* theCallback) override { return S_OK; }
HRESULT StartScheduledPlayback ( BMDTimeValue playbackStartTime,  BMDTimeScale timeScale,  double playbackSpeed) override { events.push_back("start"); if (!callback) return E_FAIL;
    if (startStatus == S_OK) {
        running = true;
        if (peers) {
            allAudioPrerollEndedAtStart = true;
            for (TestOutput *peer : *peers) if (peer->videoEnabled && peer->hardware->groupID == hardware->groupID && (peer->outputFlags & bmdVideoOutputSynchronizeToPlaybackGroup)) {
                allAudioPrerollEndedAtStart &= !peer->preroll;
                peer->running = true; peer->streamTime = 0;
            }
        }
    }
    return startStatus; }
// A synchronized output stops its whole SDK group; an ungrouped output stops alone.
std::vector<TestOutput *> stopTargets() {
    if (!peers || !(outputFlags & bmdVideoOutputSynchronizeToPlaybackGroup)) return {this};
    std::vector<TestOutput *> targets;
    for (TestOutput *peer : *peers) if (peer->hardware->groupID == hardware->groupID && (peer->outputFlags & bmdVideoOutputSynchronizeToPlaybackGroup)) targets.push_back(peer);
    return targets;
}
HRESULT StopScheduledPlayback ( BMDTimeValue stopPlaybackAtTime,  BMDTimeValue* actualStopTime,  BMDTimeScale timeScale) override { events.push_back("stop");
    if (stopStatus == S_OK) for (TestOutput *peer : stopTargets()) {
        if (!peer->running) continue;
        if (flushBeforeStopped) { peer->flush(); peer->stopped(); }
        else { peer->stopped(); peer->flush(); }
    }
    return stopStatus; }
HRESULT IsScheduledPlaybackRunning ( bool* active) override { *active = running; return S_OK; }
HRESULT GetScheduledStreamTime ( BMDTimeScale desiredTimeScale,  BMDTimeValue* streamTime,  double* playbackSpeed) override { *streamTime = this->streamTime; *playbackSpeed = 1; return S_OK; }
HRESULT GetReferenceStatus ( BMDReferenceStatus* referenceStatus) override { return E_NOTIMPL; }
HRESULT GetHardwareReferenceClock ( BMDTimeScale desiredTimeScale,  BMDTimeValue* hardwareTime,  BMDTimeValue* timeInFrame,  BMDTimeValue* ticksPerFrame) override { return E_NOTIMPL; }
HRESULT GetFrameCompletionReferenceTimestamp ( IDeckLinkVideoFrame* theFrame,  BMDTimeScale desiredTimeScale,  BMDTimeValue* frameCompletionTimestamp) override { return E_NOTIMPL; }
};

class TestNativeDeckLink : public IDeckLink {
    std::atomic<ULONG> refs {1};
    TestOutput *output;
    TestHardware *hardware;
public:
    TestNativeDeckLink(TestOutput *o, TestHardware *h) : output(o), hardware(h) { o->AddRef(); h->AddRef(); }
    ~TestNativeDeckLink() { output->Release(); hardware->Release(); }
    ULONG AddRef() override { return ++refs; }
    ULONG Release() override { auto n = --refs; if (!n) delete this; return n; }
    HRESULT GetModelName(CFStringRef *value) override { *value = CFSTR("DeckLink 8K Pro"); CFRetain(*value); return S_OK; }
    HRESULT GetDisplayName(CFStringRef *value) override { return GetModelName(value); }
    HRESULT QueryInterface(REFIID iid, LPVOID *value) override {
        *value = nullptr;
        if (!memcmp(&iid, &IID_IDeckLinkOutput, sizeof(iid))) { if (!hardware->outputAvailable) return E_NOINTERFACE; *value = (IDeckLinkOutput *)output; output->AddRef(); return S_OK; }
        if (!memcmp(&iid, &IID_IDeckLinkProfileAttributes, sizeof(iid))) *value = (IDeckLinkProfileAttributes *)hardware;
        else if (!memcmp(&iid, &IID_IDeckLinkConfiguration, sizeof(iid))) *value = (IDeckLinkConfiguration *)hardware;
        else if (!memcmp(&iid, &IID_IDeckLinkStatus, sizeof(iid))) *value = (IDeckLinkStatus *)hardware;
        else if (!memcmp(&iid, &IID_IDeckLinkProfileManager, sizeof(iid))) *value = (IDeckLinkProfileManager *)hardware;
        else return E_NOINTERFACE;
        hardware->AddRef(); return S_OK;
    }
};

@interface DeckLinkDevice (SchedulingTests)
- (void)drainTestQueues;
@end
@implementation DeckLinkDevice (SchedulingTests)
- (void)drainTestQueues {
    dispatch_sync(self.frameDownloadQueue, ^{});
    dispatch_sync(self.playbackQueue, ^{});
    dispatch_sync(self.frameDownloadQueue, ^{});
    dispatch_sync(self.playbackQueue, ^{});
}
@end

// Tests tick each member's audio worker explicitly for deterministic driver state.
@interface ManualPlaybackGroup : DeckLinkPlaybackGroup
@end
@implementation ManualPlaybackGroup
- (void)startAudioWorker {}
@end

static id TestVideoFormat(CMTime frameDuration, BOOL withFrameRate) {
    NSMutableDictionary *extensions = [@{(__bridge NSString *)DeckLinkFormatDescriptionDisplayModeKey: @((uint32_t)'Hp59')} mutableCopy];
    if (withFrameRate) extensions[(__bridge NSString *)DeckLinkFormatDescriptionFrameRateKey] = CFBridgingRelease(CMTimeCopyAsDictionary(frameDuration, NULL));
    CMVideoFormatDescriptionRef video = NULL;
    CMVideoFormatDescriptionCreate(NULL, kCVPixelFormatType_32BGRA, 16, 16, (__bridge CFDictionaryRef)extensions, &video);
    return CFBridgingRelease(video);
}
static id TestAudioFormat() {
    AudioStreamBasicDescription asbd = {48000, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0};
    CMAudioFormatDescriptionRef audio = NULL;
    CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &audio);
    return CFBridgingRelease(audio);
}
static void DrainGroup(DeckLinkPlaybackGroup *group, NSArray<DeckLinkDevice *> *devices, BOOL callbacks) {
    for (NSUInteger round = 0; round < 8; ++round) {
        for (DeckLinkDevice *device in devices) [device drainTestQueues];
        dispatch_sync((dispatch_queue_t)[group valueForKey:@"queue"], ^{});
        if (callbacks) dispatch_sync((dispatch_queue_t)[group valueForKey:@"callbacks"], ^{});
    }
}

// A single output is a group of one: ordinary scheduled playback without SDK grouping.
@interface DeckLinkSingleOutputTests : XCTestCase {
    TestOutput *driver;
    TestHardware *hardware;
    DeckLinkDevice *device;
    DeckLinkPlaybackSession *session;
    DeckLinkPlaybackGroup *group;
    CVPixelBufferRef buffer;
    id videoFormat, audioFormat;
    NSUInteger reads, consumed;
}
/// Media behind the output's fixed audio source; nil supplies silence.
@property (atomic, copy) DeckLinkPlaybackAudioSource media;
@end
@implementation DeckLinkSingleOutputTests
- (void)setUp {
    [super setUp];
    driver = new TestOutput(); driver->audioLimit = UINT32_MAX; driver->streamTime = 0;
    hardware = new TestHardware(); driver->hardware = hardware;
    TestNativeDeckLink *native = new TestNativeDeckLink(driver, hardware);
    device = [[DeckLinkDevice alloc] initWithDeckLink:native]; native->Release();
    CVPixelBufferCreate(NULL, 16, 16, kCVPixelFormatType_32BGRA, NULL, &buffer);
    videoFormat = TestVideoFormat(CMTimeMake(1001, 60000), YES); audioFormat = TestAudioFormat();
    device.playbackVideoFormatDescriptions = @[videoFormat]; device.playbackAudioFormatDescriptions = @[audioFormat];
    [self useOutputWithAudio:YES keyer:@"None"];
}
- (DeckLinkPlaybackOutput *)outputWithAudio:(BOOL)audio keyer:(NSString *)keyer {
    __weak typeof(self) weakSelf = self;
    return [[DeckLinkPlaybackOutput alloc] initWithDevice:device videoFormat:(__bridge CMVideoFormatDescriptionRef)videoFormat
        audioFormat:audio ? (__bridge CMAudioFormatDescriptionRef)audioFormat : NULL keyingMode:keyer
        audioSource:^NSData *(NSUInteger samples, NSUInteger channels, CMTime time, BOOL discontinuity) {
            typeof(self) test = weakSelf;
            if (!test) return nil;
            ++test->reads; test->consumed += samples;
            DeckLinkPlaybackAudioSource media = test.media;
            return media ? media(samples, channels, time, discontinuity) : nil;
        }];
}
- (void)useOutputWithAudio:(BOOL)audio keyer:(NSString *)keyer {
    group = [[ManualPlaybackGroup alloc] initWithOutputs:@[[self outputWithAudio:audio keyer:keyer]]];
    session = group.sessions.firstObject;
}
- (void)tearDown {
    driver->disableAudioStatus = S_OK; driver->disableVideoStatus = S_OK; driver->stopStatus = S_OK;
    if (driver->preparationRelease) dispatch_semaphore_signal(driver->preparationRelease);
    [group closeWithCompletion:nil]; [self drain];
    session = nil; group = nil; [device drainTestQueues]; device = nil;
    driver->Release(); hardware->Release(); CVPixelBufferRelease(buffer);
    XCTAssertEqual(atomic_load(&liveFrames), 0);
    [super tearDown];
}
- (void)drain { DrainGroup(group, @[device], YES); }
- (BOOL)openGroup {
    __block BOOL opened = NO;
    [group openWithCompletion:^(BOOL success, NSError *error) { opened = success; }];
    [self drain]; return opened;
}
- (void)open { XCTAssertTrue([self openGroup]); }
- (void)submit { [group submitPixelBuffers:@[(__bridge id)buffer] completion:nil]; [self drain]; }
- (void)start { [self open]; [self submit]; XCTAssertTrue(driver->running); XCTAssertEqual(group.state, DeckLinkPlaybackGroupRunning); }
- (void)tick:(int64_t)time {
    [device performPlaybackSync:^{ driver->streamTime = time; [session serviceAudio]; }];
    [self drain];
}
- (BOOL)closeGroup {
    __block BOOL closed = NO;
    [group closeWithCompletion:^(BOOL success, NSError *error) { closed = success; }];
    [self drain]; return closed;
}
- (void)testFirstVideoAndOneAudioFrameStartPlaybackWithoutSDKGrouping {
    [self start];
    XCTAssertTrue(driver->events == (std::vector<std::string>{"schedule", "beginAudio", "audio", "endAudio", "start"}));
    XCTAssertEqual(atomic_load(&liveFrames), 1); XCTAssertEqual(driver->audioCounts.front(), 801u);
    XCTAssertEqual(driver->audioType, bmdAudioOutputStreamTimestamped);
    XCTAssertEqual(driver->outputFlags, bmdVideoOutputFlagDefault); XCTAssertTrue(hardware->groupWrites.empty());
}
- (void)testSingleOutputNeverWaitsForReference {
    device.modelName = @"DeckLink Duo 2"; hardware->locked = false; [device refreshPlaybackGroupAttributes];
    group.referencePolicy = DeckLinkPlaybackGroupReferenceRequired;
    [self start];
}
- (void)testAudioRunsIndependentlyOfVideoAndKeepsFractionalFrameBudget {
    [self start];
    for (NSUInteger i = 1; i <= 120; ++i) [self tick:i * 96];
    XCTAssertEqual(consumed, 801u + 120 * 96); XCTAssertEqual(driver->videoTimes.size(), 1u);
    XCTAssertEqual(driver->audioTimes.back(), 801 + 119 * 96); XCTAssertNil(group.error);
}
- (void)testFullBufferPreventsOverfill {
    [self start]; driver->bufferedAudio = 801; [self tick:192]; XCTAssertEqual(reads, 1u);
    driver->bufferedAudio = 750; [self tick:288]; XCTAssertEqual(driver->audioCounts.back(), 51u);
}
- (void)testMissingOrMalformedSourceProducesCorrectlySizedSilence {
    self.media = ^NSData *(NSUInteger n, NSUInteger ch, CMTime time, BOOL gap) { return [NSData dataWithBytes:"x" length:1]; };
    [self start]; XCTAssertEqualObjects(driver->lastAudio, [NSMutableData dataWithLength:801 * 4]);
    self.media = nil; [self tick:96]; XCTAssertEqualObjects(driver->lastAudio, [NSMutableData dataWithLength:96 * 4]);
}
- (void)testVideoOnlyOutputSchedulesOneFrameAheadOfTheClock {
    [self useOutputWithAudio:NO keyer:@"None"];
    // 400 samples in, frame 0 is on air: the next boundary is 1001 and one frame of lead targets 2002.
    [self start]; [self tick:400]; [self submit];
    XCTAssertTrue(driver->audioTimes.empty()); XCTAssertTrue(driver->videoTimes == (std::vector<int64_t>{0,2002}));
}
- (void)testZeroAcceptanceWaitsForWorkerAndDoesNotRepullOrRestart {
    driver->audioLimit = 0; [self open]; [self submit];
    XCTAssertFalse(driver->running); XCTAssertEqual(reads, 1u);
    [self tick:0]; [self tick:0]; XCTAssertEqual(reads, 1u); XCTAssertNil(group.error);
    driver->audioLimit = UINT32_MAX; [self tick:0];
    XCTAssertTrue(driver->running); XCTAssertEqual(reads, 1u);
    XCTAssertEqual(std::count(driver->events.begin(), driver->events.end(), "stop"), 0);
}
- (void)testPersistentZeroAcceptanceReportsFailureInsteadOfSpinning {
    XCTestExpectation *expired = [self expectationWithDescription:@"bounded no-progress recovery"];
    group.errorHandler = ^(NSError *error) { XCTAssertEqual(error.code, DeckLinkPlaybackGroupDeviceFailure); [expired fulfill]; };
    driver->audioLimit = 0; [self open]; [self submit];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), device.playbackQueue, ^{ [session serviceAudio]; });
    [self waitForExpectationsWithTimeout:1 handler:nil];
    XCTAssertEqual(reads, 1u); XCTAssertFalse(driver->running);
}
- (void)testPartialPrerollRetainsOriginalPCMAndUsesSuffixTimestamp {
    __block NSUInteger sourceReads = 0;
    self.media = ^NSData *(NSUInteger n, NSUInteger ch, CMTime time, BOOL gap) {
        ++sourceReads; NSMutableData *data = [NSMutableData dataWithLength:n * ch * 2];
        for (NSUInteger i = 0; i < n; ++i) ((int16_t *)data.mutableBytes)[i * ch] = (int16_t)i;
        return data;
    };
    driver->audioLimit = 400; [self open]; [self submit];
    XCTAssertFalse(driver->running); [self tick:0];
    XCTAssertEqual(driver->audioTime, 400); XCTAssertEqual(((const int16_t *)driver->lastAudio.bytes)[0], 400);
    XCTAssertFalse(driver->running); [self tick:0];
    XCTAssertTrue(driver->running); XCTAssertEqual(sourceReads, 1u);
    XCTAssertEqual(driver->audioTime, 800); XCTAssertEqual(((const int16_t *)driver->lastAudio.bytes)[0], 800);
}
- (void)testExpiredPartialPacketNeverRetriesInThePast {
    [self start]; driver->audioLimit = 96; [self tick:192];
    driver->audioLimit = UINT32_MAX; [self tick:24000];
    XCTAssertEqual(driver->audioTime, 24096); XCTAssertNil(group.error); XCTAssertTrue(driver->running);
    XCTAssertEqual(std::count(driver->events.begin(), driver->events.end(), "stop"), 0);
}
- (void)testLateAndDroppedVideoNeverRestartAudio {
    [self start]; driver->complete(bmdOutputFrameDisplayedLate); [self drain];
    [self tick:400]; [self submit];
    driver->complete(bmdOutputFrameDropped); [self drain]; [self tick:1200]; [self submit];
    XCTAssertNil(group.error); XCTAssertTrue(driver->videoTimes == (std::vector<int64_t>{0,2002,3003}));
}
- (void)testRetentionCapSkipsVideoWhileAudioContinues {
    [self start];
    __block NSUInteger rejected = 0;
    for (int time : {400,1200,2000,2800}) {
        [self tick:time];
        [group submitPixelBuffers:@[(__bridge id)buffer] completion:^(CMTime t, NSError *error) {
            if (error.code == DeckLinkPlaybackGroupFrameRejected) ++rejected;
        }];
        [self drain];
    }
    // Frames 0, 2002 and 3003 fill max(3, preroll); 4004 and 5005 are skipped.
    XCTAssertEqual(atomic_load(&liveFrames), 3); XCTAssertEqual(rejected, 2u);
    XCTAssertNil(group.error); XCTAssertEqual(consumed, 3601u);
    driver->complete(bmdOutputFrameCompleted); [self drain];
    [self tick:3600]; [self submit]; XCTAssertEqual(atomic_load(&liveFrames), 3);
    XCTAssertEqual(driver->videoTimes.back(), 6006);
}
- (void)testSetsFasterThanTheOutputAreDropped {
    [self start]; [self tick:400];
    [group submitPixelBuffers:@[(__bridge id)buffer] completion:nil];
    [group submitPixelBuffers:@[(__bridge id)buffer] completion:nil]; [self drain];
    XCTAssertTrue(driver->videoTimes == (std::vector<int64_t>{0,2002})); XCTAssertNil(group.error);
}
- (void)testBlockedGroupCallbacksCannotDelayAudioOrVideo {
    [self start];
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_async((dispatch_queue_t)[group valueForKey:@"callbacks"], ^{ dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)); });
    [device performPlaybackSync:^{ driver->streamTime = 400; [session serviceAudio]; }];
    [group submitPixelBuffers:@[(__bridge id)buffer] completion:nil]; DrainGroup(group, @[device], NO);
    XCTAssertEqual(driver->audioTime, 801); XCTAssertEqual(driver->audioCounts.back(), 400u);
    XCTAssertEqual(driver->videoTimes.back(), 2002);
    dispatch_semaphore_signal(gate); [self drain];
}
- (void)testNativeVideoPreparationCannotBlockAudio {
    [self start];
    driver->preparationEntered = dispatch_semaphore_create(0); driver->preparationRelease = dispatch_semaphore_create(0);
    [device performPlaybackSync:^{ driver->streamTime = 96; }];
    [group submitPixelBuffers:@[(__bridge id)buffer] completion:nil];
    XCTAssertEqual(dispatch_semaphore_wait(driver->preparationEntered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    [device performPlaybackSync:^{ driver->streamTime = 192; [session serviceAudio]; }];
    XCTAssertEqual(driver->audioCounts.back(), 192u);
    dispatch_semaphore_signal(driver->preparationRelease); [self drain];
}
- (void)testCloseWaitsForPendingPreparationBeforeDisablingOutput {
    [self start];
    driver->preparationEntered = dispatch_semaphore_create(0); driver->preparationRelease = dispatch_semaphore_create(0);
    [group submitPixelBuffers:@[(__bridge id)buffer] completion:nil];
    XCTAssertEqual(dispatch_semaphore_wait(driver->preparationEntered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    __block BOOL closed = NO; [group closeWithCompletion:^(BOOL ok, NSError *error) { closed = ok; }];
    dispatch_sync((dispatch_queue_t)[group valueForKey:@"queue"], ^{}); dispatch_sync(device.playbackQueue, ^{});
    XCTAssertFalse(closed); XCTAssertTrue(driver->videoEnabled); XCTAssertEqual([self stops], 0u);
    dispatch_semaphore_signal(driver->preparationRelease); [self drain];
    XCTAssertTrue(closed); XCTAssertEqual([self stops], 1u);
    XCTAssertFalse(driver->audioEnabled); XCTAssertFalse(driver->videoEnabled);
}
- (NSUInteger)stops {
    __block NSUInteger count = 0;
    [device performPlaybackSync:^{ count = std::count(driver->events.begin(), driver->events.end(), "stop"); }];
    return count;
}
- (void)testCloseDisablesOutputWhileGroupCallbackQueueIsBlocked {
    [self start];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    dispatch_async((dispatch_queue_t)[group valueForKey:@"callbacks"], ^{
        dispatch_semaphore_signal(entered); dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
    });
    XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    __block NSUInteger completions = 0;
    @try {
        [group closeWithCompletion:^(BOOL success, NSError *error) { XCTAssertTrue(success); XCTAssertNil(error); ++completions; }];
        DrainGroup(group, @[device], NO);
        [device performPlaybackSync:^{
            XCTAssertFalse(driver->videoEnabled); XCTAssertFalse(driver->audioEnabled);
            XCTAssertNil(device.scheduledPlaybackSession);
            XCTAssertEqual(atomic_load(&liveFrames), 0);
        }];
        XCTAssertEqual(completions, 0u);
    } @finally {
        dispatch_semaphore_signal(release);
        [self drain];
    }
    XCTAssertEqual(completions, 1u);
}
- (void)testCloseStopsSourceReadsAndCoalescesCompletions {
    [self start]; __block NSUInteger completions = 0;
    [group closeWithCompletion:^(BOOL ok, NSError *error) { XCTAssertTrue(ok); ++completions; }];
    [group closeWithCompletion:^(BOOL ok, NSError *error) { XCTAssertTrue(ok); ++completions; }];
    [self drain]; XCTAssertEqual(completions, 2u); XCTAssertEqual(group.state, DeckLinkPlaybackGroupClosed);
    [self tick:400]; [self submit]; XCTAssertEqual(reads, 1u); XCTAssertEqual(driver->videoTimes.size(), 1u);
}
- (void)testConfigurationFailureRollsBackOutputs {
    driver->enableAudioStatus = E_FAIL;
    XCTAssertFalse([self openGroup]); XCTAssertFalse(driver->audioEnabled); XCTAssertFalse(driver->videoEnabled);
    XCTAssertNil(device.scheduledPlaybackSession); XCTAssertEqual(group.state, DeckLinkPlaybackGroupClosed);
}
- (void)testNoKeyerAcceptsNoneButRejectsExternalAndRollsBack {
    [self useOutputWithAudio:YES keyer:@"External"];
    XCTAssertFalse([self openGroup]); XCTAssertFalse(driver->videoEnabled);
    [self useOutputWithAudio:YES keyer:@"None"]; [self start];
}
- (void)testKeyedOutputValidatesTheModeWithTheKeyer {
    driver->keyingModeSupported = false;
    [self useOutputWithAudio:YES keyer:@"External"];
    XCTAssertFalse([self openGroup]); XCTAssertEqual(driver->supportFlags, bmdSupportedVideoModeKeying);
    XCTAssertFalse(driver->videoEnabled); XCTAssertNil(device.scheduledPlaybackSession);
    [self useOutputWithAudio:YES keyer:@"None"]; [self start];
    XCTAssertEqual(driver->supportFlags, bmdSupportedVideoModeDefault);
}
- (void)testSecondGroupCannotReconfigureAnOwnedDevice {
    [self open];
    DeckLinkPlaybackGroup *other = [[ManualPlaybackGroup alloc] initWithOutputs:@[[self outputWithAudio:YES keyer:@"None"]]];
    __block NSError *rejection = nil;
    [other openWithCompletion:^(BOOL ok, NSError *error) { rejection = error; }];
    DrainGroup(other, @[device], YES);
    XCTAssertEqual(rejection.code, DeckLinkPlaybackGroupDeviceFailure);
    XCTAssertEqual(device.scheduledPlaybackSession, session); XCTAssertTrue(driver->videoEnabled);
}
- (void)testCloseBeforeOpenPreventsConfigurationAndSourceReads {
    XCTAssertTrue([self closeGroup]);
    XCTAssertFalse([self openGroup]);
    [self submit]; [self tick:800];
    XCTAssertFalse(driver->videoEnabled); XCTAssertEqual(reads, 0u);
}
- (void)testFailedCloseRetainsOwnershipUntilSuccessfulRetry {
    [self open]; driver->disableAudioStatus = E_FAIL;
    XCTAssertFalse([self closeGroup]); XCTAssertEqual(device.scheduledPlaybackSession, session);
    XCTAssertEqual(group.state, DeckLinkPlaybackGroupFailed);
    driver->disableAudioStatus = S_OK;
    XCTAssertTrue([self closeGroup]); XCTAssertNil(device.scheduledPlaybackSession);
}
- (void)testFailedConfigurationCleanupRetainsOwnershipForRetry {
    driver->enableAudioStatus = E_FAIL; driver->disableVideoStatus = E_FAIL;
    XCTAssertFalse([self openGroup]);
    XCTAssertTrue(driver->videoEnabled); XCTAssertEqual(device.scheduledPlaybackSession, session);
    driver->disableVideoStatus = S_OK;
    XCTAssertTrue([self closeGroup]); XCTAssertFalse(driver->videoEnabled); XCTAssertNil(device.scheduledPlaybackSession);
}
- (void)testSlowSourceCannotSubmitExpiredAudio {
    [self start];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    self.media = ^NSData *(NSUInteger n, NSUInteger ch, CMTime time, BOOL gap) {
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
        driver->streamTime = 24000;
        return nil;
    };
    size_t count = driver->audioTimes.size();
    dispatch_async(device.playbackQueue, ^{ driver->streamTime = 192; [session serviceAudio]; });
    XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    // Model a source lock held beyond the one-frame audio budget.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ dispatch_semaphore_signal(release); });
    dispatch_sync(device.playbackQueue, ^{});
    XCTAssertEqual(driver->audioTimes.size(), count);
    self.media = nil; [self tick:24000];
    XCTAssertGreaterThanOrEqual(driver->audioTime, 24000); XCTAssertNil(group.error);
}
- (void)testUnboundedAudioCapacityIsRejectedBeforeEnablingHardware {
    videoFormat = TestVideoFormat(CMTimeMake(INT64_MAX, 1), YES);
    device.playbackVideoFormatDescriptions = @[videoFormat];
    [self useOutputWithAudio:YES keyer:@"None"];
    XCTAssertFalse([self openGroup]); XCTAssertFalse(driver->videoEnabled); XCTAssertFalse(driver->audioEnabled);
}
- (void)testFormatWithoutDeckLinkFrameRateIsRejected {
    videoFormat = TestVideoFormat(kCMTimeInvalid, NO);
    device.playbackVideoFormatDescriptions = @[videoFormat];
    [self useOutputWithAudio:YES keyer:@"None"];
    __block NSError *rejection = nil;
    [group openWithCompletion:^(BOOL ok, NSError *error) { rejection = error; }]; [self drain];
    XCTAssertEqual(rejection.code, DeckLinkPlaybackGroupInvalidConfiguration);
    XCTAssertFalse(driver->videoEnabled); XCTAssertNil(device.scheduledPlaybackSession);
}
@end

@interface DeckLinkPlaybackGroupTests : XCTestCase {
    std::vector<TestOutput *> peers;
    TestOutput *drivers[2];
    TestHardware *hardware[2];
    NSArray<DeckLinkDevice *> *devices;
    NSArray<DeckLinkPlaybackSession *> *members;
    DeckLinkPlaybackGroup *group;
    CVPixelBufferRef buffer;
    id videoFormat, audioFormat;
}
@end
@implementation DeckLinkPlaybackGroupTests
- (void)setUp {
    [super setUp];
    CVPixelBufferCreate(NULL, 16, 16, kCVPixelFormatType_32BGRA, NULL, &buffer);
    videoFormat = TestVideoFormat(CMTimeMake(1001, 60000), YES); audioFormat = TestAudioFormat();
    NSMutableArray *outputs = [NSMutableArray new];
    for (NSUInteger i = 0; i < 2; ++i) {
        drivers[i] = new TestOutput(); hardware[i] = new TestHardware(); hardware[i]->index = i;
        hardware[i]->groupID = 17 + i;
        drivers[i]->hardware = hardware[i]; drivers[i]->peers = &peers; drivers[i]->audioLimit = UINT32_MAX;
        peers.push_back(drivers[i]);
        TestNativeDeckLink *native = new TestNativeDeckLink(drivers[i], hardware[i]);
        DeckLinkDevice *device = [[DeckLinkDevice alloc] initWithDeckLink:native]; native->Release();
        device.playbackVideoFormatDescriptions = @[videoFormat]; device.playbackAudioFormatDescriptions = @[audioFormat];
        [outputs addObject:device];
    }
    devices = outputs; [self useGroupWithOutputs:[self outputsWithAudio:YES]];
}
- (DeckLinkPlaybackOutput *)outputOn:(DeckLinkDevice *)device video:(id)video audio:(BOOL)audio {
    return [[DeckLinkPlaybackOutput alloc] initWithDevice:device videoFormat:(__bridge CMVideoFormatDescriptionRef)video
        audioFormat:audio ? (__bridge CMAudioFormatDescriptionRef)audioFormat : NULL keyingMode:@"None" audioSource:nil];
}
- (NSArray<DeckLinkPlaybackOutput *> *)outputsWithAudio:(BOOL)audio {
    NSMutableArray *outputs = [NSMutableArray new];
    for (DeckLinkDevice *device in devices) [outputs addObject:[self outputOn:device video:videoFormat audio:audio]];
    return outputs;
}
- (void)useGroupWithOutputs:(NSArray<DeckLinkPlaybackOutput *> *)outputs {
    group = [[ManualPlaybackGroup alloc] initWithOutputs:outputs]; members = (NSArray *)group.sessions;
}
- (NSArray *)frameSet { return @[(__bridge id)buffer, (__bridge id)buffer]; }
- (void)waitUntil:(BOOL (^)(void))predicate {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!predicate() && end.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    XCTAssertTrue(predicate());
}
- (void)openExpectingSuccess:(BOOL)success {
    XCTestExpectation *opened = [self expectationWithDescription:@"group open"];
    [group openWithCompletion:^(BOOL ok, NSError *error) { XCTAssertEqual(ok, success); XCTAssertEqual(error == nil, success); [opened fulfill]; }];
    [self waitForExpectations:@[opened] timeout:2];
}
- (void)start {
    [self openExpectingSuccess:YES];
    [group submitPixelBuffers:self.frameSet completion:nil];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupRunning; }];
}
- (void)closeExpectingSuccess:(BOOL)success {
    XCTestExpectation *closed = [self expectationWithDescription:@"group close"];
    [group closeWithCompletion:^(BOOL ok, NSError *error) { XCTAssertEqual(ok, success); XCTAssertEqual(error == nil, success); [closed fulfill]; }];
    [self waitForExpectations:@[closed] timeout:2];
}
- (NSUInteger)calls:(const char *)operation {
    __block NSUInteger count = 0;
    for (NSUInteger i = 0; i < 2; ++i) [devices[i] performPlaybackSync:^{ count += std::count(drivers[i]->events.begin(), drivers[i]->events.end(), operation); }];
    return count;
}
- (void)tearDown {
    for (NSUInteger i = 0; i < 2; ++i) {
        drivers[i]->disableAudioStatus = S_OK; drivers[i]->disableVideoStatus = S_OK; drivers[i]->stopStatus = S_OK;
        hardware[i]->setGroupStatus = S_OK;
        if (drivers[i]->preparationRelease) dispatch_semaphore_signal(drivers[i]->preparationRelease);
    }
    [self closeExpectingSuccess:YES]; group = nil; members = nil;
    for (DeckLinkDevice *device in devices) [device drainTestQueues];
    devices = nil;
    for (NSUInteger i = 0; i < 2; ++i) { drivers[i]->Release(); hardware[i]->Release(); }
    peers.clear(); CVPixelBufferRelease(buffer);
    XCTAssertEqual(atomic_load(&liveFrames), 0);
    [super tearDown];
}
- (void)testOneStartUpdatesAllMembersAndEndsAllAudioPreroll {
    [self start]; XCTAssertEqual([self calls:"start"], 1u);
    XCTAssertTrue(drivers[0]->allAudioPrerollEndedAtStart);
    for (NSUInteger i = 0; i < 2; ++i) {
        XCTAssertTrue(devices[i].playbackActive); XCTAssertEqual(drivers[i]->outputFlags, bmdVideoOutputSynchronizeToPlaybackGroup);
        XCTAssertEqual(drivers[i]->audioTimes.front(), 0); XCTAssertEqual(drivers[i]->videoTimes.front(), 0);
        [devices[i] performPlaybackSync:^{ drivers[i]->streamTime = 96; [members[i] serviceAudio]; }];
        XCTAssertEqual(drivers[i]->audioTimes.back(), 801); XCTAssertFalse(drivers[i]->preroll);
    }
    XCTAssertEqual(hardware[0]->groupID, hardware[1]->groupID);
}
- (void)testOneAudioWorkerServicesEveryMember {
    group = [[DeckLinkPlaybackGroup alloc] initWithOutputs:[self outputsWithAudio:YES]]; members = (NSArray *)group.sessions;
    [self start];
    // After preroll each output holds audio up to 801; at 960 samples in, the shared worker tops both up.
    for (NSUInteger i = 0; i < 2; ++i) [devices[i] performPlaybackSync:^{ drivers[i]->streamTime = 960; }];
    [self waitUntil:^BOOL {
        __block BOOL serviced = YES;
        for (NSUInteger i = 0; i < 2; ++i) [devices[i] performPlaybackSync:^{ serviced = serviced && drivers[i]->audioTimes.back() >= 801; }];
        return serviced;
    }];
    XCTAssertNil(group.error);
}
- (void)testAttributeRefreshPublishesOnlyACompleteSnapshot {
    DeckLinkDevice *device = devices[0];
    DeckLinkPlaybackGroupAttributes *before = device.playbackGroupAttributes;
    hardware[0]->cardID = 99; hardware[0]->index = 2;
    hardware[0]->minimumPreroll = 4; hardware[0]->supported = false;
    hardware[0]->attributesQueryEntered = dispatch_semaphore_create(0);
    hardware[0]->attributesQueryRelease = dispatch_semaphore_create(0);
    XCTestExpectation *refreshed = [self expectationWithDescription:@"complete attribute refresh"];
    dispatch_async(device.playbackQueue, ^{ [device refreshPlaybackGroupAttributes]; [refreshed fulfill]; });
    XCTAssertEqual(dispatch_semaphore_wait(hardware[0]->attributesQueryEntered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    @try {
        // The driver has returned a new card ID, but the rest of the query is blocked.
        XCTAssertEqual(device.playbackGroupAttributes, before);
        XCTAssertEqualObjects(device.playbackGroupAttributes.deviceGroupID, @42);
        XCTAssertEqualObjects(device.playbackGroupAttributes.subDeviceIndex, @0);
        XCTAssertTrue(device.playbackGroupAttributes.supportsPlaybackSynchronization);
        XCTAssertEqual(device.playbackGroupAttributes.minimumPrerollVideoFrames, 1u);
    } @finally { dispatch_semaphore_signal(hardware[0]->attributesQueryRelease); }
    [self waitForExpectations:@[refreshed] timeout:2];
    DeckLinkPlaybackGroupAttributes *after = device.playbackGroupAttributes;
    XCTAssertNotEqual(after, before);
    XCTAssertEqualObjects(after.deviceGroupID, @99);
    XCTAssertEqualObjects(after.subDeviceIndex, @2);
    XCTAssertFalse(after.supportsPlaybackSynchronization);
    XCTAssertEqual(after.minimumPrerollVideoFrames, 4u);
    XCTAssertEqualObjects(before.deviceGroupID, @42);
    XCTAssertEqualObjects(before.subDeviceIndex, @0);
    hardware[0]->attributesQueryEntered = nil; hardware[0]->attributesQueryRelease = nil;
}
- (void)testProfileActivationRefreshRunsOnPlaybackQueue {
    DeckLinkDevice *device = devices[0];
    DeckLinkPlaybackGroupAttributes *before = device.playbackGroupAttributes;
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    dispatch_async(device.playbackQueue, ^{
        dispatch_semaphore_signal(entered); dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
    });
    XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    hardware[0]->minimumPreroll = 5;
    @try {
        XCTAssertEqual(hardware[0]->profileCallback->ProfileActivated(NULL), S_OK);
        XCTAssertEqual(device.playbackGroupAttributes, before);
    } @finally { dispatch_semaphore_signal(release); }
    [device performPlaybackSync:^{}];
    XCTAssertEqual(device.playbackGroupAttributes.minimumPrerollVideoFrames, 5u);
    XCTAssertEqual(before.minimumPrerollVideoFrames, 1u);
}
- (void)testProfileActivationRefreshesAttributesWithoutAPlaybackQueue {
    hardware[0]->outputAvailable = false;
    TestNativeDeckLink *native = new TestNativeDeckLink(drivers[0], hardware[0]);
    DeckLinkDevice *device = [[DeckLinkDevice alloc] initWithDeckLink:native]; native->Release();
    XCTAssertNil(device.playbackQueue);
    hardware[0]->minimumPreroll = 6;
    XCTAssertEqual(hardware[0]->profileCallback->ProfileActivated(NULL), S_OK);
    XCTAssertEqual(device.playbackGroupAttributes.minimumPrerollVideoFrames, 6u);
}
- (void)testFormatListsRemainValidDuringConcurrentReplacement {
    DeckLinkDevice *device = devices[0];
    dispatch_group_t work = dispatch_group_create();
    dispatch_queue_t callers = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_async(work, callers, ^{
        for (NSUInteger i = 0; i < 1000; ++i) {
            [device performPlaybackSync:^{
                NSMutableArray *values = [NSMutableArray arrayWithObject:@(i)];
                device.playbackVideoFormatDescriptions = values;
                device.playbackAudioFormatDescriptions = values;
                device.playbackKeyingModes = values;
                [values removeAllObjects]; // Published arrays must own immutable copies.
            }];
        }
    });
    for (NSUInteger reader = 0; reader < 3; ++reader) dispatch_group_async(work, callers, ^{
        for (NSUInteger i = 0; i < 1000; ++i) {
            NSArray *video = device.playbackVideoFormatDescriptions;
            NSArray *audio = device.playbackAudioFormatDescriptions;
            NSArray *keying = device.playbackKeyingModes;
            XCTAssertEqual(video.count, 1u);
            XCTAssertEqual(audio.count, 1u);
            XCTAssertEqual(keying.count, 1u);
            XCTAssertNotNil(video.firstObject);
            XCTAssertNotNil(audio.firstObject);
            XCTAssertNotNil(keying.firstObject);
        }
    });
    XCTAssertEqual(dispatch_group_wait(work, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0);
}
- (void)testFirstSetFillsEachMembersOwnMinimumPreroll {
    hardware[0]->minimumPreroll = 4; hardware[1]->minimumPreroll = 2;
    for (DeckLinkDevice *device in devices) [device refreshPlaybackGroupAttributes];
    [self start];
    XCTAssertTrue(drivers[0]->videoTimes == (std::vector<int64_t>{0,1001,2002,3003}));
    XCTAssertTrue(drivers[1]->videoTimes == (std::vector<int64_t>{0,1001}));
    XCTAssertEqual([self calls:"start"], 1u);
}
- (void)testStopArmsAllMembersAndRestoresPriorConfiguration {
    [self start]; [self closeExpectingSuccess:YES]; XCTAssertEqual([self calls:"stop"], 1u);
    for (NSUInteger i = 0; i < 2; ++i) {
        XCTAssertFalse(drivers[i]->videoEnabled); XCTAssertFalse(drivers[i]->audioEnabled);
        XCTAssertEqual(hardware[i]->groupID, 17 + i); XCTAssertNil(devices[i].scheduledPlaybackSession);
    }
    XCTAssertEqual(atomic_load(&liveFrames), 0);
}
- (void)testFlushBeforeStoppedCallbackAlsoDrainsTheWholeGroup {
    drivers[0]->flushBeforeStopped = true; drivers[1]->flushBeforeStopped = true;
    [self start]; [self closeExpectingSuccess:YES]; XCTAssertEqual([self calls:"stop"], 1u);
}
- (void)testRejectsMultipleCardsBeforeConfiguration {
    hardware[1]->cardID = 99; [devices[1] refreshPlaybackGroupAttributes];
    [self openExpectingSuccess:NO]; XCTAssertTrue(hardware[0]->groupWrites.empty());
}
- (void)testUnknownCardIdentityIsRejected {
    hardware[0]->identityAvailable = false; [devices[0] refreshPlaybackGroupAttributes]; [self openExpectingSuccess:NO];
}
- (void)testDuplicateSubDeviceIsRejected {
    hardware[1]->index = 0; [devices[1] refreshPlaybackGroupAttributes]; [self openExpectingSuccess:NO];
}
- (void)testUnsupportedSynchronizationIsRejected {
    hardware[1]->supported = false; [devices[1] refreshPlaybackGroupAttributes]; [self openExpectingSuccess:NO];
    XCTAssertEqual(group.error.code, DeckLinkPlaybackGroupUnsupportedDevice);
}
- (void)testSingleOutputRunsWithoutSDKGroupOrReference {
    for (NSUInteger i = 0; i < 2; ++i) { devices[i].modelName = @"DeckLink Duo 2"; hardware[i]->locked = false; [devices[i] refreshPlaybackGroupAttributes]; }
    [self useGroupWithOutputs:@[[self outputsWithAudio:YES][0]]];
    [self openExpectingSuccess:YES];
    [group submitPixelBuffers:@[(__bridge id)buffer] completion:nil];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupRunning; }];
    XCTAssertEqual(drivers[0]->outputFlags, bmdVideoOutputFlagDefault); XCTAssertTrue(hardware[0]->groupWrites.empty());
    XCTAssertFalse(drivers[1]->running);
}
- (void)testDifferentFrameRatesAreRejected {
    id fifty = TestVideoFormat(CMTimeMake(1, 50), YES);
    devices[1].playbackVideoFormatDescriptions = @[videoFormat, fifty];
    [self useGroupWithOutputs:@[[self outputsWithAudio:YES][0], [self outputOn:devices[1] video:fifty audio:NO]]];
    [self openExpectingSuccess:NO]; XCTAssertEqual(group.error.code, DeckLinkPlaybackGroupInvalidConfiguration);
    XCTAssertTrue(hardware[0]->groupWrites.empty());
    for (DeckLinkDevice *device in devices) XCTAssertNil(device.scheduledPlaybackSession);
}
- (void)testPartialConfigurationFailureRollsBackEveryMember {
    drivers[1]->enableAudioStatus = E_FAIL; [self openExpectingSuccess:NO];
    for (NSUInteger i = 0; i < 2; ++i) {
        XCTAssertFalse(drivers[i]->videoEnabled); XCTAssertNil(devices[i].scheduledPlaybackSession);
        XCTAssertEqual(hardware[i]->groupID, 17 + i);
    }
}
- (void)testFailedCleanupRetainsAllOwnershipUntilRetry {
    [self start]; drivers[1]->disableAudioStatus = E_FAIL;
    [self closeExpectingSuccess:NO]; XCTAssertEqual(group.state, DeckLinkPlaybackGroupFailed);
    for (NSUInteger i = 0; i < 2; ++i) XCTAssertEqual(devices[i].scheduledPlaybackSession, members[i]);
    drivers[1]->disableAudioStatus = S_OK; [self closeExpectingSuccess:YES];
    for (DeckLinkDevice *device in devices) XCTAssertNil(device.scheduledPlaybackSession);
}
- (void)testReferenceIsRequiredForDuo2EvenOnOnePhysicalCard {
    for (NSUInteger i = 0; i < 2; ++i) { devices[i].modelName = @"DeckLink Duo 2"; hardware[i]->locked = false; [devices[i] refreshPlaybackGroupAttributes]; }
    group.prerollTimeout = 0.3;
    NSMutableArray<NSNumber *> *states = [NSMutableArray new];
    group.stateHandler = ^(DeckLinkPlaybackGroupState state) { @synchronized (states) { [states addObject:@(state)]; } };
    [self openExpectingSuccess:YES];
    [group submitPixelBuffers:self.frameSet completion:nil];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupWaitingForReference; }];
    // Waiting for reference outlasts the preroll timeout without failing or starting.
    [NSThread sleepForTimeInterval:0.5];
    XCTAssertEqual(group.state, DeckLinkPlaybackGroupWaitingForReference); XCTAssertNil(group.error); XCTAssertEqual([self calls:"start"], 0u);
    for (NSUInteger i = 0; i < 2; ++i) hardware[i]->locked = true;
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupRunning; }];
    XCTAssertEqual([self calls:"start"], 1u);
    [self waitUntil:^BOOL { @synchronized (states) { return [states.lastObject isEqual:@(DeckLinkPlaybackGroupRunning)]; } }];
    @synchronized (states) { XCTAssertTrue([states containsObject:@(DeckLinkPlaybackGroupWaitingForReference)]); }
}
- (void)test8KProCanStartWithoutExternalReference {
    hardware[0]->locked = false; hardware[1]->locked = false; [self start];
}
- (void)testReferenceLossStopsAllOutputs {
    for (DeckLinkDevice *device in devices) { device.modelName = @"DeckLink Quad 2"; [device refreshPlaybackGroupAttributes]; }
    [self start]; hardware[1]->locked = false;
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupClosed; }];
    XCTAssertEqual(group.error.code, DeckLinkPlaybackGroupReferenceUnavailable); XCTAssertEqual([self calls:"stop"], 1u);
}
- (void)testDeviceInvalidationStopsAllOutputs {
    [self start]; [devices[1] invalidatePlayback];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupClosed; }];
    XCTAssertEqual(group.error.code, DeckLinkPlaybackGroupDeviceFailure); XCTAssertEqual([self calls:"stop"], 1u);
}
- (void)testMissingPrerollTimesOutWithoutStarting {
    group.prerollTimeout = 0.05;
    [self openExpectingSuccess:YES];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupClosed; }];
    XCTAssertEqual(group.error.code, DeckLinkPlaybackGroupPrerollTimedOut); XCTAssertEqual([self calls:"start"], 0u);
}
- (void)testStartFailureCleansUpPrerolledMembers {
    drivers[0]->startStatus = E_FAIL; [self openExpectingSuccess:YES];
    [group submitPixelBuffers:self.frameSet completion:nil];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupClosed; }];
    XCTAssertNotNil(group.error); XCTAssertEqual(atomic_load(&liveFrames), 0);
}
- (void)testMemberRejectsDuplicateAndPastTimesWithoutStopping {
    [self start];
    XCTestExpectation *accepted = [self expectationWithDescription:@"aligned frames"]; accepted.expectedFulfillmentCount = 2;
    for (DeckLinkPlaybackSession *session in members) [session submitPixelBuffer:buffer atTime:2002 accepted:^(HRESULT status) {
        XCTAssertEqual(status, S_OK); [accepted fulfill];
    }];
    [self waitForExpectations:@[accepted] timeout:2];
    XCTAssertEqual(drivers[0]->videoTimes.back(), 2002); XCTAssertEqual(drivers[1]->videoTimes.back(), 2002);
    XCTestExpectation *rejected = [self expectationWithDescription:@"duplicate slot"]; rejected.expectedFulfillmentCount = 2;
    [members[0] submitPixelBuffer:buffer atTime:2002 accepted:^(HRESULT status) { XCTAssertEqual(status, S_FALSE); [rejected fulfill]; }];
    [members[0] submitPixelBuffer:buffer atTime:1500 accepted:^(HRESULT status) { XCTAssertEqual(status, E_INVALIDARG); [rejected fulfill]; }];
    [self waitForExpectations:@[rejected] timeout:2]; XCTAssertEqual(group.state, DeckLinkPlaybackGroupRunning);
}
- (void)testCloseWaitsForPreparationOnEveryMember {
    [self start];
    drivers[1]->preparationEntered = dispatch_semaphore_create(0); drivers[1]->preparationRelease = dispatch_semaphore_create(0);
    [group submitPixelBuffers:self.frameSet completion:nil];
    XCTAssertEqual(dispatch_semaphore_wait(drivers[1]->preparationEntered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    XCTestExpectation *closed = [self expectationWithDescription:@"drained preparation"];
    [group closeWithCompletion:^(BOOL ok, NSError *error) { XCTAssertTrue(ok); [closed fulfill]; }];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupClosing; }];
    XCTAssertEqual([self calls:"stop"], 0u);
    dispatch_semaphore_signal(drivers[1]->preparationRelease);
    [self waitForExpectations:@[closed] timeout:2]; XCTAssertEqual([self calls:"stop"], 1u);
}
- (void)testFourOutputsStartAndStopAsOneGroup {
    TestOutput *additional[2]; TestHardware *attributes[2];
    NSMutableArray *four = [[self outputsWithAudio:YES] mutableCopy];
    NSMutableArray *extraDevices = [NSMutableArray new];
    for (NSUInteger i = 0; i < 2; ++i) {
        additional[i] = new TestOutput(); attributes[i] = new TestHardware(); attributes[i]->index = i + 2;
        additional[i]->hardware = attributes[i]; additional[i]->peers = &peers; additional[i]->audioLimit = UINT32_MAX;
        peers.push_back(additional[i]);
        TestNativeDeckLink *native = new TestNativeDeckLink(additional[i], attributes[i]);
        DeckLinkDevice *device = [[DeckLinkDevice alloc] initWithDeckLink:native]; native->Release();
        device.playbackVideoFormatDescriptions = @[videoFormat]; device.playbackAudioFormatDescriptions = @[audioFormat];
        [extraDevices addObject:device];
        [four addObject:[self outputOn:device video:videoFormat audio:YES]];
    }
    [self useGroupWithOutputs:four]; [self openExpectingSuccess:YES];
    NSArray *set = @[(__bridge id)buffer, (__bridge id)buffer, (__bridge id)buffer, (__bridge id)buffer];
    [group submitPixelBuffers:set completion:nil];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupRunning; }];
    XCTAssertEqual([self calls:"start"], 1u);
    for (DeckLinkPlaybackOutput *output in four) XCTAssertTrue(output.device.playbackActive);
    [self closeExpectingSuccess:YES]; XCTAssertEqual([self calls:"stop"], 1u);
    for (DeckLinkDevice *device in extraDevices) [device drainTestQueues];
    group = nil; four = nil; extraDevices = nil; peers.resize(2);
    for (NSUInteger i = 0; i < 2; ++i) { additional[i]->Release(); attributes[i]->Release(); }
    [self useGroupWithOutputs:[self outputsWithAudio:YES]];
}
- (void)testGroupCannotTakeAnOutputOwnedByAnotherGroup {
    DeckLinkPlaybackGroup *single = [[ManualPlaybackGroup alloc] initWithOutputs:@[[self outputsWithAudio:YES][1]]];
    XCTestExpectation *opened = [self expectationWithDescription:@"existing output owner"];
    [single openWithCompletion:^(BOOL ok, NSError *error) { XCTAssertTrue(ok); [opened fulfill]; }];
    [self waitForExpectations:@[opened] timeout:2];
    [self openExpectingSuccess:NO];
    XCTAssertEqual(devices[1].scheduledPlaybackSession, single.sessions.firstObject); XCTAssertTrue(drivers[1]->videoEnabled);
    XCTAssertNil(devices[0].scheduledPlaybackSession);
    XCTestExpectation *closed = [self expectationWithDescription:@"owner closes"];
    [single closeWithCompletion:^(BOOL ok, NSError *error) { XCTAssertTrue(ok); [closed fulfill]; }];
    [self waitForExpectations:@[closed] timeout:2];
}
- (void)testPartialAudioPrerollOnOneOutputDelaysTheWholeGroup {
    drivers[1]->audioLimit = 400;
    [self openExpectingSuccess:YES]; [group submitPixelBuffers:self.frameSet completion:nil];
    [self waitUntil:^BOOL { return drivers[1]->audioTime == 0 && !drivers[1]->audioTimes.empty(); }];
    for (DeckLinkDevice *device in devices) [device drainTestQueues];
    XCTAssertEqual([self calls:"start"], 0u);
    [devices[1] performPlaybackSync:^{ [members[1] serviceAudio]; }];
    XCTAssertEqual([self calls:"start"], 0u);
    [devices[1] performPlaybackSync:^{ [members[1] serviceAudio]; }];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupRunning; }];
    XCTAssertEqual(drivers[1]->audioTime, 800); XCTAssertEqual([self calls:"start"], 1u);
}
- (void)testFailedStopKeepsTheWholeGroupOwnedAndCanBeRetried {
    [self start];
    // Either output can be the stop leader.
    for (NSUInteger i = 0; i < 2; ++i) [devices[i] performPlaybackSync:^{ drivers[i]->stopStatus = E_FAIL; }];
    [self closeExpectingSuccess:NO];
    for (NSUInteger i = 0; i < 2; ++i) [devices[i] performPlaybackSync:^{
        XCTAssertTrue(drivers[i]->running); XCTAssertEqual(devices[i].scheduledPlaybackSession, members[i]);
        drivers[i]->stopStatus = S_OK;
    }];
    [self closeExpectingSuccess:YES];
}
- (void)testGroupConfigurationRestorationFailureDoesNotBlockClose {
    [self start]; hardware[1]->setGroupStatus = E_FAIL; [self closeExpectingSuccess:YES];
    for (DeckLinkDevice *device in devices) XCTAssertNil(device.scheduledPlaybackSession);
    XCTAssertEqual(hardware[0]->groupID, 17); XCTAssertNotEqual(hardware[1]->groupID, 18);
    // The stale ID is harmless: a later single output enables video without group sync.
    [self useGroupWithOutputs:@[[self outputsWithAudio:NO][1]]];
    [self openExpectingSuccess:YES];
    [devices[1] performPlaybackSync:^{ XCTAssertEqual(drivers[1]->outputFlags, bmdVideoOutputFlagDefault); }];
}
- (void)testFrameSetsPrerollAutomaticallyAndShareOneRunningBoundary {
    for (NSUInteger i = 0; i < 2; ++i) { hardware[i]->minimumPreroll = 2; [devices[i] refreshPlaybackGroupAttributes]; }
    [self useGroupWithOutputs:[self outputsWithAudio:NO]]; [self openExpectingSuccess:YES];
    XCTestExpectation *prerolled = [self expectationWithDescription:@"first set fills preroll"];
    [group submitPixelBuffers:self.frameSet completion:^(CMTime time, NSError *error) {
        XCTAssertNil(error); XCTAssertEqual(CMTimeCompare(time, kCMTimeZero), 0); [prerolled fulfill];
    }];
    [self waitForExpectations:@[prerolled] timeout:2];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupRunning; }];
    for (NSUInteger i = 0; i < 2; ++i) XCTAssertTrue(drivers[i]->videoTimes == (std::vector<int64_t>{0,1001}));
    // 0.1 s into playback: frame 5 is on air, so the next boundary is 6006 and one frame of lead targets 7007.
    // Grouped outputs share one hardware clock, so every member's driver advances together.
    for (NSUInteger i = 0; i < 2; ++i) [devices[i] performPlaybackSync:^{ drivers[i]->streamTime = 4800; }];
    XCTestExpectation *running = [self expectationWithDescription:@"shared running boundary"];
    [group submitPixelBuffers:self.frameSet completion:^(CMTime time, NSError *error) {
        XCTAssertNil(error); XCTAssertEqual(CMTimeCompare(time, CMTimeMake(7007,60000)), 0); [running fulfill];
    }];
    [self waitForExpectations:@[running] timeout:2];
    for (NSUInteger i = 0; i < 2; ++i) [devices[i] performPlaybackSync:^{ XCTAssertEqual(drivers[i]->videoTimes.back(), 7007); }];
    XCTestExpectation *dropped = [self expectationWithDescription:@"set rendered faster than output"];
    [group submitPixelBuffers:self.frameSet completion:^(CMTime time, NSError *error) {
        XCTAssertNil(error); XCTAssertFalse(CMTIME_IS_VALID(time)); [dropped fulfill];
    }];
    [self waitForExpectations:@[dropped] timeout:2];
    for (NSUInteger i = 0; i < 2; ++i) [devices[i] performPlaybackSync:^{ XCTAssertEqual(drivers[i]->videoTimes.size(), 3u); }];
    XCTAssertEqual([self calls:"start"], 1u);
}
- (void)testFrameSetNeedsOneBufferPerMember {
    [self openExpectingSuccess:YES];
    XCTestExpectation *rejected = [self expectationWithDescription:@"short frame set"];
    [group submitPixelBuffers:@[(__bridge id)buffer] completion:^(CMTime time, NSError *error) {
        XCTAssertEqual(error.code, DeckLinkPlaybackGroupInvalidConfiguration); [rejected fulfill];
    }];
    [self waitForExpectations:@[rejected] timeout:2]; XCTAssertEqual([self calls:"schedule"], 0u);
}
- (void)testReferencePolicyCanWaiveRequirementForUnrecognizedHardware {
    for (NSUInteger i = 0; i < 2; ++i) { devices[i].modelName = @"DeckLink 8K Pro G2"; hardware[i]->locked = false; [devices[i] refreshPlaybackGroupAttributes]; }
    group.referencePolicy = DeckLinkPlaybackGroupReferenceNotRequired;
    [self start]; XCTAssertNil(group.error);
}
- (void)testReferencePolicyCanRequireReferenceOn8KPro {
    hardware[0]->locked = false; hardware[1]->locked = false;
    group.referencePolicy = DeckLinkPlaybackGroupReferenceRequired;
    [self openExpectingSuccess:YES];
    [group submitPixelBuffers:self.frameSet completion:nil];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupWaitingForReference; }];
    XCTAssertEqual([self calls:"start"], 0u);
    [self closeExpectingSuccess:YES]; XCTAssertEqual([self calls:"start"], 0u);
}
- (void)testProfileCallbackInvalidatesTheGroup {
    [self start]; XCTAssertTrue(hardware[1]->profileCallback != nullptr);
    hardware[1]->profileCallback->ProfileChanging(NULL, true);
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupClosed; }];
    XCTAssertNotNil(group.error); XCTAssertEqual([self calls:"stop"], 1u);
}
- (void)testDroppingAGroupStartsOneCoordinatedCleanup {
    [self start]; __weak DeckLinkPlaybackGroup *weakGroup = group; group = nil;
    [self waitUntil:^BOOL { return weakGroup == nil && devices[0].scheduledPlaybackSession == nil && devices[1].scheduledPlaybackSession == nil; }];
    XCTAssertEqual([self calls:"stop"], 1u); XCTAssertEqual(atomic_load(&liveFrames), 0);
    [self useGroupWithOutputs:[self outputsWithAudio:YES]];
}
- (void)testGroupCallbacksCannotBlockHardwareCleanup {
    [self start];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    dispatch_async((dispatch_queue_t)[group valueForKey:@"callbacks"], ^{
        dispatch_semaphore_signal(entered); dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
    });
    XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)), 0);
    @try {
        [group closeWithCompletion:nil];
        [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupClosed; }];
        XCTAssertEqual(atomic_load(&liveFrames), 0);
        XCTAssertNil(devices[0].scheduledPlaybackSession);
    } @finally { dispatch_semaphore_signal(release); }
}
- (void)testADeviceWithoutPlaybackIsRejectedBeforeScheduling {
    DeckLinkDevice *captureOnly = [[DeckLinkDevice alloc] init];
    captureOnly.playbackGroupAttributes = devices[1].playbackGroupAttributes;
    XCTAssertFalse(captureOnly.referenceSignalLocked);
    [self useGroupWithOutputs:@[[self outputsWithAudio:YES][0], [self outputOn:captureOnly video:videoFormat audio:NO]]];
    [self openExpectingSuccess:NO]; XCTAssertNil(devices[0].scheduledPlaybackSession);
    XCTAssertEqual(group.error.code, DeckLinkPlaybackGroupUnsupportedDevice);
}
- (void)testCloseRequestedDuringOpeningClosesOnceOpenFinishes {
    XCTestExpectation *opened = [self expectationWithDescription:@"open runs to completion"];
    XCTestExpectation *closed = [self expectationWithDescription:@"close while opening"];
    [group openWithCompletion:^(BOOL ok, NSError *error) { XCTAssertTrue(ok); XCTAssertNil(error); [opened fulfill]; }];
    [group closeWithCompletion:^(BOOL ok, NSError *error) { XCTAssertTrue(ok); [closed fulfill]; }];
    [self waitForExpectations:@[opened,closed] timeout:2];
    XCTAssertEqual(group.state, DeckLinkPlaybackGroupClosed);
    for (DeckLinkDevice *device in devices) XCTAssertNil(device.scheduledPlaybackSession);
    XCTAssertEqual([self calls:"start"], 0u);
}
- (void)testNativeSubmissionFailureClosesAllMembers {
    [self start]; drivers[1]->scheduleStatus = E_FAIL;
    [group submitPixelBuffers:self.frameSet completion:nil];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupClosed; }];
    XCTAssertEqual(group.error.code, DeckLinkPlaybackGroupDeviceFailure); XCTAssertEqual([self calls:"stop"], 1u);
    XCTAssertEqual(atomic_load(&liveFrames), 0);
}
- (void)testAnAlreadyStoppedPeerDoesNotWaitForAnotherStoppedCallback {
    [self start];
    [devices[0] performPlaybackSync:^{ drivers[0]->stopped(); drivers[0]->flush(); }];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupClosed; }];
    XCTAssertNotNil(group.error); XCTAssertEqual([self calls:"stop"], 1u);
    XCTAssertNil(devices[0].scheduledPlaybackSession); XCTAssertNil(devices[1].scheduledPlaybackSession);
}
- (void)testReferenceCanAcquireLockDuringPrerollBeforeStarting {
    for (NSUInteger i = 0; i < 2; ++i) { devices[i].modelName = @"DeckLink Duo 2"; hardware[i]->locked = false; [devices[i] refreshPlaybackGroupAttributes]; }
    [self openExpectingSuccess:YES];
    [group submitPixelBuffers:self.frameSet completion:nil];
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupWaitingForReference; }];
    XCTAssertEqual([self calls:"start"], 0u);
    hardware[0]->locked = true; hardware[1]->locked = true;
    [self waitUntil:^BOOL { return group.state == DeckLinkPlaybackGroupRunning; }];
    XCTAssertNil(group.error); XCTAssertEqual([self calls:"start"], 1u);
}

@end

#import "DeckLinkPlaybackGroup+Internal.h"
#import "DeckLinkPlaybackSession+Internal.h"
#include <cmath>

NSString * const DeckLinkPlaybackGroupErrorDomain = @"DeckLinkPlaybackGroupErrorDomain";
static NSError *GroupError(DeckLinkPlaybackGroupError code, NSString *message, NSError *underlying = nil) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:DeckLinkPlaybackGroupErrorDomain code:code userInfo:info];
}
static NSError *NativeGroupError(HRESULT status) {
    return status == S_OK ? nil : GroupError(DeckLinkPlaybackGroupDeviceFailure, @"An output operation failed.",
        [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil]);
}
// Late or excess frames are skipped without stopping playback.
static NSError *FrameError(HRESULT status) {
    if (status == S_FALSE || status == E_OUTOFMEMORY) return GroupError(DeckLinkPlaybackGroupFrameRejected, @"An output skipped a late or excess frame.",
        [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil]);
    return NativeGroupError(status);
}

// Call on the group's queue. Member playback queues only ever post asynchronously to the
// group's queue and never wait on it, so waiting on each member in turn cannot deadlock.
// Every member runs the operation; the first failure is returned.
static HRESULT OnEachMember(NSArray<DeckLinkPlaybackSession *> *members, HRESULT (^operation)(DeckLinkPlaybackSession *)) {
    HRESULT result = S_OK;
    for (DeckLinkPlaybackSession *session in members) {
        __block HRESULT status = S_OK;
        [session.device performPlaybackSync:^{ status = operation(session); }];
        if (result == S_OK && status != S_OK) result = status;
    }
    return result;
}

// Call on queue. Shared by explicit close and deallocation, so it captures the members,
// never a dying group. Only arming (which drains frame preparation) and the driver's
// stop and frame release are asynchronous; every other step is a direct member call.
// A single output is closed the same way: its only member is the stop leader.
static void CloseMembers(NSArray<DeckLinkPlaybackSession *> *members, dispatch_queue_t queue, void (^done)(HRESULT)) {
    if (!members.count) { done(S_OK); return; }
    OnEachMember(members, ^HRESULT(DeckLinkPlaybackSession *session) { [session beginGroupCloseOnQueue]; return S_OK; });
    dispatch_group_t armed = dispatch_group_create(), drained = dispatch_group_create();
    __block HRESULT armResult = S_OK, drainResult = S_OK;
    dispatch_group_enter(drained); // Held until the single stop has been broadcast.
    for (DeckLinkPlaybackSession *session in members) {
        dispatch_group_enter(armed); dispatch_group_enter(drained);
        [session.device armStopWithCompletion:^(HRESULT result) {
            dispatch_async(queue, ^{
                if (drainResult == S_OK && result != S_OK) drainResult = result;
                dispatch_group_leave(drained);
            });
        } armed:^(HRESULT result) {
            dispatch_async(queue, ^{
                if (armResult == S_OK && result != S_OK) armResult = result;
                dispatch_group_leave(armed);
            });
        }];
    }
    dispatch_group_notify(armed, queue, ^{
        // Snapshot every member BEFORE issuing the single SDK stop. A peer that already
        // stopped has no future stopped callback, even if others still run.
        NSMutableSet<DeckLinkPlaybackSession *> *running = [NSMutableSet new];
        HRESULT queried = OnEachMember(members, ^HRESULT(DeckLinkPlaybackSession *session) {
            BOOL isRunning = NO;
            HRESULT status = [session.device getPlaybackRunningOnQueue:&isRunning];
            if (isRunning) [running addObject:session];
            return status;
        });
        HRESULT result = armResult != S_OK ? armResult : queried;
        for (DeckLinkPlaybackSession *leader in members) if ([running containsObject:leader]) {
            HRESULT stopped = OnEachMember(@[leader], ^HRESULT(DeckLinkPlaybackSession *session) {
                return [session.device requestStopOnQueue];
            });
            if (result == S_OK) result = stopped;
            break;
        }
        OnEachMember(members, ^HRESULT(DeckLinkPlaybackSession *session) {
            [session.device completeStopOnQueue:result wasRunning:[running containsObject:session]]; return S_OK;
        });
        if (drainResult == S_OK && result != S_OK) drainResult = result;
        dispatch_group_leave(drained);
    });
    dispatch_group_notify(drained, queue, ^{
        if (drainResult != S_OK) { done(drainResult); return; }
        HRESULT disabled = OnEachMember(members, ^HRESULT(DeckLinkPlaybackSession *session) {
            return [session disableGroupOutputOnQueue];
        });
        if (disabled != S_OK) { done(disabled); return; }
        OnEachMember(members, ^HRESULT(DeckLinkPlaybackSession *session) { [session releaseGroupOwnershipOnQueue]; return S_OK; });
        done(S_OK);
    });
}

@interface DeckLinkPlaybackGroup () {
    dispatch_queue_t _queue, _callbacks;
    dispatch_source_t _timer;
    NSMutableArray<DeckLinkPlaybackSession *> *_reserved;
    NSMutableArray<DeckLinkPlaybackCompletion> *_closeHandlers;
    double _deadline;
    int64_t _sdkGroupID;
    BOOL _primed;
    int64_t _lastSubmittedTime;
}
@property (atomic, assign) DeckLinkPlaybackGroupState state;
@property (atomic, strong) NSError *error;
@end

@implementation DeckLinkPlaybackGroup
- (instancetype)initWithOutputs:(NSArray<DeckLinkPlaybackOutput *> *)outputs {
    if ((self = [super init])) {
        _outputs = [outputs copy]; _prerollTimeout = 5.0;
        NSMutableArray *sessions = [NSMutableArray new];
        for (DeckLinkPlaybackOutput *output in _outputs) [sessions addObject:[[[self sessionClass] alloc] initWithOutput:output group:self]];
        _sessions = [sessions copy];
        _queue = dispatch_queue_create("DeckLinkPlaybackGroup.coordinator", DISPATCH_QUEUE_SERIAL);
        _callbacks = dispatch_queue_create("DeckLinkPlaybackGroup.callbacks", DISPATCH_QUEUE_SERIAL);
        _reserved = [NSMutableArray new]; _closeHandlers = [NSMutableArray new];
        _lastSubmittedTime = -1;
        // Deliberately distinct from the physical DeviceGroupID. IDs are persistent
        // driver settings; close restores the previous values on a best-effort basis.
        _sdkGroupID = (int64_t)(arc4random_uniform(INT32_MAX - 1) + 1);
    }
    return self;
}
- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
    if (!_reserved.count) return;
    NSArray *members = [_reserved copy];
    dispatch_queue_t queue = _queue;
    dispatch_async(queue, ^{
        CloseMembers(members, queue, ^(HRESULT status) {
            if (status != S_OK) NSLog(@"DeckLink playback group fallback cleanup failed: 0x%x", status);
        });
    });
}
- (void)deliver:(DeckLinkPlaybackCompletion)callback error:(NSError *)error {
    if (callback) dispatch_async(_callbacks, ^{ callback(error == nil, error); });
}
- (Class)sessionClass { return DeckLinkPlaybackSession.class; }
- (BOOL)synchronized { return self.sessions.count > 1; }
- (BOOL)requiresReference:(DeckLinkDevice *)device {
    if (!self.synchronized) return NO;
    switch (_referencePolicy) {
        case DeckLinkPlaybackGroupReferenceRequired: return YES;
        case DeckLinkPlaybackGroupReferenceNotRequired: return NO;
        default: return device.playbackGroupRequiresReference;
    }
}
- (BOOL)referenceLockedOnQueue {
    __block BOOL locked = YES;
    OnEachMember(self.sessions, ^HRESULT(DeckLinkPlaybackSession *session) {
        if (locked && [self requiresReference:session.device]) locked = session.device.referenceSignalLocked;
        return S_OK;
    });
    return locked;
}

#pragma mark Opening

- (void)openWithCompletion:(DeckLinkPlaybackCompletion)completion {
    dispatch_async(_queue, ^{
        if (self.state != DeckLinkPlaybackGroupNew) {
            [self deliver:completion error:GroupError(DeckLinkPlaybackGroupInvalidConfiguration, @"A playback group can only be opened once.")]; return;
        }
        // Opening runs to completion in this block, so close and member events queued
        // meanwhile always observe a finished open.
        [self transition:DeckLinkPlaybackGroupOpening];
        NSError *error = [self validateMembers];
        if (!error) {
            HRESULT status = OnEachMember(self.sessions, ^HRESULT(DeckLinkPlaybackSession *session) {
                HRESULT result = [session reserveOnQueue];
                if (result == S_OK) [self->_reserved addObject:session];
                return result;
            });
            int64_t groupID = self.synchronized ? self->_sdkGroupID : 0;
            if (status == S_OK) status = OnEachMember(self.sessions, ^HRESULT(DeckLinkPlaybackSession *session) {
                return [session openOnQueue:groupID];
            });
            error = NativeGroupError(status);
        }
        [self finishOpening:error completion:completion];
    });
}
- (NSError *)validateMembers {
    if (!self.sessions.count || !std::isfinite(_prerollTimeout) || _prerollTimeout <= 0) {
        return GroupError(DeckLinkPlaybackGroupInvalidConfiguration, @"A group requires at least one output and a positive finite preroll timeout.");
    }
    CMTime duration = self.sessions.firstObject.frameDuration;
    for (DeckLinkPlaybackSession *session in self.sessions) {
        if (!CMTIME_IS_NUMERIC(session.frameDuration) || session.frameDuration.value <= 0 || CMTimeCompare(duration, session.frameDuration) != 0) {
            return GroupError(DeckLinkPlaybackGroupInvalidConfiguration, @"Outputs require DeckLink video formats with identical frame rates.");
        }
        if (!session.device.playbackSupported) return GroupError(DeckLinkPlaybackGroupUnsupportedDevice, @"A device does not support playback.");
    }
    if (!self.synchronized) return nil;
    NSNumber *cardID = nil;
    NSMutableSet *indices = [NSMutableSet new];
    for (DeckLinkPlaybackSession *session in self.sessions) {
        DeckLinkPlaybackGroupAttributes *attributes = session.device.playbackGroupAttributes;
        if (session == self.sessions.firstObject) cardID = attributes.deviceGroupID;
        if (!cardID || ![attributes.deviceGroupID isEqual:cardID] || !attributes.subDeviceIndex || attributes.subDeviceIndex.longLongValue < 0 ||
            attributes.subDeviceIndex.unsignedLongLongValue >= attributes.numberOfSubDevices || [indices containsObject:attributes.subDeviceIndex]) {
            return GroupError(DeckLinkPlaybackGroupInvalidConfiguration, @"Synchronized outputs must be distinct sub-devices on one card.");
        }
        if (!attributes.supportsPlaybackSynchronization) {
            return GroupError(DeckLinkPlaybackGroupUnsupportedDevice, @"An output does not support SDK playback synchronization.");
        }
        [indices addObject:attributes.subDeviceIndex];
    }
    return nil;
}
- (void)finishOpening:(NSError *)error completion:(DeckLinkPlaybackCompletion)completion {
    if (error) {
        self.error = error; [self transition:DeckLinkPlaybackGroupClosing];
        CloseMembers([_reserved copy], _queue, ^(HRESULT result) {
            [self finishClose:result];
            [self deliver:completion error:error];
        });
        return;
    }
    [self transition:DeckLinkPlaybackGroupPrerolling];
    _deadline = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) + _prerollTimeout;
    __weak typeof(self) weakSelf = self;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf monitor]; });
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_resume(_timer);
    [self deliver:completion error:nil];
    [self tryStart];
}

#pragma mark Starting and monitoring

- (void)memberReady { dispatch_async(_queue, ^{ [self tryStart]; }); }
- (void)memberFailed:(HRESULT)status {
    dispatch_async(_queue, ^{
        [self failGroup:GroupError(DeckLinkPlaybackGroupDeviceFailure, @"An output failed or was invalidated.",
            [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil])];
    });
}
- (void)transition:(DeckLinkPlaybackGroupState)state {
    if (self.state == state) return;
    self.state = state;
    void (^handler)(DeckLinkPlaybackGroupState) = self.stateHandler;
    if (handler) dispatch_async(_callbacks, ^{ handler(state); });
}
- (void)tryStart {
    if (self.state != DeckLinkPlaybackGroupPrerolling && self.state != DeckLinkPlaybackGroupWaitingForReference) return;
    __block BOOL ready = YES;
    OnEachMember(self.sessions, ^HRESULT(DeckLinkPlaybackSession *session) {
        ready = ready && [session isReadyForGroupStartOnQueue]; return S_OK;
    });
    if (!ready) return;
    // Validate reference last, after all initial media is accepted. Waiting for lock
    // has no deadline; the monitor retries until lock or close.
    if (![self referenceLockedOnQueue]) { [self transition:DeckLinkPlaybackGroupWaitingForReference]; return; }
    [self transition:DeckLinkPlaybackGroupStarting];
    HRESULT status = OnEachMember(self.sessions, ^HRESULT(DeckLinkPlaybackSession *session) {
        return [session prepareGroupStartOnQueue];
    });
    // One SDK start on any member starts the whole hardware group.
    if (status == S_OK) status = OnEachMember(@[self.sessions.firstObject], ^HRESULT(DeckLinkPlaybackSession *leader) {
        return [leader.device startPlaybackOnQueue:leader.frameDuration.timescale];
    });
    if (status != S_OK) { [self failGroup:NativeGroupError(status)]; return; }
    OnEachMember(self.sessions, ^HRESULT(DeckLinkPlaybackSession *session) { [session groupDidStartOnQueue]; return S_OK; });
    [self transition:DeckLinkPlaybackGroupRunning];
}
// Unexpected stops arrive through each device's stopped callback, so only reference
// lock and the preroll deadline are polled.
- (void)monitor {
    switch (self.state) {
        case DeckLinkPlaybackGroupPrerolling:
            if (CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) >= _deadline) {
                [self failGroup:GroupError(DeckLinkPlaybackGroupPrerollTimedOut, @"Not all outputs supplied their initial preroll before the timeout.")];
            }
            break;
        case DeckLinkPlaybackGroupWaitingForReference: [self tryStart]; break;
        case DeckLinkPlaybackGroupRunning:
            if (![self referenceLockedOnQueue]) [self failGroup:GroupError(DeckLinkPlaybackGroupReferenceUnavailable, @"A grouped output lost reference lock.")];
            break;
        default: break;
    }
}
- (void)failGroup:(NSError *)error {
    if (self.state == DeckLinkPlaybackGroupClosing || self.state == DeckLinkPlaybackGroupClosed || self.state == DeckLinkPlaybackGroupFailed) return;
    self.error = error;
    [self transition:DeckLinkPlaybackGroupFailed];
    void (^handler)(NSError *) = self.errorHandler;
    if (handler) dispatch_async(_callbacks, ^{ handler(error); });
    [self closeWithCompletion:nil];
}

#pragma mark Submission

// Call on the group's queue while running. Samples the first member's clock and returns
// the next frame boundary in units of the frame timescale, or -1.
- (int64_t)nextPresentationTimeOnQueue:(HRESULT *)outStatus {
    DeckLinkPlaybackSession *leader = self.sessions.firstObject;
    CMTime duration = leader.frameDuration;
    __block int64_t time = -1;
    *outStatus = OnEachMember(@[leader], ^HRESULT(DeckLinkPlaybackSession *session) {
        DeckLinkPlaybackClock clock;
        HRESULT status = [session.device readPlaybackClockOnQueue:&clock];
        if (status != S_OK) return status;
        if (!clock.running || clock.streamTime < 0) return E_ABORT;
        int64_t current = CMTimeConvertScale(CMTimeMake(clock.streamTime, 48000), duration.timescale, kCMTimeRoundingMethod_RoundTowardZero).value;
        int64_t frame = current / duration.value;
        if (frame >= INT64_MAX / duration.value - 2) return E_INVALIDARG;
        time = (frame + 1) * duration.value;
        return S_OK;
    });
    return time;
}
- (void)submitPixelBuffers:(NSArray *)buffers completion:(void (^)(CMTime, NSError *))completion {
    NSArray *frames = [buffers copy];
    dispatch_async(_queue, ^{
        CMTime duration = self.sessions.firstObject.frameDuration;
        void (^finish)(int64_t, NSError *) = ^(int64_t time, NSError *error) {
            CMTime result = time < 0 ? kCMTimeInvalid : CMTimeMake(time, duration.timescale);
            if (completion) dispatch_async(self->_callbacks, ^{ completion(result, error); });
        };
        NSArray<DeckLinkPlaybackSession *> *members = self.sessions;
        BOOL valid = frames.count == members.count;
        for (id frame in frames) valid = valid && CFGetTypeID((__bridge CFTypeRef)frame) == CVPixelBufferGetTypeID();
        if (!valid) { finish(-1, GroupError(DeckLinkPlaybackGroupInvalidConfiguration, @"Submit one pixel buffer per member.")); return; }
        DeckLinkPlaybackGroupState state = self.state;
        if (state != DeckLinkPlaybackGroupPrerolling && state != DeckLinkPlaybackGroupWaitingForReference &&
            state != DeckLinkPlaybackGroupStarting && state != DeckLinkPlaybackGroupRunning) {
            finish(-1, GroupError(DeckLinkPlaybackGroupInvalidConfiguration, @"The group is not open.")); return;
        }
        if (state != DeckLinkPlaybackGroupRunning && self->_primed) { finish(-1, nil); return; }

        dispatch_group_t accepted = dispatch_group_create();
        __block HRESULT rejection = S_OK;
        void (^submit)(NSUInteger, int64_t) = ^(NSUInteger index, int64_t time) {
            dispatch_group_enter(accepted);
            [members[index] submitPixelBuffer:(__bridge CVPixelBufferRef)frames[index] atTime:time accepted:^(HRESULT status) {
                dispatch_async(self->_queue, ^{
                    if (rejection == S_OK) rejection = status;
                    dispatch_group_leave(accepted);
                });
            }];
        };

        if (!self->_primed) {
            // Repeat each member's first frame to meet its own device's preroll, which may
            // differ between sub-devices of one card. Preroll times are contiguous from zero.
            self->_primed = YES;
            NSUInteger longest = 1;
            for (NSUInteger i = 0; i < members.count; ++i) {
                NSUInteger count = MAX((NSUInteger)1, members[i].device.minimumPrerollVideoFrames);
                longest = MAX(longest, count);
                for (NSUInteger frame = 0; frame < count; ++frame) submit(i, (int64_t)frame * duration.value);
            }
            self->_lastSubmittedTime = (int64_t)(longest - 1) * duration.value;
            dispatch_group_notify(accepted, self->_queue, ^{
                NSError *error = rejection == S_OK ? nil : GroupError(DeckLinkPlaybackGroupDeviceFailure, @"Initial preroll was rejected.", FrameError(rejection));
                if (error) [self failGroup:error];
                finish(error ? -1 : 0, error);
            });
            return;
        }

        HRESULT status = S_OK;
        int64_t next = [self nextPresentationTimeOnQueue:&status];
        if (status != S_OK) { finish(-1, NativeGroupError(status)); return; }
        // One frame of lead covers asynchronous native preparation.
        int64_t target = next + duration.value;
        // A set rendered faster than the output would repeat a slot; keep latency fixed by dropping it.
        if (target <= self->_lastSubmittedTime) { finish(-1, nil); return; }
        self->_lastSubmittedTime = target;
        for (NSUInteger i = 0; i < members.count; ++i) submit(i, target);
        dispatch_group_notify(accepted, self->_queue, ^{ finish(target, FrameError(rejection)); });
    });
}

#pragma mark Closing

- (void)closeWithCompletion:(DeckLinkPlaybackCompletion)completion {
    dispatch_async(_queue, ^{
        if (completion) [self->_closeHandlers addObject:[completion copy]];
        if (self.state == DeckLinkPlaybackGroupClosing) return;
        if (self.state == DeckLinkPlaybackGroupClosed || self.state == DeckLinkPlaybackGroupNew) { [self finishClose:S_OK]; return; }
        [self transition:DeckLinkPlaybackGroupClosing];
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        CloseMembers([self->_reserved copy], self->_queue, ^(HRESULT result) { [self finishClose:result]; });
    });
}
- (void)finishClose:(HRESULT)status {
    [self transition:status == S_OK ? DeckLinkPlaybackGroupClosed : DeckLinkPlaybackGroupFailed];
    if (status == S_OK) [_reserved removeAllObjects];
    else self.error = NativeGroupError(status);
    NSArray *handlers = [_closeHandlers copy]; [_closeHandlers removeAllObjects];
    for (DeckLinkPlaybackCompletion handler in handlers) [self deliver:handler error:NativeGroupError(status)];
}
@end

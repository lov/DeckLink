#import "DeckLinkPlaybackGroup.h"
#import "DeckLinkAPI.h"
@class DeckLinkPlaybackSession;

@interface DeckLinkPlaybackGroup ()
/// One session per output, in the order of `outputs`.
@property (nonatomic, copy, readonly) NSArray<DeckLinkPlaybackSession *> *sessions;
/// Starts the shared audio worker once open; tests replace it to tick members manually.
- (void)startAudioWorker;
@end

/// Events posted by member sessions; both return immediately and never wait on the group.
@interface DeckLinkPlaybackGroup (MemberEvents)
- (void)memberReady;
- (void)memberFailed:(HRESULT)status;
@end

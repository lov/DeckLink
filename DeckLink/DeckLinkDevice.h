#import <Foundation/Foundation.h>

#define kDeckLinkPrimaryRGBPixelFormat bmdFormat8BitBGRA

@interface DeckLinkDevice : NSObject

@property (nonatomic, copy, readonly) NSString *modelName;
@property (nonatomic, copy, readonly) NSString *displayName;

@property (nonatomic, assign, readonly) int32_t persistantID;
@property (nonatomic, assign, readonly) int32_t topologicalID;

/// Thread-safe getters read an immutable snapshot refreshed after profile activation.
/// Physical hardware identity, or nil when the driver does not expose it.
@property (nonatomic, copy, readonly) NSNumber *deviceGroupID;
@property (nonatomic, copy, readonly) NSNumber *subDeviceIndex;
@property (nonatomic, assign, readonly) NSUInteger numberOfSubDevices;
@property (nonatomic, assign, readonly) BOOL supportsPlaybackSynchronization;
/// At least one; playback groups honor this before starting.
@property (nonatomic, assign, readonly) NSUInteger minimumPrerollVideoFrames;
/// NO for the documented DeckLink 8K Pro internal synchronization exception.
/// Unrecognized hardware conservatively requires external reference.
@property (nonatomic, assign, readonly) BOOL playbackGroupRequiresReference;
/// Queries the driver. NO also indicates unavailable reference status.
@property (nonatomic, assign, readonly) BOOL referenceSignalLocked;

/// Atomic access permits replacing the semaphore while capture callbacks read it.
@property (atomic, strong) dispatch_semaphore_t videoCaptureSemaphore;


@end

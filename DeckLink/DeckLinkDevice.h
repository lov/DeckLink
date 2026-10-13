#import <Foundation/Foundation.h>

#define kDeckLinkPrimaryRGBPixelFormat bmdFormat8BitBGRA

/// Immutable playback-group attributes from one complete driver query.
/// Read related fields from one snapshot; the device replaces it after profile activation.
@interface DeckLinkPlaybackGroupAttributes : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/// Physical card identity, or nil when the driver does not expose it.
@property (nonatomic, copy, readonly) NSNumber *deviceGroupID;
/// This output's index on its card, or nil when unavailable.
@property (nonatomic, copy, readonly) NSNumber *subDeviceIndex;
@property (nonatomic, assign, readonly) NSUInteger numberOfSubDevices;
@property (nonatomic, assign, readonly) BOOL supportsPlaybackSynchronization;
/// At least one; playback groups honor this before starting.
@property (nonatomic, assign, readonly) NSUInteger minimumPrerollVideoFrames;
/// NO for the documented DeckLink 8K Pro internal synchronization exception.
/// Unrecognized hardware conservatively requires external reference.
@property (nonatomic, assign, readonly) BOOL playbackGroupRequiresReference;
@end

@interface DeckLinkDevice : NSObject

@property (nonatomic, copy, readonly) NSString *modelName;
@property (nonatomic, copy, readonly) NSString *displayName;

@property (nonatomic, assign, readonly) int32_t persistantID;
@property (nonatomic, assign, readonly) int32_t topologicalID;

/// Thread-safe; replaced as a whole after profile activation. nil for devices without output.
@property (atomic, strong, readonly) DeckLinkPlaybackGroupAttributes *playbackGroupAttributes;
/// Queries the driver. NO also indicates unavailable reference status.
@property (nonatomic, assign, readonly) BOOL referenceSignalLocked;

/// Atomic access permits replacing the semaphore while capture callbacks read it.
@property (atomic, strong) dispatch_semaphore_t videoCaptureSemaphore;


@end

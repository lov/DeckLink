#import <Foundation/Foundation.h>

#define kDeckLinkPrimaryRGBPixelFormat bmdFormat8BitBGRA

typedef void(^DeckLinkDeviceStopPlaybackCompletionHandler)(BOOL success, NSError *error);

@interface DeckLinkDevice : NSObject

@property (nonatomic, copy, readonly) NSString *modelName;
@property (nonatomic, copy, readonly) NSString *displayName;

@property (nonatomic, assign, readonly) int32_t persistantID;
@property (nonatomic, assign, readonly) int32_t topologicalID;

@property (atomic, assign, readonly) NSUInteger frameBufferCount;

@property (atomic, strong) dispatch_semaphore_t videoCaptureSemaphore;


@end

#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>

#import "DeckLink.h"


@interface DeckLink_042_Playback : XCTestCase

@end


@implementation DeckLink_042_Playback

- (void)setUp
{
	[super setUp];
	
	self.continueAfterFailure = NO;
}

- (void)tearDown
{
	[super tearDown];
}

- (void)testVideoFormatDescriptionsCarryModeAndFrameRate
{
	DeckLinkDevice *device = [DeckLinkDevice devicesWithIODirection:DeckLinkDeviceIODirectionPlayback].firstObject;
	XCTAssertNotNil(device);
	
	NSArray *videoFormatDescriptions = device.playbackVideoFormatDescriptions;
	XCTAssertGreaterThan(videoFormatDescriptions.count, 0);
	
	for (id videoFormatDescription_ in videoFormatDescriptions)
	{
		CMVideoFormatDescriptionRef videoFormatDescription = (__bridge CMVideoFormatDescriptionRef)videoFormatDescription_;
		XCTAssertNotNil((__bridge id)CMFormatDescriptionGetExtension(videoFormatDescription, DeckLinkFormatDescriptionDisplayModeKey));
		CMTime frameDuration = kCMTimeInvalid;
		XCTAssertEqual(CMVideoFormatDescriptionGetDeckLinkFrameRate(videoFormatDescription, &frameDuration), noErr);
		XCTAssertTrue(CMTIME_IS_NUMERIC(frameDuration));
	}
}

- (void)testAudioFormatDescriptions
{
	DeckLinkDevice *device = [DeckLinkDevice devicesWithIODirection:DeckLinkDeviceIODirectionPlayback].firstObject;
	XCTAssertNotNil(device);
	XCTAssertGreaterThan(device.playbackAudioFormatDescriptions.count, 0);
}

- (void)testKeyingModesIncludeNone
{
	DeckLinkDevice *device = [DeckLinkDevice devicesWithIODirection:DeckLinkDeviceIODirectionPlayback].firstObject;
	XCTAssertNotNil(device);
	XCTAssertTrue([device.playbackKeyingModes containsObject:DeckLinkKeyingModeNone]);
}

@end

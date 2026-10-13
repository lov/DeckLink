# DeckLink — Imimot fork

A macOS Objective-C framework for Blackmagic Design DeckLink and UltraStudio devices, maintained by Imimot.

This project is a fork of [Boinx Software's DeckLink framework](https://github.com/boinx/DeckLink). It retains the original device-discovery and capture APIs, with substantial changes to playback, pixel-buffer handling, format support, and output lifecycle management. The wrapper and this fork's additions are MIT licensed; see [LICENSE.txt](LICENSE.txt).

## Features

- Device discovery, connection notifications, and supported video/audio format enumeration.
- Video and audio capture through Core Media sample-buffer delegates.
- Scheduled video and audio playback through `DeckLinkPlaybackGroup`, for a single output or for synchronized outputs on one physical card.
- Asynchronous native video-frame preparation, bounded buffer retention, and completion-based release.
- Timestamped audio, partial-write handling, silence generation, and recovery from missed output time.
- Keying and helpers for pixel formats, bit depth, alpha, and color metadata.

## Responsibilities

The framework owns communication with the device. The application owns the media being played.

| Framework | Application |
| --- | --- |
| Discover devices and expose supported formats | Select a device and format; persist settings |
| Configure, start, and stop hardware output | Decide when output should be enabled |
| Prepare native frames and choose their presentation time | Decode, render, apply effects, and supply pixel buffers |
| Request and schedule PCM audio | Decode, mix, map channels, apply gain and fades |
| Maintain the hardware output timeline | Maintain the playhead and implement pause, resume, and seek |
| Retain buffers, handle driver backpressure, and close output safely | Present errors and choose whether to retry or disable output |

There are two timelines: the application's media position and the device's continuously advancing output position. A seek changes the media supplied by the application; it does not require restarting the device's output timeline.

## Requirements and build

- macOS 14.0 or later.
- Xcode with the macOS SDK and command-line tools selected.
- A compatible Blackmagic Desktop Video installation and device for actual capture or playback. The dispatch code loads the driver from `/Library/Frameworks/DeckLinkAPI.framework`.

Build a Release framework for Intel and Apple Silicon from the repository root:

```sh
xcodebuild \
  -project DeckLink.xcodeproj \
  -scheme 'DeckLink Debug' \
  -configuration Release \
  build \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$PWD/Build"
```

The result is `Build/Release/DeckLink.framework`. Link and embed it in the application, sign it as part of the application's normal distribution process, and import:

```objc
#import <DeckLink/DeckLink.h>
```

## Playback

All playback goes through `DeckLinkPlaybackGroup`. A group with one output is an ordinary independent output. A group with two or more outputs plays out synchronized on sub-devices of one physical card. The lifecycle and submission are the same in both cases:

1. Describe each output with a `DeckLinkPlaybackOutput`. It takes a device, formats from the device's `playbackVideoFormatDescriptions` and `playbackAudioFormatDescriptions`, a keying mode, and an audio source. The frame duration is the video format's own DeckLink frame rate.
2. Create the group from the outputs, then set its `errorHandler` and, optionally, its `stateHandler`.
3. Open the group. After opening succeeds, submit one rendered pixel buffer per output for each render pass.
4. Keep supplying video and audio while the output timeline advances. Pause, seek, and switch media inside the audio source.
5. Close the group before changing any output setting or device, or before replacing it after an error.

Output settings, including the audio source, are fixed for the group's lifetime.

```objc
// One output; add more outputs on the same card to synchronize them.
DeckLinkPlaybackOutput *output = [[DeckLinkPlaybackOutput alloc]
    initWithDevice:device videoFormat:videoFormat audioFormat:audioFormat keyingMode:DeckLinkKeyingModeNone
    audioSource:^NSData *(NSUInteger samples, NSUInteger channels, CMTime presentationTime, BOOL discontinuity) {
        return nil; // Replace with prepared interleaved PCM; nil is silence.
    }];

// Retain the group until close completes.
self.outputGroup = [[DeckLinkPlaybackGroup alloc] initWithOutputs:@[output]];
self.outputGroup.errorHandler = ^(NSError *error) {
    // The group has started cleanup; report the failure on the application's queue.
};
[self.outputGroup openWithCompletion:^(BOOL success, NSError *error) {
    if (!success) return;
    // Notify the renderer that it may submit frame sets.
}];

// Once per render pass, one buffer per output in `outputs` order:
[self.outputGroup submitPixelBuffers:@[(__bridge id)renderedPixelBuffer] completion:nil];
```

Pixel buffers must match the selected output dimensions and pixel format and carry the color metadata the driver requires. The application handles rendering and pixel-format conversion; the framework wraps the buffer in a native DeckLink frame. Do not modify a buffer after submitting it.

### Video timing and buffering

The first set after open fills preroll: each buffer is repeated up to its own device's `playbackGroupAttributes.minimumPrerollVideoFrames`, at contiguous times from zero. Sets submitted before playback runs are dropped. Playback starts automatically once every output has its video preroll and, when audio is enabled, a complete audio preroll packet. The default `prerollTimeout` is five seconds. Missing initial content fails and closes the group rather than generating placeholder video.

While running, the group reads one output's clock once per set and schedules every output at the same time: the next output frame boundary plus one frame of lead, which covers native preparation. A set that would not advance past the last scheduled time is dropped, so latency stays fixed when rendering runs faster than the output. The completion reports the scheduled time, or `kCMTimeInvalid` with a nil error for a dropped set.

Each output retains at most `max(3, minimumPrerollVideoFrames)` video buffers, including those being prepared and those awaiting completion. Devices requesting more than 64 preroll frames are rejected at open. If a frame arrives too late, or an output already holds its maximum, that output skips the frame and the completion reports `DeckLinkPlaybackGroupFrameRejected`; playback continues. Other driver failures stop the group.

### Audio contract

- Audio is 48 kHz interleaved signed 16-bit or 32-bit PCM in the selected format.
- `samples` counts sample frames: each contains one sample per channel. Return exactly `samples * channels * bytesPerSample` bytes of immutable data.
- The audio source runs serially on the device's scheduling queue. Supply prepared audio promptly; do not wait for decoding, rendering, or UI work.
- `presentationTime` uses the device's output timeline with a timescale of 48000. It is not the application's clip/playhead position.
- Returning `nil`, or data with the wrong length, supplies silence.
- The source is fixed for the output's lifetime. Pause, seek, mute, or switch media inside it; smooth transitions there as well.
- `discontinuity` indicates recovery after missed output time. The application can use it to reset audio-processing state or apply a transition.
- During recovery, the framework may request and discard missed audio to advance the source.

One audio worker per group requests service every 2 ms for each output with audio, on that output's device queue, and keeps roughly one video frame of audio ahead of the output clock. A group therefore wakes once per tick, not once per output. If the driver accepts only part of a packet, the output keeps the unwritten portion and retries it at its adjusted timestamp.

### Threading, errors, and closing

The framework uses separate serial queues for native frame preparation, per-device scheduling and audio service, group coordination, and group callbacks. Preparation and client callbacks therefore never occupy the scheduling queue. Open/close completions, submission completions, `errorHandler`, and `stateHandler` run on the group's private callback queue. Dispatch UI work to the main queue and application state changes to their owning queue.

Every error uses `DeckLinkPlaybackGroupErrorDomain`. Driver failures carry the native status as an `NSOSStatusErrorDomain` underlying error. A runtime failure stops every output, starts cleanup, and keeps the error in `error`. Await a successful close before creating a replacement group.

`closeWithCompletion:` stops each output's audio source reads. It then waits for frame preparation, sends one SDK stop, and waits for frame release. Finally it disables audio and video output and restores each device's previous SDK playback-group ID. Repeated close calls during closing join the same operation. If cleanup fails, every output keeps its device reserved; retry close before reusing the outputs. Dropping a group starts best-effort cleanup; retain it and call close explicitly to observe failures and retry.

Low buffering requires timely media production. Matching the nominal render rate does not align the renderer's clock phase with the device's. Late frames and audio underruns can still occur under load.

## Synchronized outputs on one card

A group with two or more outputs requires distinct sub-devices of one physical card that support SDK playback synchronization, and video formats with identical frame rates. It rejects different physical `deviceGroupID` values, unavailable identities, duplicate sub-device indices, inactive outputs, devices owned by another group, and unsupported synchronization. Connector counts and profile peer groups are not used as physical-card identity. Grouping does not merge media sources: each output still receives its own video and audio.

The group ends audio preroll on every member and makes one SDK start call, so the outputs start on the same frame. Hardware synchronization alone does not guarantee that separately prepared frames target the same frame number; `submitPixelBuffers:completion:` schedules every member at the same time for that reason. Native submissions remain separate per output; there is no atomic submission across outputs.

The SDK requires common reference lock for grouped playback, with the documented exception of sub-devices of the **DeckLink 8K Pro**. The framework recognizes that exact SDK model name; other models conservatively require external reference. Set `referencePolicy` before open to always require or never require reference instead, for example for hardware known to synchronize internally. Duo 2 and Quad 2 therefore require REF IN even when every selected output is on one card. Ensure the reference frame rate and timing are compatible with the selected outputs.

Once every member is prerolled, a group that requires reference waits for lock in `DeckLinkPlaybackGroupWaitingForReference`, without a deadline, and then starts. Close the group to stop waiting. Lock is polled every 100 ms while waiting or running; losing it stops the group. An unexpected stop is detected through each device's stopped callback rather than by polling. Profile-change callbacks and browser device-removal notifications invalidate the group. Grouping is requested per output with `bmdVideoOutputSynchronizeToPlaybackGroup`. The previous SDK playback-group ID, a persistent driver setting, is restored on close on a best-effort basis: a failed restore is logged and does not fail close. See Blackmagic's [synchronization requirements](https://sdk-doc.blackmagicdesign.com/decklink-sdk/HighLevel/synchronized.html).

## Tests

The playback tests use a mock driver and require no connected device:

```sh
xcodebuild test \
  -project DeckLink.xcodeproj \
  -scheme 'DeckLink Debug' \
  -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:DeckLinkTests/DeckLinkSingleOutputTests \
  -only-testing:DeckLinkTests/DeckLinkPlaybackGroupTests \
  CODE_SIGNING_ALLOWED=NO
```

They cover:
- buffer limits and ownership, frame preparation, and callback isolation;
- preroll, partial audio writes, missed timestamps, and source replacement;
- single-output playback and synchronized start/stop of up to four outputs;
- shared frame-set boundaries, reference requirements and loss, and profile invalidation;
- preroll timeout and retryable cleanup failures.

Other tests in `DeckLinkTests` cover capture and format enumeration; they require suitable Blackmagic hardware and drivers.

Public header comments use `///` documentation for Xcode Quick Help. See [DeckLinkPlaybackGroup.h](DeckLink/DeckLinkPlaybackGroup.h) and [DeckLinkPlaybackOutput.h](DeckLink/DeckLinkPlaybackOutput.h) for the API contracts.

## License and attribution

The Objective-C wrapper and Imimot's additions are distributed under the MIT license in [LICENSE.txt](LICENSE.txt). The upstream Boinx copyright notice is preserved alongside attribution for this fork. The extent of the changes does not remove that attribution.

The bundled files in [DeckLink/DeckLinkAPI](DeckLink/DeckLinkAPI) are Blackmagic Design SDK components with their own copyright and license notices. Those file-level notices remain in place and are separate from the wrapper's MIT license. They reference the [Blackmagic DeckLink SDK EULA](https://www.blackmagicdesign.com/EULA/DeckLinkSDK) where applicable.

Include `LICENSE.txt` when redistributing the wrapper or substantial portions of it, and preserve the applicable notices for bundled SDK components.

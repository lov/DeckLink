// Probes whether each DeckLink playback device can play 'Ay10' (10-bit 4:2:2:4 Y'CbCrA) frames,
// and which way the pixel buffers have to be created:
//   A: a CVPixelBufferPool after registering 'Ay10' with CoreVideo (no framework buffer API needed)
//   B: buffers created by DeckLink (IDeckLinkMacVideoBuffer::CreateCVPixelBufferRef), as MetalBase does
// A 'v210' pool buffer is the control: Mitti plays those today.
//
// Build and run (no DeckLink.framework needed; it links the SDK dispatch code directly):
//   clang++ -std=c++17 -fobjc-arc -O1 -I DeckLink/DeckLinkAPI Tools/Ay10Probe.mm \
//     DeckLink/DeckLinkAPI/DeckLinkAPIDispatch.cpp -framework Foundation -framework CoreVideo \
//     -framework CoreFoundation -framework IOSurface -framework Metal -framework ImageIO -framework CoreGraphics \
//     -o /tmp/Ay10Probe && /tmp/Ay10Probe [seconds] [image.png] [--external]
// With a keying-capable device, each accepted frame is shown for [seconds] (default 1) with the
// internal keyer on (external with --external). Without an image the frame is grey with alpha
// ramping from 0 (left) to full (right). With an image, it is drawn into Rec.709 premultiplied
// BGRA and shown as 8-bit BGRA first (what Mitti keys with today), then as 'Ay10' for comparison.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <vector>
#include <algorithm>
#include <cmath>
#include "DeckLinkAPI.h"

static const OSType kAy10 = 'Ay10';

static NSString *Result(HRESULT r) { return r == S_OK ? @"S_OK" : [NSString stringWithFormat:@"0x%08x", (unsigned)r]; }
static NSString *FourCC(OSType t) {
    char c[5] = { (char)(t >> 24), (char)(t >> 16), (char)(t >> 8), (char)t, 0 };
    return [NSString stringWithUTF8String:c];
}

// One big-endian 32-bit word per pixel: Y (bits 0-9) | Cb or Cr (10-19) | A (20-29).
static uint32_t Ay10Word(uint32_t y, uint32_t c, uint32_t a) {
    return CFSwapInt32HostToBig((y & 0x3FF) | ((c & 0x3FF) << 10) | ((a & 0x3FF) << 20));
}

static void FillAy10(CVPixelBufferRef buffer) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer);
    for (size_t y = 0; y < height; ++y) {
        uint32_t *words = (uint32_t *)(base + y * row);
        for (size_t x = 0; x < width; ++x) words[x] = Ay10Word(721, 512, (uint32_t)(x * 1023 / (width - 1)));
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

// The test image, drawn at the output size as premultiplied BGRA in Rec.709.
static std::vector<uint8_t> gImage;
static size_t gImageWidth = 0, gImageHeight = 0;

static bool LoadImage(NSString *path, size_t width, size_t height) {
    if (gImageWidth == width && gImageHeight == height) return true;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    if (source) CFRelease(source);
    if (!image) return false;
    gImage.assign(width * height * 4, 0);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    CGContextRef context = CGBitmapContextCreate(gImage.data(), width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context); CGColorSpaceRelease(space); CGImageRelease(image);
    gImageWidth = width; gImageHeight = height;
    size_t transparent = 0, partial = 0;
    for (size_t i = 3; i < gImage.size(); i += 4) { transparent += gImage[i] == 0; partial += gImage[i] > 0 && gImage[i] < 255; }
    printf("  image: %zux%zu, %.1f%% transparent, %.1f%% partly transparent pixels\n", width, height,
        100.0 * transparent / (width * height), 100.0 * partial / (width * height));
    return true;
}

static void FillBGRAFromImage(CVPixelBufferRef buffer) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    for (size_t y = 0; y < gImageHeight; ++y)
        memcpy(base + y * CVPixelBufferGetBytesPerRow(buffer), gImage.data() + y * gImageWidth * 4, gImageWidth * 4);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

// BT.709 video range, chroma averaged per pixel pair (as Mitti's v210 path), full-range alpha.
static void FillAy10FromImage(CVPixelBufferRef buffer) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    auto code = [](double v, double offset, double scale) { return (uint32_t)fmin(fmax(lround(offset + v * scale), 4), 1019); };
    for (size_t y = 0; y < gImageHeight; ++y) {
        const uint8_t *src = gImage.data() + y * gImageWidth * 4;
        uint32_t *words = (uint32_t *)(base + y * CVPixelBufferGetBytesPerRow(buffer));
        for (size_t x = 0; x < gImageWidth; x += 2) {
            double luma[2], cb = 0, cr = 0; uint32_t alpha[2];
            for (int k = 0; k < 2; ++k) {
                const uint8_t *p = src + std::min(x + k, gImageWidth - 1) * 4;  // B G R A
                double r = p[2] / 255.0, g = p[1] / 255.0, b = p[0] / 255.0;
                luma[k] = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                cb += (b - luma[k]) / 1.8556 / 2; cr += (r - luma[k]) / 1.5748 / 2;
                alpha[k] = (uint32_t)lround(p[3] * 1023.0 / 255.0);
            }
            words[x] = Ay10Word(code(luma[0], 64, 876), code(cb, 512, 896), alpha[0]);
            if (x + 1 < gImageWidth) words[x + 1] = Ay10Word(code(luma[1], 64, 876), code(cr, 512, 896), alpha[1]);
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

static void RegisterAy10WithCoreVideo(void) {
    NSDictionary *description = @{
        (NSString *)kCVPixelFormatName: @"Ay10 (DeckLink 10-bit 4:2:2:4 Y'CbCrA, big-endian)",
        (NSString *)kCVPixelFormatConstant: @(kAy10),
        (NSString *)kCVPixelFormatBitsPerBlock: @32,
        (NSString *)kCVPixelFormatBlockWidth: @1,
        (NSString *)kCVPixelFormatContainsYCbCr: @YES,
        (NSString *)kCVPixelFormatContainsAlpha: @YES,
    };
    CVPixelFormatDescriptionRegisterDescriptionWithPixelFormatType((__bridge CFDictionaryRef)description, kAy10);
}

static CVPixelBufferRef CreatePoolBuffer(OSType format, size_t width, size_t height, NSString **error) {
    NSDictionary *attributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(format),
        (NSString *)kCVPixelBufferWidthKey: @(width),
        (NSString *)kCVPixelBufferHeightKey: @(height),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (NSString *)kCVBufferPropagatedAttachmentsKey: @{
            (NSString *)kCVImageBufferColorPrimariesKey: (NSString *)kCVImageBufferColorPrimaries_ITU_R_709_2,
            (NSString *)kCVImageBufferYCbCrMatrixKey: (NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            (NSString *)kCVImageBufferTransferFunctionKey: (NSString *)kCVImageBufferTransferFunction_ITU_R_709_2,
        },
    };
    CVPixelBufferPoolRef pool = NULL;
    CVReturn status = CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &pool);
    if (status != kCVReturnSuccess) { *error = [NSString stringWithFormat:@"CVPixelBufferPoolCreate %d", status]; return NULL; }
    CVPixelBufferRef buffer = NULL;
    status = CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &buffer);
    CVPixelBufferPoolRelease(pool);
    if (status != kCVReturnSuccess) { *error = [NSString stringWithFormat:@"CVPixelBufferPoolCreatePixelBuffer %d", status]; return NULL; }
    return buffer;
}

static NSString *DescribeBuffer(CVPixelBufferRef buffer, id<MTLDevice> metal) {
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
    NSString *texture = @"no IOSurface";
    if (surface) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint
            width:CVPixelBufferGetBytesPerRow(buffer) / 4 height:CVPixelBufferGetHeight(buffer) mipmapped:NO];
        d.usage = MTLTextureUsageShaderWrite; d.storageMode = MTLStorageModeShared;
        texture = [metal newTextureWithDescriptor:d iosurface:surface plane:0] ? @"Metal R32Uint view OK" : @"Metal R32Uint view FAILED";
    }
    CFDictionaryRef attachments = CVBufferCopyAttachments(buffer, kCVAttachmentMode_ShouldPropagate);
    NSString *keys = [[(__bridge NSDictionary *)attachments allKeys] componentsJoinedByString:@", "];
    if (attachments) CFRelease(attachments);
    return [NSString stringWithFormat:@"%@ %zux%zu, %zu bytes/row, IOSurface %@, %@, attachments: [%@]",
        FourCC(CVPixelBufferGetPixelFormatType(buffer)), CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
        CVPixelBufferGetBytesPerRow(buffer), surface ? @"yes" : @"no", texture, keys ?: @""];
}

static IDeckLinkMutableVideoFrame *FrameFromBuffer(IDeckLinkOutput *output, CVPixelBufferRef buffer, NSString *label) {
    IDeckLinkMacOutput *mac = NULL;
    HRESULT r = output->QueryInterface(IID_IDeckLinkMacOutput, (void **)&mac);
    IDeckLinkMutableVideoFrame *frame = NULL;
    if (r == S_OK) r = mac->CreateVideoFrameFromCVPixelBufferRef(buffer, &frame);
    if (mac) mac->Release();
    printf("    %s: CreateVideoFrameFromCVPixelBufferRef %s", label.UTF8String, Result(r).UTF8String);
    if (frame) printf(" -> frame %s %ldx%ld, %ld bytes/row", FourCC(frame->GetPixelFormat()).UTF8String, frame->GetWidth(), frame->GetHeight(), frame->GetRowBytes());
    printf("\n");
    return frame;
}

static void ProbeDevice(IDeckLink *deckLink, id<MTLDevice> metal, double seconds, NSString *imagePath, bool external) {
    CFStringRef name = NULL; deckLink->GetDisplayName(&name);
    printf("\n== %s\n", [(__bridge NSString *)name ?: @"?" UTF8String]);
    if (name) CFRelease(name);

    IDeckLinkOutput *output = NULL;
    if (deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&output) != S_OK) { printf("  no playback interface\n"); return; }
    IDeckLinkProfileAttributes *attributes = NULL;
    bool internalKey = false, externalKey = false;
    if (deckLink->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attributes) == S_OK) {
        attributes->GetFlag(BMDDeckLinkSupportsInternalKeying, &internalKey);
        attributes->GetFlag(BMDDeckLinkSupportsExternalKeying, &externalKey);
        attributes->Release();
    }
    printf("  keying: internal %s, external %s\n", internalKey ? "yes" : "no", externalKey ? "yes" : "no");

    // Which modes each format supports, plain and for keying.
    const BMDPixelFormat formats[] = { bmdFormat8BitYUV, bmdFormat10BitYUV, bmdFormat10BitYUVA, bmdFormat8BitBGRA };
    IDeckLinkDisplayModeIterator *modes = NULL;
    BMDDisplayMode testMode = 0; long testWidth = 0, testHeight = 0;
    int counts[4] = {0}, keyCounts[4] = {0}, total = 0;
    if (output->GetDisplayModeIterator(&modes) == S_OK) {
        IDeckLinkDisplayMode *mode = NULL;
        while (modes->Next(&mode) == S_OK) {
            ++total;
            for (int i = 0; i < 4; ++i) {
                bool plain = false, keyed = false;
                output->DoesSupportVideoMode(bmdVideoConnectionUnspecified, mode->GetDisplayMode(), formats[i], bmdNoVideoOutputConversion, bmdSupportedVideoModeDefault, NULL, &plain);
                output->DoesSupportVideoMode(bmdVideoConnectionUnspecified, mode->GetDisplayMode(), formats[i], bmdNoVideoOutputConversion, bmdSupportedVideoModeKeying, NULL, &keyed);
                counts[i] += plain; keyCounts[i] += keyed;
                // Prefer 1080p25; otherwise the first mode that plays Ay10.
                if (formats[i] == bmdFormat10BitYUVA && plain && (!testMode || mode->GetDisplayMode() == bmdModeHD1080p25)) {
                    testMode = mode->GetDisplayMode(); testWidth = mode->GetWidth(); testHeight = mode->GetHeight();
                }
            }
            mode->Release();
        }
        modes->Release();
    }
    printf("  modes supported out of %d (plain / with keying):\n", total);
    for (int i = 0; i < 4; ++i) printf("    %s: %d / %d\n", FourCC(formats[i]).UTF8String, counts[i], keyCounts[i]);
    if (!testMode) { testMode = bmdModeHD1080p25; testWidth = 1920; testHeight = 1080; printf("  no Ay10 mode; still trying buffer creation at 1920x1080\n"); }
    else printf("  test mode: %s %ldx%ld\n", FourCC(testMode).UTF8String, testWidth, testHeight);

    int32_t rowBytes = 0;
    HRESULT r = output->RowBytesForPixelFormat(bmdFormat10BitYUVA, (int32_t)testWidth, &rowBytes);
    printf("  RowBytesForPixelFormat(Ay10, %ld): %s, %d bytes\n", testWidth, Result(r).UTF8String, rowBytes);

    // B: DeckLink-created buffer.
    printf("  B, DeckLink-created buffer:\n");
    CVPixelBufferRef bufferB = NULL;
    IDeckLinkMutableVideoFrame *created = NULL;
    r = output->CreateVideoFrame((int32_t)testWidth, (int32_t)testHeight, rowBytes ?: (int32_t)testWidth * 4, bmdFormat10BitYUVA, bmdFrameFlagDefault, &created);
    printf("    CreateVideoFrame(Ay10): %s\n", Result(r).UTF8String);
    if (created) {
        IDeckLinkVideoFrameMutableMetadataExtensions *metadata = NULL;
        if (created->QueryInterface(IID_IDeckLinkVideoFrameMutableMetadataExtensions, (void **)&metadata) == S_OK) {
            printf("    set Rec.709 colorspace metadata: %s\n", Result(metadata->SetInt(bmdDeckLinkFrameMetadataColorspace, bmdColorspaceRec709)).UTF8String);
            metadata->Release();
        }
        IDeckLinkMacVideoBuffer *mac = NULL;
        r = created->QueryInterface(IID_IDeckLinkMacVideoBuffer, (void **)&mac);
        if (r == S_OK) r = mac->CreateCVPixelBufferRef((void **)&bufferB);
        if (mac) mac->Release();
        printf("    CreateCVPixelBufferRef: %s\n", Result(r).UTF8String);
        if (bufferB) printf("    buffer: %s\n", DescribeBuffer(bufferB, metal).UTF8String);
    }

    // A: our own pool after registering Ay10.
    printf("  A, CVPixelBufferPool with 'Ay10' registered:\n");
    NSString *error = nil;
    CVPixelBufferRef bufferA = CreatePoolBuffer(kAy10, testWidth, testHeight, &error);
    printf("    pool buffer: %s\n", bufferA ? DescribeBuffer(bufferA, metal).UTF8String : error.UTF8String);
    if (bufferA && rowBytes && CVPixelBufferGetBytesPerRow(bufferA) != (size_t)rowBytes)
        printf("    note: pool row bytes %zu differ from DeckLink's %d\n", CVPixelBufferGetBytesPerRow(bufferA), rowBytes);

    CVPixelBufferRef control = CreatePoolBuffer(kCVPixelFormatType_422YpCbCr10, testWidth, testHeight, &error);
    bool hasImage = imagePath && LoadImage(imagePath, testWidth, testHeight);
    if (imagePath && !hasImage) printf("  couldn't load %s\n", imagePath.UTF8String);
    CVPixelBufferRef bgra = hasImage ? CreatePoolBuffer(kCVPixelFormatType_32BGRA, testWidth, testHeight, &error) : NULL;
    // Fully transparent black, shown for a second between frames so each change is visible.
    CVPixelBufferRef black = CreatePoolBuffer(kCVPixelFormatType_32BGRA, testWidth, testHeight, &error);
    if (black) {
        CVPixelBufferLockBaseAddress(black, 0);
        memset(CVPixelBufferGetBaseAddress(black), 0, CVPixelBufferGetDataSize(black));
        CVPixelBufferUnlockBaseAddress(black, 0);
    }

    printf("  CVPixelBuffer -> DeckLink frame:\n");
    IDeckLinkMutableVideoFrame *frameControl = control ? FrameFromBuffer(output, control, @"control v210 pool") : NULL;
    IDeckLinkMutableVideoFrame *frameA = bufferA ? FrameFromBuffer(output, bufferA, @"A Ay10 pool") : NULL;
    IDeckLinkMutableVideoFrame *frameB = bufferB ? FrameFromBuffer(output, bufferB, @"B DeckLink-created") : NULL;
    IDeckLinkMutableVideoFrame *frameBGRA = bgra ? FrameFromBuffer(output, bgra, @"reference BGRA pool") : NULL;
    IDeckLinkMutableVideoFrame *frameBlack = black ? FrameFromBuffer(output, black, @"black BGRA pool") : NULL;
    void (*fillAy10)(CVPixelBufferRef) = hasImage ? FillAy10FromImage : FillAy10;
    if (bufferA) fillAy10(bufferA);
    if (bufferB) fillAy10(bufferB);
    if (bgra) FillBGRAFromImage(bgra);

    // Show each accepted frame, with the keyer on when the device has one.
    printf("  output in %s:\n", FourCC(testMode).UTF8String);
    r = output->EnableVideoOutput(testMode, bmdVideoOutputFlagDefault);
    printf("    EnableVideoOutput: %s\n", Result(r).UTF8String);
    if (r == S_OK) {
        IDeckLinkKeyer *keyer = NULL;
        if ((external ? externalKey : internalKey) && deckLink->QueryInterface(IID_IDeckLinkKeyer, (void **)&keyer) == S_OK) {
            HRESULT k = keyer->Enable(external);
            if (k == S_OK) k = keyer->SetLevel(255);
            printf("    %s keyer on: %s\n", external ? "external" : "internal", Result(k).UTF8String);
        }
        struct { const char *label; IDeckLinkMutableVideoFrame *frame; IDeckLinkVideoFrame *direct; } shows[] = {
            { "control v210 pool", hasImage ? NULL : frameControl, NULL },
            { "reference 8-bit BGRA pool", frameBGRA, NULL },
            { "A Ay10 pool", frameA, NULL },
            { "B DeckLink-created (via CVPixelBuffer)", frameB, NULL },
            { "B DeckLink frame directly", NULL, hasImage ? NULL : created },
        };
        for (auto &show : shows) {
            IDeckLinkVideoFrame *frame = show.frame ?: show.direct;
            if (!frame) continue;
            if (frameBlack) {
                output->DisplayVideoFrameSync(frameBlack);
                printf("    black\n"); fflush(stdout);
                [NSThread sleepForTimeInterval:1.0];
            }
            printf("    DisplayVideoFrameSync %s: %s\n", show.label, Result(output->DisplayVideoFrameSync(frame)).UTF8String);
            fflush(stdout);
            [NSThread sleepForTimeInterval:seconds];
        }
        if (keyer) { keyer->Disable(); keyer->Release(); }
        output->DisableVideoOutput();
    }

    if (frameControl) frameControl->Release();
    if (frameA) frameA->Release();
    if (frameB) frameB->Release();
    if (frameBGRA) frameBGRA->Release();
    CVPixelBufferRelease(bgra);
    if (frameBlack) frameBlack->Release();
    CVPixelBufferRelease(black);
    if (created) created->Release();
    CVPixelBufferRelease(control);
    CVPixelBufferRelease(bufferA);
    CVPixelBufferRelease(bufferB);
    output->Release();
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        double seconds = 1.0; NSString *imagePath = nil; bool external = false;
        for (int i = 1; i < argc; ++i) {
            NSString *arg = @(argv[i]);
            if ([arg isEqualToString:@"--external"]) external = true;
            else if (arg.doubleValue > 0) seconds = arg.doubleValue;
            else imagePath = arg.stringByExpandingTildeInPath;
        }
        RegisterAy10WithCoreVideo();
        id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
        IDeckLinkAPIInformation *info = CreateDeckLinkAPIInformationInstance();
        if (info) {
            CFStringRef version = NULL;
            if (info->GetString(BMDDeckLinkAPIVersion, &version) == S_OK) {
                printf("Desktop Video %s\n", [(__bridge NSString *)version UTF8String]);
                CFRelease(version);
            }
            info->Release();
        }
        IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
        if (!iterator) { printf("DeckLink drivers not installed\n"); return 1; }
        IDeckLink *deckLink = NULL; int found = 0;
        while (iterator->Next(&deckLink) == S_OK) { ++found; ProbeDevice(deckLink, metal, seconds, imagePath, external); deckLink->Release(); }
        iterator->Release();
        if (!found) printf("no DeckLink devices\n");
    }
    return 0;
}

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include "VirtualDisplay.h"

// Declarations for CoreGraphics' private virtual display classes. Types checked against
// the runtime on macOS 27.0 (16 Nov 2026).

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

bool vd_available(void) {
    return NSClassFromString(@"CGVirtualDisplay") != nil &&
           NSClassFromString(@"CGVirtualDisplayDescriptor") != nil &&
           NSClassFromString(@"CGVirtualDisplaySettings") != nil &&
           NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

void *vd_create(const char *name, int width, int height, double refreshHz, bool hidpi, CGDirectDisplayID *displayIDOut) {
    if (!vd_available()) return NULL;
    @autoreleasepool {
        CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        descriptor.queue = dispatch_queue_create("cleanmirror.virtualdisplay", DISPATCH_QUEUE_SERIAL);
        descriptor.name = [NSString stringWithUTF8String:name];
        int scale = hidpi ? 2 : 1;
        descriptor.maxPixelsWide = (unsigned int)(width * scale);
        descriptor.maxPixelsHigh = (unsigned int)(height * scale);
        // A 24-inch 16:9 panel, so macOS treats 1920x1080 as a normal (not Retina) screen.
        descriptor.sizeInMillimeters = CGSizeMake(531, 299);
        // Fixed IDs, so macOS remembers where you put the screen between runs. The Retina version
        // counts as a different screen, so macOS keeps its settings separately.
        descriptor.vendorID = 0x434D;     // "CM"
        descriptor.productID = hidpi ? 0x2160 : 0x1080;
        descriptor.serialNum = 0x0001;
        // Rec.709 / sRGB primaries, D65 white: the same colours the capture and the box use.
        descriptor.redPrimary = CGPointMake(0.640, 0.330);
        descriptor.greenPrimary = CGPointMake(0.300, 0.600);
        descriptor.bluePrimary = CGPointMake(0.150, 0.060);
        descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        descriptor.terminationHandler = ^(id a, id b) {};

        CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (!display || display.displayID == 0) return NULL;

        CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        settings.hiDPI = hidpi ? 1 : 0;
        settings.modes = @[ [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:(unsigned int)width
                                                                                       height:(unsigned int)height
                                                                                  refreshRate:refreshHz] ];
        if (![display applySettings:settings]) return NULL;

        if (displayIDOut) *displayIDOut = display.displayID;
        return (void *)CFBridgingRetain(display);
    }
}

bool vd_use_hidpi_mode(CGDirectDisplayID displayID, int width, int height) {
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(displayID);
    bool already = current && CGDisplayModeGetWidth(current) == (size_t)width &&
                   CGDisplayModeGetPixelWidth(current) == (size_t)(width * 2);
    if (current) CGDisplayModeRelease(current);
    if (already) return true;

    CFDictionaryRef options = (__bridge CFDictionaryRef)@{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, options);
    bool switched = false;
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes) && !switched; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetWidth(mode) == (size_t)width && CGDisplayModeGetHeight(mode) == (size_t)height &&
            CGDisplayModeGetPixelWidth(mode) == (size_t)(width * 2)) {
            CGDisplayConfigRef config;
            if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
                CGConfigureDisplayWithDisplayMode(config, displayID, mode, NULL);
                switched = CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) == kCGErrorSuccess;
            }
        }
    }
    if (modes) CFRelease(modes);
    return switched;
}

void vd_destroy(void *handle) {
    if (handle) CFBridgingRelease(handle);
}

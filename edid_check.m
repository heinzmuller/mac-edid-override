// Read-only diagnostics using public CoreGraphics APIs, without private layouts.
@import Foundation;
@import CoreGraphics;
int main(void) {
    @autoreleasepool {
        CGDirectDisplayID displays[16];
        uint32_t count = 0;
        if (CGGetActiveDisplayList(16, displays, &count) != kCGErrorSuccess) return 1;
        for (uint32_t i=0; i<count; i++) {
            CGDirectDisplayID d=displays[i];
            CGDisplayModeRef mode=CGDisplayCopyDisplayMode(d);
            if (!mode) continue;
            printf("Display %u %s vendor=%04x product=%04x serial=%u: %zux%zu pixels, %.2f Hz\n",
                   d, CGDisplayIsBuiltin(d)?"built-in":"external", CGDisplayVendorNumber(d),
                   CGDisplayModelNumber(d), CGDisplaySerialNumber(d), CGDisplayModeGetPixelWidth(mode),
                   CGDisplayModeGetPixelHeight(mode), CGDisplayModeGetRefreshRate(mode));
            CGDisplayModeRelease(mode);
        }
        return 0;
    }
}

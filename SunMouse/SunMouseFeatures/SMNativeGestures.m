// Protocol and gesture field mapping informed by Mac Mouse Fix TouchSimulator.m.
// Copyright (c) 2019-2023 Noah Nuebling. Adaptation: SunMouse, 2026.
// See THIRD_PARTY_NOTICES.md and Licenses/MMF-License.txt.
#import "SMNativeGestures.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
@protocol SMHIDEvent <NSObject>
- (instancetype)initWithType:(uint32_t)type timestamp:(uint64_t)timestamp senderID:(uint64_t)sender;
- (void)setOptions:(uint32_t)options;
- (void)setIntegerValue:(NSInteger)value forField:(uint32_t)field;
- (void)setDoubleValue:(double)value forField:(uint32_t)field;
- (void)appendEvent:(id)event;
@end
BOOL SMPostDockGesture(double progress, double velocity, int motion, int phase) {
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return NO;
    if (@available(macOS 27.0, *)) {
        static void *hidHandle, *skyHandle;
        static void (*setHID)(CGEventRef, CFTypeRef);
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            hidHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
            skyHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
            if (skyHandle) setHID = dlsym(skyHandle, "SLEventSetIOHIDEvent");
        });
        Class cls = NSClassFromString(@"HIDEvent");
        if (!cls || !setHID || ![cls instancesRespondToSelector:@selector(initWithType:timestamp:senderID:)] ||
            ![cls instancesRespondToSelector:@selector(setDoubleValue:forField:)]) { CFRelease(event); return NO; }
        id<SMHIDEvent> hid = [(id<SMHIDEvent>)[cls alloc] initWithType:23 timestamp:mach_absolute_time() senderID:0];
        if (!hid) { CFRelease(event); return NO; }
        [hid setOptions:(uint32_t)phase << 24];
        [hid setIntegerValue:motion forField:(23 << 16) | 1];
        [hid setIntegerValue:3 forField:(23 << 16) | 5];
        [hid setDoubleValue:progress forField:(23 << 16) | 2];
        if (phase == 4 || phase == 8) {
            id<SMHIDEvent> child = [(id<SMHIDEvent>)[cls alloc] initWithType:9 timestamp:mach_absolute_time() senderID:0];
            [child setDoubleValue:velocity forField:9 << 16];
            [child setDoubleValue:velocity forField:(9 << 16) | 1];
            [hid appendEvent:child];
        }
        CGEventSetType(event, 30);
        setHID(event, (__bridge CFTypeRef)hid);
    } else {
        CGEventSetType(event, 30);
        CGEventSetIntegerValueField(event, 110, 23);
        CGEventSetIntegerValueField(event, 132, phase);
        CGEventSetIntegerValueField(event, 134, phase);
        CGEventSetDoubleValueField(event, 124, progress);
        float f = progress; uint32_t bits; memcpy(&bits, &f, sizeof(bits));
        CGEventSetIntegerValueField(event, 135, bits);
        CGEventSetIntegerValueField(event, 123, motion);
        CGEventSetIntegerValueField(event, 165, motion);
        uint32_t motionBits = (uint32_t)motion; float encodedMotion;
        memcpy(&encodedMotion, &motionBits, sizeof(encodedMotion));
        CGEventSetDoubleValueField(event, 119, encodedMotion);
        CGEventSetDoubleValueField(event, 139, encodedMotion);
        CGEventSetDoubleValueField(event, 129, velocity);
        CGEventSetDoubleValueField(event, 130, velocity);
    }
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, 0x53554E4D4F555345);
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
    return YES;
}

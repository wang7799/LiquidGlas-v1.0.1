//
//  LGPercentageDisplay.m  (v1.0.6)
//  LiquidGlas - Control Center volume / brightness percentage + coloured icons
//
//  Shape (the full reasoning is in NOTES.md):
//
//    LGSliderDescriptor      one typed table entry per slider kind. It names the
//                            kind, how the slider is recognised (class-name
//                            matchers and accessibility matchers), where the
//                            true value comes from, which colour its glyph
//                            gets and which preference key switches its
//                            percentage on. A third slider kind is one table
//                            entry and nothing else.
//
//    LGSliderState           every piece of per-slider state lives here: the
//                            percentage label, the glyph, the last rendered
//                            value, the applied tint, the resolved private
//                            scale. One owner, no duplication.
//
//    LGPercentageController  the single owner of the state table. Both
//                            discovery paths - the runtime swizzle of
//                            CCUIContinuousSliderView and the bounded fallback
//                            scan - feed this one controller.
//
//  Injection: the module never filters itself by bundle id. It stays idle
//  until it finds a Control Center slider, so the filter plist alone decides
//  where it runs. On iOS 17+ the Control Center slider views live in the
//  separate com.apple.controlcenter process, not in SpringBoard.
//
//  Values: the public system value is the source of truth
//  (AVAudioSession.outputVolume / UIScreen.mainScreen.brightness). The private
//  slider value is the guarded fallback. Its 0...1 versus 0...100 scale is
//  resolved from the slider's own maximum and from the public value, so the
//  wrong scale can never be printed.
//
//  Safety: every private class lookup is nil checked, every private selector
//  call is guarded by respondsToSelector:, every KVC read is wrapped in
//  @try, and every private call on the hot path runs inside a @try.
//
//  CPU: the work is event driven off the real slider callbacks
//  (layoutSubviews / setValue:) and off the system value notifications. The
//  only timer is the discovery tick, and it walks the view tree only until a
//  slider has been registered.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#include <string.h>
#include <strings.h>

#pragma mark - Constants

static NSString * const kLGPrefsDomain = @"com.wang7799.liquidglas";

// Preference keys that already exist and keep working.
static NSString * const kLGKeyShowVolumePercentage = @"showVolumePercentage";
static NSString * const kLGKeyShowBrightnessPercentage = @"showBrightnessPercentage";
static NSString * const kLGKeyShowFallbackHUD = @"showFallbackHUD";
static NSString * const kLGKeyShowLoadBanner = @"showLoadBanner";
static NSString * const kLGKeyPercentageFontSize = @"percentageFontSize";

// Preference keys added in v1.0.6. The panel is the only writer.
static NSString * const kLGKeyColorizeSliderIcons = @"colorizeSliderIcons";
static NSString * const kLGKeySliderIconColor = @"sliderIconColor";

#define LGLog(fmt, ...) NSLog((@"[LiquidGlas] " fmt), ##__VA_ARGS__)

#pragma mark - Domain types

typedef NS_ENUM(NSUInteger, LGSliderKind) {
    LGSliderKindUnknown = 0,
    LGSliderKindVolume,
    LGSliderKindBrightness,
};

// The private slider scale is 0...1 on some releases and 0...100 on others.
typedef NS_ENUM(NSUInteger, LGPrivateScale) {
    LGPrivateScaleUnknown = 0,
    LGPrivateScaleUnit,      // 0...1
    LGPrivateScalePercent,   // 0...100
};

// A reader for the public system value of a slider kind. A negative result
// means "not available".
typedef CGFloat (*LGValueReader)(void);

// Class name hints are C strings so the matching path never allocates.
// The accessibility hints are the UTF-8 bytes of the English and the Chinese
// word, written as escapes so the source encoding cannot matter.
static const char * const kLGVolumeClassHints[] = { "volume", NULL };
static const char * const kLGVolumeAccessibilityHints[] = {
    "volume", "\xe9\x9f\xb3\xe9\x87\x8f", NULL
};
static const char * const kLGBrightnessClassHints[] = { "brightness", "backlight", NULL };
static const char * const kLGBrightnessAccessibilityHints[] = {
    "brightness", "\xe4\xba\xae\xe5\xba\xa6", NULL
};

// v1.0.7: tuned for CPU efficiency - longer discovery interval, smaller scan budget
static const NSTimeInterval kLGDiscoveryInterval = 2.0;
static const double kLGConfigThrottle = 0.5;
static const NSUInteger kLGScanBudget = 750;
static const NSInteger kLGMaxAncestorLevels = 4;
static const NSInteger kLGMaxGlyphDepth = 2;

// The public value and the private value may disagree while one of them is
// still catching up. Inside this window they are treated as equal.
static const double kLGValueAgreementTolerance = 0.15;
// A value that moved by less than this counts as "unchanged".
static const double kLGValueEpsilon = 0.005;
// The shortest interval between two system value reads on the slider path.
static const double kLGValueReadInterval = 0.1;

// The private colour setters that belong to the glyph.
//
// The track setters the original author's binary uses
// (setOnTintColor:, setMinimumTrackTintColor:, setMaximumTrackTintColor:,
// setThumbTintColor:) are deliberately not in this list: they paint the
// filled part of the slider, and the fill must never be decorated.
static NSString * const kLGPrivateGlyphColorSetters[] = {
    @"setGlyphColor:",
    @"setGlyphTintColor:",
    @"setFallbackColor:",
};

#pragma mark - Forward declarations

static BOOL LGLayoutHookInstalled = NO;
static BOOL LGSetValueHookInstalled = NO;
static IMP LGOrigLayoutSubviews = NULL;
static IMP LGOrigSetValueFloat = NULL;
static IMP LGOrigSetValueDouble = NULL;

static void LGSliderLayoutSubviews(id self, SEL _cmd);
static void LGSliderSetValueFloat(id self, SEL _cmd, float value);
static void LGSliderSetValueDouble(id self, SEL _cmd, double value);
static void LGPreferencesDidChange(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef info);

#pragma mark - System value readers

static CGFloat LGReadSystemVolume(void) {
    static AVAudioSession *session = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            session = [AVAudioSession sharedInstance];
        } @catch (__unused NSException *exception) {
            session = nil;
        }
    });
    if (!session) return -1.0;
    @try {
        return (CGFloat)session.outputVolume;
    } @catch (__unused NSException *exception) {
        return -1.0;
    }
}

static CGFloat LGReadScreenBrightness(void) {
    @try {
        return (CGFloat)[UIScreen mainScreen].brightness;
    } @catch (__unused NSException *exception) {
        return -1.0;
    }
}

#pragma mark - Descriptor table

@interface LGSliderDescriptor : NSObject

@property (nonatomic, readonly) LGSliderKind kind;
@property (nonatomic, readonly) LGValueReader valueReader;
@property (nonatomic, readonly, strong) UIColor *iconColor;
@property (nonatomic, readonly, copy) NSString *percentageKey;
@property (nonatomic, readonly) BOOL percentageEnabledByDefault;

- (instancetype)initWithKind:(LGSliderKind)kind
                   classHints:(const char * const *)classHints
           accessibilityHints:(const char * const *)accessibilityHints
                  valueReader:(LGValueReader)valueReader
                    iconColor:(UIColor *)iconColor
                percentageKey:(NSString *)percentageKey
       percentageEnabledByDefault:(BOOL)percentageEnabledByDefault;

- (const char * const *)classHints;
- (const char * const *)accessibilityHints;

@end

@implementation LGSliderDescriptor {
    const char * const *_classHints;
    const char * const *_accessibilityHints;
}

- (instancetype)initWithKind:(LGSliderKind)kind
                   classHints:(const char * const *)classHints
           accessibilityHints:(const char * const *)accessibilityHints
                  valueReader:(LGValueReader)valueReader
                    iconColor:(UIColor *)iconColor
                percentageKey:(NSString *)percentageKey
       percentageEnabledByDefault:(BOOL)percentageEnabledByDefault {
    self = [super init];
    if (self) {
        _kind = kind;
        _classHints = classHints;
        _accessibilityHints = accessibilityHints;
        _valueReader = valueReader;
        _iconColor = iconColor;
        _percentageKey = [percentageKey copy];
        _percentageEnabledByDefault = percentageEnabledByDefault;
    }
    return self;
}

- (const char * const *)classHints { return _classHints; }
- (const char * const *)accessibilityHints { return _accessibilityHints; }

@end

// The one table that describes every slider kind the tweak understands.
// Adding a kind means adding one entry here and one panel cell.
static NSArray<LGSliderDescriptor *> *LGSliderDescriptorTable(void) {
    static NSArray<LGSliderDescriptor *> *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        LGSliderDescriptor *volume =
            [[LGSliderDescriptor alloc] initWithKind:LGSliderKindVolume
                                          classHints:kLGVolumeClassHints
                                  accessibilityHints:kLGVolumeAccessibilityHints
                                         valueReader:LGReadSystemVolume
                                           iconColor:[UIColor systemGreenColor]
                                       percentageKey:kLGKeyShowVolumePercentage
                        percentageEnabledByDefault:YES];
        LGSliderDescriptor *brightness =
            [[LGSliderDescriptor alloc] initWithKind:LGSliderKindBrightness
                                          classHints:kLGBrightnessClassHints
                                  accessibilityHints:kLGBrightnessAccessibilityHints
                                         valueReader:LGReadScreenBrightness
                                           iconColor:[UIColor systemBlueColor]
                                       percentageKey:kLGKeyShowBrightnessPercentage
                        percentageEnabledByDefault:YES];
        table = @[volume, brightness];
    });
    return table;
}

#pragma mark - Per slider state

// All per slider state lives here. The controller owns it through a weak table,
// so a slider that is torn down takes its state with it.
@interface LGSliderState : NSObject

@property (nonatomic, weak) UIView *slider;
@property (nonatomic, strong) LGSliderDescriptor *descriptor;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, weak) UIImageView *glyph;
@property (nonatomic, strong) UIImage *originalGlyphImage;
@property (nonatomic, strong) UIColor *originalGlyphTint;
@property (nonatomic, strong) UIColor *appliedTint;
@property (nonatomic, assign) NSInteger renderedPercent;
@property (nonatomic, assign) LGPrivateScale privateScale;
@property (nonatomic, assign) BOOL tintApplied;
@property (nonatomic, assign) BOOL preferPrivateValue;
@property (nonatomic, assign) CGRect lastBounds;
@property (nonatomic, assign) CGFloat lastFontSize;
@property (nonatomic, assign) double lastValueRead;
@property (nonatomic, assign) double lastPublicValue;
@property (nonatomic, assign) double lastNormalizedValue;

@end

@implementation LGSliderState

- (instancetype)init {
    self = [super init];
    if (self) {
        _renderedPercent = -1;
        _privateScale = LGPrivateScaleUnknown;
        _lastBounds = CGRectNull;
        _lastFontSize = 0.0;
        _lastValueRead = 0.0;
        _lastPublicValue = -1.0;
        _lastNormalizedValue = -1.0;
    }
    return self;
}

@end

#pragma mark - Configuration snapshot

// A snapshot of the preferences. The hot path only ever reads this snapshot,
// never the preference store.
@interface LGConfiguration : NSObject

// The percentage switch per descriptor, keyed by the descriptor's preference
// key. The table drives it, so a new kind needs no code here.
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *percentageFlags;
@property (nonatomic, assign) BOOL showFallbackHUD;
@property (nonatomic, assign) BOOL showLoadBanner;
@property (nonatomic, assign) BOOL colorizeSliderIcons;
@property (nonatomic, assign) CGFloat percentageFontSize;
@property (nonatomic, strong) UIColor *iconColorOverride;

- (BOOL)percentageEnabledForDescriptor:(LGSliderDescriptor *)descriptor;

@end

@implementation LGConfiguration

- (BOOL)percentageEnabledForDescriptor:(LGSliderDescriptor *)descriptor {
    NSNumber *flag = self.percentageFlags[descriptor.percentageKey];
    if (!flag) return descriptor.percentageEnabledByDefault;
    return flag.boolValue;
}

@end

#pragma mark - Preference reading

// The preferences are read once per configuration refresh, never on the hot
// path. The persistent domain carries the values PreferenceLoader wrote; the
// CFPreferences path covers the case where the domain is not materialised.
static NSDictionary *LGPreferenceDomain(void) {
    NSDictionary *domain = [[NSUserDefaults standardUserDefaults]
                             persistentDomainForName:kLGPrefsDomain];
    if (domain.count > 0) return domain;

    CFArrayRef keys = CFPreferencesCopyKeyList(CFSTR("com.wang7799.liquidglas"),
                                               kCFPreferencesCurrentUser,
                                               kCFPreferencesCurrentHost);
    if (!keys) return @{};
    CFDictionaryRef values = CFPreferencesCopyMultiple(keys,
                                                       CFSTR("com.wang7799.liquidglas"),
                                                       kCFPreferencesCurrentUser,
                                                       kCFPreferencesCurrentHost);
    CFRelease(keys);
    if (!values) return @{};
    return (__bridge_transfer NSDictionary *)values;
}

static BOOL LGPreferenceBool(NSDictionary *domain, NSString *key, BOOL defaultValue) {
    id value = domain[key];
    if (![value isKindOfClass:[NSNumber class]]) return defaultValue;
    return [value boolValue];
}

static CGFloat LGPreferenceFloat(NSDictionary *domain, NSString *key, CGFloat defaultValue) {
    id value = domain[key];
    if (![value isKindOfClass:[NSNumber class]]) return defaultValue;
    return (CGFloat)[value doubleValue];
}

static NSString *LGPreferenceString(NSDictionary *domain, NSString *key, NSString *defaultValue) {
    id value = domain[key];
    if (![value isKindOfClass:[NSString class]]) return defaultValue;
    return value;
}

// "#RRGGBB" or "#RRGGBBAA" into a colour. An empty string means "no override".
static UIColor *LGColorFromHex(NSString *text) {
    NSString *hex = [text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (hex.length == 0) return nil;
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    if (hex.length != 6 && hex.length != 8) return nil;
    unsigned long long raw = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    if (![scanner scanHexLongLong:&raw]) return nil;
    CGFloat red, green, blue, alpha;
    if (hex.length == 8) {
        red = (CGFloat)((raw >> 24) & 0xFF) / 255.0;
        green = (CGFloat)((raw >> 16) & 0xFF) / 255.0;
        blue = (CGFloat)((raw >> 8) & 0xFF) / 255.0;
        alpha = (CGFloat)(raw & 0xFF) / 255.0;
    } else {
        red = (CGFloat)((raw >> 16) & 0xFF) / 255.0;
        green = (CGFloat)((raw >> 8) & 0xFF) / 255.0;
        blue = (CGFloat)(raw & 0xFF) / 255.0;
        alpha = 1.0;
    }
    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

#pragma mark - View helpers

static NSArray<UIWindow *> *LGAllWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIApplication *application = [UIApplication sharedApplication];
    if (!application) return windows;
    // The legacy window list still works in processes that do not adopt
    // scenes. It is deprecated, so the warning is silenced locally.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in application.windows) {
        if (window) [windows addObject:window];
    }
#pragma clang diagnostic pop
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in [(UIWindowScene *)scene windows]) {
            if (window && ![windows containsObject:window]) [windows addObject:window];
        }
    }
    return windows;
}

// Whether the subtree contains a Control Center view. The name test is the
// signal that survives a rename of the surrounding controllers.
static BOOL LGSubtreeLooksLikeControlCenter(UIView *view, NSInteger depth) {
    if (!view) return NO;
    const char *name = class_getName([view class]);
    if (name && (strcasestr(name, "CCUI") != NULL ||
                 strcasestr(name, "MRU") != NULL ||
                 strcasestr(name, "ControlCenter") != NULL)) {
        return YES;
    }
    if (depth <= 0) return NO;
    for (UIView *sub in view.subviews) {
        if (LGSubtreeLooksLikeControlCenter(sub, depth - 1)) return YES;
    }
    return NO;
}

// The proven fill rule: a plain UIView with masksToBounds between the
// material and the slider is the coloured fill, never the icon.
static BOOL LGIsPlainFillView(UIView *view) {
    const char *name = class_getName([view class]);
    if (!name || strcmp(name, "UIView") != 0) return NO;
    return view.layer.masksToBounds;
}

// A view that carries the slider level or its background. Never an icon.
static BOOL LGIsTrackOrFillView(UIView *view) {
    const char *name = class_getName([view class]);
    if (!name) return NO;
    if (strcasestr(name, "Fill") != NULL) return YES;
    if (strcasestr(name, "Track") != NULL) return YES;
    if (strcasestr(name, "Background") != NULL) return YES;
    return NO;
}

static void LGCollectImageViews(UIView *view, NSInteger depth,
                                NSMutableArray<UIImageView *> *out) {
    for (UIView *sub in view.subviews) {
        if (LGIsPlainFillView(sub)) continue;
        if (LGIsTrackOrFillView(sub)) continue;
        if ([sub isKindOfClass:[UIImageView class]]) {
            UIImageView *imageView = (UIImageView *)sub;
            if (imageView.image) [out addObject:imageView];
        }
        if (depth > 0) LGCollectImageViews(sub, depth - 1, out);
    }
}

// Whether an image is a system symbol. The getter is called through the
// runtime, so the module does not depend on how a release declares it.
static BOOL LGImageIsSymbol(UIImage *image) {
    if (!image) return NO;
    static SEL selector = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        selector = NSSelectorFromString(@"isSymbolImage");
    });
    if (!selector || ![image respondsToSelector:selector]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(image, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

// How good a candidate is as "the glyph". A symbol or a template image wins;
// the class name and the size break the tie.
static NSInteger LGGlyphScore(UIImageView *imageView) {
    UIImage *image = imageView.image;
    if (!image) return -1;
    NSInteger score = 0;
    if (LGImageIsSymbol(image)) score += 4;
    if (image.renderingMode == UIImageRenderingModeAlwaysTemplate) score += 3;
    const char *name = class_getName([imageView class]);
    if (name && (strcasestr(name, "Glyph") != NULL || strcasestr(name, "Icon") != NULL)) {
        score += 2;
    }
    CGFloat side = MAX(CGRectGetWidth(imageView.bounds), CGRectGetHeight(imageView.bounds));
    if (side > 0.0 && side <= 44.0) score += 1;
    if (side > 72.0) score -= 3;
    return score;
}

// The glyph of a slider: the small symbol image that belongs to it.
static UIImageView *LGFindGlyphImageView(UIView *slider) {
    if (!slider) return nil;

    NSMutableArray<UIImageView *> *candidates = [NSMutableArray array];
    LGCollectImageViews(slider, kLGMaxGlyphDepth, candidates);
    UIImageView *best = nil;
    NSInteger bestScore = 2;
    for (UIImageView *candidate in candidates) {
        NSInteger score = LGGlyphScore(candidate);
        if (score > bestScore) {
            bestScore = score;
            best = candidate;
        }
    }
    if (best) return best;

    // The glyph sometimes sits next to the slider rather than inside it. Only
    // a view that is named like a glyph, or a symbol image, is accepted there,
    // so an unrelated module icon is never coloured.
    UIView *parent = slider.superview;
    if (!parent) return nil;
    NSMutableArray<UIImageView *> *siblings = [NSMutableArray array];
    LGCollectImageViews(parent, 2, siblings);
    UIImageView *fallback = nil;
    for (UIImageView *candidate in siblings) {
        const char *name = class_getName([candidate class]);
        BOOL named = name && (strcasestr(name, "Glyph") != NULL ||
                              strcasestr(name, "Icon") != NULL);
        if (!named && !LGImageIsSymbol(candidate.image)) continue;
        CGFloat side = MAX(CGRectGetWidth(candidate.bounds), CGRectGetHeight(candidate.bounds));
        if (side > 48.0) continue;
        if (named) return candidate;
        if (!fallback) fallback = candidate;
    }
    return fallback;
}

static BOOL LGViewIsDescendantOf(UIView *view, UIView *ancestor) {
    if (!view || !ancestor) return NO;
    for (UIView *node = view; node; node = node.superview) {
        if (node == ancestor) return YES;
    }
    return NO;
}

// The class chain of the slider and of its ancestors, matched case
// insensitively against the descriptor hints.
static BOOL LGClassChainMatches(UIView *slider, const char * const *hints) {
    NSInteger level = 0;
    for (UIView *node = slider; node && level < kLGMaxAncestorLevels; node = node.superview, level++) {
        for (Class cls = [node class]; cls; cls = class_getSuperclass(cls)) {
            const char *name = class_getName(cls);
            if (!name) break;
            for (size_t i = 0; hints[i] != NULL; i++) {
                if (strcasestr(name, hints[i]) != NULL) return YES;
            }
        }
    }
    return NO;
}

static BOOL LGTextMatchesHint(NSString *text, const char *hint) {
    if (text.length == 0) return NO;
    NSString *needle = [NSString stringWithUTF8String:hint];
    if (!needle) return NO;
    return [text rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL LGAccessibilityChainMatches(UIView *slider, const char * const *hints) {
    NSInteger level = 0;
    for (UIView *node = slider; node && level < kLGMaxAncestorLevels; node = node.superview, level++) {
        NSString *identifier = node.accessibilityIdentifier;
        NSString *label = node.accessibilityLabel;
        for (size_t i = 0; hints[i] != NULL; i++) {
            if (LGTextMatchesHint(identifier, hints[i])) return YES;
            if (LGTextMatchesHint(label, hints[i])) return YES;
        }
    }
    return NO;
}

// A monochrome image can safely be turned into a template, because the
// template keeps the alpha silhouette and only replaces the colour. A colour
// image cannot, so it is left alone.
static BOOL LGImageIsMonochrome(UIImage *image) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return NO;
    CGColorSpaceRef space = CGImageGetColorSpace(cgImage);
    if (!space) return NO;
    CFStringRef name = CGColorSpaceGetName(space);
    if (!name) return NO;
    if (CFStringCompare(name, CFSTR("kCGColorSpaceGenericGray"),
                        kCFCompareCaseInsensitive) == kCFCompareEqualTo) return YES;
    if (CFStringCompare(name, CFSTR("kCGColorSpaceGenericGrayGamma2.2"),
                        kCFCompareCaseInsensitive) == kCFCompareEqualTo) return YES;
    if (CFStringCompare(name, CFSTR("DeviceGray"),
                        kCFCompareCaseInsensitive) == kCFCompareEqualTo) return YES;
    return NO;
}

#pragma mark - Private slider value

// The scale a slider uses, as far as it can be told from the outside.
typedef NS_ENUM(NSUInteger, LGScaleHint) {
    LGScaleHintUnknown = 0,
    LGScaleHintUnit,      // 0...1
    LGScaleHintPercent,   // 0...100
};

// What is known about one slider class.
//
// The lookup runs on every slider callback, so it is done once per class and
// cached. The KVC key is remembered as well: a key that does not exist
// raises NSUndefinedKeyException, and raising one on every callback is
// expensive, so the failing spellings are tried once and then dropped.
@interface LGSliderTraits : NSObject

@property (nonatomic, assign) BOOL hasValueAccessor;
@property (nonatomic, assign) BOOL valueIsDouble;
// The KVC spelling that worked for this class, or nil when none did.
@property (nonatomic, copy) NSString *workingKey;
// Set once the KVC search has run, so it is not repeated.
@property (nonatomic, assign) BOOL keySearchDone;
// The scale the slider's own range states, and whether it has been read.
@property (nonatomic, assign) LGScaleHint scaleHint;
@property (nonatomic, assign) BOOL scaleHintResolved;

@end

@implementation LGSliderTraits
@end

// The traits of a slider class, cached once.
static LGSliderTraits *LGSliderTraitsForClass(Class sliderClass) {
    static NSMutableDictionary<NSValue *, LGSliderTraits *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    if (!sliderClass) return nil;

    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)sliderClass];
    LGSliderTraits *cached = cache[key];
    if (cached) return cached;

    LGSliderTraits *traits = [[LGSliderTraits alloc] init];
    SEL selector = NSSelectorFromString(@"value");
    Method method = class_getInstanceMethod(sliderClass, selector);
    if (method) {
        const char *encoding = method_getTypeEncoding(method);
        // The first character of the encoding is the return type.
        if (encoding && (encoding[0] == 'd' || encoding[0] == 'f')) {
            traits.hasValueAccessor = YES;
            traits.valueIsDouble = (encoding[0] == 'd');
        }
    }
    if (cache.count > 64) [cache removeAllObjects];
    cache[key] = traits;
    return traits;
}

// The scale of a slider, read from its own range when it exposes one.
//
// The range is read once per class: a key that does not exist raises
// NSUndefinedKeyException, and that is far too expensive to repeat on every
// slider callback.
static LGScaleHint LGScaleHintForSlider(UIView *slider) {
    LGSliderTraits *traits = LGSliderTraitsForClass([slider class]);
    if (!traits) return LGScaleHintUnknown;
    if (traits.scaleHintResolved) return traits.scaleHint;
    traits.scaleHintResolved = YES;
    @try {
        id maximum = [slider valueForKey:@"maximumValue"];
        if ([maximum isKindOfClass:[NSNumber class]]) {
            double value = [maximum doubleValue];
            if (fabs(value - 1.0) <= 0.001) traits.scaleHint = LGScaleHintUnit;
            else if (fabs(value - 100.0) <= 0.001) traits.scaleHint = LGScaleHintPercent;
        }
    } @catch (__unused NSException *exception) {
    }
    return traits.scaleHint;
}

// A private reading of the slider value.
typedef struct {
    double value;        // -1 when the value could not be read
    LGScaleHint hint;    // what the source says about the scale
} LGPrivateReading;

static LGPrivateReading LGReadPrivateSlider(UIView *slider) {
    LGPrivateReading reading = {-1.0, LGScaleHintUnknown};
    if (!slider) return reading;

    static SEL valueSelector = NULL;
    static dispatch_once_t selectorToken;
    dispatch_once(&selectorToken, ^{
        valueSelector = NSSelectorFromString(@"value");
    });

    LGSliderTraits *traits = LGSliderTraitsForClass([slider class]);
    if (traits.hasValueAccessor) {
        @try {
            if (traits.valueIsDouble) {
                reading.value = (double)((double (*)(id, SEL))objc_msgSend)(slider, valueSelector);
            } else {
                reading.value = (double)((float (*)(id, SEL))objc_msgSend)(slider, valueSelector);
            }
            if (isfinite(reading.value) && reading.value >= 0.0) return reading;
            reading.value = -1.0;
        } @catch (__unused NSException *exception) {
            reading.value = -1.0;
        }
    }

    // The KVC spellings that the Control Center sliders use. The key that
    // works is remembered per class, so a failing spelling is only paid for
    // once.
    if (traits.keySearchDone) {
        if (!traits.workingKey) return reading;
    }
    static NSArray<NSString *> *percentKeys = nil;
    static dispatch_once_t keysToken;
    dispatch_once(&keysToken, ^{
        percentKeys = @[@"percentValue", @"_percentValue", @"percent"];
    });
    NSString *firstKey = traits.workingKey;
    for (NSString *key in percentKeys) {
        if (traits.keySearchDone && ![key isEqualToString:firstKey]) continue;
        @try {
            id raw = [slider valueForKey:key];
            if (![raw isKindOfClass:[NSNumber class]]) continue;
            double value = [raw doubleValue];
            if (!isfinite(value) || value < 0.0) continue;
            reading.value = value;
            // A value above 1 states its own scale. A value of 1 or below
            // does not, so the scale stays unknown and the public value has
            // to confirm it.
            reading.hint = (value > 1.0) ? LGScaleHintPercent : LGScaleHintUnknown;
            traits.workingKey = key;
            traits.keySearchDone = YES;
            return reading;
        } @catch (__unused NSException *exception) {
            continue;
        }
    }
    traits.keySearchDone = YES;
    return reading;
}

static NSInteger LGPercentFromNormalizedValue(CGFloat value) {
    double scaled = (double)value * 100.0;
    if (!isfinite(scaled)) return 0;
    NSInteger percent = (NSInteger)lround(scaled);
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    return percent;
}

// The type of the first argument of a method, taken from its type encoding.
//
// A method encoding looks like "ret@:arg", with optional qualifiers in front
// of the argument ("r" for const, "n" for in, and so on). A struct return is
// written in braces and is not parsed here.
static char LGFirstArgumentType(const char *encoding) {
    if (!encoding || encoding[0] == '{' || encoding[0] == '(') return '\0';
    const char *cursor = encoding + 1;
    if (*cursor != '@') return '\0';
    cursor++;
    if (*cursor != ':') return '\0';
    cursor++;
    while (*cursor == 'r' || *cursor == 'n' || *cursor == 'N' ||
           *cursor == 'o' || *cursor == 'O' || *cursor == 'R' || *cursor == 'V') {
        cursor++;
    }
    return *cursor;
}

#pragma mark - Controller

@interface LGPercentageController : NSObject

@property (nonatomic, strong) LGConfiguration *configuration;

+ (instancetype)sharedController;

- (void)start;
- (void)handleSliderEvent:(UIView *)slider;
- (void)handleSystemValueChange;
- (void)markConfigurationStale;
- (void)refreshConfiguration;

@end

// The private surface of the controller. It is declared here so every
// selector is visible to the compiler.
@interface LGPercentageController ()

- (void)installSliderHooksIfNeeded;
- (LGSliderDescriptor *)descriptorForSlider:(UIView *)slider;
- (LGSliderDescriptor *)descriptorByValue:(UIView *)slider;
- (BOOL)isEligibleSlider:(UIView *)slider;
- (void)applyState:(LGSliderState *)state force:(BOOL)force;
- (CGFloat)resolvedValueForState:(LGSliderState *)state
                             raw:(LGPrivateReading)reading
                     publicValue:(CGFloat)publicValue;
- (UILabel *)labelForState:(LGSliderState *)state;
- (void)layoutLabelForState:(LGSliderState *)state;
- (UIColor *)iconColorForDescriptor:(LGSliderDescriptor *)descriptor;
- (void)applyIconTint:(LGSliderState *)state color:(UIColor *)color;
- (void)applyPrivateGlyphColor:(id)target color:(UIColor *)color;
- (UIImageView *)glyphForState:(LGSliderState *)state;
- (UIWindow *)controlCenterWindow;
- (void)startDiscoveryTimer;
- (void)stopDiscoveryTimer;
- (void)discoveryTick;
- (BOOL)hasActiveSlider;
- (void)scanForSlidersInRoot:(UIView *)root;
- (void)showLoadBannerIfNeeded;
- (void)updateHUD;
- (void)showHUDInWindow:(UIWindow *)window text:(NSString *)text;
- (void)hideHUD;

@end

@implementation LGPercentageController {
    NSMapTable<UIView *, LGSliderState *> *_states;
    dispatch_source_t _discoveryTimer;
    NSInteger _discoveryMisses;
    double _lastConfigRefresh;
    double _lastSubtreeScan;
    BOOL _configurationStale;
    BOOL _sawControlCenter;
    BOOL _bannerShown;
    double _hudBannerUntil;
    UIView *_hudContainer;
    UILabel *_hudLabel;
}

+ (instancetype)sharedController {
    static LGPercentageController *controller = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] init];
    });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _states = [NSMapTable weakToStrongObjectsMapTable];
        LGConfiguration *configuration = [[LGConfiguration alloc] init];
        configuration.percentageFlags = @{};
        configuration.showFallbackHUD = YES;
        configuration.showLoadBanner = YES;
        configuration.colorizeSliderIcons = YES;
        configuration.percentageFontSize = 12.0;
        self.configuration = configuration;
    }
    return self;
}

#pragma mark Lifecycle

- (void)start {
    [self refreshConfiguration];
    [self installSliderHooksIfNeeded];
    [self registerNotifications];
    [self startDiscoveryTimer];
}

// Reads the preferences and rebuilds the snapshot. The descriptor table
// drives the percentage switches, so a new kind needs no code here.
- (void)refreshConfiguration {
    double now = CFAbsoluteTimeGetCurrent();
    if (_lastConfigRefresh > 0.0 && (now - _lastConfigRefresh) < kLGConfigThrottle) {
        _configurationStale = YES;
        return;
    }
    _lastConfigRefresh = now;
    _configurationStale = NO;

    NSDictionary *domain = LGPreferenceDomain();
    NSMutableDictionary<NSString *, NSNumber *> *flags = [NSMutableDictionary dictionary];
    for (LGSliderDescriptor *descriptor in LGSliderDescriptorTable()) {
        flags[descriptor.percentageKey] =
            @(LGPreferenceBool(domain, descriptor.percentageKey,
                               descriptor.percentageEnabledByDefault));
    }

    LGConfiguration *configuration = [[LGConfiguration alloc] init];
    configuration.percentageFlags = flags;
    configuration.showFallbackHUD = LGPreferenceBool(domain, kLGKeyShowFallbackHUD, YES);
    configuration.showLoadBanner = LGPreferenceBool(domain, kLGKeyShowLoadBanner, YES);
    configuration.colorizeSliderIcons = LGPreferenceBool(domain, kLGKeyColorizeSliderIcons, YES);
    CGFloat fontSize = LGPreferenceFloat(domain, kLGKeyPercentageFontSize, 12.0);
    configuration.percentageFontSize = (fontSize >= 9.0 && fontSize <= 24.0) ? fontSize : 12.0;
    configuration.iconColorOverride = LGColorFromHex(LGPreferenceString(domain,
                                                                        kLGKeySliderIconColor, @""));
    self.configuration = configuration;

    for (LGSliderState *state in [_states objectEnumerator]) {
        if (state.descriptor) [self applyState:state force:YES];
    }
    [self updateHUD];
}

// The preferences changed. The reload is deferred to the next tick so a
// burst of preference writes cannot flood the hot path.
- (void)markConfigurationStale {
    _configurationStale = YES;
}

- (void)registerNotifications {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];
    __weak LGPercentageController *weakSelf = self;

    void (^onValueChange)(NSNotification *) = ^(NSNotification *note) {
        (void)note;
        [weakSelf handleSystemValueChange];
    };
    void (^onWindowEvent)(NSNotification *) = ^(NSNotification *note) {
        (void)note;
        [weakSelf startDiscoveryTimer];
    };

    NSArray<NSString *> *valueNames = @[UIScreenBrightnessDidChangeNotification,
                                       @"AVSystemController_SystemVolumeDidChangeNotification"];
    for (NSString *name in valueNames) {
        id token = [center addObserverForName:name object:nil queue:mainQueue
                                    usingBlock:onValueChange];
        // The notification centre owns the token; it stays valid for the
        // lifetime of the process.
        (void)token;
    }

    NSArray<NSString *> *windowNames = @[UIApplicationDidBecomeActiveNotification,
                                         UIWindowDidBecomeVisibleNotification,
                                         UIWindowDidBecomeKeyNotification];
    for (NSString *name in windowNames) {
        id token = [center addObserverForName:name object:nil queue:mainQueue
                                    usingBlock:onWindowEvent];
        (void)token;
    }

    // PreferenceLoader writes through cfprefsd. The Darwin notification tells
    // us that the snapshot is stale.
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    LGPreferencesDidChange,
                                    CFSTR("kCFPreferencesAnyApplication"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

#pragma mark Slider hooks

- (void)installSliderHooksIfNeeded {
    if (LGLayoutHookInstalled && LGSetValueHookInstalled) return;
    Class sliderClass = NSClassFromString(@"CCUIContinuousSliderView");
    if (!sliderClass) return;
    @try {
        if (!LGLayoutHookInstalled) {
            Method layout = class_getInstanceMethod(sliderClass, @selector(layoutSubviews));
            if (layout) {
                IMP original = method_getImplementation(layout);
                if (original != (IMP)LGSliderLayoutSubviews) {
                    LGOrigLayoutSubviews = original;
                    class_replaceMethod(sliderClass, @selector(layoutSubviews),
                                        (IMP)LGSliderLayoutSubviews,
                                        method_getTypeEncoding(layout));
                }
                LGLayoutHookInstalled = YES;
            }
        }
        if (!LGSetValueHookInstalled) {
            Method setValue = class_getInstanceMethod(sliderClass, @selector(setValue:));
            const char *encoding = setValue ? method_getTypeEncoding(setValue) : NULL;
            char argumentType = LGFirstArgumentType(encoding);
            if (setValue && argumentType == 'd') {
                IMP original = method_getImplementation(setValue);
                if (original != (IMP)LGSliderSetValueDouble) {
                    LGOrigSetValueDouble = original;
                    class_replaceMethod(sliderClass, @selector(setValue:),
                                        (IMP)LGSliderSetValueDouble, encoding);
                }
                LGSetValueHookInstalled = YES;
            } else if (setValue && argumentType == 'f') {
                IMP original = method_getImplementation(setValue);
                if (original != (IMP)LGSliderSetValueFloat) {
                    LGOrigSetValueFloat = original;
                    class_replaceMethod(sliderClass, @selector(setValue:),
                                        (IMP)LGSliderSetValueFloat, encoding);
                }
                LGSetValueHookInstalled = YES;
            }
        }
        LGLog(@"slider hooks: layout=%d setValue=%d",
              (int)LGLayoutHookInstalled, (int)LGSetValueHookInstalled);
    } @catch (__unused NSException *exception) {
        LGLog(@"slider hooks failed: %@", exception);
    }
}

#pragma mark Slider events

- (void)handleSliderEvent:(UIView *)slider {
    if (![slider isKindOfClass:[UIView class]]) return;
    LGSliderState *state = [_states objectForKey:slider];
    if (!state) {
        // The kind of a slider is resolved exactly once. A slider that is not
        // one of ours is remembered as such, so the matching cost is paid
        // once per slider and not once per layout pass.
        state = [[LGSliderState alloc] init];
        state.slider = slider;
        state.descriptor = [self descriptorForSlider:slider];
        [_states setObject:state forKey:slider];
        if (state.descriptor) {
            LGLog(@"registered %@ slider %@",
                  state.descriptor.kind == LGSliderKindVolume ? @"volume" : @"brightness",
                  NSStringFromClass([slider class]));
        }
    }
    if (!state.descriptor) return;
    [self applyState:state force:NO];
}

- (void)handleSystemValueChange {
    for (LGSliderState *state in [_states objectEnumerator]) {
        if (state.descriptor) [self applyState:state force:YES];
    }
    [self updateHUD];
}

// Recognition, in order of confidence:
//   1. an explicit accessibility label or identifier,
//   2. a class name in the chain,
//   3. the value itself: the private slider value is matched against both
//      public values under both scale hypotheses, and the closest fit wins.
// Nothing else is consulted, so the kind of a slider is decided by data.
- (LGSliderDescriptor *)descriptorForSlider:(UIView *)slider {
    NSArray<LGSliderDescriptor *> *table = LGSliderDescriptorTable();
    for (LGSliderDescriptor *descriptor in table) {
        if (LGAccessibilityChainMatches(slider, [descriptor accessibilityHints])) {
            return [self isEligibleSlider:slider] ? descriptor : nil;
        }
    }
    for (LGSliderDescriptor *descriptor in table) {
        if (LGClassChainMatches(slider, [descriptor classHints])) {
            return [self isEligibleSlider:slider] ? descriptor : nil;
        }
    }
    return [self descriptorByValue:slider];
}

// The value based fallback. It resolves the kind at the same time by picking
// the hypothesis with the smallest error, and it refuses to guess when the
// two kinds are equally plausible.
- (LGSliderDescriptor *)descriptorByValue:(UIView *)slider {
    LGPrivateReading reading = LGReadPrivateSlider(slider);
    double raw = reading.value;
    if (raw < 0.0 || raw > 100.0) return nil;

    NSArray<LGSliderDescriptor *> *table = LGSliderDescriptorTable();
    LGSliderDescriptor *best = nil;
    double bestError = INFINITY;
    double runnerUpError = INFINITY;
    for (LGSliderDescriptor *descriptor in table) {
        LGValueReader reader = descriptor.valueReader;
        CGFloat publicValue = reader();
        if (publicValue < 0.0) continue;
        double candidates[2];
        candidates[0] = raw;
        candidates[1] = raw / 100.0;
        for (NSInteger index = 0; index < 2; index++) {
            double normalized = candidates[index];
            if (normalized < 0.0 || normalized > 1.0) continue;
            double error = fabs(normalized - (double)publicValue);
            if (error < bestError) {
                runnerUpError = bestError;
                bestError = error;
                best = descriptor;
            } else if (error < runnerUpError) {
                runnerUpError = error;
            }
        }
    }
    if (!best) return nil;
    if (bestError > kLGValueAgreementTolerance) return nil;
    if (runnerUpError - bestError < 0.04) return nil;
    if (![self isEligibleSlider:slider]) return nil;
    return best;
}

// The SpringBoard volume HUD reuses Control Center views inside an elastic
// hierarchy and animates them, so a label there fights the animation.
- (BOOL)isEligibleSlider:(UIView *)slider {
    for (UIView *node = slider; node; node = node.superview) {
        const char *name = class_getName([node class]);
        if (!name) break;
        if (strncmp(name, "SBElastic", 8) == 0) return NO;
    }
    return YES;
}

#pragma mark Applying a state

// Renders one slider. The `force` flag bypasses the read throttle, which is
// what the system value notification needs.
- (void)applyState:(LGSliderState *)state force:(BOOL)force {
    UIView *slider = state.slider;
    if (!slider) return;
    LGSliderDescriptor *descriptor = state.descriptor;
    if (!descriptor) return;

    if (![self.configuration percentageEnabledForDescriptor:descriptor]) {
        state.label.hidden = YES;
        [self applyIconTint:state color:nil];
        return;
    }

    // The system value read is the expensive part, so it is throttled on the
    // slider callback path. The notification path reads it every time.
    double now = CFAbsoluteTimeGetCurrent();
    if (!force && (now - state.lastValueRead) < kLGValueReadInterval) {
        [self layoutLabelForState:state];
        return;
    }
    state.lastValueRead = now;

    LGValueReader reader = descriptor.valueReader;
    CGFloat publicValue = reader();
    LGPrivateReading reading = LGReadPrivateSlider(slider);
    CGFloat value = [self resolvedValueForState:state
                                          raw:reading
                                  publicValue:publicValue];
    if (value < 0.0) {
        state.label.hidden = YES;
        return;
    }

    NSInteger percent = LGPercentFromNormalizedValue(value);
    UILabel *label = [self labelForState:state];
    label.hidden = NO;
    if (state.renderedPercent != percent) {
        label.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
        state.renderedPercent = percent;
    }
    [self layoutLabelForState:state];
    [self applyIconTint:state color:[self iconColorForDescriptor:descriptor]];
}

// Resolves the value that is printed.
//
// The public system value is the source of truth. The private slider value is
// the guarded fallback, and it is only used when the public value is
// unavailable or when the public value demonstrably did not move while the
// private one did.
//
// The private scale (0...1 or 0...100) is resolved from the slider's own
// range, from the name of the property it came from, from the range of the
// raw value, and finally from the public value. A scale that stays unknown
// means no private number is printed at all, so a wrong number is impossible.
- (CGFloat)resolvedValueForState:(LGSliderState *)state
                             raw:(LGPrivateReading)reading
                     publicValue:(CGFloat)publicValue {
    double raw = reading.value;
    BOOL publicValid = isfinite((double)publicValue) &&
                       publicValue >= 0.0 && publicValue <= 1.0;
    BOOL rawValid = isfinite(raw) && raw >= 0.0 && raw <= 100.0;

    if (rawValid) {
        if (state.privateScale == LGPrivateScaleUnknown) {
            // The scale is resolved from four sources, strongest first: the
            // slider's own range, what the source of the value says about it,
            // the range of the raw value, and finally the public value.
            LGScaleHint hint = LGScaleHintForSlider(state.slider);
            if (hint == LGScaleHintUnknown) hint = reading.hint;
            if (hint == LGScaleHintUnit) {
                state.privateScale = LGPrivateScaleUnit;
            } else if (hint == LGScaleHintPercent) {
                state.privateScale = LGPrivateScalePercent;
            } else if (raw > 1.0) {
                // A 0...1 slider can never exceed 1.
                state.privateScale = LGPrivateScalePercent;
            } else if (publicValid) {
                double errorUnit = fabs(raw - (double)publicValue);
                double errorPercent = fabs(raw / 100.0 - (double)publicValue);
                if (errorUnit <= 0.05 || errorPercent <= 0.05) {
                    state.privateScale = (errorUnit <= errorPercent) ? LGPrivateScaleUnit
                                                                     : LGPrivateScalePercent;
                }
            }
        } else if (raw > 1.0 && state.privateScale == LGPrivateScaleUnit) {
            // The earlier assumption was wrong.
            state.privateScale = LGPrivateScalePercent;
        }
    }

    double normalized = -1.0;
    if (rawValid) {
        if (state.privateScale == LGPrivateScaleUnit) {
            normalized = (raw <= 1.0) ? raw : -1.0;
        } else if (state.privateScale == LGPrivateScalePercent) {
            normalized = raw / 100.0;
        }
    }

    // Freshness test. When one of the two values moved and the other did
    // not, the one that did not move is the stale one.
    if (publicValid && normalized >= 0.0) {
        double publicMoved = (state.lastPublicValue >= 0.0)
            ? fabs((double)publicValue - state.lastPublicValue) : 1.0;
        double privateMoved = (state.lastNormalizedValue >= 0.0)
            ? fabs(normalized - state.lastNormalizedValue) : 1.0;
        if (publicMoved <= kLGValueEpsilon && privateMoved > 0.02) {
            state.preferPrivateValue = YES;
        } else if (privateMoved <= kLGValueEpsilon && publicMoved > 0.02) {
            state.preferPrivateValue = NO;
        } else if (fabs((double)publicValue - normalized) <= kLGValueAgreementTolerance) {
            state.preferPrivateValue = NO;
        }
    }
    if (publicValid) state.lastPublicValue = publicValue;
    if (normalized >= 0.0) state.lastNormalizedValue = normalized;

    if (publicValid && !state.preferPrivateValue) return publicValue;
    if (normalized >= 0.0) return (CGFloat)normalized;
    if (publicValid) return publicValue;
    return -1.0;
}

#pragma mark Label

- (UILabel *)labelForState:(LGSliderState *)state {
    if (state.label) return state.label;
    UIView *slider = state.slider;
    if (!slider) return nil;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.userInteractionEnabled = NO;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    label.layer.cornerRadius = 7.0;
    label.layer.masksToBounds = YES;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    state.label = label;
    // Attaching a subview during a layout pass is not allowed, so the label
    // joins the slider after the current pass has finished.
    __weak UIView *weakSlider = slider;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongSlider = weakSlider;
        if (!strongSlider || label.superview == strongSlider) return;
        [strongSlider addSubview:label];
        [strongSlider bringSubviewToFront:label];
    });
    [self layoutLabelForState:state];
    return label;
}

- (void)layoutLabelForState:(LGSliderState *)state {
    UILabel *label = state.label;
    UIView *slider = state.slider;
    if (!label || !slider) return;
    CGRect bounds = slider.bounds;
    CGFloat fontSize = self.configuration.percentageFontSize;
    BOOL boundsChanged = !CGRectEqualToRect(bounds, state.lastBounds);
    BOOL fontChanged = (fontSize != state.lastFontSize);
    if (!boundsChanged && !fontChanged) return;
    state.lastBounds = bounds;
    state.lastFontSize = fontSize;

    label.font = [UIFont monospacedDigitSystemFontOfSize:fontSize
                                                  weight:UIFontWeightSemibold];
    CGFloat width = MIN(42.0, MAX(CGRectGetWidth(bounds) - 6.0, 24.0));
    CGFloat height = MAX(fontSize + 2.0, 14.0);
    BOOL vertical = CGRectGetWidth(bounds) < CGRectGetHeight(bounds);
    CGRect frame;
    if (vertical) {
        // A vertical slider fills from the bottom, so the readout goes to the
        // top where the level does not reach first.
        frame = CGRectMake((CGRectGetWidth(bounds) - width) / 2.0, 3.0, width, height);
    } else {
        frame = CGRectMake(2.0, 2.0, width, height);
    }
    label.frame = frame;
}

#pragma mark Icon colour

- (UIColor *)iconColorForDescriptor:(LGSliderDescriptor *)descriptor {
    if (!self.configuration.colorizeSliderIcons) return nil;
    UIColor *override = self.configuration.iconColorOverride;
    if (override) return override;
    return descriptor.iconColor;
}

// Tints the glyph only. The track and the fill are never touched.
- (void)applyIconTint:(LGSliderState *)state color:(UIColor *)color {
    UIImageView *glyph = [self glyphForState:state];
    if (!glyph) return;
    if (!color) {
        if (!state.tintApplied) return;
        glyph.image = state.originalGlyphImage;
        glyph.tintColor = state.originalGlyphTint;
        state.tintApplied = NO;
        state.appliedTint = nil;
        return;
    }
    if (state.tintApplied && state.appliedTint && [state.appliedTint isEqual:color]) return;

    if (!state.tintApplied) {
        state.originalGlyphImage = glyph.image;
        state.originalGlyphTint = glyph.tintColor;
        state.tintApplied = YES;
    }

    UIImage *image = glyph.image;
    if (image) {
        BOOL templateReady = (image.renderingMode == UIImageRenderingModeAlwaysTemplate);
        if (!templateReady && (LGImageIsSymbol(image) || LGImageIsMonochrome(image))) {
            // A symbol or a monochrome glyph keeps its shape as a template and
            // picks up the tint colour. A colour image is left untouched.
            glyph.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            templateReady = YES;
        }
        if (templateReady) {
            glyph.tintColor = color;
            state.appliedTint = color;
            [self applyPrivateGlyphColor:state.slider color:color];
            return;
        }
    }

    // The glyph is not a template image. The private glyph colour setters are
    // the last resort; they exist on the Control Center sliders.
    [self applyPrivateGlyphColor:state.slider color:color];
    state.appliedTint = color;
}

- (void)applyPrivateGlyphColor:(id)target color:(UIColor *)color {
    if (!target || !color) return;
    NSUInteger count = sizeof(kLGPrivateGlyphColorSetters) / sizeof(kLGPrivateGlyphColorSetters[0]);
    for (NSUInteger index = 0; index < count; index++) {
        SEL selector = NSSelectorFromString(kLGPrivateGlyphColorSetters[index]);
        if (!selector || ![target respondsToSelector:selector]) continue;
        @try {
            ((void (*)(id, SEL, UIColor *))objc_msgSend)(target, selector, color);
        } @catch (__unused NSException *exception) {
        }
        return;
    }
}

- (UIImageView *)glyphForState:(LGSliderState *)state {
    UIImageView *glyph = state.glyph;
    if (glyph && LGViewIsDescendantOf(glyph, state.slider)) return glyph;
    glyph = LGFindGlyphImageView(state.slider);
    state.glyph = glyph;
    return glyph;
}

#pragma mark Discovery

// The Control Center window. The name test is cheap and runs on every tick;
// the subtree scan is the fallback and is throttled.
- (UIWindow *)controlCenterWindow {
    UIWindow *fallback = nil;
    for (UIWindow *window in LGAllWindows()) {
        if (!window || window.hidden || window.alpha < 0.01) continue;
        if (window.windowLevel != UIWindowLevelNormal) continue;
        const char *name = class_getName([window class]);
        if (name && (strcasestr(name, "ControlCenter") != NULL ||
                     strcasestr(name, "CCUI") != NULL)) {
            return window;
        }
        UIViewController *controller = window.rootViewController;
        const char *controllerName = class_getName([controller class]);
        if (controllerName && (strcasestr(controllerName, "ControlCenter") != NULL ||
                               strcasestr(controllerName, "CCUI") != NULL)) {
            return window;
        }
        if (!fallback) fallback = window;
    }
    // Fallback: look at the hierarchy, but not more than once every two
    // seconds, because it walks the whole tree.
    double now = CFAbsoluteTimeGetCurrent();
    if (fallback && (now - _lastSubtreeScan) > 2.0) {
        _lastSubtreeScan = now;
        UIView *root = fallback.rootViewController.view ?: fallback;
        if (LGSubtreeLooksLikeControlCenter(root, 8)) return fallback;
    }
    return nil;
}

- (void)startDiscoveryTimer {
    if (_discoveryTimer) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              // v1.0.7: slower initial wake + larger leeway = fewer CPU interrupts
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                              (uint64_t)(kLGDiscoveryInterval * NSEC_PER_SEC),
                              (uint64_t)(0.25 * NSEC_PER_SEC));
    __weak LGPercentageController *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf discoveryTick];
    });
    dispatch_resume(timer);
    _discoveryTimer = timer;
}

- (void)stopDiscoveryTimer {
    if (!_discoveryTimer) return;
    dispatch_source_cancel(_discoveryTimer);
    _discoveryTimer = nil;
}

// The only timer in the module.
//
// It runs once per second while a Control Center window exists and stops as
// soon as the Control Center is gone. It walks the view tree only until a
// slider has been registered; after that the swizzle does all the work.
- (void)discoveryTick {
    [self installSliderHooksIfNeeded];

    UIWindow *window = [self controlCenterWindow];
    if (!window) {
        _discoveryMisses++;
        if (_discoveryMisses >= 2) [self stopDiscoveryTimer];
        return;
    }
    _discoveryMisses = 0;

    if (!_sawControlCenter) {
        _sawControlCenter = YES;
        [self refreshConfiguration];
        [self showLoadBannerIfNeeded];
    } else if (_configurationStale) {
        [self refreshConfiguration];
    }

    if (![self hasActiveSlider]) {
        UIView *root = window.rootViewController.view ?: window;
        [self scanForSlidersInRoot:root];
    }
    [self updateHUD];
}

- (BOOL)hasActiveSlider {
    for (LGSliderState *state in [_states objectEnumerator]) {
        if (state.descriptor) return YES;
    }
    return NO;
}

// The fallback discovery path: a bounded, breadth limited scan that only runs
// until a slider has been registered.
- (void)scanForSlidersInRoot:(UIView *)root {
    if (!root) return;
    // v1.0.7: halve the scan budget and cap branching to bound per-tick work.
    NSUInteger budget = kLGScanBudget / 2;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0 && budget > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        budget--;
        const char *name = class_getName([view class]);
        if (name && strcasestr(name, "slider") != NULL) {
            [self handleSliderEvent:view];
        }
        NSInteger capped = 0;
        for (UIView *sub in view.subviews) {
            if (++capped > 5) break;
            [stack addObject:sub];
        }
    }
}

#pragma mark Fallback HUD

- (void)showLoadBannerIfNeeded {
    if (_bannerShown) return;
    if (!self.configuration.showLoadBanner) return;
    UIWindow *window = [self controlCenterWindow];
    if (!window) return;
    _bannerShown = YES;
    _hudBannerUntil = CFAbsoluteTimeGetCurrent() + 2.5;
    [self updateHUD];
}

- (void)updateHUD {
    double now = CFAbsoluteTimeGetCurrent();
    if (now < _hudBannerUntil) {
        UIWindow *window = [self controlCenterWindow];
        if (!window) return;
        [self showHUDInWindow:window text:@"LiquidGlas 已加载 ✓"];
        return;
    }
    if (!self.configuration.showFallbackHUD) {
        [self hideHUD];
        return;
    }
    if ([self hasActiveSlider]) {
        // A real slider carries the percentage, the HUD would only duplicate it.
        [self hideHUD];
        return;
    }
    UIWindow *window = [self controlCenterWindow];
    if (!window) {
        [self hideHUD];
        return;
    }
    CGFloat volume = LGReadSystemVolume();
    CGFloat brightness = LGReadScreenBrightness();
    NSString *volumeText = (volume >= 0.0)
        ? [NSString stringWithFormat:@"%ld%%", (long)LGPercentFromNormalizedValue(volume)]
        : @"--";
    NSString *brightnessText = (brightness >= 0.0)
        ? [NSString stringWithFormat:@"%ld%%", (long)LGPercentFromNormalizedValue(brightness)]
        : @"--";
    NSString *text = [NSString stringWithFormat:@"音量 %@    亮度 %@",
                      volumeText, brightnessText];
    [self showHUDInWindow:window text:text];
}

- (void)showHUDInWindow:(UIWindow *)window text:(NSString *)text {
    if (!window) return;
    UIView *container = _hudContainer;
    if (!container) {
        container = [[UIView alloc] initWithFrame:CGRectZero];
        container.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.72];
        container.layer.cornerRadius = 12.0;
        container.userInteractionEnabled = NO;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, 174, 18)];
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        [container addSubview:label];
        _hudLabel = label;
        _hudContainer = container;
    }
    CGFloat top = window.safeAreaInsets.top + 8.0;
    container.frame = CGRectMake((CGRectGetWidth(window.bounds) - 190.0) / 2.0,
                                 MAX(top, 20.0), 190.0, 26.0);
    _hudLabel.frame = CGRectMake(8, 4, 174, 18);
    if (![_hudLabel.text isEqualToString:text]) _hudLabel.text = text;
    if (container.superview != window) [window addSubview:container];
    [window bringSubviewToFront:container];
    container.hidden = NO;
    container.alpha = 1.0;
}

- (void)hideHUD {
    UIView *container = _hudContainer;
    if (!container || container.hidden) return;
    container.hidden = YES;
    [container removeFromSuperview];
}

@end

#pragma mark - Swizzle entry points

static void LGSliderLayoutSubviews(id self, SEL _cmd) {
    if (LGOrigLayoutSubviews) {
        ((void (*)(id, SEL))LGOrigLayoutSubviews)(self, _cmd);
    }
    @try {
        [[LGPercentageController sharedController] handleSliderEvent:(UIView *)self];
    } @catch (__unused NSException *exception) {
    }
}

static void LGSliderSetValueFloat(id self, SEL _cmd, float value) {
    if (LGOrigSetValueFloat) {
        ((void (*)(id, SEL, float))LGOrigSetValueFloat)(self, _cmd, value);
    }
    @try {
        [[LGPercentageController sharedController] handleSliderEvent:(UIView *)self];
    } @catch (__unused NSException *exception) {
    }
}

static void LGSliderSetValueDouble(id self, SEL _cmd, double value) {
    if (LGOrigSetValueDouble) {
        ((void (*)(id, SEL, double))LGOrigSetValueDouble)(self, _cmd, value);
    }
    @try {
        [[LGPercentageController sharedController] handleSliderEvent:(UIView *)self];
    } @catch (__unused NSException *exception) {
    }
}

static void LGPreferencesDidChange(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef info) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)info;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[LGPercentageController sharedController] markConfigurationStale];
    });
}

#pragma mark - Bootstrap

__attribute__((constructor))
static void LGPercentageDisplayInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"(none)";
        NSString *process = [[NSProcessInfo processInfo] processName] ?: @"";
        // The widget extension processes are memory constrained and do not host
        // the Control Center, so the module stays out of them.
        if ([process containsString:@"chronod"] ||
            [process containsString:@"WidgetRenderer"] ||
            [process containsString:@"ClockAngel"]) {
            return;
        }
        LGLog(@"percentage module loaded in %@ (%@)", bundle, process);
        [[LGPercentageController sharedController] start];
    });
}

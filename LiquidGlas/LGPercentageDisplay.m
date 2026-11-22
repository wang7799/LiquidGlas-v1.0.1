//
//  LGPercentageDisplay.m  (v1.0.4)
//  LiquidGlas - Control Center volume / brightness percentage overlay
//
//  v1.0.3：修复窗口枚举（UIWindowScene）、通知即时扫描、放宽识别、保底 HUD、诊断日志。
//  v1.0.4：针对 Dopamine RootHide / iOS 17.3.1 再加两条"看得见"的诊断与保底：
//  1. respring 后 1.5 秒显示一次「LiquidGlas 已加载 ✓」横幅 ——
//     看到它 = dylib 已被注入并初始化；看不到 = 注入/越狱状态问题，不用再猜代码。
//  2. 控制中心一出现就主动弹一次「音量 xx% · 亮度 xx%」浮层（不必拖动滑条），
//     避免"只打开看一眼、没触发通知所以什么都没有"的情况。
//
//  数值取自公开 API：AVAudioSession.outputVolume / UIScreen.mainScreen.brightness。
//  不引用私有类头文件、不 hook 私有方法，只依赖公开框架，隐根 / 无根环境均可加载。
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <math.h>

static NSString * const kLGPrefsDomain = @"com.wang7799.liquidglas";
static char kLGPercentLabelKey;
static char kLGPercentKindKey;
static char kLGCachedBoundsKey;
static NSTimeInterval const kLGRefreshInterval = 0.5;

// 控制中心展开/收起的边沿检测（不依赖 window 类名，靠视图类名）
static BOOL LGSawControlCenterView = NO;
static BOOL LGHudShownForPresentation = NO;
static NSUInteger LGNoControlCenterTicks = 0;

typedef NS_ENUM(NSUInteger, LGSliderKind) {
    LGSliderKindNone = 0,
    LGSliderKindVolume,
    LGSliderKindBrightness,
};

#define LGLog(fmt, ...) NSLog((@"[LiquidGlas] " fmt), ##__VA_ARGS__)

#pragma mark - Preferences

static NSDictionary *LGPrefs(void) {
    return [[NSUserDefaults standardUserDefaults] persistentDomainForName:kLGPrefsDomain];
}

static BOOL LGPrefsBool(NSString *key, BOOL defaultValue) {
    id value = LGPrefs()[key];
    return value ? [value boolValue] : defaultValue;
}

static CGFloat LGPrefsFontSize(void) {
    CGFloat size = [LGPrefs()[@"percentageFontSize"] floatValue];
    return (size >= 9.0 && size <= 24.0) ? size : 12.0;
}

#pragma mark - Window enumeration

// iOS 15+ 控制中心可能挂在 UIWindowScene 上，UIApplication.windows 不可靠。
static NSArray<UIWindow *> *LGAllWindows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    NSMutableSet<UIWindow *> *seen = [NSMutableSet set];
    void (^add)(UIWindow *) = ^(UIWindow *window) {
        if (window && ![seen containsObject:window]) {
            [seen addObject:window];
            [result addObject:window];
        }
    };

    for (UIWindow *window in app.windows) add(window);
    add(app.keyWindow);

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in [(UIWindowScene *)scene windows]) add(window);
        }
    }
    return result;
}

static BOOL LGControlCenterVisible(void) {
    for (UIWindow *window in LGAllWindows()) {
        if (window.hidden || window.alpha < 0.01) continue;
        NSString *windowName = NSStringFromClass([window class]).lowercaseString;
        NSString *rootName = NSStringFromClass([window.rootViewController class]).lowercaseString;
        if ([windowName containsString:@"controlcenter"] || [windowName containsString:@"ccui"] ||
            [rootName containsString:@"controlcenter"] || [rootName containsString:@"ccui"]) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - Slider detection

static NSString *LGClassChain(Class cls) {
    NSMutableString *chain = [NSMutableString string];
    for (int i = 0; cls && i < 8; i++, cls = class_getSuperclass(cls)) {
        [chain appendFormat:@"%s ", class_getName(cls)];
    }
    return [chain lowercaseString];
}

static NSString *LGA11yText(UIView *view) {
    return [NSString stringWithFormat:@"%@ %@ %@",
            view.accessibilityIdentifier ?: @"",
            view.accessibilityLabel ?: @"",
            view.accessibilityHint ?: @""].lowercaseString;
}

static BOOL LGHasNumericValue(UIView *view) {
    @try {
        return [[view valueForKey:@"value"] isKindOfClass:[NSNumber class]];
    } @catch (NSException *exception) {
        return NO;
    }
}

static LGSliderKind LGKindForView(UIView *view) {
    if (!view) return LGSliderKindNone;

    NSString *chain = LGClassChain([view class]);
    NSString *a11y = LGA11yText(view);
    CGRect bounds = view.bounds;
    BOOL tall = bounds.size.height > 90.0 && bounds.size.height > bounds.size.width * 1.4;
    BOOL wide = bounds.size.width > 90.0 && bounds.size.width > bounds.size.height * 1.4;

    BOOL relevant = [chain containsString:@"slider"] ||
                    [chain containsString:@"volume"] ||
                    [chain containsString:@"brightness"] ||
                    [chain containsString:@"display"] ||
                    [chain containsString:@"ccui"] ||
                    [chain containsString:@"module"] ||
                    [chain containsString:@"controlcenter"] ||
                    [a11y containsString:@"volume"] ||
                    [a11y containsString:@"brightness"] ||
                    [a11y containsString:@"音量"] ||
                    [a11y containsString:@"亮度"];
    if (!relevant) return LGSliderKindNone;

    BOOL looksLikeSlider = [chain containsString:@"slider"] || LGHasNumericValue(view) || tall || wide;
    if (!looksLikeSlider) return LGSliderKindNone;

    BOOL isVolume = [chain containsString:@"volume"] ||
                    [a11y containsString:@"volume"] || [a11y containsString:@"音量"];
    BOOL isBrightness = [chain containsString:@"brightness"] ||
                        [chain containsString:@"display"] ||
                        [a11y containsString:@"brightness"] || [a11y containsString:@"亮度"];
    if (isVolume && isBrightness) isBrightness = NO;

    if (!isVolume && !isBrightness) {
        UIView *parent = view.superview;
        for (int i = 0; parent && i < 8; i++, parent = parent.superview) {
            NSString *pc = LGClassChain([parent class]);
            NSString *pa = LGA11yText(parent);
            if ([pc containsString:@"volume"] || [pa containsString:@"volume"] || [pa containsString:@"音量"]) {
                isVolume = YES; break;
            }
            if ([pc containsString:@"brightness"] || [pc containsString:@"display"] ||
                [pa containsString:@"brightness"] || [pa containsString:@"亮度"]) {
                isBrightness = YES; break;
            }
        }
    }

    if (isVolume) return LGSliderKindVolume;
    if (isBrightness) return LGSliderKindBrightness;
    return LGSliderKindNone;
}

#pragma mark - Value reading

static CGFloat LGSystemValue(LGSliderKind kind, UIView *slider) {
    CGFloat value = -1.0;
    if (kind == LGSliderKindVolume) {
        value = [AVAudioSession sharedInstance].outputVolume;
    } else if (kind == LGSliderKindBrightness) {
        value = [UIScreen mainScreen].brightness;
    }
    if (value >= 0.0 && value <= 1.0) return value;

    @try {
        id raw = [slider valueForKey:@"value"];
        if ([raw isKindOfClass:[NSNumber class]]) {
            return MIN(MAX([raw floatValue], 0.0), 1.0);
        }
    } @catch (NSException *exception) {}
    return -1.0;
}

#pragma mark - Overlay label on the slider

static UILabel *LGEnsureLabel(UIView *slider, LGSliderKind kind) {
    UILabel *label = objc_getAssociatedObject(slider, &kLGPercentLabelKey);
    BOOL created = NO;
    if (!label) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.backgroundColor = [UIColor clearColor];
        label.textColor = [UIColor colorWithWhite:1.0 alpha:0.95];
        label.textAlignment = NSTextAlignmentCenter;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.7;
        label.userInteractionEnabled = NO;
        label.layer.shadowColor = [UIColor blackColor].CGColor;
        label.layer.shadowOffset = CGSizeMake(0, 0.5);
        label.layer.shadowOpacity = 0.55;
        label.layer.shadowRadius = 2.0;
        label.tag = 0x4C4750;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
        objc_setAssociatedObject(slider, &kLGPercentLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(slider, &kLGPercentKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        created = YES;
    }
    if (label.superview != slider) {
        [slider addSubview:label];
        created = YES;
    }

    CGFloat fontSize = LGPrefsFontSize();
    CGRect bounds = slider.bounds;
    NSValue *cached = objc_getAssociatedObject(slider, &kLGCachedBoundsKey);
    if (created || label.font.pointSize != fontSize || !CGRectEqualToRect(bounds, [cached CGRectValue])) {
        label.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
        BOOL portrait = bounds.size.height > bounds.size.width * 1.3;
        CGFloat h = MAX(fontSize + 4.0, 16.0);
        label.frame = portrait
            ? CGRectMake(2.0, 6.0, MAX(bounds.size.width - 4.0, 24.0), h)
            : CGRectMake(MAX(bounds.size.width - 48.0, 0.0), (bounds.size.height - h) / 2.0, 44.0, h);
        objc_setAssociatedObject(slider, &kLGCachedBoundsKey,
                                 [NSValue valueWithCGRect:bounds],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [slider bringSubviewToFront:label];
    }
    return label;
}

static void LGUpdateLabel(UIView *slider) {
    if (slider.hidden || slider.alpha < 0.01) return;

    NSNumber *kindBox = objc_getAssociatedObject(slider, &kLGPercentKindKey);
    LGSliderKind kind = (LGSliderKind)[kindBox integerValue];
    if (kind == LGSliderKindNone) return;

    BOOL enabled = (kind == LGSliderKindVolume)
        ? LGPrefsBool(@"showVolumePercentage", YES)
        : LGPrefsBool(@"showBrightnessPercentage", YES);

    UILabel *label = LGEnsureLabel(slider, kind);
    label.hidden = !enabled;
    if (!enabled) return;

    CGFloat value = LGSystemValue(kind, slider);
    if (value < 0.0) { label.text = nil; return; }

    int percent = MIN(MAX((int)lroundf(value * 100.0), 0), 100);
    NSString *text = [NSString stringWithFormat:@"%d%%", percent];
    if (![label.text isEqualToString:text]) label.text = text;
}

#pragma mark - Discovery & refresh

static NSHashTable<UIView *> *LGTrackedSliders(void) {
    static NSHashTable<UIView *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static void LGScanView(UIView *view, NSUInteger depth) {
    if (depth > 20) return;

    // 控制中心不一定是独立 window，靠视图类名判断它是否展开
    NSString *className = NSStringFromClass([view class]).lowercaseString;
    if ([className containsString:@"ccui"] ||
        [className containsString:@"controlcenter"] ||
        [className containsString:@"module"]) {
        LGSawControlCenterView = YES;
    }

    LGSliderKind kind = LGKindForView(view);
    if (kind != LGSliderKindNone && ![LGTrackedSliders() containsObject:view]) {
        [LGTrackedSliders() addObject:view];
        objc_setAssociatedObject(view, &kLGPercentKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGLog(@"found %@ slider: %@ (%.0f%%)",
              kind == LGSliderKindVolume ? @"volume" : @"brightness",
              NSStringFromClass([view class]), LGSystemValue(kind, view) * 100.0);
    }
    for (UIView *subview in view.subviews) LGScanView(subview, depth + 1);
}

static void LGScanWindows(void) {
    LGSawControlCenterView = NO;
    for (UIWindow *window in LGAllWindows()) {
        if (window.hidden || window.alpha < 0.01) continue;
        LGScanView(window, 0);
    }
}

static void LGRefresh(void) {
    for (UIView *slider in [LGTrackedSliders() allObjects]) LGUpdateLabel(slider);
}

static BOOL LGHasVisibleSlider(LGSliderKind kind) {
    for (UIView *slider in [LGTrackedSliders() allObjects]) {
        if (slider.hidden || slider.alpha < 0.01) continue;
        NSNumber *box = objc_getAssociatedObject(slider, &kLGPercentKindKey);
        if ([box integerValue] == kind) return YES;
    }
    return NO;
}

#pragma mark - Fallback HUD

static UIView *LGHudContainer(void) {
    static UIView *hud;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        blur.frame = CGRectMake(0, 0, 220, 34);
        blur.layer.cornerRadius = 17.0;
        blur.clipsToBounds = YES;
        blur.userInteractionEnabled = NO;
        UILabel *label = [[UILabel alloc] initWithFrame:blur.bounds];
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.7;
        label.tag = 0x4C4748;
        [blur.contentView addSubview:label];
        hud = blur;
    });
    return hud;
}

static void LGShowFallbackHUD(NSString *text) {
    UIWindow *target = nil;
    for (UIWindow *window in [LGAllWindows() reverseObjectEnumerator]) {
        if (!window.hidden && window.alpha > 0.01) { target = window; break; }
    }
    if (!target) return;

    UIView *hud = LGHudContainer();
    UILabel *label = [hud viewWithTag:0x4C4748];
    label.text = text;

    CGFloat top = 20.0;
    if (@available(iOS 11.0, *)) top = target.safeAreaInsets.top + 8.0;
    hud.frame = CGRectMake((target.bounds.size.width - 220.0) / 2.0, MAX(top, 20.0), 220.0, 34.0);
    [hud.layer removeAllAnimations];
    hud.alpha = 1.0;
    [target addSubview:hud];
    [target bringSubviewToFront:hud];
    LGLog(@"HUD: %@ on %@", text, NSStringFromClass([target class]));

    [UIView animateWithDuration:0.25 delay:1.6 options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ hud.alpha = 0.0; }
                     completion:^(BOOL finished) { [hud removeFromSuperview]; hud.alpha = 1.0; }];
}

// 拖动必然触发亮度/音量通知：立刻扫描，找不到滑块就显示保底浮层
static void LGOnValueChanged(LGSliderKind kind) {
    LGScanWindows();
    LGRefresh();

    BOOL enabled = (kind == LGSliderKindVolume)
        ? LGPrefsBool(@"showVolumePercentage", YES)
        : LGPrefsBool(@"showBrightnessPercentage", YES);
    if (!enabled) return;
    if (LGHasVisibleSlider(kind)) return;
    if (!LGPrefsBool(@"showFallbackHUD", YES)) return;

    CGFloat value = (kind == LGSliderKindVolume)
        ? [AVAudioSession sharedInstance].outputVolume
        : [UIScreen mainScreen].brightness;
    value = MIN(MAX(value, 0.0), 1.0);
    NSString *title = (kind == LGSliderKindVolume) ? @"音量" : @"亮度";
    LGShowFallbackHUD([NSString stringWithFormat:@"%@ %d%%", title, (int)lroundf(value * 100.0)]);
}

// 控制中心一出现就主动显示一次，不需要用户先拖动滑条
static void LGOnControlCenterAppeared(void) {
    LGRefresh();
    if (!LGPrefsBool(@"showFallbackHUD", YES)) return;
    if (LGHasVisibleSlider(LGSliderKindVolume) && LGHasVisibleSlider(LGSliderKindBrightness)) return;

    CGFloat volume = MIN(MAX([AVAudioSession sharedInstance].outputVolume, 0.0), 1.0);
    CGFloat brightness = MIN(MAX([UIScreen mainScreen].brightness, 0.0), 1.0);
    NSString *text = [NSString stringWithFormat:@"音量 %d%% · 亮度 %d%%",
                        (int)lroundf(volume * 100.0), (int)lroundf(brightness * 100.0)];
    LGShowFallbackHUD(text);
    LGLog(@"control center appeared: %@", text);
}

// respring 后的注入确认横幅：看到它 = dylib 已被加载并初始化
static void LGShowLoadBanner(void) {
    if (!LGPrefsBool(@"showLoadBanner", YES)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LGLog(@"load banner, windows=%lu, bundle=%@",
              (unsigned long)LGAllWindows().count,
              [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)");
        LGShowFallbackHUD(@"LiquidGlas 已加载 ✓");
    });
}

#pragma mark - Bootstrap

__attribute__((constructor))
static void LGPercentageDisplayInit(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

    // dylib 的 constructor 早于 UIApplication 初始化，推迟到主队列
    dispatch_async(dispatch_get_main_queue(), ^{
        LGLog(@"loaded, windows=%lu", (unsigned long)LGAllWindows().count);

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];

        [center addObserverForName:UIScreenBrightnessDidChangeNotification
                            object:nil queue:mainQueue
                        usingBlock:^(NSNotification *note) { LGOnValueChanged(LGSliderKindBrightness); }];

        [center addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
                            object:nil queue:mainQueue
                        usingBlock:^(NSNotification *note) { LGOnValueChanged(LGSliderKindVolume); }];

        for (NSString *name in @[UIWindowDidBecomeVisibleNotification,
                                  UIWindowDidBecomeKeyNotification,
                                  UIApplicationDidBecomeActiveNotification]) {
            [center addObserverForName:name object:nil queue:mainQueue
                          usingBlock:^(NSNotification *note) { LGScanWindows(); LGRefresh(); }];
        }

        __block NSUInteger tick = 0;
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:kLGRefreshInterval
                                                         repeats:YES
                                                           block:^(NSTimer *t) {
            tick++;
            // 每次都扫，保证控制中心一展开就能捕获滑条；视图释放后 weak 表自动清理
            LGScanWindows();
            LGRefresh();

            if (LGSawControlCenterView || LGControlCenterVisible()) {
                LGNoControlCenterTicks = 0;
                if (!LGHudShownForPresentation) {
                    LGHudShownForPresentation = YES;
                    LGOnControlCenterAppeared();
                }
            } else if (++LGNoControlCenterTicks > 6) {
                // 约 3 秒没看到控制中心视图，视为已收起，下次展开重新弹
                LGHudShownForPresentation = NO;
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];

        LGScanWindows();
        LGRefresh();
        // SpringBoard 启动稍晚时控制中心视图才建立，补一次延迟扫描
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ LGScanWindows(); LGRefresh(); });
        LGShowLoadBanner();
    });
}
